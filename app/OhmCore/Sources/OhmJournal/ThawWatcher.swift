import Darwin
import Foundation

/// `ohm-thawd` (ADR 0004 § 6 "Kilit protokolü"). Holds `thawd.lock` for life as its liveness signal,
/// sleeps in the kernel (kqueue or flock) and runs `JournalRecovery` whenever `owner.lock` becomes free
/// while the journal still has open groups.
public enum ThawWatcher {
    public enum Mode: Sendable, Equatable {
        /// LaunchAgent (`KeepAlive`): lives forever.
        case agent
        /// Spawned by Ohm (`--spawned`): retries after Ohm dies until no open effect remains.
        case spawned
    }

    /// Command-line entry used by `ohm-thawd/main.swift` and the test host.
    ///   ohm-thawd [--spawned] [--dir <journal dir>]
    public static func main(arguments: [String]) -> Never {
        var mode = Mode.agent
        var paths = JournalPaths.standard
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--spawned": mode = .spawned
            case "--dir" where i + 1 < arguments.count:
                i += 1
                paths = JournalPaths(directory: arguments[i])
            default: break
            }
            i += 1
        }
        run(paths: paths, mode: mode)
    }

    public static func run(paths: JournalPaths, mode: Mode) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Never let a terminal hang-up or a closed pipe take the watcher down.
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        paths.ensureDirectory()

        let thawdLock: FileLock
        do { thawdLock = try FileLock(path: paths.thawdLock) } catch {
            log("cannot open thawd.lock: \(error)")
            exit(1)
        }
        // One spawned protector is sufficient. Do not accumulate blocked children on every launch.
        if mode == .spawned, !thawdLock.tryLockExclusive() {
            log("another watcher is already protecting the journal")
            exit(0)
        }
        // LaunchAgent waits and takes over when an existing watcher dies.
        guard mode == .spawned || thawdLock.lockExclusiveBlocking() else {
            log("cannot lock thawd.lock errno=\(errno)")
            exit(1)
        }
        log("ready mode=\(mode) pid=\(getpid())")

        switch mode {
        case .spawned:
            // Ohm spawned us while holding owner.lock, so blocking here is "wait for Ohm to die".
            spawnedLoop(paths: paths)
            withExtendedLifetime(thawdLock) {}
            exit(0)
        case .agent:
            agentLoop(paths: paths)
            withExtendedLifetime(thawdLock) {}
            exit(0)
        }
    }

    /// Bounded recovery lifetime: missing provenance cannot improve, persistent faults get 16
    /// attempts. Records remain durable for the next owner or explicit user resolution.
    static func spawnedLoop(paths: JournalPaths, recover: (() -> RecoveryReport?)? = nil,
                            pause: ((Double) -> Void)? = nil,
                            emitLog: (String) -> Void = log,
                            shouldStop: () -> Bool = { false }) {
        var failures = 0
        var previousSummary: String?
        while !shouldStop() {
            let report: RecoveryReport?
            if let recover { report = recover() } else { report = recoverOnce(paths: paths) }
            logChanged(report, previous: &previousSummary, emitLog: emitLog)
            if let report, !report.needsRetry, !hasOpenGroups(paths) { return }
            if let report, !report.needsRetry, !report.missingRecordedBoot.isEmpty,
               JournalReader.read(path: paths.journal).openGroups().allSatisfy({ $0.boot == nil }) {
                emitLog("recorded boot is missing; explicit user resolution required")
                return
            }
            failures += 1
            if failures >= 16 {
                emitLog("recovery retry budget exhausted; records retained for next launch or user resolution")
                return
            }
            let delay = retryDelay(failures)
            if let pause { pause(delay) } else { waitForChange(paths: paths, timeoutSeconds: delay) }
        }
    }

    static func retryDelay(_ failures: Int) -> Double {
        min(300.0, 0.1 * pow(2, Double(min(failures - 1, 12))))
    }

    /// LaunchAgent loop. After every recovery the journal is checked again *after* the watch is
    /// armed (a new Ohm may have written and died in between, T-024 #3). If recovery could not
    /// finish (unresolved members, failed rewrite) it is retried with a bounded backoff (≤ 300 s)
    /// instead of spinning.
    public static func agentLoop(paths: JournalPaths, pollTimeoutSeconds: Int = 60,
                                 afterRecovery: (() -> Void)? = nil, shouldStop: () -> Bool = { false }) {
        var failures = 0
        var previousSummary: String?
        var onlyMissingBoot = false
        while !shouldStop() {
            if onlyMissingBoot {
                waitForChange(paths: paths, timeoutSeconds: Double(pollTimeoutSeconds), recheck: {
                    JournalReader.read(path: paths.journal).openGroups().contains { $0.boot != nil }
                })
            } else {
                waitForOpenGroups(paths: paths, timeoutSeconds: pollTimeoutSeconds, shouldStop: shouldStop)
            }
            if shouldStop() { return }
            let r = recoverOnce(paths: paths)
            logChanged(r, previous: &previousSummary)
            afterRecovery?()
            if r == nil || r?.needsRetry == true {
                failures = min(failures + 1, 13)
                waitForChange(paths: paths, timeoutSeconds: retryDelay(failures))
            } else {
                failures = 0
            }
            onlyMissingBoot = r?.needsRetry == false && r?.missingRecordedBoot.isEmpty == false
        }
    }

    @discardableResult
    static func recoverOnce(paths: JournalPaths) -> RecoveryReport? {
        let lock: OwnerLock
        do { lock = try OwnerLock.acquireBlocking(paths: paths) } catch {
            log("cannot lock owner.lock: \(error)")
            return nil
        }
        let me = JournalPid(pid: getpid(), start: ProcessProbe.startAbs(getpid()) ?? 0)
        let r = JournalRecovery.run(lock: lock, owner: me, consumeNotices: false)
        lock.release()
        return r
    }

    static func hasOpenGroups(_ paths: JournalPaths) -> Bool {
        !JournalReader.read(path: paths.journal).openGroups().isEmpty
    }

    static func waitForOpenGroups(paths: JournalPaths, timeoutSeconds: Int = 60, shouldStop: () -> Bool = { false }) {
        while !hasOpenGroups(paths), !shouldStop() {
            waitForChange(paths: paths, timeoutSeconds: Double(timeoutSeconds), recheck: { hasOpenGroups(paths) })
        }
    }

    /// Blocks in kevent() until the journal file or its directory changes, or the timeout expires.
    /// The directory is watched because recovery replaces the file with `rename`; the file itself is
    /// watched because appends do not modify the directory.
    static func waitForChange(paths: JournalPaths, timeoutSeconds: Double, recheck: (() -> Bool)? = nil) {
        let kq = kqueue()
        guard kq >= 0 else { usleep(useconds_t(timeoutSeconds * 1e6)); return }
        defer { close(kq) }
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for path in [paths.directory, paths.journal] {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            fds.append(fd)
            var ev = kevent(
                ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE | NOTE_ATTRIB),
                data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }
        // Close the race between the caller's check and arming the watch.
        if let recheck, recheck() { return }
        var out = kevent()
        let seconds = Int(timeoutSeconds)
        var ts = timespec(tv_sec: seconds, tv_nsec: Int((timeoutSeconds - Double(seconds)) * 1e9))
        _ = kevent(kq, nil, 0, &out, 1, &ts)
    }

    static func summary(_ r: RecoveryReport?) -> String {
        guard let r else { return "recovery unavailable" }
        return "recovery groups=\(r.openGroupsFound) thawed=\(r.thawed.map(\.pid)) ecoreCleared=\(r.eCoreCleared.map(\.pid)) skipped=\(r.skippedIdentity.map(\.pid)) unresolved=\(r.unresolved.map(\.pid)) unverifiedBoot=\(r.unverifiedBoot.map(\.pid)) missingRecordedBoot=\(r.missingRecordedBoot.map(\.pid)) bootDiscarded=\(r.discardedForBoot) corrupt=\(r.corrupt) rewriteFailed=\(r.rewriteFailed)"
    }

    private static func logChanged(_ report: RecoveryReport?, previous: inout String?, emitLog: (String) -> Void = log) {
        let current = summary(report)
        if current != previous { emitLog(current); previous = current }
    }

    static func log(_ s: String) {
        let t = clock_gettime_nsec_np(CLOCK_REALTIME)
        print("[\(t)] ohm-thawd: \(s)")
    }
}

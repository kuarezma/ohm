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
        // Another watcher already holds it: wait and take over when it dies (0 CPU while blocked).
        guard thawdLock.lockExclusiveBlocking() else {
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

    /// The spawned watcher keeps its liveness lock until recovery verifies every effect is undone.
    static func spawnedLoop(paths: JournalPaths, recover: (() -> RecoveryReport?)? = nil,
                            pause: (Double) -> Void = { usleep(useconds_t($0 * 1e6)) },
                            shouldStop: () -> Bool = { false }) {
        var failures = 0
        while !shouldStop() {
            let report: RecoveryReport?
            if let recover { report = recover() } else { report = recoverOnce(paths: paths) }
            if let report, !report.needsRetry, !hasOpenGroups(paths) { return }
            failures = min(failures + 1, 7)
            pause(retryDelay(failures))
        }
    }

    private static func retryDelay(_ failures: Int) -> Double {
        min(5.0, 0.1 * pow(2, Double(failures - 1)))
    }

    /// LaunchAgent loop. After every recovery the journal is checked again *after* the watch is
    /// armed (a new Ohm may have written and died in between, T-024 #3). If recovery could not
    /// finish (unresolved members, failed rewrite) it is retried with a bounded backoff (≤ 5 s)
    /// instead of spinning.
    public static func agentLoop(paths: JournalPaths, pollTimeoutSeconds: Int = 60,
                                 afterRecovery: (() -> Void)? = nil, shouldStop: () -> Bool = { false }) {
        var failures = 0
        while !shouldStop() {
            waitForOpenGroups(paths: paths, timeoutSeconds: pollTimeoutSeconds, shouldStop: shouldStop)
            if shouldStop() { return }
            let r = recoverOnce(paths: paths)
            afterRecovery?()
            if r == nil || r?.needsRetry == true {
                failures = min(failures + 1, 7)
                usleep(useconds_t(retryDelay(failures) * 1e6))
            } else {
                failures = 0
            }
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
        log("recovery groups=\(r.openGroupsFound) thawed=\(r.thawed.map(\.pid)) ecoreCleared=\(r.eCoreCleared.map(\.pid)) skipped=\(r.skippedIdentity.map(\.pid)) unresolved=\(r.unresolved.map(\.pid)) unverifiedBoot=\(r.unverifiedBoot.map(\.pid)) bootDiscarded=\(r.discardedForBoot) corrupt=\(r.corrupt) rewriteFailed=\(r.rewriteFailed)")
        lock.release()
        return r
    }

    static func hasOpenGroups(_ paths: JournalPaths) -> Bool {
        !JournalReader.read(path: paths.journal).openGroups().isEmpty
    }

    static func waitForOpenGroups(paths: JournalPaths, timeoutSeconds: Int = 60, shouldStop: () -> Bool = { false }) {
        while !hasOpenGroups(paths), !shouldStop() {
            waitForChange(paths: paths, timeoutSeconds: timeoutSeconds, recheck: { hasOpenGroups(paths) })
        }
    }

    /// Blocks in kevent() until the journal file or its directory changes, or the timeout expires.
    /// The directory is watched because recovery replaces the file with `rename`; the file itself is
    /// watched because appends do not modify the directory.
    static func waitForChange(paths: JournalPaths, timeoutSeconds: Int, recheck: (() -> Bool)? = nil) {
        let kq = kqueue()
        guard kq >= 0 else { sleep(UInt32(timeoutSeconds)); return }
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
        var ts = timespec(tv_sec: timeoutSeconds, tv_nsec: 0)
        _ = kevent(kq, nil, 0, &out, 1, &ts)
    }

    static func log(_ s: String) {
        let t = clock_gettime_nsec_np(CLOCK_REALTIME)
        print("[\(t)] ohm-thawd: \(s)")
    }
}

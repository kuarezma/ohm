import Darwin
import Foundation
import OhmModel

public struct RecoveryReport: Sendable {
    /// Groups from another boot session were discarded without any signal (§ 5 rule 2).
    public var discardedForBoot = false
    /// Groups whose boot session could not be established (no `open` record, or the current boot
    /// is unreadable). Not a match (D3): no signal; left to the launch-time SSTOP scan and the user.
    public var unverifiedBoot: [JournalPid] = []
    public var corrupt = false
    public var ignoredTail = false
    /// Processes that received SIGCONT (helpers first, then root, per group).
    public var thawed: [JournalPid] = []
    /// Processes whose PRIO_DARWIN_BG policy was removed.
    public var eCoreCleared: [JournalPid] = []
    /// Entries that are gone or whose pid now belongs to another process: nothing to undo (D3).
    public var skippedIdentity: [JournalPid] = []
    /// Entries that could not be resolved (probe error or failed signal). Kept open in the journal
    /// and retried; never forgotten (T-024 #1).
    public var unresolved: [JournalPid] = []
    public var apps: [String] = []
    /// `recovered` notices written by an earlier recovery (e.g. by ohm-thawd), for the UI (§ 9).
    public var notices: [JournalRecord] = []
    public var openGroupsFound: Int = 0
    /// The journal could not be rewritten; the caller must not enable effects (T-024 #2).
    public var rewriteFailed = false
}

/// How recovery reaches processes; tests inject failures.
public protocol RecoverySignaling {
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus
    /// Returns 0 or errno.
    func sendCont(_ pid: Int32) -> Int32
    /// Removes PRIO_DARWIN_BG. Returns 0 or errno.
    func clearBackground(_ pid: Int32) -> Int32
}

public struct LiveRecoverySignaler: RecoverySignaling {
    public init() {}
    public func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus { ProcessProbe.identityStatus(id) }
    public func sendCont(_ pid: Int32) -> Int32 {
        guard pid > 1 else { return EINVAL }
        return kill(pid, SIGCONT) == 0 ? 0 : errno
    }
    public func clearBackground(_ pid: Int32) -> Int32 {
        guard pid > 1 else { return EINVAL }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) == 0 ? 0 : errno
    }
}

/// ADR 0004 § 5 "Okuma ve kurtarma". Shared by Ohm (launch), `ohm-thawd` and `ohm thaw --all`.
public enum JournalRecovery {
    /// - Parameters:
    ///   - lock: proof that the caller holds `owner.lock` (§ 5 rule 1).
    ///   - owner: identity written into the fresh `open` record after compaction.
    ///   - consumeNotices: Ohm passes true after it has shown the notices; the watcher keeps them.
    @discardableResult
    public static func run(lock: OwnerLock, owner: JournalPid, consumeNotices: Bool,
                           signaler: any RecoverySignaling = LiveRecoverySignaler()) -> RecoveryReport {
        let paths = lock.paths
        var report = RecoveryReport()
        let snap = JournalReader.read(path: paths.journal)
        let currentBoot = ProcessProbe.bootSessionUUID()
        report.corrupt = snap.corrupt
        report.ignoredTail = snap.ignoredTail
        report.notices = snap.records.filter { $0.op == .recovered }

        let groups = snap.openGroups()
        report.openGroupsFound = groups.count
        var retained: [JournalRecord] = []
        for g in groups {
            // D3: start times are only comparable within one boot session. Unknown on either side
            // is not a match.
            guard let b = g.boot, let cur = currentBoot else {
                report.unverifiedBoot += g.pids
                continue
            }
            guard b == cur else {
                report.discardedForBoot = true
                continue
            }
            if let app = g.app, !report.apps.contains(app) { report.apps.append(app) }
            var pending: [JournalPid] = []
            let order: [JournalPid]
            switch g.kind {
            case .freeze:
                // Helpers first (reverse journal order), root last (§ 3).
                order = g.pids.filter { $0.role != .root }.reversed() + g.pids.filter { $0.role == .root }
            case .eCore:
                order = g.pids.reversed()
            }
            for p in order {
                switch signaler.identityStatus(p.identity) {
                case .gone, .mismatch:
                    report.skippedIdentity.append(p)
                case .unknown:
                    pending.append(p)
                case .match:
                    let rc = g.kind == .freeze ? signaler.sendCont(p.pid) : signaler.clearBackground(p.pid)
                    if rc == 0 {
                        if g.kind == .freeze { report.thawed.append(p) } else { report.eCoreCleared.append(p) }
                    } else if rc == ESRCH {
                        report.skippedIdentity.append(p)
                    } else {
                        pending.append(p)
                    }
                }
            }
            if !pending.isEmpty {
                report.unresolved += pending
                retained.append(JournalRecord(op: g.kind == .freeze ? .freeze : .ecore, group: g.group, app: g.app,
                                              origin: "recovery", pids: pending))
            }
        }

        // § 5 rules 6 and 7: note what was done, then rewrite the file as `open` + notices + the
        // groups that are still unresolved (after the notices: a `recovered` record closes what precedes it).
        var kept = consumeNotices ? [] : report.notices
        let signalled = report.thawed.count + report.eCoreCleared.count
        if signalled > 0 || !report.unverifiedBoot.isEmpty {
            var n = JournalRecord(op: .recovered, count: signalled, apps: report.apps)
            if !report.unverifiedBoot.isEmpty { n.reason = "unverifiedBoot:\(report.unverifiedBoot.count)" }
            kept.append(n)
        }
        report.rewriteFailed = !rewrite(paths: paths, boot: currentBoot, owner: owner, keeping: kept + retained)
        return report
    }

    /// § 5 rule 7. With nothing to keep: `ftruncate` + fresh `open`. Otherwise `journal.jsonl.tmp`,
    /// `fsync`, `rename`. Returns false if the result is not a complete, fsynced journal.
    static func rewrite(paths: JournalPaths, boot: String?, owner: JournalPid, keeping: [JournalRecord]) -> Bool {
        var records = [JournalRecord(op: .open, boot: boot, owner: owner)] + keeping
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for i in records.indices {
            records[i].seq = UInt64(i + 1)
            if records[i].ts == 0 { records[i].ts = now }
        }
        guard let body = try? records.reduce(into: Data(), { $0.append(try $1.encodedLine()) }) else { return false }
        if keeping.isEmpty {
            let fd = open(paths.journal, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard ftruncate(fd, 0) == 0 else { return false }
            guard (try? FreezeJournal.writeAll(fd, body)) != nil, fsync(fd) == 0 else {
                // Leave an empty file rather than a partial line; the caller disables effects.
                _ = ftruncate(fd, 0)
                return false
            }
            return true
        }
        let fd = open(paths.journalTmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let ok = (try? FreezeJournal.writeAll(fd, body)) != nil && fsync(fd) == 0
        close(fd)
        guard ok, rename(paths.journalTmp, paths.journal) == 0 else {
            unlink(paths.journalTmp)
            return false
        }
        return true
    }
}

/// Ohm launch sequence (§ 6 "Ohm açılışı"): lock, recover leftovers, open the writer.
/// Throws unless a valid, fsynced journal exists afterwards: effects stay off without one.
public enum JournalSession {
    public static func open(paths: JournalPaths, ownerLockRetry: Double = 5) throws -> (FreezeJournal, RecoveryReport) {
        let lock = try OwnerLock.acquire(paths: paths, retryFor: ownerLockRetry)
        let me = JournalPid(pid: getpid(), start: ProcessProbe.startAbs(getpid()) ?? 0)
        let report = JournalRecovery.run(lock: lock, owner: me, consumeNotices: true)
        if report.rewriteFailed { throw JournalError.rewriteFailed }
        let journal = try FreezeJournal(paths: paths, ownerLock: lock, owner: me)
        return (journal, report)
    }
}

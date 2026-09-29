import Darwin
import Foundation
import OhmModel

public struct RecoveryReport: Sendable {
    /// The journal came from another boot session and was discarded without any signal (§ 5 rule 2).
    public var discardedForBoot = false
    public var corrupt = false
    public var ignoredTail = false
    /// Processes that received SIGCONT (helpers first, then root, per group).
    public var thawed: [JournalPid] = []
    /// Processes whose PRIO_DARWIN_BG policy was removed.
    public var eCoreCleared: [JournalPid] = []
    /// Journal entries whose (pid, start) no longer matched a live process: not signalled (D3).
    public var skippedIdentity: [JournalPid] = []
    public var apps: [String] = []
    /// `recovered` notices written by an earlier recovery (e.g. by ohm-thawd), for the UI (§ 9).
    public var notices: [JournalRecord] = []
    public var openGroupsFound: Int = 0
}

/// ADR 0004 § 5 "Okuma ve kurtarma". Shared by Ohm (launch), `ohm-thawd` and `ohm thaw --all`.
public enum JournalRecovery {
    /// - Parameters:
    ///   - lock: proof that the caller holds `owner.lock` (§ 5 rule 1).
    ///   - owner: identity written into the fresh `open` record after compaction.
    ///   - consumeNotices: Ohm passes true after it has shown the notices; the watcher keeps them.
    @discardableResult
    public static func run(lock: OwnerLock, owner: JournalPid, consumeNotices: Bool) -> RecoveryReport {
        let paths = lock.paths
        var report = RecoveryReport()
        let snap = JournalReader.read(path: paths.journal)
        let currentBoot = ProcessProbe.bootSessionUUID()
        report.corrupt = snap.corrupt
        report.ignoredTail = snap.ignoredTail
        report.notices = snap.records.filter { $0.op == .recovered }

        let groups = snap.openGroups()
        report.openGroupsFound = groups.count
        for g in groups {
            // § 5 rule 2 / D3: start times from another boot session mean nothing. If either boot is
            // unknown (no `open` record, sysctl failure) we still signal, but only after the identity
            // check — SIGCONT and "remove BG" to a verified process are harmless; leaving one stopped is not.
            if let b = g.boot, let cur = currentBoot, b != cur {
                report.discardedForBoot = true
                continue
            }
            if let app = g.app, !report.apps.contains(app) { report.apps.append(app) }
            switch g.kind {
            case .freeze:
                // Helpers first (reverse journal order), root last (§ 3).
                let roots = g.pids.filter { $0.role == .root }
                let helpers = g.pids.filter { $0.role != .root }
                for p in helpers.reversed() + roots {
                    if p.pid > 1, ProcessProbe.matches(p.identity) {
                        kill(p.pid, SIGCONT)
                        report.thawed.append(p)
                    } else {
                        report.skippedIdentity.append(p)
                    }
                }
            case .eCore:
                for p in g.pids.reversed() {
                    if p.pid > 1, ProcessProbe.matches(p.identity) {
                        setpriority(PRIO_DARWIN_PROCESS, id_t(p.pid), 0)
                        report.eCoreCleared.append(p)
                    } else {
                        report.skippedIdentity.append(p)
                    }
                }
            }
        }

        // § 5 rules 6 and 7: note what was done, then rewrite the file as `open` (+ kept notices).
        var kept = consumeNotices ? [] : report.notices
        let signalled = report.thawed.count + report.eCoreCleared.count
        if signalled > 0 {
            kept.append(JournalRecord(op: .recovered, count: signalled, apps: report.apps))
        }
        rewrite(paths: paths, boot: currentBoot, owner: owner, keeping: kept)
        return report
    }

    /// § 5 rule 7. With nothing to keep: `ftruncate` + fresh `open`. Otherwise `journal.jsonl.tmp`,
    /// `fsync`, `rename` (the watcher watches the directory, so the rename is safe).
    static func rewrite(paths: JournalPaths, boot: String?, owner: JournalPid, keeping: [JournalRecord]) {
        var records = [JournalRecord(op: .open, boot: boot, owner: owner)] + keeping
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for i in records.indices {
            records[i].seq = UInt64(i + 1)
            if records[i].ts == 0 { records[i].ts = now }
        }
        guard let body = try? records.reduce(into: Data(), { $0.append(try $1.encodedLine()) }) else { return }
        if keeping.isEmpty {
            let fd = open(paths.journal, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            guard ftruncate(fd, 0) == 0 else { return }
            _ = try? FreezeJournal.writeAll(fd, body)
            fsync(fd)
        } else {
            let fd = open(paths.journalTmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            let ok = (try? FreezeJournal.writeAll(fd, body)) != nil && fsync(fd) == 0
            close(fd)
            if ok { rename(paths.journalTmp, paths.journal) } else { unlink(paths.journalTmp) }
        }
    }
}

/// Ohm launch sequence (§ 6 "Ohm açılışı"): lock, recover leftovers, open the writer.
public enum JournalSession {
    public static func open(paths: JournalPaths, ownerLockRetry: Double = 5) throws -> (FreezeJournal, RecoveryReport) {
        let lock = try OwnerLock.acquire(paths: paths, retryFor: ownerLockRetry)
        let me = JournalPid(pid: getpid(), start: ProcessProbe.startAbs(getpid()) ?? 0)
        let report = JournalRecovery.run(lock: lock, owner: me, consumeNotices: true)
        let journal = try FreezeJournal(paths: paths, ownerLock: lock, owner: me)
        return (journal, report)
    }
}

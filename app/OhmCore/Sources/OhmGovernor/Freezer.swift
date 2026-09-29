import Darwin
import Foundation
import OhmJournal
import OhmModel

struct FrozenGroup: Sendable {
    let id: UUID
    let app: RunningAppInfo
    let key: AppKey?
    let origin: EffectOrigin
    var root: ProcessIdentity { app.identity }
    /// In stop order; thawed in reverse.
    var helpers: [ProcessIdentity]
    let hiddenByOhm: Bool
    let frozenAt: Date
    let deadline: Date
    var byRule: Bool { origin.isRule }
    var members: [ProcessIdentity] { [root] + helpers }
}

enum FreezeFailure: Error {
    case journal(JournalError)
    case identityMismatch(Int32)
    case signal(Int32, Int32)
    case tableFull
    case veto([FreezeVeto])
    case unstableTree
    case verifyTimeout([Int32])

    var thawReason: ThawReason {
        switch self {
        case .verifyTimeout: .verifyFailed
        default: .rollback
        }
    }
}

/// Phase B mechanics of ADR 0004 § 4: write-ahead journal, stop root then helpers to a fixed point,
/// verify, and all-or-nothing rollback. Everything here is synchronous: no suspension point (D4).
final class Freezer {
    let signaler: any ProcessSignaling
    let tree: any ProcessTreeEnumerating
    let policy: SafetyPolicy
    let config: GovernorConfig

    init(signaler: any ProcessSignaling, tree: any ProcessTreeEnumerating, policy: SafetyPolicy, config: GovernorConfig) {
        self.signaler = signaler
        self.tree = tree
        self.policy = policy
        self.config = config
    }

    struct Request {
        let group: UUID
        let app: RunningAppInfo
        let origin: EffectOrigin
        let hiddenByOhm: Bool
        /// Background processes are frozen alone; their children keep running (§ 2).
        let withTree: Bool
    }

    /// Returns the helpers in stop order, or rolls everything back and returns the failure.
    func freeze(_ r: Request, journal: any FreezeJournaling) -> Result<[ProcessIdentity], FreezeFailure> {
        var stopped: [ProcessIdentity] = []
        let root = r.app.identity
        do {
            try append(journal, JournalRecord(op: .freeze, group: r.group, app: r.app.bundleID,
                                              origin: r.origin.journalValue,
                                              pids: [JournalPid(root, role: .root)], hiddenByOhm: r.hiddenByOhm))
            try stopOne(root, isRoot: true, &stopped)
            var fixed = !r.withTree
            if r.withTree {
                for _ in 1...3 {
                    let known = Set(stopped.map(\.pid))
                    let new = tree.helpers(of: root, bundlePath: r.app.bundlePath).filter { !known.contains($0.pid) }
                    if new.isEmpty { fixed = true; break }
                    let v = policy.treeVetoes(r.app, pids: new.map(\.pid), forRule: r.origin.isRule)
                    if !v.isEmpty { throw FreezeFailure.veto(v) }
                    for chunk in stride(from: 0, to: new.count, by: 32).map({ Array(new[$0..<min($0 + 32, new.count)]) }) {
                        try append(journal, JournalRecord(op: .freeze, group: r.group, app: r.app.bundleID,
                                                          origin: r.origin.journalValue,
                                                          pids: chunk.map { JournalPid($0, role: .helper) }))
                    }
                    for h in new { try stopOne(h, isRoot: false, &stopped) }
                }
            }
            guard fixed else { throw FreezeFailure.unstableTree }
            try verifyStoppedBlocking(&stopped)
        } catch let f as FreezeFailure {
            rollback(r.group, stopped, reason: f.thawReason, journal: journal)
            return .failure(f)
        } catch {
            rollback(r.group, stopped, reason: .rollback, journal: journal)
            return .failure(.journal(.encode))
        }
        return .success(Array(stopped.dropFirst()))
    }

    private func append(_ journal: any FreezeJournaling, _ record: JournalRecord) throws {
        do { try journal.append(record, sync: true) } catch let e as JournalError {
            throw FreezeFailure.journal(e)
        }
    }

    /// Identity check (D3) → thaw table → SIGSTOP → `stopped`. A helper that vanished between
    /// enumeration and here is skipped (nothing to stop; recovery re-verifies identity anyway).
    private func stopOne(_ p: ProcessIdentity, isRoot: Bool, _ stopped: inout [ProcessIdentity]) throws {
        guard let s = signaler.startAbs(p.pid) else {
            if isRoot { throw FreezeFailure.identityMismatch(p.pid) }
            return
        }
        guard s == p.startAbsTime else { throw FreezeFailure.identityMismatch(p.pid) }
        guard ThawTable.add(p.pid) else { throw FreezeFailure.tableFull }
        let rc = signaler.send(p.pid, SIGSTOP)
        if rc != 0 {
            ThawTable.remove(p.pid)
            if rc == ESRCH && !isRoot { return }
            throw FreezeFailure.signal(p.pid, rc)
        }
        stopped.append(p)
    }

    /// Blocking wait on the Governor queue (not a suspension point): every pid must reach SSTOP within
    /// `verifyLimit`. A helper that died meanwhile leaves the group; a dead root is a failure.
    private func verifyStoppedBlocking(_ stopped: inout [ProcessIdentity]) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(config.verifyLimit * 1e9)
        while true {
            var pending: [Int32] = []
            var gone: Set<Int32> = []
            for (i, p) in stopped.enumerated() {
                if !signaler.matches(p) {
                    if i == 0 { throw FreezeFailure.identityMismatch(p.pid) }
                    gone.insert(p.pid)
                } else if !signaler.isStopped(p.pid) {
                    pending.append(p.pid)
                }
            }
            if !gone.isEmpty {
                stopped.removeAll { gone.contains($0.pid) }
                gone.forEach(ThawTable.remove)
            }
            if pending.isEmpty { return }
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw FreezeFailure.verifyTimeout(pending) }
            usleep(useconds_t(config.verifyPoll * 1e6))
        }
    }

    /// D10: best effort, no step depends on the previous one. Last stopped is continued first.
    func rollback(_ g: UUID, _ stopped: [ProcessIdentity], reason: ThawReason, journal: any FreezeJournaling) {
        for p in stopped.reversed() where signaler.matches(p) { _ = signaler.send(p.pid, SIGCONT) }
        stopped.forEach { ThawTable.remove($0.pid) }
        // If this write fails, recovery repeats the identity-checked SIGCONT: harmless.
        try? journal.append(JournalRecord(op: .thaw, group: g, reason: reason.rawValue), sync: false)
    }

    /// Helpers first (reverse stop order), root last (§ 3). Synchronous. Throws only if the journal
    /// write fails, after every SIGCONT has already been sent.
    func thaw(_ group: FrozenGroup, reason: ThawReason, journal: (any FreezeJournaling)?) throws {
        for h in group.helpers.reversed() where signaler.matches(h) { _ = signaler.send(h.pid, SIGCONT) }
        if signaler.matches(group.root) { _ = signaler.send(group.root.pid, SIGCONT) }
        group.members.forEach { ThawTable.remove($0.pid) }
        // No fsync: a lost thaw record only makes recovery repeat a verified SIGCONT.
        try journal?.append(JournalRecord(op: .thaw, group: group.id, reason: reason.rawValue), sync: false)
    }
}

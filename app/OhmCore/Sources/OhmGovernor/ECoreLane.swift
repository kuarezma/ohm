import Darwin
import Foundation
import OhmJournal
import OhmModel

struct ECoreGroup: Sendable {
    let id: UUID
    let app: RunningAppInfo
    let key: AppKey?
    let origin: EffectOrigin
    var params: ECoreParams
    var pids: [ProcessIdentity]
}

/// PRIO_DARWIN_BG on an app's tree (ADR 0004 § 8). `getpriority` cannot read the policy back (T-012),
/// so this record plus the journal are the only truth: the `ecore` record is written and fsynced
/// before any `setpriority` (D1), and removal writes `ecoreOff` after `setpriority(…, 0)`.
final class ECoreLane {
    let signaler: any ProcessSignaling
    private(set) var groups: [Int32: ECoreGroup] = [:]

    init(signaler: any ProcessSignaling) { self.signaler = signaler }

    func group(root pid: Int32) -> ECoreGroup? { groups[pid] }

    /// Applies to `root` + `helpers`. Throws the journal error before anything is changed.
    func apply(app: RunningAppInfo, key: AppKey?, origin: EffectOrigin, params: ECoreParams,
               helpers: [ProcessIdentity], journal: any FreezeJournaling) throws -> UUID {
        let id = UUID()
        let members = [app.identity] + helpers
        try journal.append(JournalRecord(op: .ecore, group: id, app: app.bundleID, origin: origin.journalValue,
                                         pids: [JournalPid(app.identity, role: .root)]
                                             + helpers.map { JournalPid($0, role: .helper) }), sync: true)
        var applied: [ProcessIdentity] = []
        for p in members where signaler.matches(p) {
            if signaler.setBackground(p.pid, true) == 0 { applied.append(p) }
        }
        groups[app.pid] = ECoreGroup(id: id, app: app, key: key, origin: origin, params: params, pids: applied)
        return id
    }

    /// Helpers started later (ambient tick, § 8): journal first, then policy.
    func extend(root: Int32, with new: [ProcessIdentity], journal: any FreezeJournaling) throws {
        guard var g = groups[root] else { return }
        let fresh = new.filter { n in !g.pids.contains(where: { $0.pid == n.pid }) }
        guard !fresh.isEmpty else { return }
        try journal.append(JournalRecord(op: .ecore, group: g.id, app: g.app.bundleID, origin: g.origin.journalValue,
                                         pids: fresh.map { JournalPid($0, role: .helper) }), sync: true)
        for p in fresh where signaler.matches(p) {
            if signaler.setBackground(p.pid, true) == 0 { g.pids.append(p) }
        }
        groups[root] = g
    }

    /// Removes the policy from every verified member. `ecoreOff` is written only when every member
    /// is resolved; the unresolved ones are returned for the Governor to retry (T-024 #1).
    func remove(root: Int32, reason: ThawReason, journal: (any FreezeJournaling)?) throws
        -> (group: ECoreGroup, unresolved: [ProcessIdentity])? {
        guard let g = groups.removeValue(forKey: root) else { return nil }
        let unresolved = try finish(g.id, ordered: g.pids.reversed(), reason: reason, journal: journal)
        return (g, unresolved)
    }

    func finish(_ id: UUID, ordered: [ProcessIdentity], reason: ThawReason, journal: (any FreezeJournaling)?) throws -> [ProcessIdentity] {
        var unresolved: [ProcessIdentity] = []
        for p in ordered {
            switch signaler.identityStatus(p) {
            case .gone, .mismatch: continue
            case .unknown: unresolved.append(p)
            case .match:
                let rc = signaler.setBackground(p.pid, false)
                if rc != 0 && rc != ESRCH { unresolved.append(p) }
            }
        }
        if unresolved.isEmpty {
            try journal?.append(JournalRecord(op: .ecoreOff, group: id, reason: reason.rawValue), sync: false)
        }
        return unresolved
    }

    func dropMember(_ pid: Int32) {
        for (root, var g) in groups where g.pids.contains(where: { $0.pid == pid }) {
            g.pids.removeAll { $0.pid == pid }
            groups[root] = g
        }
    }
}

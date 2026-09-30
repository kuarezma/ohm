import Darwin
import Dispatch
import Foundation
import OhmJournal
import OhmModel
import Synchronization

public struct GovernorConfig: Sendable {
    public var minHiddenFloor = 300.0
    public var refreezeGrace = 600.0
    public var maxFrozenRegular = 7200.0
    public var maxFrozenBackground = 1800.0
    public var hideTimeout = 1.0
    public var hidePoll = 0.02
    public var verifyLimit = 0.1
    public var verifyPoll = 0.005
    public var healthCheckDelay = 5.0
    /// How long a newly started watcher may take to hold `thawd.lock` (waited without blocking the actor).
    public var protectionStartTimeout = 2.0
    public var postWakeQuiet = 120.0
    public var powerOffReenable = 300.0
    public var eCoreFrontmostDelay = 2.0
    public var healthFile = FreezeHealthStore.standardPath
    public var ownBundlePrefix = "dev.ohm."
    /// `Ohm.app` path: anything executing from inside it is Ohm (thawd, widget, CLI).
    public var ownBundlePath: String? = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : nil
    public var ownPids: Set<Int32> = []
    public var appleAllowlist: Set<String> = ["com.apple.Safari", "com.apple.Preview"]
    public var protectedPathPrefixes = ["/System/", "/usr/", "/Library/Apple/"]
    public var userNeverFreeze: Set<String> = []

    public init() {}
}

/// ADR 0004 § 4. Runs on its own serial queue (ADR 0001 § 3, `.userInitiated`); journal I/O and the
/// bounded verification wait block that queue, never the cooperative pool.
public actor Governor: Governing {
    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public nonisolated let events: AsyncStream<GovernorEvent>
    private let continuation: AsyncStream<GovernorEvent>.Continuation

    let config: GovernorConfig
    private let appControl: any AppControlling
    private let signaler: any ProcessSignaling
    private let tree: any ProcessTreeEnumerating
    private let policy: SafetyPolicy
    private let freezer: Freezer
    private let lane: ECoreLane
    private let protection: any ProtectionProviding
    private let health: FreezeHealthStore
    private let journal: (any FreezeJournaling)?

    // § 4 operation generation and global state.
    public private(set) var generation: UInt64 = 0
    public private(set) var desired = DesiredState()
    public private(set) var disabledReason: FreezeVeto?
    private var powerOffInProgress = false
    private var postWakeUntil: Date?
    private var shuttingDown = false
    private let startedAt = Date()

    private var groups: [UUID: FrozenGroup] = [:]
    private var groupByRoot: [Int32: UUID] = [:]
    private var inFlight: [Int32: UUID] = [:]
    private var manualFreezes: Set<ProcessIdentity> = []
    private var manualECore: [Int32: (RunningAppInfo, ECoreParams, EffectOrigin)] = [:]
    private var lastActive: [Int32: Date] = [:]
    private var graceUntil: [ProcessIdentity: Date] = [:]
    private var exitSources: [Int32: any DispatchSourceProcess] = [:]
    private var exitIdentities: [Int32: ProcessIdentity] = [:]
    private var watcherSource: (any DispatchSourceProcess)?
    private final class ExitObservation: Sendable {
        let observedAt = Mutex<Date?>(nil)
    }
    private var exitObservations: [Int32: ExitObservation] = [:]
    private struct HealthCheck {
        let group: FrozenGroup
        let deadline: Date
        let exits: [ExitObservation]
        let task: Task<Void, Never>
    }
    private var healthChecks: [UUID: HealthCheck] = [:]

    /// Undo that could not complete (failed SIGCONT / BG removal or probe error). The journal group
    /// stays open and the crash-handler table keeps the pids until every member is resolved (T-024 #1).
    private struct PendingUndo {
        enum Kind { case freeze, eCore }
        let kind: Kind
        let id: UUID
        var members: [ProcessIdentity]
        let reason: ThawReason
    }
    private var pendingUndo: [UUID: PendingUndo] = [:]
    private var retryScheduled = false
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    private var retryToken: UInt64 = 0
    private var nextUndoRetry = Date.distantPast
    private var nextRecoveryRetry = Date.distantPast
    private var recoveryRetryAttempt = 0

    public init(config: GovernorConfig = GovernorConfig(),
                journal: sending (any FreezeJournaling)?,
                appControl: sending any AppControlling,
                protection: sending any ProtectionProviding,
                signaler: sending any ProcessSignaling = DarwinSignaler(),
                tree: sending any ProcessTreeEnumerating = SystemProcessTree(),
                probes: sending any SafetyProbing = SystemSafetyProbes()) {
        queue = DispatchSerialQueue(label: "dev.ohm.governor", qos: .userInitiated)
        (events, continuation) = AsyncStream.makeStream(of: GovernorEvent.self, bufferingPolicy: .bufferingNewest(64))
        self.config = config
        self.journal = journal
        self.appControl = appControl
        self.protection = protection
        self.signaler = signaler
        self.tree = tree
        health = FreezeHealthStore(path: config.healthFile)
        policy = SafetyPolicy(probes: probes, config: config, health: health)
        freezer = Freezer(signaler: signaler, tree: tree, policy: policy, config: config)
        lane = ECoreLane(signaler: signaler)
        if journal == nil { disabledReason = .journalUnwritable }
        else if journal?.boot == nil { disabledReason = .bootUnverified }
        else if journal?.recoveryReport?.blocksEffects == true { disabledReason = .recoveryPending }
    }

    // MARK: Status (UI, CLI `ohm status`, tests)

    /// `.none` whenever the watcher is not verifiably ready, whatever mode was chosen.
    public var protectionMode: ProtectionMode { protection.isReady() ? protection.mode : .none }
    public var pendingUndoPids: [Int32] { pendingUndo.values.flatMap { $0.members.map(\.pid) }.sorted() }
    public var frozenRootPids: [Int32] { groups.values.map(\.root.pid).sorted() }
    public func frozenMembers(root: Int32) -> [Int32]? {
        groupByRoot[root].flatMap { groups[$0] }.map { $0.members.map(\.pid) }
    }
    public func isFreezeUnsafe(_ bundleID: String) -> Bool { health.isUnsafe(bundleID) }
    public func clearFreezeUnsafe(_ bundleID: String) { health.unmark(bundleID) }
    public var eCoreRootPids: [Int32] { lane.groups.keys.sorted() }
    public func eCoreMembers(root: Int32) -> [Int32]? { lane.group(root: root)?.pids.map(\.pid) }

    /// Dynamic user never-freeze list (ADR 0004 D4, Rev 1).
    public func setUserNeverFreeze(_ bundleIDs: Set<String>) {
        policy.setUserNeverFreeze(bundleIDs)
        generation &+= 1
        for (id, g) in groups {
            let bundleMatches = g.app.bundleID.map { bundleIDs.contains($0) } ?? false
            let keyMatches = g.key.map { $0.kind == .bundleID && bundleIDs.contains($0.value) } ?? false
            if bundleMatches || keyMatches {
                thawGroup(id, reason: .userNeverList)
            }
        }
    }

    // MARK: Protection (§ 6)

    /// Chooses the protection mode; call at launch and when SMAppService status changes.
    /// The readiness wait suspends instead of blocking the Governor queue (T-024 #5): activation
    /// thaws keep flowing while a watcher starts.
    @discardableResult
    public func startProtection() async -> ProtectionMode {
        let mode = await confirmReady(protection.activate())
        modeChanged(mode)
        return mode
    }

    /// A started watcher that does not take `thawd.lock` in time is stopped: mode `none`.
    private func confirmReady(_ mode: ProtectionMode) async -> ProtectionMode {
        guard mode != .none else { return .none }
        let deadline = Date().addingTimeInterval(config.protectionStartTimeout)
        while !protection.isReady(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if protection.isReady() { return mode }
        protection.abandon()
        return .none
    }

    private func modeChanged(_ mode: ProtectionMode) {
        generation &+= 1
        continuation.yield(.protectionChanged(mode))
        watcherSource?.cancel()
        watcherSource = nil
        if mode == .none {
            thawEverything(.protectionLost, includeECore: true)
            return
        }
        if mode == .spawnedWatcher, let pid = protection.spawnedPid {
            let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            src.setEventHandler { [weak self] in
                Task { await self?.spawnedWatcherExited() }
            }
            src.resume()
            watcherSource = src
        }
    }

    private func spawnedWatcherExited() async {
        modeChanged(await confirmReady(protection.watcherDied()))
    }

    // MARK: Governing

    public func reconcile(_ newDesired: DesiredState) async -> ReconcileReport {
        if newDesired != desired {
            generation &+= 1
            desired = newDesired
        }
        // Every await below may interleave with another reconcile, a power-off, a mode change…:
        // after each one the loop continues only if nothing moved the generation (T-024 #4).
        let token = generation
        var report = ReconcileReport()
        // Rule contributions that disappeared (level-triggered, ADR 0003 § 3).
        for g in groups.values where g.byRule {
            if g.key.flatMap({ desired.effects[$0]?.freeze }) == nil { thawGroup(g.id, reason: .ruleEnded) }
        }
        for (root, g) in lane.groups where g.origin.isRule {
            if g.key.flatMap({ desired.effects[$0]?.eCore }) == nil { removeECore(root: root, reason: .ruleEnded) }
        }
        for key in desired.effects.keys.sorted(by: { $0.value < $1.value }) {
            for app in appControl.apps(for: key) {
                guard generation == token, let effect = desired.effects[key] else { return report }
                if let fp = effect.freeze, groupByRoot[app.pid] == nil, inFlight[app.pid] == nil {
                    let origin = effect.origins[.freeze]?.first(where: \.isRule) ?? .rule(UUID())
                    let minHidden = max(Double(fp.minHiddenSeconds), config.minHiddenFloor)
                    report.outcomes[key] = await runFreeze(app: app, key: key, origin: origin,
                                                           minHidden: minHidden, confirmedBackground: false)
                    guard generation == token else { return report }
                }
                if let ep = desired.effects[key]?.eCore {
                    let origin = effect.origins[.eCore]?.first(where: \.isRule) ?? .rule(UUID())
                    if let o = ensureECore(app: app, key: key, origin: origin, params: ep), report.outcomes[key] == nil {
                        report.outcomes[key] = o
                    }
                }
            }
        }
        return report
    }

    public func perform(_ command: GovernorCommand) async -> GovernorOutcome {
        switch command {
        case let .freeze(pid, origin, confirmedBackground):
            guard let app = appControl.app(pid: pid) else { return .vetoed([.notRunning]) }
            manualFreezes.insert(app.identity)
            let outcome = await runFreeze(app: app, key: app.bundleID.map(AppKey.bundle), origin: origin,
                                          minHidden: 0, confirmedBackground: confirmedBackground)
            if case .frozen = outcome {} else { manualFreezes.remove(app.identity) }
            return outcome
        case let .thaw(pid):
            let id = groupByRoot[pid] ?? groups.values.first(where: { $0.members.contains { $0.pid == pid } })?.id
            guard let id else { return .notFound }
            thawGroup(id, reason: .user)
            return .thawed(groups: 1)
        case let .eCore(pid, on, origin):
            if !on {
                manualECore[pid] = nil
                retryPending(force: true)
                return removeECore(root: pid, reason: .user) ? .eCoreRemoved(groups: 1) : .notFound
            }
            guard let app = appControl.app(pid: pid) else { return .vetoed([.notRunning]) }
            let params = ECoreParams(whileFrontmost: .release)
            manualECore[pid] = (app, params, origin)
            return ensureECore(app: app, key: app.bundleID.map(AppKey.bundle), origin: origin, params: params)
                ?? .eCoreApplied(group: lane.group(root: pid)?.id ?? UUID())
        case .thawAll:
            let r = thawAll(reason: .user)
            guard r.recoveryComplete else {
                return .vetoed([disabledReason == .journalUnwritable ? .journalUnwritable : .recoveryPending])
            }
            return .thawed(groups: r.freezeGroups)
        }
    }

    /// Thaws every frozen group (the "Hepsini çöz" path). For `quit`, `powerOff`, `protectionLost`
    /// and `journalUnwritable` E-core policies are removed as well (D2).
    public func thawAll(reason: ThawReason) -> ThawReport {
        generation &+= 1
        let knownGroups = Set(groups.keys).union(lane.groups.values.map(\.id)).union(pendingUndo.keys)
        let withECore: Set<ThawReason> = [.quit, .powerOff, .protectionLost, .journalUnwritable]
        var report = thawEverything(reason, includeECore: withECore.contains(reason) || reason == .user)
        if reason == .user {
            retryPending(force: true)
            // Active groups are undone first. Recovery can now inspect the entire journal safely.
            do {
                if let recovered = try journal?.retryRecovery(forceCloseUnverifiable: true) {
                    report.forcedClosedGroups = recovered.forcedClosedGroups.count
                    if recovered.blocksEffects {
                        report.recoveryFailures.append("Journal kurtarmasında doğrulanamayan veya geri alınamayan süreçler kaldı.")
                    }
                    for (id, kind) in recovered.closedGroups where !knownGroups.contains(id) {
                        switch kind {
                        case .freeze: report.freezeGroups += 1
                        case .eCore: report.eCoreGroups += 1
                        }
                    }
                    let unresolved = Set(recovered.unresolved.map(\.identity))
                    for (id, var pending) in pendingUndo {
                        pending.members.filter { !unresolved.contains($0) }.forEach { ThawTable.remove($0.pid) }
                        pending.members.removeAll { !unresolved.contains($0) }
                        pendingUndo[id] = pending.members.isEmpty ? nil : pending
                    }
                    resetRetryIfIdle()
                    updateRecoveryVeto(recovered)
                }
            } catch {
                report.recoveryFailures.append("Journal kurtarması başarısız: \(error).")
                report.forcedClosedGroups = journal?.recoveryReport?.forcedClosedGroups.count ?? 0
                disableEffects()
            }
        }
        if report.forcedClosedGroups > 0 {
            report.recoveryFailures.append("\(report.forcedClosedGroups) grubun kimliği doğrulanamadı; sinyal gönderilmeden yalnız kayıtları kapatıldı.")
        }
        if !pendingUndo.isEmpty || !groups.isEmpty ||
            ((withECore.contains(reason) || reason == .user) && !lane.groups.isEmpty) {
            report.recoveryFailures.append("Bazı süreç etkileri henüz geri alınamadı; Ohm yeniden deniyor.")
        }
        if disabledReason == .journalUnwritable {
            report.recoveryFailures.append("Journal yazılamıyor; kurtarmanın kalıcı olarak tamamlandığı doğrulanamadı.")
        } else if journal?.boot == nil {
            report.recoveryFailures.append("Önyükleme oturumu doğrulanamadı; kurtarma tamamlanmadı.")
        }
        report.recoveryComplete = report.recoveryFailures.isEmpty
        return report
    }

    /// `applicationShouldTerminate`: no new effects, everything thawed and removed, synchronously.
    public func shutdown() -> ThawReport {
        shuttingDown = true
        let report = thawAll(reason: .quit)
        let checks = Array(healthChecks.values)
        healthChecks.removeAll()
        for check in checks {
            check.task.cancel()
            check.group.members.forEach { unwatchIfUnused($0) }
        }
        return report
    }

    // MARK: Workspace events (§ 7)

    public func handle(_ event: WorkspaceEvent) {
        switch event {
        case .activated(let pid):
            lastActive[pid] = Date()
            // D5: activation always thaws; nothing can prevent it.
            if let id = groupByRoot[pid] { thawGroup(id, reason: .activation) }
            if pendingUndo.values.contains(where: { $0.members.contains { $0.pid == pid } }) { retryPending(force: true) }
            if let g = lane.group(root: pid), g.params.whileFrontmost == .release {
                removeECore(root: pid, reason: .frontmost)
            }
        case .deactivated(let pid):
            lastActive[pid] = Date()
        case .terminated(let pid):
            processExited(pid)
            lastActive[pid] = nil
            manualECore[pid] = nil
        case .willPowerOff:
            powerOffInProgress = true
            generation &+= 1
            thawEverything(.powerOff, includeECore: true)
            let delay = config.powerOffReenable
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await self?.powerOffCancelled()
            }
        case .willSleep:
            generation &+= 1
        case .didWake:
            generation &+= 1
            postWakeUntil = Date().addingTimeInterval(config.postWakeQuiet)
            for g in groups.values {
                switch signaler.identityStatus(g.root) {
                case .gone, .mismatch:
                    thawGroup(g.id, reason: .terminated)
                    continue
                case .unknown:
                    thawGroup(g.id, reason: .verifyFailed)
                    continue
                case .match: break
                }
                helperLoop: for h in g.helpers {
                    switch signaler.identityStatus(h) {
                    case .gone, .mismatch: processExited(h.pid)
                    case .unknown:
                        thawGroup(g.id, reason: .verifyFailed)
                        break helperLoop
                    case .match: break
                    }
                }
            }
            expireByWallClock()
        }
    }

    /// Ambient tick (10 s, ADR 0004 § 8): wall-clock limits, new E-core helpers, pending rule effects.
    public func tick() async {
        retryRecoveryIfDue()
        retryPending()
        // No effect may exist or grow without a verifiably ready watcher (D1, T-024 #5).
        guard protection.isReady() else {
            if !groups.isEmpty || !lane.groups.isEmpty {
                generation &+= 1
                continuation.yield(.protectionChanged(.none))
                thawEverything(.protectionLost, includeECore: true)
            }
            if protection.mode != .none { _ = await startProtection() }
            return
        }
        expireByWallClock()
        for (root, g) in lane.groups {
            guard let journal, signaler.identityStatus(g.app.identity) == .match else { continue }
            let known = Set(g.pids.map(\.pid))
            let new = tree.helpers(of: g.app.identity, bundlePath: g.app.bundlePath).filter { !known.contains($0.pid) }
            if !new.isEmpty {
                do { try lane.extend(root: root, with: new, journal: journal) } catch { disableEffects() }
            }
        }
        for (pid, entry) in manualECore where lane.group(root: pid) == nil {
            _ = ensureECore(app: entry.0, key: entry.0.bundleID.map(AppKey.bundle), origin: entry.2, params: entry.1)
        }
        _ = await reconcile(desired)
    }

    private func powerOffCancelled() {
        guard powerOffInProgress else { return }
        powerOffInProgress = false
        generation &+= 1
    }

    // MARK: Freeze (§ 4)

    private struct FreezeOp {
        let id = UUID()
        let token: UInt64
        let app: RunningAppInfo
        let key: AppKey?
        let origin: EffectOrigin
        let minHidden: Double
        let confirmedBackground: Bool
        let startedAt = Date()
        var byRule: Bool { origin.isRule }
    }

    private func runFreeze(app: RunningAppInfo, key: AppKey?, origin: EffectOrigin, minHidden: Double,
                           confirmedBackground: Bool) async -> GovernorOutcome {
        let op = FreezeOp(token: generation, app: app, key: key, origin: origin, minHidden: minHidden,
                          confirmedBackground: confirmedBackground)
        let pid = app.pid
        if let other = inFlight[pid], other != op.id { return veto(op, [.busy]) }
        inFlight[pid] = op.id
        defer { if inFlight[pid] == op.id { inFlight[pid] = nil } }

        // FAZ A — the only suspension point is the hide wait.
        let first = admissible(op)
        if !first.isEmpty { return veto(op, first) }
        let regular = app.activationPolicy == .regular
        let hiddenByOhm = regular && !appControl.isHidden(pid: pid)
        if hiddenByOhm { appControl.hide(pid: pid) }
        if regular {
            let deadline = Date().addingTimeInterval(config.hideTimeout)
            while !(appControl.isHidden(pid: pid) && !appControl.hasOnScreenWindows(pid: pid)), Date() < deadline {
                try? await Task.sleep(for: .seconds(config.hidePoll))
            }
        }

        // FAZ B — no `await` from here to the return (D4).
        var vetoes = admissible(op)
        if regular, !(appControl.isHidden(pid: pid) && !appControl.hasOnScreenWindows(pid: pid)) {
            vetoes.append(.notHidden)
        }
        guard vetoes.isEmpty, let journal else {
            restoreHide(op, hiddenByOhm: hiddenByOhm)
            return veto(op, vetoes.isEmpty ? [.journalUnwritable] : vetoes)
        }
        let g = UUID()
        let result = freezer.freeze(.init(group: g, app: app, origin: origin, hiddenByOhm: hiddenByOhm,
                                          withTree: regular && app.bundlePath != nil), journal: journal)
        switch result {
        case .success(let helpers):
            let limit = regular ? config.maxFrozenRegular : config.maxFrozenBackground
            let grp = FrozenGroup(id: g, app: app, key: key, origin: origin, helpers: helpers,
                                  hiddenByOhm: hiddenByOhm, frozenAt: Date(), deadline: Date().addingTimeInterval(limit))
            register(grp)
            continuation.yield(.frozen(group: g, bundleID: app.bundleID, pids: grp.members.map(\.pid)))
            return .frozen(group: g)
        case .failure(let f):
            restoreHide(op, hiddenByOhm: hiddenByOhm)
            let unresolved = freezer.lastRollbackUnresolved
            if !unresolved.isEmpty {
                keepPending(PendingUndo(kind: .freeze, id: g, members: unresolved, reason: f.thawReason))
            }
            continuation.yield(.rolledBack(group: g, reason: f.thawReason))
            switch f {
            case .veto(let v): return veto(op, v)
            case .unstableTree: return veto(op, [.unstableTree])
            case .tableFull: return veto(op, [.tableFull])
            case .journal(let e):
                disableEffects()
                return .rolledBack(.rollback, detail: "journal: \(e)")
            case .identityMismatch(let p): return .rolledBack(.rollback, detail: "identity mismatch pid \(p)")
            case .identityUnknown(let p, let error): return .rolledBack(.rollback, detail: "identity unreadable pid \(p) errno \(error)")
            case .signal(let p, let e): return .rolledBack(.rollback, detail: "kill(\(p)) errno \(e)")
            case .verifyTimeout(let ps): return .rolledBack(.verifyFailed, detail: "not stopped: \(ps)")
            }
        }
    }

    private func veto(_ op: FreezeOp, _ v: [FreezeVeto]) -> GovernorOutcome {
        continuation.yield(.vetoed(bundleID: op.app.bundleID, vetoes: v))
        return .vetoed(v)
    }

    /// Recomputed from scratch on every call (§ 4).
    private func admissible(_ op: FreezeOp) -> [FreezeVeto] {
        var v: [FreezeVeto] = []
        let pid = op.app.pid
        let now = Date()
        if op.token != generation { v.append(.superseded) }
        if !protection.isReady() { v.append(.protectionNotReady) }
        if journal == nil || disabledReason != nil { v.append(disabledReason ?? .journalUnwritable) }
        if powerOffInProgress { v.append(.powerOffInProgress) }
        if let q = postWakeUntil, now < q { v.append(.postWakeQuiet) }
        if shuttingDown { v.append(.shuttingDown) }
        if op.byRule {
            if op.key.flatMap({ desired.effects[$0]?.freeze }) == nil { v.append(.notDesired) }
        } else if !manualFreezes.contains(op.app.identity) {
            v.append(.notDesired)
        }
        switch signaler.identityStatus(op.app.identity) {
        case .match: break
        case .gone, .mismatch: return v + [.notRunning]
        case .unknown: return v + [.safetyProbeFailed]
        }
        v += policy.topologyVetoes(op.app, origin: op.origin)
        v += policy.scopeVetoes(op.app, forRule: op.byRule, confirmedBackground: op.confirmedBackground)
        // D9: frontmost is an absolute veto; an activation seen during this operation counts too.
        if appControl.isActive(pid: pid) || (lastActive[pid].map { $0 > op.startedAt } ?? false) {
            v.append(.frontmost)
        }
        let seenActive = lastActive[pid] ?? startedAt
        let inactiveFor = now.timeIntervalSince(seenActive)
        var needHidden = op.minHidden
        if op.byRule, let until = graceUntil[op.app.identity] {
            if now < until { v.append(.refreezeGrace) }
            needHidden = max(needHidden, config.refreezeGrace)
        }
        if inactiveFor < needHidden { v.append(.recentlyActive) }
        let regular = op.app.activationPolicy == .regular
        let helpers = regular ? tree.helpers(of: op.app.identity, bundlePath: op.app.bundlePath) : []
        let pids = [pid] + helpers.map(\.pid)
        v += policy.treeVetoes(op.app, pids: pids, forRule: op.byRule)
        if groupByRoot[pid] != nil || (inFlight[pid].map { $0 != op.id } ?? false) { v.append(.busy) }
        if ThawTable.count + pids.count > ThawTable.capacity { v.append(.tableFull) }
        var seen = Set<FreezeVeto>()
        return v.filter { seen.insert($0).inserted }
    }

    /// Only if Ohm hid it; never touch what the user hid (§ 4 restoreHide).
    private func restoreHide(_ op: FreezeOp, hiddenByOhm: Bool) {
        if hiddenByOhm, signaler.identityStatus(op.app.identity) == .match, !appControl.isActive(pid: op.app.pid) {
            appControl.unhide(pid: op.app.pid)
        }
    }

    private func register(_ g: FrozenGroup) {
        groups[g.id] = g
        groupByRoot[g.root.pid] = g.id
        graceUntil[g.root] = nil
        for m in g.members { watchExit(m) }
        let id = g.id
        let delay = g.deadline.timeIntervalSinceNow
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            await self?.expire(id)
        }
    }

    private func watchExit(_ identity: ProcessIdentity) {
        let pid = identity.pid
        if exitIdentities[pid] == identity { return }
        unwatch(pid)
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let observation = ExitObservation()
        src.setEventHandler { [weak self] in
            let observedAt = Date()
            // Save definitive evidence before scheduling the actor hop. The health timer may
            // run before that Task under load; its snapshot still sees this exit.
            observation.observedAt.withLock { $0 = observedAt }
            Task { await self?.processExited(pid, authoritative: true, identity: identity, exitedAt: observedAt) }
        }
        src.resume()
        exitSources[pid] = src
        exitIdentities[pid] = identity
        exitObservations[pid] = observation
    }

    private func unwatch(_ pid: Int32) {
        exitSources.removeValue(forKey: pid)?.cancel()
        exitIdentities[pid] = nil
        exitObservations[pid] = nil
    }

    /// A thaw keeps its identity-bound exit source through the health window. A newer freeze or
    /// E-core group may share that source, so an expired check must not cancel their protection.
    private func unwatchIfUnused(_ identity: ProcessIdentity) {
        guard exitIdentities[identity.pid] == identity,
              !groups.values.contains(where: { $0.members.contains(identity) }),
              !lane.groups.values.contains(where: { $0.pids.contains(identity) }),
              !healthChecks.values.contains(where: { $0.group.members.contains(identity) }) else { return }
        unwatch(identity.pid)
    }

    private func expire(_ id: UUID) {
        guard let g = groups[id], Date() >= g.deadline else { return }
        thawGroup(id, reason: .maxDuration)
    }

    private func expireByWallClock() {
        let now = Date()
        for g in groups.values where now >= g.deadline { thawGroup(g.id, reason: .maxDuration) }
    }

    /// A frozen root that dies takes its group down: helpers are continued immediately (§ 4).
    /// A dying helper just leaves the group.
    private func processExited(_ pid: Int32, authoritative: Bool = false, identity: ProcessIdentity? = nil, exitedAt: Date? = nil) {
        if authoritative, exitIdentities[pid] == identity { unwatch(pid) }
        if authoritative, let identity {
            // NOTE_EXIT is definitive even if the post-thaw rusage probe is unreadable.
            for check in healthChecks.values where (exitedAt ?? Date()) <= check.deadline && check.group.members.contains(identity) {
                markFreezeUnsafe(check.group)
            }
            for (id, var pending) in pendingUndo where pending.members.contains(identity) {
                pending.members.removeAll { $0 == identity }
                ThawTable.remove(pid)
                if pending.members.isEmpty {
                    do {
                        try journal?.append(JournalRecord(op: pending.kind == .freeze ? .thaw : .ecoreOff,
                                                          group: id, reason: ThawReason.terminated.rawValue), sync: false)
                        pendingUndo[id] = nil
                    } catch { disableEffects() }
                } else { pendingUndo[id] = pending }
            }
            resetRetryIfIdle()
        }
        lane.dropMember(pid, authoritative: authoritative, identity: identity)
        if let g = lane.group(root: pid), identity == nil || identity == g.app.identity {
            removeECore(root: pid, reason: .terminated)
        }
        if let id = groupByRoot[pid], identity == nil || identity == groups[id]?.root {
            if authoritative {
                // NOTE_EXIT is tied to the old process, so never SIGCONT a reused root pid.
                ThawTable.remove(pid)
            }
            thawGroup(id, reason: .terminated, exitedIdentity: authoritative ? identity : nil)
            return
        }
        for (id, var g) in groups where g.helpers.contains(where: { $0.pid == pid }) {
            guard let helper = g.helpers.first(where: { $0.pid == pid }) else { continue }
            if let identity, helper != identity { continue }
            if !authoritative {
                switch signaler.identityStatus(helper) {
                case .gone, .mismatch: break
                case .unknown, .match: continue
                }
            }
            g.helpers.removeAll { $0.pid == pid }
            groups[id] = g
            ThawTable.remove(pid)
        }
    }

    /// Synchronous, no suspension (§ 4 thaw).
    @discardableResult
    private func thawGroup(_ id: UUID, reason: ThawReason, exitedIdentity: ProcessIdentity? = nil) -> Bool {
        guard let g = groups.removeValue(forKey: id) else { return false }
        groupByRoot[g.root.pid] = nil
        let noHealthCheck: Set<ThawReason> = [.terminated, .quit, .powerOff, .rollback]
        if !noHealthCheck.contains(reason) { scheduleHealthCheck(g) }
        g.members.forEach { unwatchIfUnused($0) }
        manualFreezes.remove(g.root)
        var journalFailed = false
        do {
            let unresolved: [ProcessIdentity]
            if let exitedIdentity {
                unresolved = try freezer.finish(g.id, ordered: (g.helpers.reversed() + [g.root]).filter { $0 != exitedIdentity },
                                                 reason: reason, journal: journal)
            } else {
                unresolved = try freezer.thaw(g, reason: reason, journal: journal)
            }
            if !unresolved.isEmpty {
                keepPending(PendingUndo(kind: .freeze, id: g.id, members: unresolved, reason: reason))
            }
        } catch { journalFailed = true }
        if reason == .activation || reason == .maxDuration {
            graceUntil[g.root] = Date().addingTimeInterval(config.refreezeGrace)
        }
        continuation.yield(.thawed(group: id, reason: reason))
        if journalFailed { disableEffects() }
        compactIfIdle()
        return true
    }

    private func compactIfIdle() {
        guard groups.isEmpty, lane.groups.isEmpty, pendingUndo.isEmpty, disabledReason == nil else { return }
        do { try journal?.compactIfIdle() } catch { disableEffects() }
    }

    // MARK: Unresolved undo (T-024 #1)

    private func keepPending(_ p: PendingUndo) {
        pendingUndo[p.id] = p
        scheduleRetry()
    }

    /// Retries every unresolved SIGCONT / BG removal; writes the thaw / ecoreOff record only once a
    /// group is fully resolved.
    private func retryPending(force: Bool = false) {
        guard force || Date() >= nextUndoRetry else { return }
        for (id, p) in pendingUndo {
            do {
                let left: [ProcessIdentity]
                switch p.kind {
                case .freeze: left = try freezer.finish(id, ordered: p.members, reason: p.reason, journal: journal)
                case .eCore: left = try lane.finish(id, ordered: p.members, reason: p.reason, journal: journal)
                }
                if left.isEmpty {
                    pendingUndo[id] = nil
                    continuation.yield(p.kind == .freeze ? .thawed(group: id, reason: p.reason)
                                                         : .eCoreRemoved(group: id, reason: p.reason))
                } else {
                    pendingUndo[id]?.members = left
                }
            } catch {
                pendingUndo[id] = nil
                disableEffects()
            }
        }
        if pendingUndo.isEmpty { resetRetryIfIdle() } else { scheduleRetry() }
    }

    private func resetRetryIfIdle() {
        guard pendingUndo.isEmpty else { return }
        retryTask?.cancel()
        retryTask = nil
        retryScheduled = false
        retryAttempt = 0
        retryToken &+= 1
        nextUndoRetry = .distantPast
    }

    /// Persistent failures back off to five minutes; tick cannot bypass the scheduled deadline.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = min(300.0, 0.1 * pow(2, Double(retryAttempt)))
        retryAttempt = min(retryAttempt + 1, 12)
        nextUndoRetry = Date().addingTimeInterval(delay)
        retryToken &+= 1
        let token = retryToken
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryTimerFired(token)
        }
    }

    private func retryTimerFired(_ token: UInt64) {
        guard token == retryToken else { return }
        retryTask = nil
        retryScheduled = false
        retryPending(force: true)
    }

    /// § 3: keep NOTE_EXIT as health evidence until the post-thaw window closes.
    private func scheduleHealthCheck(_ g: FrozenGroup) {
        guard g.app.bundleID != nil else { return }
        let delay = config.healthCheckDelay
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.healthCheck(g.id)
        }
        let exits = g.members.compactMap { exitIdentities[$0.pid] == $0 ? exitObservations[$0.pid] : nil }
        healthChecks[g.id] = HealthCheck(group: g, deadline: Date().addingTimeInterval(delay), exits: exits, task: task)
    }

    private func healthCheck(_ id: UUID) {
        guard let check = healthChecks.removeValue(forKey: id) else { return }
        let g = check.group
        let observedExit = check.exits.contains { observation in
            observation.observedAt.withLock { $0.map { $0 <= check.deadline } ?? false }
        }
        if observedExit || g.members.contains(where: {
            switch signaler.identityStatus($0) {
            case .gone, .mismatch: true
            case .unknown: false
            case .match: ProcessProbe.bsdInfo($0.pid)?.pbi_status == UInt32(SZOMB)
            }
        }) {
            markFreezeUnsafe(g)
        }
        g.members.forEach { unwatchIfUnused($0) }
    }

    private func markFreezeUnsafe(_ g: FrozenGroup) {
        guard let bundle = g.app.bundleID, !health.isUnsafe(bundle) else { return }
        health.mark(bundle)
        continuation.yield(.freezeUnsafeMarked(bundleID: bundle))
    }

    @discardableResult
    private func thawEverything(_ reason: ThawReason, includeECore: Bool) -> ThawReport {
        var report = ThawReport()
        for id in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) where thawGroup(id, reason: reason) {
            report.freezeGroups += 1
        }
        if includeECore {
            for root in lane.groups.keys.sorted() where removeECore(root: root, reason: reason) {
                report.eCoreGroups += 1
            }
            manualECore.removeAll()
        }
        manualFreezes.removeAll()
        return report
    }

    /// Journal write failed: freeze and E-core are disabled and existing effects undone (§ 5).
    private func disableEffects() {
        guard disabledReason != .journalUnwritable else { return }
        disabledReason = .journalUnwritable
        generation &+= 1
        continuation.yield(.effectsDisabled(.journalUnwritable))
        thawEverything(.journalUnwritable, includeECore: true)
    }

    // MARK: E-core (§ 8)

    /// Returns nil when nothing needed doing or it was applied/extended; `.vetoed` otherwise.
    private func ensureECore(app: RunningAppInfo, key: AppKey?, origin: EffectOrigin, params: ECoreParams) -> GovernorOutcome? {
        let pid = app.pid
        lane.updateParams(root: pid, params: params)
        let effectiveParams = lane.group(root: pid)?.params ?? params
        if effectiveParams.whileFrontmost == .release {
            let recentlyActive = lastActive[pid].map { Date().timeIntervalSince($0) < config.eCoreFrontmostDelay } ?? false
            if appControl.isActive(pid: pid) || recentlyActive {
                removeECore(root: pid, reason: .frontmost)
                return nil
            }
        }
        var v: [FreezeVeto] = []
        if !protection.isReady() { v.append(.protectionNotReady) }
        if journal == nil || disabledReason != nil { v.append(disabledReason ?? .journalUnwritable) }
        if powerOffInProgress { v.append(.powerOffInProgress) }
        if shuttingDown { v.append(.shuttingDown) }
        switch signaler.identityStatus(app.identity) {
        case .match: break
        case .gone, .mismatch: v.append(.notRunning)
        case .unknown: v.append(.safetyProbeFailed)
        }
        // Safer choice (ADR silent): the static scope gate, minus the `.regular` requirement, also
        // applies to E-core so system UI processes never get PRIO_DARWIN_BG.
        v += policy.scopeVetoes(app, forRule: false, confirmedBackground: true)
        guard v.isEmpty, let journal else {
            continuation.yield(.vetoed(bundleID: app.bundleID, vetoes: v))
            return .vetoed(v)
        }
        let helpers = tree.helpers(of: app.identity, bundlePath: app.bundlePath)
        do {
            if lane.group(root: pid) != nil {
                try lane.extend(root: pid, with: helpers, journal: journal)
                lane.group(root: pid)?.pids.forEach { watchExit($0) }
                return nil
            }
            let id = try lane.apply(app: app, key: key, origin: origin, params: params, helpers: helpers, journal: journal)
            lane.group(root: pid)?.pids.forEach { watchExit($0) }
            continuation.yield(.eCoreApplied(group: id, bundleID: app.bundleID))
            return .eCoreApplied(group: id)
        } catch {
            disableEffects()
            return .vetoed([.journalUnwritable])
        }
    }

    /// The journal owns owner.lock for its lifetime. No second lock acquisition or await here.
    private func retryRecoveryIfDue() {
        guard disabledReason == .bootUnverified || disabledReason == .recoveryPending,
              journal?.recoveryReport?.needsRetry == true || journal?.boot == nil,
              Date() >= nextRecoveryRetry, groups.isEmpty, lane.groups.isEmpty, pendingUndo.isEmpty else { return }
        nextRecoveryRetry = Date().addingTimeInterval(min(300, 5 * pow(2, Double(recoveryRetryAttempt))))
        recoveryRetryAttempt = min(recoveryRetryAttempt + 1, 6)
        do {
            if let report = try journal?.retryRecovery(forceCloseUnverifiable: false) { updateRecoveryVeto(report) }
        } catch { disableEffects() }
    }

    private func updateRecoveryVeto(_ report: RecoveryReport) {
        guard disabledReason != .journalUnwritable else { return }
        if journal?.boot == nil { disabledReason = .bootUnverified }
        else if report.blocksEffects { disabledReason = .recoveryPending }
        else {
            disabledReason = nil
            recoveryRetryAttempt = 0
            generation &+= 1
        }
    }

    @discardableResult
    private func removeECore(root: Int32, reason: ThawReason) -> Bool {
        do {
            guard let (g, unresolved) = try lane.remove(root: root, reason: reason, journal: journal) else { return false }
            if unresolved.isEmpty {
                continuation.yield(.eCoreRemoved(group: g.id, reason: reason))
            } else {
                keepPending(PendingUndo(kind: .eCore, id: g.id, members: unresolved, reason: reason))
            }
        } catch {
            disableEffects()
        }
        return true
    }
}

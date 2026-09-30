import Darwin
import Foundation
@testable import OhmGovernor
@testable import OhmJournal
import OhmModel
import Synchronization
import Testing

// Model kernel faults deterministically; only exit watchers touch test-spawned processes.
private final class T026SignalState: Sendable {
    struct Values {
        var identities: [Int32: UInt64] = [:]
        var unknown: Set<Int32> = []
        var unknownAfterStop: Set<Int32> = []
        var stopped: Set<Int32> = []
        var signals: [(Int32, Int32)] = []
        var background: [(Int32, Bool)] = []
    }
    let values = Mutex(Values())
}

private final class T026Signaler: ProcessSignaling {
    let state: T026SignalState
    init(_ state: T026SignalState) { self.state = state }
    func startAbs(_ pid: Int32) -> UInt64? {
        state.values.withLock { $0.unknown.contains(pid) ? nil : $0.identities[pid] }
    }
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus {
        state.values.withLock {
            if $0.unknown.contains(id.pid) { return .unknown(EPERM) }
            guard let start = $0.identities[id.pid] else { return .gone }
            return start == id.startAbsTime ? .match : .mismatch
        }
    }
    func send(_ pid: Int32, _ sig: Int32) -> Int32 {
        state.values.withLock {
            $0.signals.append((pid, sig))
            if sig == SIGSTOP {
                $0.stopped.insert(pid)
                if $0.unknownAfterStop.contains(pid) { $0.unknown.insert(pid) }
            } else if sig == SIGCONT { $0.stopped.remove(pid) }
        }
        return 0
    }
    func isStopped(_ pid: Int32) -> Bool { state.values.withLock { $0.stopped.contains(pid) } }
    func setBackground(_ pid: Int32, _ on: Bool) -> Int32 {
        state.values.withLock { $0.background.append((pid, on)) }
        return 0
    }
}

private final class T026Journal: FreezeJournaling {
    let boot: String?
    init(boot: String?) { self.boot = boot }
    func append(_ record: JournalRecord, sync: Bool) throws {}
    func compactIfIdle() throws {}
}

private struct T026Rig {
    let apps = FakeAppState()
    let signals = T026SignalState()
    let treeState = TreeState()
    let gov: Governor
    init(boot: String? = "t026-boot", healthCheckDelay: Double = 5) {
        var config = testConfig(tempDir("t026"))
        config.minHiddenFloor = 0
        config.refreezeGrace = 0
        config.healthCheckDelay = healthCheckDelay
        gov = Governor(config: config, journal: T026Journal(boot: boot), appControl: FakeAppControl(apps),
                       protection: FakeProtection(FakeProtectionState()), signaler: T026Signaler(signals),
                       tree: FakeTree(treeState), probes: FakeProbes(ProbeState()))
    }
    func add(_ pid: Int32, bundle: String = "dev.ohmtest.t026", bundlePath: String? = nil) {
        let app = appInfo(pid, bundleID: bundle, bundle: bundlePath)
        apps.add(app)
        signals.values.withLock { $0.identities[pid] = app.identity.startAbsTime }
    }
}

@Suite("T-026 Governor regressions", .serialized)
struct T026RegressionTests {
    @Test("T026b P2-1: Governor thaw-all closes retained prior-session tracking and counts it")
    func userClosesPriorSession() async throws {
        let paths = JournalPaths(directory: tempDir("t026b-user"))
        let group = UUID()
        try JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_101, start: 1)])
            .encodedLine().write(to: URL(fileURLWithPath: paths.journal))
        let journal = try JournalSession.open(paths: paths, ownerLockRetry: 0, signaler: T026bBootSignaler()).0
        let gov = Governor(config: testConfig(paths.directory), journal: journal,
                           appControl: FakeAppControl(FakeAppState()), protection: FakeProtection(FakeProtectionState()),
                           signaler: T026Signaler(T026SignalState()), tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        #expect(await gov.disabledReason == .recoveryPending)
        // Tracking is closed, but unknown identity never proves that the effect was undone.
        #expect(await gov.perform(.thawAll) == .vetoed([.recoveryPending]))
        #expect(await gov.disabledReason == nil)
        let snapshot = JournalReader.read(path: paths.journal)
        #expect(snapshot.openGroups().isEmpty)
        #expect(snapshot.records.contains { $0.group == group && $0.reason == "userForcedUnverified" })
        _ = await gov.shutdown()
    }

    @Test("T026b P2-1: existing watcher lock is reused without another spawned child")
    func reuseWatcher() throws {
        let paths = JournalPaths(directory: tempDir("t026b-reuse"))
        let incumbent = try FileLock(path: paths.thawdLock)
        try #require(incumbent.tryLockExclusive())
        let protection = WatcherProtection(paths: paths, executable: "/missing/ohm-thawd", useLaunchAgent: false)
        #expect(protection.activate() == .spawnedWatcher)
        #expect(protection.spawnedPid == nil && protection.isReady())
        incumbent.unlock()
        #expect(!protection.isReady())
    }

    @Test("T026b P2-2: E-core authoritative exit bypasses unknown probes")
    func authoritativeECoreExit() throws {
        let state = T026SignalState()
        let root = ProcessIdentity(pid: 990_091, startAbsTime: 1)
        let helper = ProcessIdentity(pid: 990_092, startAbsTime: 2)
        state.values.withLock { $0.identities = [root.pid: 1, helper.pid: 2] }
        let app = RunningAppInfo(identity: root, bundleID: "test", bundlePath: nil, executablePath: nil,
                                 activationPolicy: .regular, uid: getuid())
        let lane = ECoreLane(signaler: T026Signaler(state))
        _ = try lane.apply(app: app, key: nil, origin: .manual, params: ECoreParams(whileFrontmost: .release), helpers: [helper],
                           journal: T026Journal(boot: "A"))
        state.values.withLock { $0.unknown = [helper.pid] }
        lane.dropMember(helper.pid, authoritative: true, identity: helper)
        #expect(lane.group(root: root.pid)?.pids == [root])
        #expect(state.values.withLock { $0.background.filter { !$0.1 }.isEmpty })
    }

    @Test("T026b P2-4: bundleless runaway requires and accepts the extra background confirmation")
    func runawayBackgroundConfirmation() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig()
        let identity = try #require(ProcessProbe.identity(of: pid))
        rig.apps.add(RunningAppInfo(identity: identity, bundleID: nil, bundlePath: nil,
                                   executablePath: "/tmp/node", activationPolicy: .prohibited, uid: getuid()))
        rig.signals.values.withLock { $0.identities[pid] = identity.startAbsTime }
        defer { ThawTable.remove(pid) }
        let rejected = await rig.gov.perform(.freeze(pid: pid, origin: .runaway, confirmedBackground: false))
        #expect(vetoes(rejected) == [.backgroundNeedsConfirmation])
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: pid, origin: .runaway, confirmedBackground: true))))
        #expect(await rig.gov.frozenMembers(root: pid) == [pid])
        _ = await rig.gov.shutdown()
    }

    @Test("T026b P2-5: failed recovery is bounded even across repeated ticks")
    func tickRecoveryThrottle() async {
        let state = T026bRecoveryState()
        state.succeeds.withLock { $0 = false }
        let gov = Governor(config: testConfig(tempDir("t026b-throttle")), journal: T026bJournal(state),
                           appControl: FakeAppControl(FakeAppState()), protection: FakeProtection(FakeProtectionState()),
                           signaler: T026Signaler(T026SignalState()), tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        for _ in 0..<20 { await gov.tick() }
        #expect(state.attempts.withLock { $0 } == 1)
        #expect(await gov.disabledReason == .bootUnverified)
        _ = await gov.shutdown()
    }

    @Test("T026b P3: unknown identity on wake or thaw never marks freezeUnsafe", arguments: [false, true])
    func unknownHealth(wake: Bool) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig(healthCheckDelay: 0.01)
        let id = ProcessIdentity(pid: pid, startAbsTime: 123)
        rig.apps.add(RunningAppInfo(identity: id, bundleID: "health", bundlePath: nil, executablePath: nil,
                                   activationPolicy: .regular, uid: getuid()))
        rig.signals.values.withLock { $0.identities[pid] = id.startAbsTime }
        defer { ThawTable.remove(pid) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: pid, origin: .manual, confirmedBackground: false))))
        rig.signals.values.withLock { $0.unknown = [pid] }
        if wake { await rig.gov.handle(.didWake) } else { _ = await rig.gov.perform(.thaw(pid: pid)) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!(await rig.gov.isFreezeUnsafe("health")))
        #expect(await rig.gov.pendingUndoPids == [pid])
        rig.signals.values.withLock { $0.unknown = [] }
        _ = await rig.gov.thawAll(reason: .user)
        _ = await rig.gov.shutdown()
    }

    @Test("T026b P2-2: NOTE_EXIT drops a helper despite unknown or matching probes", arguments: [false, true])
    func authoritativeExit(unknown: Bool) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let helperID = try #require(ProcessProbe.identity(of: helper))
        let rig = T026Rig(); rig.add(root, bundlePath: "/tmp/T026.app")
        rig.signals.values.withLock {
            $0.identities[helper] = helperID.startAbsTime
        }
        rig.treeState.provider.withLock { $0 = { _ in [helperID] } }
        defer { ThawTable.remove(root); ThawTable.remove(helper) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        if unknown { rig.signals.values.withLock { _ = $0.unknown.insert(helper) } }
        bag.kill9(helper)
        for _ in 0..<100 {
            if await rig.gov.frozenMembers(root: root) == [root] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.gov.frozenMembers(root: root) == [root])
        #expect(!ThawTable.contains(helper))
        _ = await rig.gov.shutdown()
    }

    @Test("T026b Rev1: NOTE_EXIT after thaw marks unsafe despite unknown or matching probes", arguments: [false, true], [false, true])
    func healthExitAfterThaw(unknown: Bool, rootExits: Bool) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let helperID = try #require(ProcessProbe.identity(of: helper))
        let rig = T026Rig(healthCheckDelay: 0.2)
        rig.add(root, bundle: "com.apple.TextEdit", bundlePath: "/tmp/T026.app")
        rig.signals.values.withLock { $0.identities[helper] = helperID.startAbsTime }
        rig.treeState.provider.withLock { $0 = { _ in [helperID] } }
        defer { ThawTable.remove(root); ThawTable.remove(helper) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        #expect(await rig.gov.perform(.thaw(pid: root)) == .thawed(groups: 1))
        let exited = rootExits ? root : helper
        if unknown { rig.signals.values.withLock { _ = $0.unknown.insert(exited) } }
        bag.kill9(exited)
        for _ in 0..<100 {
            if await rig.gov.isFreezeUnsafe("com.apple.TextEdit") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.gov.isFreezeUnsafe("com.apple.TextEdit"))
        if rootExits {
            rig.apps.m.withLock { $0[root] = nil }
            let relaunched = bag.spawn("/bin/sleep", ["120"])
            rig.add(relaunched, bundle: "com.apple.TextEdit", bundlePath: "/tmp/T026.app")
        }
        let key = AppKey.bundle("com.apple.TextEdit")
        let report = await rig.gov.reconcile(DesiredState(effects: [key: DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 0), origins: [.freeze: [.rule(UUID())]])]))
        #expect(vetoes(report.outcomes[key] ?? .notFound).contains(.unsafeTopology))
        _ = await rig.gov.shutdown()
    }

    @Test("T026b Rev1: probe-error thaw still uses definitive helper exit for health")
    func healthExitAfterProbeErrorThaw() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let helperID = try #require(ProcessProbe.identity(of: helper))
        let rig = T026Rig(healthCheckDelay: 0.2)
        rig.add(root, bundlePath: "/tmp/T026.app")
        rig.signals.values.withLock { $0.identities[helper] = helperID.startAbsTime }
        rig.treeState.provider.withLock { $0 = { _ in [helperID] } }
        defer { ThawTable.remove(root); ThawTable.remove(helper) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        rig.signals.values.withLock { _ = $0.unknown.insert(helper) }
        await rig.gov.handle(.didWake)
        #expect(await rig.gov.frozenRootPids.isEmpty)
        #expect(await rig.gov.pendingUndoPids == [helper])
        #expect(!(await rig.gov.isFreezeUnsafe("dev.ohmtest.t026")))
        bag.kill9(helper)
        for _ in 0..<100 {
            if await rig.gov.isFreezeUnsafe("dev.ohmtest.t026") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.gov.isFreezeUnsafe("dev.ohmtest.t026"))
        #expect(await rig.gov.pendingUndoPids.isEmpty)
        _ = await rig.gov.shutdown()
    }

    @Test("T026b Rev1: expired health check keeps the exit source of a newer freeze")
    func healthWindowRefreeze() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let helperID = try #require(ProcessProbe.identity(of: helper))
        let rig = T026Rig(healthCheckDelay: 0.05)
        rig.add(root, bundlePath: "/tmp/T026.app")
        rig.signals.values.withLock { $0.identities[helper] = helperID.startAbsTime }
        rig.treeState.provider.withLock { $0 = { _ in [helperID] } }
        defer { ThawTable.remove(root); ThawTable.remove(helper) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        _ = await rig.gov.perform(.thaw(pid: root))
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        try await Task.sleep(for: .milliseconds(150))
        rig.signals.values.withLock { _ = $0.unknown.insert(helper) }
        bag.kill9(helper)
        for _ in 0..<100 {
            if await rig.gov.frozenMembers(root: root) == [root] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.gov.frozenMembers(root: root) == [root])
        #expect(!(await rig.gov.isFreezeUnsafe("dev.ohmtest.t026")))
        _ = await rig.gov.shutdown()
    }

    @Test("T026b Rev1: health observation ends on timeout or shutdown", arguments: [false, true])
    func healthWindowEnds(shutdown: Bool) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig(healthCheckDelay: shutdown ? 0.3 : 0.05)
        rig.add(pid)
        defer { ThawTable.remove(pid) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: pid, origin: .manual, confirmedBackground: false))))
        _ = await rig.gov.perform(.thaw(pid: pid))
        if shutdown { _ = await rig.gov.shutdown() }
        else { try await Task.sleep(for: .milliseconds(150)) }
        rig.signals.values.withLock { _ = $0.unknown.insert(pid) }
        bag.kill9(pid)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!(await rig.gov.isFreezeUnsafe("dev.ohmtest.t026")))
        _ = await rig.gov.shutdown()
    }

    @Test("T026b Rev1: unready owned watcher is reaped even when startup identity is unreadable")
    func unreadableWatcherCleanup() throws {
        let paths = JournalPaths(directory: tempDir("t026b-unreadable-watcher"))
        let protection = WatcherProtection(paths: paths, executable: "/bin/sleep", arguments: ["30"],
                                           useLaunchAgent: false)
        protection.identityProbe = { _ in nil }
        #expect(protection.activate() == .spawnedWatcher)
        let pid = try #require(protection.spawnedPid)
        defer {
            // Reap only our still-owned child; never signal a pid already released for reuse.
            if waitpid(pid, nil, WNOHANG) == 0 { safeKill(pid, SIGKILL); _ = waitpid(pid, nil, 0) }
        }
        #expect(!protection.isReady())
        protection.abandon()
        #expect(protection.mode == .none && protection.spawnedPid == nil)
        let result = waitpid(pid, nil, WNOHANG)
        #expect(result == -1 && errno == ECHILD, "abandon must kill and reap its unready child")
    }

    @Test("T026b P2-3: manual E-core release survives a rule keep policy")
    func manualECoreRelease() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig(); rig.add(pid)
        _ = await rig.gov.perform(.eCore(pid: pid, on: true, origin: .manual))
        let key = AppKey.bundle("dev.ohmtest.t026")
        _ = await rig.gov.reconcile(DesiredState(effects: [key: DesiredEffect(eCore: ECoreParams(whileFrontmost: .keep),
                                                                           origins: [.eCore: [.rule(UUID())]])]))
        _ = await rig.gov.reconcile(DesiredState())
        await rig.gov.handle(.activated(pid: pid))
        #expect(await rig.gov.eCoreRootPids.isEmpty)
        _ = await rig.gov.shutdown()
    }

    @Test("T026b P2-4: runaway card is user-confirmed; only rules are automatic")
    func runawayIsManual() {
        #expect(!EffectOrigin.runaway.isAutomatic)
        #expect(EffectOrigin.rule(UUID()).isAutomatic)
    }

    @Test("T026b P2-5: tick retries recovery and re-enables effects")
    func tickRecovery() async {
        let state = T026bRecoveryState()
        let gov = Governor(config: testConfig(tempDir("t026b-retry")), journal: T026bJournal(state),
                           appControl: FakeAppControl(FakeAppState()), protection: FakeProtection(FakeProtectionState()),
                           signaler: T026Signaler(T026SignalState()), tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        #expect(await gov.disabledReason != nil)
        await gov.tick()
        #expect(state.attempts.withLock { $0 } == 1)
        #expect(await gov.disabledReason == nil)
        await gov.tick()
        #expect(state.attempts.withLock { $0 } == 1)
        _ = await gov.shutdown()
    }

    @Test("P1: unknown member during verification stays in the table and pending undo", arguments: [false, true])
    func verifyUnknownHelper(unknownRoot: Bool) throws {
        let state = T026SignalState()
        let root = ProcessIdentity(pid: 990_021, startAbsTime: 1)
        let helper = ProcessIdentity(pid: 990_022, startAbsTime: 2)
        let unknown = unknownRoot ? root : helper
        let resolved = unknownRoot ? helper : root
        state.values.withLock { $0.identities = [root.pid: 1, helper.pid: 2]; $0.unknownAfterStop = [unknown.pid] }
        defer { ThawTable.remove(root.pid); ThawTable.remove(helper.pid) }
        let treeState = TreeState()
        treeState.provider.withLock { $0 = { _ in [helper] } }
        let config = testConfig(tempDir("t026-verify"))
        let policy = SafetyPolicy(probes: FakeProbes(ProbeState()), config: config,
                                  health: FreezeHealthStore(path: config.healthFile))
        let freezer = Freezer(signaler: T026Signaler(state), tree: FakeTree(treeState), policy: policy, config: config)
        let app = RunningAppInfo(identity: root, bundleID: "test", bundlePath: "/tmp/Test.app",
                                 executablePath: nil, activationPolicy: .regular, uid: getuid())
        let result = freezer.freeze(.init(group: UUID(), app: app, origin: .manual, hiddenByOhm: false,
                                          withTree: true), journal: T026Journal(boot: "boot"))
        if case .success = result { Issue.record("unknown identity must not produce a successful partial freeze") }
        #expect(freezer.lastRollbackUnresolved == [unknown])
        #expect(ThawTable.contains(unknown.pid))
        #expect(state.values.withLock { $0.signals.contains { $0.0 == resolved.pid && $0.1 == SIGCONT } })
        state.values.withLock { $0.unknown = [] }
        #expect(freezer.continueMembers([unknown]).isEmpty)
        #expect(!ThawTable.contains(unknown.pid))
    }

    @Test("P1: wake and termination never drop an unknown member", arguments: [false, true])
    func wakeUnknownHelper(unknownRoot: Bool) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let apps = FakeAppState(), signals = T026SignalState(), tree = TreeState()
        let rootApp = appInfo(root, bundle: "/tmp/T026.app")
        let helperID = try #require(ProcessProbe.identity(of: helper))
        apps.add(rootApp)
        signals.values.withLock { $0.identities = [root: rootApp.identity.startAbsTime, helper: helperID.startAbsTime] }
        tree.provider.withLock { $0 = { _ in [helperID] } }
        let gov = Governor(config: testConfig(tempDir("t026-wake")), journal: T026Journal(boot: "boot"),
                           appControl: FakeAppControl(apps), protection: FakeProtection(FakeProtectionState()),
                           signaler: T026Signaler(signals), tree: FakeTree(tree), probes: FakeProbes(ProbeState()))
        defer { ThawTable.remove(root); ThawTable.remove(helper) }
        #expect(isFrozen(await gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        let unknown = unknownRoot ? root : helper
        signals.values.withLock { _ = $0.unknown.insert(unknown) }
        await gov.handle(.didWake)
        await gov.handle(.terminated(pid: helper))
        #expect(ThawTable.contains(unknown))
        let members = await gov.frozenMembers(root: root) ?? []
        let pending = await gov.pendingUndoPids
        #expect(members.contains(unknown) || pending.contains(unknown))
        signals.values.withLock { $0.unknown = [] }
        _ = await gov.thawAll(reason: .user)
        await gov.tick()
        #expect(!ThawTable.contains(unknown))
    }

    @Test("P1: missing trusted boot disables freeze and E-core before kernel effects")
    func bootRequired() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig(boot: nil); rig.add(pid)
        defer { ThawTable.remove(pid) }
        #expect(vetoes(await rig.gov.perform(.freeze(pid: pid, origin: .manual, confirmedBackground: false)))
            .contains(.bootUnverified))
        #expect(vetoes(await rig.gov.perform(.eCore(pid: pid, on: true, origin: .manual))).contains(.bootUnverified))
        #expect(rig.signals.values.withLock { $0.signals.isEmpty && $0.background.isEmpty })
        _ = await rig.gov.shutdown()
    }

    @Test("P1: a frozen helper with unknown identity is retained on termination without a wake event")
    func frozenUnknownExit() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let helperID = try #require(ProcessProbe.identity(of: helper))
        let rig = T026Rig(); rig.add(root, bundlePath: "/tmp/T026.app")
        rig.signals.values.withLock { $0.identities[helper] = helperID.startAbsTime }
        rig.treeState.provider.withLock { $0 = { _ in [helperID] } }
        defer { ThawTable.remove(root); ThawTable.remove(helper) }
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: root, origin: .manual, confirmedBackground: false))))
        #expect(await rig.gov.frozenMembers(root: root) == [root, helper])
        rig.signals.values.withLock { _ = $0.unknown.insert(helper) }
        await rig.gov.handle(.terminated(pid: helper))
        #expect(await rig.gov.frozenMembers(root: root) == [root, helper])
        #expect(ThawTable.contains(helper))
        rig.signals.values.withLock { $0.unknown = [] }
        _ = await rig.gov.perform(.thaw(pid: root))
        #expect(!ThawTable.contains(helper))
        #expect(rig.signals.values.withLock { $0.signals.contains { $0.0 == helper && $0.1 == SIGCONT } })
        _ = await rig.gov.shutdown()
    }

    @Test("Decision: rules require verified topology; user-confirmed runaway, manual and CLI remain available")
    func automaticTopology() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig(); rig.add(pid)
        defer { ThawTable.remove(pid) }
        let key = AppKey.bundle("dev.ohmtest.t026")
        let desired = DesiredState(effects: [key: DesiredEffect(freeze: FreezeParams(minHiddenSeconds: 0),
                                                               origins: [.freeze: [.rule(UUID())]])])
        let report = await rig.gov.reconcile(desired)
        #expect(vetoes(report.outcomes[key] ?? .notFound).contains { $0.rawValue == "unverifiedTopology" })
        _ = await rig.gov.thawAll(reason: .user)
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: pid, origin: .runaway, confirmedBackground: false))))
        _ = await rig.gov.thawAll(reason: .user)
        for origin in [EffectOrigin.manual, .cli] {
            #expect(isFrozen(await rig.gov.perform(.freeze(pid: pid, origin: origin, confirmedBackground: false))))
            _ = await rig.gov.thawAll(reason: .user)
        }
        _ = await rig.gov.perform(.eCore(pid: pid, on: true, origin: .rule(UUID())))
        #expect(await rig.gov.eCoreRootPids == [pid])
        _ = await rig.gov.shutdown()
    }

    @Test("Decision: only the spike-verified TextEdit topology permits automatic freezing")
    func verifiedTextEdit() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let rig = T026Rig(); rig.add(pid, bundle: "com.apple.TextEdit")
        defer { ThawTable.remove(pid) }
        let key = AppKey.bundle("com.apple.TextEdit")
        let desired = DesiredState(effects: [key: DesiredEffect(freeze: FreezeParams(minHiddenSeconds: 0),
                                                               origins: [.freeze: [.rule(UUID())]])])
        let report = await rig.gov.reconcile(desired)
        #expect(isFrozen(report.outcomes[key] ?? .notFound))
        _ = await rig.gov.thawAll(reason: .user)
        #expect(isFrozen(await rig.gov.perform(.freeze(pid: pid, origin: .runaway, confirmedBackground: false))))
        _ = await rig.gov.thawAll(reason: .user)
        _ = await rig.gov.shutdown()
    }

    @Test("P2: reconciled E-core policy controls activation in both directions")
    func eCoreParamsRefresh() async throws {
        for (initial, updated) in [(FrontmostPolicy.keep, FrontmostPolicy.release), (.release, .keep)] {
            let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
            let pid = bag.spawn("/bin/sleep", ["120"])
            let rig = T026Rig(); rig.add(pid)
            let key = AppKey.bundle("dev.ohmtest.t026")
            let origin = EffectOrigin.rule(UUID())
            func desired(_ policy: FrontmostPolicy) -> DesiredState {
                DesiredState(effects: [key: DesiredEffect(eCore: ECoreParams(whileFrontmost: policy),
                                                          origins: [.eCore: [origin]])])
            }
            _ = await rig.gov.reconcile(desired(initial))
            _ = await rig.gov.reconcile(desired(updated))
            await rig.gov.handle(.activated(pid: pid))
            #expect(await rig.gov.eCoreRootPids == (updated == .release ? [] : [pid]))
            #expect(rig.signals.values.withLock { $0.background.filter { $0.1 }.count == 1 }, "refresh must not reapply BG")
            _ = await rig.gov.shutdown()
        }
    }

    @Test("P1: unknown E-core member survives an exit notification until its policy can be undone", arguments: [false, true])
    func eCoreUnknownExit(unknownRoot: Bool) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let helperID = try #require(ProcessProbe.identity(of: helper))
        let rig = T026Rig(); rig.add(root)
        rig.signals.values.withLock { $0.identities[helper] = helperID.startAbsTime }
        rig.treeState.provider.withLock { $0 = { _ in [helperID] } }
        _ = await rig.gov.perform(.eCore(pid: root, on: true, origin: .manual))
        #expect(await rig.gov.eCoreMembers(root: root) == [root, helper])
        let unknown = unknownRoot ? root : helper
        rig.signals.values.withLock { _ = $0.unknown.insert(unknown) }
        await rig.gov.handle(.terminated(pid: unknown))
        let members = await rig.gov.eCoreMembers(root: root) ?? []
        let pending = await rig.gov.pendingUndoPids
        #expect(members.contains(unknown) || pending.contains(unknown))
        rig.signals.values.withLock { $0.unknown = [] }
        _ = await rig.gov.perform(.eCore(pid: root, on: false, origin: .manual))
        await rig.gov.tick()
        #expect(await rig.gov.pendingUndoPids.isEmpty)
        #expect(rig.signals.values.withLock { $0.background.contains { $0.0 == unknown && !$0.1 } })
        _ = await rig.gov.shutdown()
    }

    @Test("T026b P2-1: spawned watcher exits for absent recorded boot; shared user path closes it")
    func spawnedWatcherKeepsLock() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty) }
        let paths = JournalPaths(directory: tempDir("t026-spawned"))
        let owner = try OwnerLock.acquire(paths: paths, retryFor: 0)
        let group = UUID()
        let record = JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_061, start: 1)])
        try record.encodedLine().write(to: URL(fileURLWithPath: paths.journal))
        let watcher = bag.spawn(hostPath, ["thawd", "--spawned", "--dir", paths.directory],
                                log: paths.directory + "/watcher.log")
        try #require(waitUntil(2) { FileLock.isHeldByAnother(path: paths.thawdLock) })
        let identity = try #require(ProcessProbe.identity(of: watcher))
        owner.release()
        try #require(waitUntil(1) { readLog(paths.directory + "/watcher.log").contains("missingRecordedBoot=[990061]") })
        #expect(waitUntil(1) { !ProcessProbe.isLive(identity) })
        #expect(!FileLock.isHeldByAnother(path: paths.thawdLock))
        #expect(JournalReader.read(path: paths.journal).openGroups().map(\.group) == [group])
        let report = try JournalSession.thawAll(paths: paths)
        #expect(report.forcedClosedGroups == [group])
        #expect(JournalReader.read(path: paths.journal).openGroups().isEmpty)
        #expect(JournalReader.read(path: paths.journal).records.contains { $0.group == group && $0.reason == "userForcedUnverified" })
        #expect(waitUntil(1) {
            !ProcessProbe.isLive(identity) && !FileLock.isHeldByAnother(path: paths.thawdLock)
        })
        #expect(!FileLock.isHeldByAnother(path: paths.thawdLock))
    }
}

private final class T026bRecoveryState: Sendable {
    let attempts = Mutex(0)
    let succeeds = Mutex(true)
}

private struct T026bBootSignaler: RecoverySignaling {
    func bootSessionUUID() -> String? { "test" }
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus { .unknown(EPERM) }
    func sendCont(_ pid: Int32) -> Int32 { EPERM }
    func clearBackground(_ pid: Int32) -> Int32 { EPERM }
}

private final class T026bJournal: FreezeJournaling {
    var boot: String?
    var recoveryReport: RecoveryReport? = {
        var report = RecoveryReport()
        report.unverifiedBoot = [JournalPid(pid: 990_072, start: 2)]
        return report
    }()
    let state: T026bRecoveryState
    init(_ state: T026bRecoveryState) { self.state = state }
    func append(_ record: JournalRecord, sync: Bool) throws {}
    func compactIfIdle() throws {}
    func retryRecovery(forceCloseUnverifiable: Bool) throws -> RecoveryReport? {
        state.attempts.withLock { $0 += 1 }
        if !state.succeeds.withLock({ $0 }) { return recoveryReport }
        boot = "verified"
        recoveryReport = RecoveryReport()
        return recoveryReport
    }
}

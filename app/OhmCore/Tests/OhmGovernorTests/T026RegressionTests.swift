import Darwin
import Foundation
@testable import OhmGovernor
import OhmJournal
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
    init(boot: String? = "t026-boot") {
        var config = testConfig(tempDir("t026"))
        config.minHiddenFloor = 0
        config.refreezeGrace = 0
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
            .contains(.journalUnwritable))
        #expect(vetoes(await rig.gov.perform(.eCore(pid: pid, on: true, origin: .manual))).contains(.journalUnwritable))
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

    @Test("Decision: rule and runaway require verified topology; manual, CLI and E-core remain available")
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
        #expect(vetoes(await rig.gov.perform(.freeze(pid: pid, origin: .runaway, confirmedBackground: false)))
            .contains { $0.rawValue == "unverifiedTopology" })
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

    @Test("P1: real spawned watcher stays alive for unknown boot, exits after the open effect is closed")
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
        try #require(waitUntil(1) { readLog(paths.directory + "/watcher.log").contains("unverifiedBoot=[990061]") })
        #expect(ProcessProbe.isLive(identity))
        #expect(FileLock.isHeldByAnother(path: paths.thawdLock))
        #expect(JournalReader.read(path: paths.journal).openGroups().map(\.group) == [group])
        // Simulate an explicit user resolution while holding the same writer lock as the CLI.
        let resolution = try OwnerLock.acquire(paths: paths, retryFor: 1)
        let close = JournalRecord(op: .thaw, group: group, reason: "user")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.journal))
        try handle.seekToEnd()
        try handle.write(contentsOf: close.encodedLine())
        try handle.synchronize()
        try handle.close()
        resolution.release()
        #expect(waitUntil(1) {
            !ProcessProbe.isLive(identity) && !FileLock.isHeldByAnother(path: paths.thawdLock)
        })
        #expect(!FileLock.isHeldByAnother(path: paths.thawdLock))
    }
}

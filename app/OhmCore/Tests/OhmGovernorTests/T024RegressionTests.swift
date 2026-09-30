import Darwin
import Foundation
import OhmGovernor
import OhmJournal
import OhmModel
import Synchronization
import Testing

/// Regression tests for the T-024 review findings. Each one failed on the pre-fix code
/// (see ADR 0004 "T-023 sonuçları" for how each failure was demonstrated).
@Suite("T-024 review regressions", .serialized)
struct T024RegressionTests {

    // MARK: #1 — a failed SIGCONT / BG removal must not be forgotten

    @Test("#1a: failed SIGCONT keeps the group open (table + journal) and is retried")
    func r1_failedThawRetried() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("r1a")
        let a = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a))
        #expect(isFrozen(await rig.freeze(a)))
        rig.sig.contFail.withLock { $0[a] = EPERM }
        _ = await rig.gov.perform(.thaw(pid: a))
        let journal = rig.dir + "/journal.jsonl"
        #expect(isT(a))
        #expect(ThawTable.contains(a), "unresolved member must stay in the crash-handler table")
        #expect(JournalReader.read(path: journal).openGroups().count == 1, "no thaw record while unresolved")
        rig.sig.contFail.withLock { $0 = [:] }
        await rig.gov.tick()
        #expect(waitUntil(1) { !isT(a) })
        #expect(JournalReader.read(path: journal).openGroups().isEmpty)
        #expect(!ThawTable.contains(a))
    }

    @Test("#1b: failed BG removal keeps the E-core group open and is retried")
    func r1_failedECoreOffRetried() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("r1b")
        let y = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        rig.apps.add(appInfo(y))
        _ = await rig.gov.perform(.eCore(pid: y, on: true, origin: .manual))
        rig.sig.bgOffFail.withLock { _ = $0.insert(y) }
        _ = await rig.gov.perform(.eCore(pid: y, on: false, origin: .manual))
        let journal = rig.dir + "/journal.jsonl"
        #expect(JournalReader.read(path: journal).openGroups().count == 1, "no ecoreOff while unresolved")
        rig.sig.bgOffFail.withLock { $0 = [] }
        await rig.gov.tick()
        #expect(rig.sig.background.withLock { $0.contains { $0.0 == y && !$0.1 } })
        #expect(JournalReader.read(path: journal).openGroups().isEmpty)
    }

    @Test("#1c: identity probe error during thaw is unresolved, not 'gone'; retried")
    func r1_identityUnknownRetried() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("r1c")
        let a = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a))
        #expect(isFrozen(await rig.freeze(a)))
        rig.sig.identityUnknown.withLock { _ = $0.insert(a) }
        _ = await rig.gov.perform(.thaw(pid: a))
        #expect(isT(a) && ThawTable.contains(a))
        #expect(await rig.gov.pendingUndoPids == [a])
        rig.sig.identityUnknown.withLock { $0 = [] }
        await rig.gov.tick()
        #expect(waitUntil(1) { !isT(a) })
        #expect(await rig.gov.pendingUndoPids.isEmpty)
    }

    // MARK: #2 — journal renewal failure must stop effects

    @Test("#2a: short write during compaction → later appends refuse (no glued freeze record)")
    func r2_compactionShortWrite() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("r2a")
        let host = bag.spawn(hostPath, ["compact-fault", "--dir", dir], log: dir + "/h.log")
        var st: Int32 = 0
        _ = waitpid(host, &st, 0)
        let log = readLog(dir + "/h.log")
        print("T-024 #2a: \(log.split(separator: "\n").map { $0.drop { $0 != "]" }.dropFirst(2) }.joined(separator: " | "))")
        #expect(log.contains("COMPACT threw"))
        #expect(log.contains("APPEND threw"))
        #expect(!log.contains("corrupt=true"))
    }

    @Test("#2b: short write while recovery rewrites the journal → JournalSession.open throws")
    func r2_rewriteShortWrite() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("r2b")
        let host = bag.spawn(hostPath, ["rewrite-fault", "--dir", dir], log: dir + "/h.log")
        var st: Int32 = 0
        _ = waitpid(host, &st, 0)
        let log = readLog(dir + "/h.log")
        print("T-024 #2b: \(log.split(separator: "\n").map { $0.drop { $0 != "]" }.dropFirst(2) }.joined(separator: " | "))")
        #expect(log.contains("OPEN threw"))
    }

    // MARK: #6 — the crash handler re-verifies identity

    @Test("#6: crash handler does not SIGCONT a table entry whose start time does not match (pid reuse)")
    func r6_handlerVerifiesIdentity() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("r6h")
        let target = bag.spawn("/bin/sleep", ["120"])
        let host = bag.spawn(hostPath, ["sigtest", "--pid", "\(target)", "--wrong-start"], log: dir + "/sig.log")
        var st: Int32 = 0
        _ = waitpid(host, &st, 0)
        usleep(200_000)
        let stillT = isT(target)
        print("T-024 #6 handler: host died by signal \(st & 0x7f); target with mismatching table entry stat=\(stillT ? "T" : "S")")
        #expect(readLog(dir + "/sig.log").contains("STOPPED stat=T"))
        #expect(stillT, "the handler must not signal an unverified identity")
    }

    // MARK: #7 — a probe that cannot measure is a veto

    @Test("#7: failing safety probes veto the freeze (never 'safe')")
    func r7_probeFailureVetoes() async throws {
        for probe in ["audio", "assertions", "taps", "traced", "children"] {
            let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
            let rig = try Rig("r7-\(probe)")
            let a = bag.spawn("/bin/sleep", ["120"])
            rig.apps.add(appInfo(a, bundle: "/tmp/ohm-t024-fake.app"))
            rig.probes.failing.withLock { _ = $0.insert(probe) }
            let o = await rig.freeze(a)
            #expect(vetoes(o).contains(.safetyProbeFailed), "\(probe): \(o)")
            #expect(rig.sig.sent(SIGSTOP).isEmpty && !isT(a))
        }
    }

    // MARK: #4 — reconcile must not act on a request that changed while it was suspended

    @Test("#4: rule (freeze + E-core) deleted during the hide wait → no BG applied")
    func r4_staleReconcile() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("r4") { $0.minHiddenFloor = 0 }
        let y = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        let key = AppKey.bundle("com.apple.TextEdit")
        rig.apps.add(appInfo(y, bundleID: key.value), hidden: false)
        let gov = rig.gov
        rig.apps.onHide.withLock { $0 = { _ in Task { _ = await gov.reconcile(DesiredState()) } } }
        let rule = EffectOrigin.rule(UUID())
        _ = await gov.reconcile(DesiredState(effects: [key: DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 0), eCore: ECoreParams(whileFrontmost: .keep),
            origins: [.freeze: [rule], .eCore: [rule]])]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gov.eCoreRootPids.isEmpty)
        #expect(!rig.sig.background.withLock { $0.contains { $0.0 == y && $0.1 } })
        #expect(rig.sig.sent(SIGSTOP).isEmpty)
    }

    // MARK: #5 — protection readiness and a non-blocked actor

    @Test("#5a: tick with unready protection neither extends BG nor keeps effects")
    func r5_tickUnready() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("r5a")
        let root = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        let helper = bag.spawn("/bin/sleep", ["120"])
        let hid = ProcessProbe.identity(of: helper)!
        let includeHelper = Atomic<Bool>(false)
        rig.treeState.provider.withLock {
            $0 = { _ in includeHelper.load(ordering: .sequentiallyConsistent) ? [hid] : [] }
        }
        rig.apps.add(appInfo(root, bundle: "/tmp/ohm-t024-fake.app"))
        _ = await rig.gov.perform(.eCore(pid: root, on: true, origin: .manual))
        #expect(await rig.gov.eCoreRootPids == [root])
        rig.prot.ready.store(false, ordering: .sequentiallyConsistent)
        includeHelper.store(true, ordering: .sequentiallyConsistent)
        await rig.gov.tick()
        #expect(!rig.sig.background.withLock { $0.contains { $0.0 == helper && $0.1 } })
        #expect(await rig.gov.eCoreRootPids.isEmpty)
    }

    @Test("#5b: watcher that never takes thawd.lock → mode none (not a silent spawnedWatcher)")
    func r5_spawnTimeout() async throws {
        let dir = tempDir("r5b")
        let before = Set(childrenOfTest(exe: "/bin/sleep"))
        let prot = WatcherProtection(paths: JournalPaths(directory: dir), executable: "/bin/sleep", arguments: ["30"],
                                     useLaunchAgent: false)
        let gov = Governor(config: testConfig(dir), journal: try openJournal(dir), appControl: FakeAppControl(FakeAppState()),
                           protection: prot, tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        let mode = await gov.startProtection()
        let leftover = Set(childrenOfTest(exe: "/bin/sleep")).subtracting(before)
        for p in leftover { safeKill(p, SIGKILL); waitpid(p, nil, 0) }
        #expect(mode == .none)
        #expect(leftover.isEmpty, "the unready watcher child must be killed")
    }

    @Test("#5c: the watcher start-up wait does not block the Governor (activation handled < 300 ms)")
    func r5_actorNotBlocked() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("r5c")
        let before = Set(childrenOfTest(exe: "/bin/sleep"))
        let prot = WatcherProtection(paths: JournalPaths(directory: dir), executable: "/bin/sleep", arguments: ["30"],
                                     useLaunchAgent: false)
        let gov = Governor(config: testConfig(dir), journal: try openJournal(dir), appControl: FakeAppControl(FakeAppState()),
                           protection: prot, tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        let a = bag.spawn("/bin/sleep", ["120"])
        let start = Task { await gov.startProtection() }
        try await Task.sleep(for: .milliseconds(50))
        let t0 = nowNs()
        await gov.handle(.activated(pid: a))
        let ms = Double(nowNs() - t0) / 1e6
        _ = await start.value
        for p in Set(childrenOfTest(exe: "/bin/sleep")).subtracting(before) where p != a { safeKill(p, SIGKILL); waitpid(p, nil, 0) }
        print("T-024 #5c: activation handled after \(String(format: "%.1f", ms)) ms while the watcher start-up wait ran")
        #expect(ms < 300)
    }
}

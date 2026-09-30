import Darwin
import Foundation
import OhmGovernor
import OhmJournal
import OhmModel
import Synchronization
import Testing

/// In-process rig: real journal, real signals to test-spawned processes, fake AppKit/probes/protection.
struct Rig {
    let dir: String
    let apps = FakeAppState()
    let prot = FakeProtectionState()
    let probes = ProbeState()
    let sig = SignalLog()
    let treeState = TreeState()
    let fault = JournalFault()
    let gov: Governor

    init(_ tag: String, realTree: Bool = false, realProbes: Bool = false, journal: Bool = true,
         dir: String? = nil, _ mod: (inout GovernorConfig) -> Void = { _ in }) throws {
        let d = dir ?? tempDir(tag)
        self.dir = d
        var cfg = testConfig(d)
        mod(&cfg)
        let j: FaultyJournal? = journal ? FaultyJournal(try openJournal(d), fault) : nil
        let tree: any ProcessTreeEnumerating = realTree ? SystemProcessTree() : FakeTree(treeState)
        let pr: any SafetyProbing = realProbes ? SystemSafetyProbes() : FakeProbes(probes)
        gov = Governor(config: cfg, journal: j, appControl: FakeAppControl(apps), protection: FakeProtection(prot),
                       signaler: RecordingSignaler(sig), tree: tree, probes: pr)
    }

    func freeze(_ pid: Int32) async -> GovernorOutcome {
        await gov.perform(.freeze(pid: pid, origin: .manual, confirmedBackground: false))
    }
}

func vetoes(_ o: GovernorOutcome) -> [FreezeVeto] { if case .vetoed(let v) = o { v } else { [] } }
func isFrozen(_ o: GovernorOutcome) -> Bool { if case .frozen = o { true } else { false } }

/// Fake bundle whose root is a copy of the host with one in-bundle helper child.
func spawnFakeApp(_ bag: ProcessBag, dir: String, helperArgs: [String] = [], rootArgs: [String] = [],
                  extraChild: String? = nil, log: String? = nil) -> (root: Int32, helper: Int32, bundle: String) {
    let (bundle, exe) = makeFakeBundle(dir)
    var args = ["app-root"] + rootArgs + ["--child", ([exe, "app-helper"] + helperArgs).joined(separator: " ")]
    if let extraChild { args += ["--child", extraChild] }
    let root = bag.spawn(exe, args, log: log)
    var helper: Int32 = 0
    waitUntil(3) {
        let kids = ProcessProbe.childPids(root).filter { ProcessProbe.executablePath($0) == exe }
        helper = kids.first ?? 0
        return helper != 0
    }
    for k in ProcessProbe.childPids(root) { bag.adopt(k) }
    return (root, helper, bundle)
}

func childrenOfTest(exe: String) -> [Int32] {
    ProcessProbe.childPids(getpid()).filter { ProcessProbe.executablePath($0) == exe }
}

@Suite("ADR 0004 § 10 — Governor", .serialized)
struct OhmGovernorTests {

    // MARK: 1, 2, 3, 16, 22 — separate processes

    @Test("1: kill -9 Ohm while an app is frozen → watcher thaws within 1 s")
    func t01_kill9Watcher() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t01")
        let target = bag.spawn("/bin/sleep", ["120"])
        let thawd = bag.spawn(hostPath, ["thawd", "--dir", dir], log: dir + "/thawd.log")
        #expect(waitUntil(2) { FileLock.isHeldByAnother(path: dir + "/thawd.lock") })
        let ohm = bag.spawn(hostPath, ["ohm", "--dir", dir, "--freeze-pid", "\(target)"], log: dir + "/ohm.log")
        #expect(waitUntil(5) { readLog(dir + "/ohm.log").contains("READY") })
        #expect(readLog(dir + "/ohm.log").contains("FREEZE frozen"))
        #expect(isT(target))
        let t0 = nowNs()
        bag.kill9(ohm)
        let thawed = waitUntil(1) { !isT(target) }
        let ms = Double(nowNs() - t0) / 1e6
        print("T-023 test1: kill -9 Ohm → target stat=\(isT(target) ? "T" : "S") after \(String(format: "%.1f", ms)) ms (watcher pid \(thawd))")
        #expect(thawed)
        #expect(ms < 1000)
    }

    @Test("2: Ohm and watcher both kill -9 → next launch recovery thaws (launchd restart: MANUAL, test 13)")
    func t02_killBoth() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t02")
        let target = bag.spawn("/bin/sleep", ["120"])
        let thawd = bag.spawn(hostPath, ["thawd", "--dir", dir], log: dir + "/thawd.log")
        #expect(waitUntil(2) { FileLock.isHeldByAnother(path: dir + "/thawd.lock") })
        let ohm = bag.spawn(hostPath, ["ohm", "--dir", dir, "--freeze-pid", "\(target)"], log: dir + "/ohm.log")
        #expect(waitUntil(5) { readLog(dir + "/ohm.log").contains("READY") })
        bag.kill9(thawd)
        bag.kill9(ohm)
        usleep(300_000)
        let stillT = isT(target)
        let (_, report) = try JournalSession.open(paths: JournalPaths(directory: dir), ownerLockRetry: 1)
        let after = isT(target)
        print("T-023 test2: both killed → stat=\(stillT ? "T" : "S"); next-launch recovery thawed=\(report.thawed.map(\.pid)) → stat=\(after ? "T" : "S")")
        #expect(stillT)
        #expect(!after)
    }

    @Test("3: SIGSEGV in the process holding the thaw table → C handler thaws")
    func t03_sigsegv() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t03")
        let target = bag.spawn("/bin/sleep", ["120"])
        let host = bag.spawn(hostPath, ["sigtest", "--pid", "\(target)"], log: dir + "/sig.log")
        var st: Int32 = 0
        _ = waitpid(host, &st, 0)
        let signalled = (st & 0x7f) != 0
        let termSig = st & 0x7f
        let thawed = waitUntil(1) { !isT(target) }
        print("T-023 test3: host died by signal \(termSig) (SIGSEGV=\(SIGSEGV), SIGBUS=\(SIGBUS)); target stat=\(isT(target) ? "T" : "S"); log: \(readLog(dir + "/sig.log").split(separator: "\n").first ?? "")")
        #expect(readLog(dir + "/sig.log").contains("STOPPED stat=T"))
        #expect(signalled && (termSig == SIGSEGV || termSig == SIGBUS))
        #expect(thawed)
    }

    @Test("16: E-core only (no freeze ever) + kill -9 Ohm → watcher removes PRIO_DARWIN_BG, P share back to ~1")
    func t16_eCoreKill9() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t16")
        let yes = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        let before = pShare(yes, seconds: 0.5) ?? -1
        _ = bag.spawn(hostPath, ["thawd", "--dir", dir], log: dir + "/thawd.log")
        #expect(waitUntil(2) { FileLock.isHeldByAnother(path: dir + "/thawd.lock") })
        let ohm = bag.spawn(hostPath, ["ohm", "--dir", dir, "--ecore-pid", "\(yes)"], log: dir + "/ohm.log")
        #expect(waitUntil(5) { readLog(dir + "/ohm.log").contains("READY") })
        #expect(readLog(dir + "/ohm.log").contains("ECORE eCoreApplied"))
        #expect(!readLog(dir + "/ohm.log").contains("FREEZE"))
        let during = pShare(yes) ?? -1
        bag.kill9(ohm)
        usleep(1_000_000)
        let after = pShare(yes) ?? -1
        print("T-023 test16: P_share baseline=\(String(format: "%.2f", before)) E-core=\(String(format: "%.2f", during)) after kill -9 Ohm=\(String(format: "%.2f", after))")
        #expect(during < 0.2)
        #expect(after > 0.9)
    }

    @Test("22a: spawnedWatcher end to end — Ohm spawns the watcher; kill -9 Ohm → thawed and BG removed within 1 s")
    func t22_spawnedWatcherKill9() throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t22")
        let target = bag.spawn("/bin/sleep", ["120"])
        let yes = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        let ohm = bag.spawn(hostPath, ["ohm", "--dir", dir, "--spawn-watcher", hostPath,
                                       "--freeze-pid", "\(target)", "--ecore-pid", "\(yes)"], log: dir + "/ohm.log")
        #expect(waitUntil(6) { readLog(dir + "/ohm.log").contains("READY") })
        let log = readLog(dir + "/ohm.log")
        #expect(log.contains("protection=spawnedWatcher"))
        #expect(log.contains("FREEZE frozen"))
        #expect(log.contains("ECORE eCoreApplied"))
        #expect(isT(target))
        let during = pShare(yes, seconds: 0.5) ?? -1
        let t0 = nowNs()
        bag.kill9(ohm)
        let thawed = waitUntil(1) { !isT(target) }
        let ms = Double(nowNs() - t0) / 1e6
        let after = pShare(yes, seconds: 0.5) ?? -1
        print("T-023 test22: spawnedWatcher: kill -9 Ohm → stat=\(isT(target) ? "T" : "S") after \(String(format: "%.1f", ms)) ms; P_share E-core=\(String(format: "%.2f", during)) after=\(String(format: "%.2f", after))")
        #expect(thawed)
        #expect(after > 0.9)
        // The spawned watcher exits by itself after recovery.
        #expect(waitUntil(2) { !FileLock.isHeldByAnother(path: dir + "/thawd.lock") })
    }

    @Test("22b: watcher child killed → respawned; respawn impossible → mode none and effects undone")
    func t22_respawn() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t22b")
        let exe = dir + "/watcher-copy"
        try FileManager.default.copyItem(atPath: hostPath, toPath: exe)
        defer { for p in childrenOfTest(exe: exe) { safeKill(p, SIGKILL); waitpid(p, nil, 0) } }
        let apps = FakeAppState()
        let paths = JournalPaths(directory: dir)
        let prot = WatcherProtection(paths: paths, executable: exe, arguments: ["thawd", "--spawned", "--dir", dir],
                                     useLaunchAgent: false)
        let gov = Governor(config: testConfig(dir), journal: try openJournal(dir), appControl: FakeAppControl(apps),
                           protection: prot, tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        #expect(await gov.startProtection() == .spawnedWatcher)
        let w1 = childrenOfTest(exe: exe).first ?? 0
        #expect(w1 != 0, "children: \(ProcessProbe.childPids(getpid()).map { ($0, ProcessProbe.executablePath($0) ?? "?") }) exe=\(exe)")
        guard w1 > 1 else { return }
        let target = bag.spawn("/bin/sleep", ["120"])
        let yes = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        apps.add(appInfo(target, bundleID: "dev.ohmtest.a"))
        apps.add(appInfo(yes, bundleID: "dev.ohmtest.b"))
        #expect(isFrozen(await gov.perform(.freeze(pid: target, origin: .manual, confirmedBackground: false))))
        _ = await gov.perform(.eCore(pid: yes, on: true, origin: .manual))
        #expect(await gov.eCoreRootPids == [yes])

        safeKill(w1, SIGKILL)
        _ = waitUntil(3) { (childrenOfTest(exe: exe).first ?? w1) != w1 && FileLock.isHeldByAnother(path: paths.thawdLock) }
        try await Task.sleep(for: .milliseconds(200))
        let w2 = childrenOfTest(exe: exe).first ?? 0
        let modeAfterRespawn = await gov.protectionMode
        #expect(modeAfterRespawn == .spawnedWatcher)
        #expect(w2 != 0 && w2 != w1)
        #expect(isT(target))

        try FileManager.default.removeItem(atPath: exe)
        safeKill(w2, SIGKILL)
        var mode = ProtectionMode.spawnedWatcher
        for _ in 0..<100 where mode != .none {
            try await Task.sleep(for: .milliseconds(20))
            mode = await gov.protectionMode
        }
        let frozen = await gov.frozenRootPids
        let ecore = await gov.eCoreRootPids
        print("T-023 test22b: watcher \(w1) killed → respawned as \(w2) (mode \(modeAfterRespawn)); respawn impossible → mode \(mode), frozen=\(frozen) ecore=\(ecore) target stat=\(isT(target) ? "T" : "S")")
        #expect(mode == .none)
        #expect(frozen.isEmpty && ecore.isEmpty)
        #expect(!isT(target))
        let o = await gov.perform(.freeze(pid: target, origin: .manual, confirmedBackground: false))
        #expect(vetoes(o).contains(.protectionNotReady))
    }

    // MARK: 7, 10 — tree order and root death (real tree)

    @Test("7: helper app — root stops first, helper wakes first")
    func t07_order() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t07", realTree: true)
        let app = spawnFakeApp(bag, dir: rig.dir)
        rig.apps.add(appInfo(app.root, bundle: app.bundle))
        let o = await rig.freeze(app.root)
        #expect(isFrozen(o))
        let members = await rig.gov.frozenMembers(root: app.root) ?? []
        #expect(members == [app.root, app.helper])
        #expect(rig.sig.sent(SIGSTOP) == [app.root, app.helper])
        #expect(isT(app.root) && isT(app.helper))
        #expect(await rig.gov.perform(.thaw(pid: app.root)) == .thawed(groups: 1))
        #expect(rig.sig.sent(SIGCONT) == [app.helper, app.root])
        #expect(!isT(app.root) && !isT(app.helper))
        print("T-023 test7: SIGSTOP order \(rig.sig.sent(SIGSTOP)) (root=\(app.root)); SIGCONT order \(rig.sig.sent(SIGCONT))")
    }

    @Test("10: frozen root killed externally → helpers are not left in T")
    func t10_rootKilled() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t10", realTree: true)
        let app = spawnFakeApp(bag, dir: rig.dir)
        rig.apps.add(appInfo(app.root, bundle: app.bundle))
        #expect(isFrozen(await rig.freeze(app.root)))
        #expect(isT(app.helper))
        let t0 = nowNs()
        bag.kill9(app.root)
        let ok = waitUntil(1) { !isT(app.helper) }
        print("T-023 test10: root killed → helper stat=\(isT(app.helper) ? "T" : "S") after \(Double(nowNs() - t0) / 1e6) ms")
        #expect(ok)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.gov.frozenRootPids.isEmpty)
    }

    // MARK: 8, 9, 11, 12, 15

    @Test("8: willPowerOff → everything thawed, new freezes refused")
    func t08_powerOff() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t08")
        let a = bag.spawn("/bin/sleep", ["120"]), b = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a, bundleID: "dev.ohmtest.a"))
        rig.apps.add(appInfo(b, bundleID: "dev.ohmtest.b"))
        #expect(isFrozen(await rig.freeze(a)))
        await rig.gov.handle(.willPowerOff)
        #expect(!isT(a))
        let o = await rig.freeze(b)
        #expect(vetoes(o).contains(.powerOffInProgress))
        #expect(!rig.sig.sent(SIGSTOP).contains(b))
        print("T-023 test8: after willPowerOff a=\(isT(a) ? "T" : "S"); freeze(b) → \(o)")
    }

    @Test("9: real vetoes — audio, power assertion, event tap, out-of-bundle child; none is frozen")
    func t09_vetoes() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t09", realTree: true, realProbes: true)
        // Audio: afplay of a silent WAV.
        let wav = rig.dir + "/silence.wav"
        FileManager.default.createFile(atPath: wav, contents: silentWAV(seconds: 20))
        let afplay = bag.spawn("/usr/bin/afplay", ["-v", "0", wav])
        let audioSeen = waitUntil(5) { SystemSafetyProbes().audioActive(pid: afplay) == true }
        // Power assertion.
        let caff = bag.spawn("/usr/bin/caffeinate", ["-i", "-t", "60"])
        _ = waitUntil(3) { SystemSafetyProbes().assertionHolders()?.contains(caff) == true }
        // Event tap.
        let tapLog = rig.dir + "/tap.log"
        let tap = bag.spawn(hostPath, ["eventtap"], log: tapLog)
        _ = waitUntil(3) { readLog(tapLog).contains("TAP") }
        // Out-of-bundle child: fake app root that runs /bin/sleep.
        let app = spawnFakeApp(bag, dir: rig.dir, extraChild: "/bin/sleep 120")
        for k in ProcessProbe.childPids(app.root) { bag.adopt(k) }

        let cases: [(String, Int32, FreezeVeto, String?)] = [
            ("audio", afplay, .audio, nil), ("powerAssertion", caff, .powerAssertion, nil),
            ("eventTap", tap, .eventTap, nil), ("outOfBundleChild", app.root, .outOfBundleChild, app.bundle),
        ]
        for (name, pid, expected, bundle) in cases {
            rig.apps.add(appInfo(pid, bundleID: "dev.ohmtest.\(name)", bundle: bundle))
            let o = await rig.freeze(pid)
            print("T-023 test9 \(name): pid \(pid) → \(o)\(name == "audio" ? " (audio seen by probe: \(audioSeen))" : "")\(name == "eventTap" ? " [\(readLog(tapLog).contains("TAP ok") ? "tap ok" : "tap FAILED")]" : "")")
            #expect(vetoes(o).contains(expected), "\(name)")
            #expect(!isT(pid))
        }
        #expect(rig.sig.sent(SIGSTOP).isEmpty)
    }

    @Test("9b: camera in use → rules freeze nothing (fake probe; camera cannot be switched on unattended)")
    func t09_camera() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t09b") { $0.minHiddenFloor = 0 }
        let a = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a, bundleID: "dev.ohmtest.cam"))
        rig.probes.camera.store(true, ordering: .sequentiallyConsistent)
        let key = AppKey.bundle("dev.ohmtest.cam")
        let r = await rig.gov.reconcile(DesiredState(effects: [key: DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 0), origins: [.freeze: [.rule(UUID())]])]))
        #expect(vetoes(r.outcomes[key] ?? .notFound).contains(.camera))
        #expect(!isT(a))
    }

    @Test("11: journal directory read-only → freeze refused, no SIGSTOP")
    func t11_readOnlyJournal() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t11")
        chmod(dir, 0o500)
        defer { chmod(dir, 0o700) }
        var opened = true
        do { _ = try openJournal(dir) } catch { opened = false }
        #expect(!opened)
        let rig = try Rig("t11", journal: false, dir: dir)
        let a = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a))
        let o = await rig.freeze(a)
        print("T-023 test11: read-only journal dir → journal open failed=\(!opened); freeze → \(o)")
        #expect(vetoes(o).contains(.journalUnwritable))
        #expect(rig.sig.sent(SIGSTOP).isEmpty && !isT(a))
    }

    @Test("12: thawd.lock not held (watcher absent) → freeze refused")
    func t12_noWatcherLock() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let dir = tempDir("t12")
        let before = Set(childrenOfTest(exe: "/bin/sleep"))
        // A "watcher" that is alive but never takes thawd.lock.
        let prot = WatcherProtection(paths: JournalPaths(directory: dir), executable: "/bin/sleep", arguments: ["30"],
                                     useLaunchAgent: false)
        let sig = SignalLog()
        let apps = FakeAppState()
        let gov = Governor(config: testConfig(dir), journal: try openJournal(dir), appControl: FakeAppControl(apps),
                           protection: prot, signaler: RecordingSignaler(sig), tree: FakeTree(TreeState()),
                           probes: FakeProbes(ProbeState()))
        let mode = await gov.startProtection()
        for p in Set(childrenOfTest(exe: "/bin/sleep")).subtracting(before) { bag.adopt(p) }
        let a = bag.spawn("/bin/sleep", ["120"])
        apps.add(appInfo(a))
        let o = await gov.perform(.freeze(pid: a, origin: .manual, confirmedBackground: false))
        print("T-023 test12: mode=\(mode), thawd.lock held=\(FileLock.isHeldByAnother(path: dir + "/thawd.lock")) → \(o)")
        #expect(vetoes(o).contains(.protectionNotReady))
        #expect(sig.sent(SIGSTOP).isEmpty)
        for p in Set(childrenOfTest(exe: "/bin/sleep")).subtracting(before) where p != a {
            safeKill(p, SIGKILL); waitpid(p, nil, 0)
        }
    }

    @Test("15: frontmost app → .frontmost for manual and rule freeze, no SIGSTOP")
    func t15_frontmost() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t15") { $0.minHiddenFloor = 0 }
        let a = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a, bundleID: "dev.ohmtest.front"), active: true)
        let manual = await rig.freeze(a)
        let key = AppKey.bundle("dev.ohmtest.front")
        let r = await rig.gov.reconcile(DesiredState(effects: [key: DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 0), origins: [.freeze: [.rule(UUID())]])]))
        print("T-023 test15: manual → \(manual); rule → \(r.outcomes[key] ?? .notFound)")
        #expect(vetoes(manual).contains(.frontmost))
        #expect(vetoes(r.outcomes[key] ?? .notFound).contains(.frontmost))
        #expect(rig.sig.sent(SIGSTOP).isEmpty)
    }

    // MARK: 17 — rollback fault injection

    @Test("17a: second journal record fails → rollback within 100 ms, group absent, effects disabled")
    func t17_journalFault() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t17a")
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let hid = ProcessProbe.identity(of: helper)!
        rig.treeState.provider.withLock { $0 = { _ in [hid] } }
        rig.apps.add(appInfo(root, bundle: "/tmp/ohm-t023-fake.app"))
        rig.fault.failFrom.store(2, ordering: .sequentiallyConsistent)
        let o = await rig.freeze(root)
        let recs = rig.sig.all()
        let stop = recs.first { $0.pid == root && $0.sig == SIGSTOP }
        let cont = recs.first { $0.pid == root && $0.sig == SIGCONT }
        let ms = stop.flatMap { s in cont.map { Double($0.ns - s.ns) / 1e6 } } ?? -1
        let disabled = await rig.gov.disabledReason
        print("T-023 test17a: \(o); root SIGSTOP→SIGCONT \(String(format: "%.2f", ms)) ms; helper stopped=\(rig.sig.sent(SIGSTOP).contains(helper)); disabled=\(String(describing: disabled))")
        #expect(ms >= 0 && ms < 100)
        #expect(!isT(root) && !isT(helper))
        #expect(await rig.gov.frozenRootPids.isEmpty)
        #expect(disabled == .journalUnwritable)
        // Effects stay disabled: E-core also refused.
        let e = await rig.gov.perform(.eCore(pid: root, on: true, origin: .manual))
        #expect(vetoes(e).contains(.journalUnwritable))
    }

    @Test("17b: identity mismatch on a helper → rollback")
    func t17_identity() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t17b")
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let wrong = ProcessIdentity(pid: helper, startAbsTime: ProcessProbe.startAbs(helper)! + 1)
        rig.treeState.provider.withLock { $0 = { _ in [wrong] } }
        rig.apps.add(appInfo(root, bundle: "/tmp/ohm-t023-fake.app"))
        let o = await rig.freeze(root)
        print("T-023 test17b: \(o)")
        guard case .rolledBack(.rollback, _) = o else { Issue.record("expected rollback, got \(o)"); return }
        #expect(!isT(root) && !isT(helper))
        #expect(!rig.sig.sent(SIGSTOP).contains(helper))
        #expect(await rig.gov.frozenRootPids.isEmpty)
    }

    @Test("17c: verification timeout → rollback (verifyFailed)")
    func t17_verifyTimeout() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t17c")
        let root = bag.spawn("/bin/sleep", ["120"]), helper = bag.spawn("/bin/sleep", ["120"])
        let hid = ProcessProbe.identity(of: helper)!
        rig.treeState.provider.withLock { $0 = { _ in [hid] } }
        rig.sig.stall.withLock { $0 = ([helper], nowNs() + 10_000_000_000) }
        rig.apps.add(appInfo(root, bundle: "/tmp/ohm-t023-fake.app"))
        let t0 = nowNs()
        let o = await rig.freeze(root)
        let ms = Double(nowNs() - t0) / 1e6
        print("T-023 test17c: \(o) after \(String(format: "%.0f", ms)) ms")
        guard case .rolledBack(.verifyFailed, _) = o else { Issue.record("expected verifyFailed, got \(o)"); return }
        #expect(!isT(root) && !isT(helper))
        #expect(await rig.gov.frozenRootPids.isEmpty)
    }

    // MARK: 18, 21 — Phase A race and hide restore

    @Test("18: events during the hide wait → no SIGSTOP and Ohm's hide is undone")
    func t18_race() async throws {
        let triggers = ["willPowerOff", "ruleDeleted", "watcherGone", "audioStarts", "activated"]
        for trig in triggers {
            let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
            let rig = try Rig("t18-\(trig)") { $0.minHiddenFloor = 0 }
            let a = bag.spawn("/bin/sleep", ["120"])
            let key = AppKey.bundle(trig == "ruleDeleted" ? "com.apple.TextEdit" : "dev.ohmtest.race")
            rig.apps.add(appInfo(a, bundleID: key.value), hidden: false)
            let gov = rig.gov, prot = rig.prot, probes = rig.probes
            rig.apps.onHide.withLock {
                $0 = { pid in
                    switch trig {
                    case "willPowerOff": Task { await gov.handle(.willPowerOff) }
                    case "ruleDeleted": Task { _ = await gov.reconcile(DesiredState()) }
                    case "watcherGone": prot.ready.store(false, ordering: .sequentiallyConsistent)
                    case "audioStarts": probes.audio.withLock { _ = $0.insert(pid) }
                    default: Task { await gov.handle(.activated(pid: pid)) }
                    }
                }
            }
            let outcome: GovernorOutcome
            if trig == "ruleDeleted" {
                let r = await gov.reconcile(DesiredState(effects: [key: DesiredEffect(
                    freeze: FreezeParams(minHiddenSeconds: 0), origins: [.freeze: [.rule(UUID())]])]))
                outcome = r.outcomes[key] ?? .notFound
            } else {
                outcome = await rig.freeze(a)
            }
            let e = rig.apps.entry(a)!
            print("T-023 test18 \(trig): \(outcome); hide=\(e.hideCalls) unhide=\(e.unhideCalls)")
            #expect(!vetoes(outcome).isEmpty, "\(trig)")
            #expect(rig.sig.sent(SIGSTOP).isEmpty, "\(trig)")
            #expect(e.hideCalls == 1 && e.unhideCalls == 1, "\(trig)")
            #expect(!isT(a))
        }
    }

    @Test("21: failed freeze re-shows only what Ohm hid")
    func t21_restoreHide() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        // Visible app, veto appears during Phase A → re-shown.
        do {
            let rig = try Rig("t21a")
            let a = bag.spawn("/bin/sleep", ["120"])
            rig.apps.add(appInfo(a), hidden: false)
            let probes = rig.probes
            rig.apps.onHide.withLock { $0 = { pid in probes.audio.withLock { _ = $0.insert(pid) } } }
            let o = await rig.freeze(a)
            let e = rig.apps.entry(a)!
            #expect(vetoes(o).contains(.audio))
            #expect(e.unhideCalls == 1 && !e.hidden)
        }
        // Visible app that never becomes hidden → .notHidden, re-shown.
        do {
            let rig = try Rig("t21b")
            let a = bag.spawn("/bin/sleep", ["120"])
            rig.apps.add(appInfo(a), hidden: false)
            rig.apps.set(a) { $0.hideDelay = 60 }
            let o = await rig.freeze(a)
            #expect(vetoes(o).contains(.notHidden))
            #expect(rig.apps.entry(a)!.unhideCalls == 1)
        }
        // Visible app, rollback after root stop (journal fault) → re-shown.
        do {
            let rig = try Rig("t21c")
            let a = bag.spawn("/bin/sleep", ["120"]), h = bag.spawn("/bin/sleep", ["120"])
            let hid = ProcessProbe.identity(of: h)!
            rig.treeState.provider.withLock { $0 = { _ in [hid] } }
            rig.apps.add(appInfo(a, bundle: "/tmp/ohm-t023-fake.app"), hidden: false)
            rig.fault.failFrom.store(2, ordering: .sequentiallyConsistent)
            let o = await rig.freeze(a)
            guard case .rolledBack = o else { Issue.record("expected rollback \(o)"); return }
            #expect(rig.apps.entry(a)!.unhideCalls == 1 && !isT(a))
        }
        // Already hidden app with a veto → stays hidden, unhide never called.
        do {
            let rig = try Rig("t21d")
            let a = bag.spawn("/bin/sleep", ["120"])
            rig.apps.add(appInfo(a), hidden: true)
            rig.probes.audio.withLock { _ = $0.insert(a) }
            let o = await rig.freeze(a)
            let e = rig.apps.entry(a)!
            print("T-023 test21: already-hidden vetoed → \(o); hide=\(e.hideCalls) unhide=\(e.unhideCalls) hidden=\(e.hidden)")
            #expect(e.hideCalls == 0 && e.unhideCalls == 0 && e.hidden)
        }
    }

    // MARK: 19, 20, 23

    @Test("19: tree that never stops growing → .unstableTree, nothing left in T")
    func t19_unstableTree() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t19")
        let root = bag.spawn("/bin/sleep", ["120"])
        let kids = (0..<8).map { _ in bag.spawn("/bin/sleep", ["120"]) }
        let ids = kids.map { ProcessProbe.identity(of: $0)! }
        // Every enumeration returns one more helper (a helper spawning a child between passes).
        rig.treeState.provider.withLock { $0 = { n in Array(ids.prefix(min(n, ids.count))) } }
        rig.apps.add(appInfo(root, bundle: "/tmp/ohm-t023-fake.app"))
        let o = await rig.freeze(root)
        let stopped = rig.sig.sent(SIGSTOP)
        print("T-023 test19: \(o); stopped then rolled back: \(stopped.count) pids; any T: \(([root] + kids).contains(where: isT))")
        #expect(vetoes(o) == [.unstableTree])
        #expect(!([root] + kids).contains(where: isT))
        #expect(await rig.gov.frozenRootPids.isEmpty)
    }

    @Test("20: helper watchdog kills the helper after thaw → freezeUnsafe, next rule freeze .unsafeTopology")
    func t20_healthCheck() async throws {
        try await checkHelperHealth(startupDelayMilliseconds: 0)
    }

    @Test("20 regression: delayed watchdog initialization still detects the frozen interval")
    func t20_delayedHelperHealthCheck() async throws {
        try await checkHelperHealth(startupDelayMilliseconds: 250)
    }

    private func checkHelperHealth(startupDelayMilliseconds: UInt32) async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t20", realTree: true) {
            $0.healthCheckDelay = 1.5
            $0.minHiddenFloor = 0
        }
        let hb = rig.dir + "/heartbeat"
        let ready = rig.dir + "/helper-ready"
        let log = rig.dir + "/watchdog.log"
        let app = spawnFakeApp(bag, dir: rig.dir,
                               helperArgs: ["--hb", hb, "--ready", ready,
                                            "--startup-delay-ms", "\(startupDelayMilliseconds)"],
                               rootArgs: ["--hb", hb], log: log)
        // A child pid can exist before main() initializes its watchdog. Do not freeze that state.
        try #require(waitUntil(3) {
            readLog(ready) == "ready" && FileManager.default.fileExists(atPath: hb)
        }, "watchdog did not initialize: \(readLog(log))")
        let bundleID = "dev.ohmtest.watchdog"
        rig.apps.add(appInfo(app.root, bundleID: bundleID, bundle: app.bundle))
        #expect(isFrozen(await rig.freeze(app.root)))
        let helperStart = ProcessProbe.startAbs(app.helper) ?? 0
        let members = await rig.gov.frozenMembers(root: app.root) ?? []
        #expect(members == [app.root, app.helper] && isT(app.helper))
        try await Task.sleep(for: .seconds(3))
        _ = await rig.gov.perform(.thaw(pid: app.root))
        let helperExited = waitUntil(1) {
            !ProcessProbe.isLive(ProcessIdentity(pid: app.helper, startAbsTime: helperStart))
        }
        #expect(helperExited, "watchdog log: \(readLog(log))")
        var unsafe = false
        for _ in 0..<60 where !unsafe {
            try await Task.sleep(for: .milliseconds(100))
            unsafe = await rig.gov.isFreezeUnsafe(bundleID)
        }
        let key = AppKey.bundle(bundleID)
        let r = await rig.gov.reconcile(DesiredState(effects: [key: DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 0), origins: [.freeze: [.rule(UUID())]])]))
        let watchdogLog = readLog(log).split(separator: "\n").suffix(2).joined(separator: " | ")
        print("T-023 test20: helper exited after thaw=\(helperExited); freezeUnsafe=\(unsafe); rule freeze → \(r.outcomes[key] ?? .notFound); startup delay=\(startupDelayMilliseconds) ms; watchdog log: \(watchdogLog)")
        #expect(unsafe)
        #expect(vetoes(r.outcomes[key] ?? .notFound).contains(.unsafeTopology))
        #expect(!isT(app.root))
    }

    @Test("23: activation during Phase B (verify wait + fsync) still thaws within 300 ms")
    func t23_activationUnderPhaseB() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("t23")
        let a = bag.spawn("/bin/sleep", ["120"]), b = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a, bundleID: "dev.ohmtest.a"))
        rig.apps.add(appInfo(b, bundleID: "dev.ohmtest.b"))
        #expect(isFrozen(await rig.freeze(a)))
        let gov = rig.gov, log = rig.sig
        let t0 = Mutex_UInt64()
        rig.sig.afterStop.withLock {
            $0 = { pid in
                guard pid == b else { return }
                log.stall.withLock { $0 = ([b], nowNs() + 90_000_000) }   // verification takes ~90 ms
                t0.set(nowNs())
                Task.detached { await gov.handle(.activated(pid: a)) }
            }
        }
        let ob = await rig.freeze(b)
        _ = waitUntil(1) { rig.sig.sent(SIGCONT).contains(a) }
        let cont = rig.sig.all().first { $0.pid == a && $0.sig == SIGCONT }
        let ms = cont.map { Double($0.ns - t0.get()) / 1e6 } ?? -1
        print("T-023 test23: activation of A during B's Phase B → SIGCONT(A) after \(String(format: "%.1f", ms)) ms; B → \(ob)")
        #expect(isFrozen(ob))
        #expect(ms >= 0 && ms < 300)
        #expect(!isT(a))
        _ = await gov.thawAll(reason: .user)
    }

    // MARK: extra coverage

    @Test("maxDuration, E-core apply/remove, shutdown thaws and removes everything")
    func extra_lifecycle() async throws {
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("extra") { $0.maxFrozenRegular = 0.3 }
        let a = bag.spawn("/bin/sleep", ["120"]), y = bag.spawn(hostPath, ["burn", "--seconds", "60"])
        rig.apps.add(appInfo(a, bundleID: "dev.ohmtest.a"))
        rig.apps.add(appInfo(y, bundleID: "dev.ohmtest.y"))
        #expect(isFrozen(await rig.freeze(a)))
        try await Task.sleep(for: .milliseconds(600))
        #expect(!isT(a))
        #expect(await rig.gov.frozenRootPids.isEmpty)
        if case .eCoreApplied = await rig.gov.perform(.eCore(pid: y, on: true, origin: .manual)) {} else { Issue.record("E-core") }
        let share = pShare(y) ?? -1
        #expect(share < 0.2)
        #expect(isFrozen(await rig.freeze(a)))
        let rep = await rig.gov.shutdown()
        #expect(rep == ThawReport(freezeGroups: 1, eCoreGroups: 1))
        #expect(!isT(a))
        #expect((pShare(y) ?? 0) > 0.9)
        #expect(vetoes(await rig.freeze(a)).contains(.shuttingDown))
        let snap = JournalReader.read(path: rig.dir + "/journal.jsonl")
        #expect(snap.openGroups().isEmpty)
    }

    @Test("scope gate: Apple bundles, system paths, Ohm itself, background without confirmation")
    func extra_scope() async throws {
        let cfg = GovernorConfig()
        #expect(SafetyPolicy.staticScopeVetoes(bundleID: "com.apple.TextEdit", executablePath: nil, config: cfg) == [.appleBundle])
        #expect(SafetyPolicy.staticScopeVetoes(bundleID: "com.apple.Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", config: cfg).isEmpty)
        #expect(SafetyPolicy.staticScopeVetoes(bundleID: "dev.ohm.Ohm", executablePath: nil, config: cfg) == [.ohmItself])
        #expect(SafetyPolicy.staticScopeVetoes(bundleID: nil, executablePath: "/usr/bin/yes", config: cfg) == [.systemPath])
        let bag = ProcessBag(); defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let rig = try Rig("scope")
        let a = bag.spawn("/bin/sleep", ["120"])
        rig.apps.add(appInfo(a, bundleID: "dev.ohmtest.bg", policy: .prohibited))
        #expect(vetoes(await rig.freeze(a)) == [.backgroundNeedsConfirmation])
        let o = await rig.gov.perform(.freeze(pid: a, origin: .manual, confirmedBackground: true))
        #expect(isFrozen(o))
        await rig.gov.handle(.terminated(pid: 999_999))
        _ = await rig.gov.thawAll(reason: .user)
        #expect(!isT(a))
    }
}

final class Mutex_UInt64: Sendable {
    private let v = Atomic<UInt64>(0)
    func set(_ x: UInt64) { v.store(x, ordering: .sequentiallyConsistent) }
    func get() -> UInt64 { v.load(ordering: .sequentiallyConsistent) }
}

func silentWAV(seconds: Int) -> Data {
    let rate = 44_100, bytes = rate * 2 * seconds
    var d = Data()
    func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ x: Int) { withUnsafeBytes(of: UInt16(x).littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
    d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    d.append(Data(count: bytes))
    return d
}

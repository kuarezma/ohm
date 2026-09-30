import Darwin
import Foundation
@testable import OhmGovernor
import OhmJournal
import OhmModel
import Synchronization
import Testing

@Suite("T-064 — Apple user apps may use E-core", .serialized)
struct T064ECoreScopeTests {
    @Test("E-core scope preserves freeze vetoes", arguments: [
        ("com.apple.dt.Xcode", "/Applications/Xcode.app", AppActivationPolicy.regular, true),
        ("com.apple.TextEdit", "/System/Applications/TextEdit.app", .regular, true),
        ("com.apple.Safari", "/System/Cryptexes/App/System/Applications/Safari.app", .regular, true),
        ("com.apple.finder", "/System/Library/CoreServices/Finder.app", .regular, false),
        ("com.apple.TextEdit", "/System/Applications/TextEdit.app", .accessory, false),
        ("com.apple.Safari", "/Applications/Safari.app", .prohibited, false),
        ("dev.ohm.Ohm", "/System/Applications/TextEdit.app", .regular, false)
    ])
    func scope(_ bundleID: String, _ bundle: String, _ activation: AppActivationPolicy,
               _ allowed: Bool) throws {
        let policy = makePolicy()
        let executable = switch bundleID {
        case "com.apple.dt.Xcode": "Xcode"
        case "com.apple.Safari": "Safari"
        case "com.apple.finder": "Finder"
        default: "TextEdit"
        }
        var app = makeApp(bundleID: bundleID, bundle: bundle, activation: activation)
        app.executablePath = bundle + "/Contents/MacOS/" + executable
        let vetoes = policy.eCoreScopeVetoes(app)
        #expect(vetoes.isEmpty == allowed, "E-core scope for \(bundle): \(vetoes)")
        if allowed {
            let freezeVetoes = policy.scopeVetoes(app, forRule: true, confirmedBackground: false)
            #expect(freezeVetoes.contains(.appleBundle))
            if bundle.hasPrefix("/System/") { #expect(freezeVetoes.contains(.systemPath)) }
        }
        if bundleID == "dev.ohm.Ohm" { #expect(vetoes.contains(.ohmItself)) }
        if activation != .regular { #expect(vetoes.contains(.notRegularApp)) }
    }

    @Test("Realpath follows aliases; protected and unknown paths stay vetoed", arguments: [
        ("/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", true),
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", false),
        ("/usr/libexec/xpcproxy", false),
        ("/Library/Apple/NoSuch.app/Contents/MacOS/NoSuch", false),
        ("/Applications/NoSuch-T064.app/Contents/MacOS/NoSuch", false)
    ])
    func aliases(_ target: String, _ allowed: Bool) throws {
        let policy = makePolicy()
        let dir = tempDir("t064-alias")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let alias = dir + "/User.app"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: target)
        var app = makeApp(bundleID: "com.apple.test")
        app.executablePath = alias
        let vetoes = policy.eCoreScopeVetoes(app)
        #expect(vetoes.isEmpty == allowed, "Resolved scope for \(target): \(vetoes)")
    }

    @Test("User never list, own PIDs and own bundle path remain protected", arguments: ["never", "pid", "bundle"])
    func remainingProtections(_ protection: String) throws {
        let bundle = "/System/Applications/TextEdit.app"
        var config = GovernorConfig()
        if protection == "never" { config.userNeverFreeze = ["com.apple.TextEdit"] }
        if protection == "pid" { config.ownPids = [4242] }
        if protection == "bundle" { config.ownBundlePath = bundle }
        let policy = makePolicy(config: config)
        var app = makeApp(bundleID: "com.apple.TextEdit", bundle: bundle)
        app.executablePath = bundle + "/Contents/MacOS/TextEdit"
        #expect(policy.eCoreScopeVetoes(app).contains(protection == "never" ? .userNeverList : .ohmItself))
    }

    @Test("Governor applies and removes rule E-core without lifting freeze vetoes")
    func governorRule() async {
        let bag = ProcessBag()
        defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let state = FakeAppState()
        var app = makeApp(bundleID: "com.apple.TextEdit", bundle: "/System/Applications/TextEdit.app")
        // No real process is signalled: this test checks the Governor's wiring, not kernel policy.
        app.identity = ProcessIdentity(pid: pid, startAbsTime: 1)
        app.executablePath = "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"
        state.add(app, hidden: true)
        let calls = ScopeCalls()
        var config = GovernorConfig()
        config.minHiddenFloor = 0
        let governor = Governor(config: config, journal: ScopeJournal(), appControl: FakeAppControl(state),
                                protection: FakeProtection(FakeProtectionState()),
                                signaler: ScopeSignaler(calls: calls), tree: FakeTree(TreeState()),
                                probes: FakeProbes(ProbeState()))
        let key = AppKey.bundle("com.apple.TextEdit")
        let desired = DesiredState(effects: [key: DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 0), eCore: ECoreParams(whileFrontmost: .keep),
            origins: [.freeze: [.rule(UUID())], .eCore: [.rule(UUID())]])])
        let report = await governor.reconcile(desired)
        #expect(vetoes(report.outcomes[key] ?? .notFound).contains(.appleBundle))
        #expect(vetoes(report.outcomes[key] ?? .notFound).contains(.systemPath))
        #expect(await governor.frozenRootPids.isEmpty)
        #expect(await governor.eCoreRootPids == [app.pid])
        #expect(calls.background.withLock { $0 } == [true])
        _ = await governor.reconcile(DesiredState())
        #expect(await governor.eCoreRootPids.isEmpty)
        #expect(calls.background.withLock { $0 } == [true, false])
    }

    private func makePolicy(config: GovernorConfig = GovernorConfig()) -> SafetyPolicy {
        var config = config
        config.appleAllowlist = []
        return SafetyPolicy(probes: FakeProbes(ProbeState()), config: config,
                            health: FreezeHealthStore(path: "/tmp/t064-unused-health.json"))
    }

    private func makeApp(bundleID: String, bundle: String? = nil,
                         activation: AppActivationPolicy = .regular) -> RunningAppInfo {
        RunningAppInfo(identity: ProcessIdentity(pid: 4242, startAbsTime: 1), bundleID: bundleID,
                       bundlePath: bundle, executablePath: nil, activationPolicy: activation, uid: getuid())
    }
}

private final class ScopeJournal: FreezeJournaling {
    let boot: String? = "t064-test-boot"
    func append(_ record: JournalRecord, sync: Bool) throws {}
    func compactIfIdle() throws {}
}

private final class ScopeCalls: Sendable {
    let background = Mutex<[Bool]>([])
}

private final class ScopeSignaler: ProcessSignaling {
    let calls: ScopeCalls
    init(calls: ScopeCalls) { self.calls = calls }
    func startAbs(_ pid: Int32) -> UInt64? { 1 }
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus { .match }
    func isStopped(_ pid: Int32) -> Bool { false }
    func send(_ pid: Int32, _ signal: Int32) -> Int32 {
        Issue.record("Scope test must not send a signal")
        return EPERM
    }
    func setBackground(_ pid: Int32, _ on: Bool) -> Int32 {
        calls.background.withLock { $0.append(on) }
        return 0
    }
}

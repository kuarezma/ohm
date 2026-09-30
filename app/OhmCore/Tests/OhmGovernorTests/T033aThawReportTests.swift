import Foundation
import OhmGovernor
import OhmJournal
import OhmModel
import Testing

private final class T033aRecoveryJournal: FreezeJournaling {
    let boot: String? = "t033a-test-boot"
    let result: RecoveryReport?
    let throwsRewrite: Bool
    init(result: RecoveryReport? = nil, throwsRewrite: Bool = false) {
        self.result = result
        self.throwsRewrite = throwsRewrite
    }
    func append(_ record: JournalRecord, sync: Bool) throws {}
    func compactIfIdle() throws {}
    func retryRecovery(forceCloseUnverifiable: Bool) throws -> RecoveryReport? {
        if throwsRewrite { throw JournalError.rewriteFailed }
        return result
    }
}

@Suite("T-033a thaw-all recovery result")
struct T033aThawReportTests {
    @Test("Rewrite failure must not become a successful thaw-all command")
    func rewriteFailureRejectsCommand() async {
        let governor = Governor(
            config: testConfig(tempDir("t033a-rewrite")),
            journal: T033aRecoveryJournal(throwsRewrite: true),
            appControl: FakeAppControl(FakeAppState()),
            protection: FakeProtection(FakeProtectionState()),
            tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        #expect(await governor.perform(.thawAll) == .vetoed([.journalUnwritable]))
        #expect(await governor.disabledReason == .journalUnwritable)
        _ = await governor.shutdown()
    }

    @Test("Rewrite error remains visible even with no live or pending groups")
    func rewriteFailureReport() async {
        let governor = Self.makeGovernor(throwsRewrite: true)
        let report = await governor.thawAll(reason: .user)
        #expect(!report.recoveryComplete)
        #expect(report.recoveryFailures.contains { $0.contains("rewriteFailed") })
        #expect(report.freezeGroups == 0 && report.eCoreGroups == 0)
        #expect(await governor.pendingUndoPids.isEmpty)
        #expect(await governor.frozenRootPids.isEmpty)
        #expect(await governor.eCoreRootPids.isEmpty)
        #expect(await governor.disabledReason == .journalUnwritable)
        _ = await governor.shutdown()
    }

    @Test("Incomplete and unverified recovery never reports success", arguments: 0..<5)
    func incompleteRecovery(kind: Int) async {
        var recovery = RecoveryReport()
        let pid = JournalPid(pid: 990_033, start: 33)
        switch kind {
        case 0: recovery.rewriteFailed = true
        case 1: recovery.unresolved = [pid]
        case 2: recovery.unverifiedBoot = [pid]
        case 3: recovery.missingRecordedBoot = [pid]
        default:
            let group = UUID()
            recovery.forcedClosedGroups = [group]
            recovery.closedGroups = [group: .freeze]
        }
        let governor = Self.makeGovernor(result: recovery)
        let report = await governor.thawAll(reason: .user)
        #expect(!report.recoveryComplete)
        #expect(!report.recoveryFailures.isEmpty)
        #expect(report.forcedClosedGroups == (kind == 4 ? 1 : 0))
        #expect(report.freezeGroups == (kind == 4 ? 1 : 0))
        #expect(await governor.perform(.thawAll) == .vetoed([.recoveryPending]))
        _ = await governor.shutdown()
    }

    @Test("Verified recovery keeps freeze/E-core counts and the existing successful outcome")
    func completeRecovery() async {
        var recovery = RecoveryReport()
        recovery.closedGroups = [UUID(): .freeze, UUID(): .eCore]
        let governor = Self.makeGovernor(result: recovery)
        #expect(
            await governor.thawAll(reason: .user) == ThawReport(freezeGroups: 1, eCoreGroups: 1))
        #expect(await governor.perform(.thawAll) == .thawed(groups: 1))
        #expect(await governor.disabledReason == nil)
        _ = await governor.shutdown()
    }

    @Test("No writer cannot verify recovery")
    func missingJournal() async {
        let governor = Governor(
            config: testConfig(tempDir("t033a-no-writer")), journal: nil,
            appControl: FakeAppControl(FakeAppState()),
            protection: FakeProtection(FakeProtectionState()),
            tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
        #expect(!(await governor.thawAll(reason: .user)).recoveryComplete)
        #expect(await governor.perform(.thawAll) == .vetoed([.journalUnwritable]))
        _ = await governor.shutdown()
    }

    private static func makeGovernor(result: RecoveryReport? = nil, throwsRewrite: Bool = false)
        -> Governor
    {
        Governor(
            config: testConfig(tempDir("t033a-report")),
            journal: T033aRecoveryJournal(result: result, throwsRewrite: throwsRewrite),
            appControl: FakeAppControl(FakeAppState()),
            protection: FakeProtection(FakeProtectionState()),
            tree: FakeTree(TreeState()), probes: FakeProbes(ProbeState()))
    }
}

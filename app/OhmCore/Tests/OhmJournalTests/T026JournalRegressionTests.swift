import Darwin
import Foundation
@testable import OhmJournal
import OhmModel
import Testing

private final class T026RecoverySignaler: RecoverySignaling {
    var boot: String?
    var continued: [Int32] = []
    var cleared: [Int32] = []
    var error: Int32 = 0
    init(boot: String?) { self.boot = boot }
    func bootSessionUUID() -> String? { boot }
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus { .match }
    func sendCont(_ pid: Int32) -> Int32 { continued.append(pid); return error }
    func clearBackground(_ pid: Int32) -> Int32 { cleared.append(pid); return error }
}

@Suite("T-026 Journal regressions", .serialized)
struct T026JournalRegressionTests {
    private func paths() -> JournalPaths {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + "ohm-t026-j-" + UUID().uuidString)
        paths.ensureDirectory()
        return paths
    }

    private func write(_ records: [JournalRecord], to paths: JournalPaths) throws {
        let body = try records.reduce(into: Data()) { $0.append(try $1.encodedLine()) }
        try body.write(to: URL(fileURLWithPath: paths.journal))
    }

    @Test("P1: absent boot stays unknown across repeated rewrites; other groups still recover")
    func missingBootRetained() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let owner = JournalPid(pid: getpid(), start: 0)
        let unknown = UUID(), verified = UUID()
        let entry = JournalPid(pid: 990_031, start: 31, role: .root)
        try write([
            JournalRecord(op: .freeze, group: unknown, app: "unknown", origin: "manual", pids: [entry], hiddenByOhm: true),
            JournalRecord(op: .open, boot: "boot-A", owner: owner),
            JournalRecord(op: .ecore, group: verified, app: "known", pids: [JournalPid(pid: 990_032, start: 32)])
        ], to: paths)
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 0)
        let signaler = T026RecoverySignaler(boot: "boot-A")
        for _ in 0..<2 {
            let report = JournalRecovery.run(lock: lock, owner: owner, consumeNotices: false, signaler: signaler)
            #expect(report.unverifiedBoot == [entry])
            #expect(!report.discardedForBoot && !report.rewriteFailed)
            let groups = JournalReader.read(path: paths.journal).openGroups()
            #expect(groups.count == 1)
            #expect(groups.first?.group == unknown && groups.first?.boot == nil && groups.first?.pids == [entry])
            #expect(JournalReader.read(path: paths.journal).records.filter { $0.op == .recovered && $0.reason == "unverifiedBoot:1" }.count == 1,
                    "retrying the same unknown boot must not grow the journal with duplicate notices")
        }
        #expect(signaler.continued.isEmpty)
        #expect(signaler.cleared == [990_032])
        #expect(JournalReader.read(path: paths.journal).records.last(where: { $0.op == .open })?.boot == "boot-A")
    }

    @Test("P1: unreadable current boot preserves original freeze and E-core boots until retry")
    func currentBootRetried() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let owner = JournalPid(pid: getpid(), start: 0)
        let freeze = UUID(), ecore = UUID(), other = UUID()
        let root = JournalPid(pid: 990_041, start: 41, role: .root)
        let helper = JournalPid(pid: 990_042, start: 42, role: .helper)
        let bg = JournalPid(pid: 990_043, start: 43, role: .root)
        try write([
            JournalRecord(op: .open, boot: "boot-A", owner: owner),
            JournalRecord(op: .freeze, group: freeze, pids: [root, helper]),
            JournalRecord(op: .ecore, group: ecore, pids: [bg]),
            JournalRecord(op: .open, boot: "boot-B", owner: owner),
            JournalRecord(op: .freeze, group: other, pids: [JournalPid(pid: 990_044, start: 44)])
        ], to: paths)
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 0)
        let signaler = T026RecoverySignaler(boot: nil)
        for _ in 0..<2 {
            let report = JournalRecovery.run(lock: lock, owner: owner, consumeNotices: true, signaler: signaler)
            #expect(report.unverifiedBoot.count == 4 && !report.discardedForBoot)
            let groups = JournalReader.read(path: paths.journal).openGroups()
            #expect(groups.map(\.boot) == ["boot-A", "boot-A", "boot-B"])
            #expect(groups.map(\.group) == [freeze, ecore, other])
            #expect(signaler.continued.isEmpty && signaler.cleared.isEmpty)
        }
        signaler.boot = "boot-A"
        let report = JournalRecovery.run(lock: lock, owner: owner, consumeNotices: true, signaler: signaler)
        #expect(report.discardedForBoot && report.unverifiedBoot.isEmpty && report.unresolved.isEmpty)
        #expect(signaler.continued == [helper.pid, root.pid])
        #expect(signaler.cleared == [bg.pid])
        #expect(JournalReader.read(path: paths.journal).openGroups().isEmpty)
    }

    @Test("P1: spawned watcher retries nil, rewrite, signal and boot failures with bounded backoff")
    func spawnedRetries() {
        let paths = paths()
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        var rewrite = RecoveryReport(); rewrite.rewriteFailed = true
        var signal = RecoveryReport(); signal.unresolved = [JournalPid(pid: 990_051, start: 1)]
        var boot = RecoveryReport(); boot.unverifiedBoot = [JournalPid(pid: 990_052, start: 2)]
        let reports: [RecoveryReport?] = [nil, rewrite, signal, boot, signal, signal, signal, signal, RecoveryReport()]
        var attempts = 0
        var delays: [Double] = []
        ThawWatcher.spawnedLoop(paths: paths, recover: {
            defer { attempts += 1 }
            return reports[min(attempts, reports.count - 1)]
        }, pause: { delays.append($0) }, shouldStop: { attempts >= reports.count })
        #expect(attempts == reports.count)
        #expect(delays == [0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 5, 5])
    }

    @Test("P1: spawned watcher rechecks the journal after a successful recovery report")
    func spawnedRechecksOpenGroups() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        try write([JournalRecord(op: .freeze, group: UUID(), pids: [JournalPid(pid: 990_053, start: 3)])], to: paths)
        var attempts = 0
        var delays: [Double] = []
        ThawWatcher.spawnedLoop(paths: paths, recover: {
            attempts += 1
            if attempts == 2 {
                do { try Data().write(to: URL(fileURLWithPath: paths.journal)) }
                catch { Issue.record("cannot close the test journal: \(error)") }
            }
            return RecoveryReport()
        }, pause: { delays.append($0) }, shouldStop: { attempts >= 2 })
        #expect(attempts == 2)
        #expect(delays == [0.1])
    }
}

import Darwin
import Foundation
@testable import OhmJournal
import OhmModel
import Testing

@Suite("T026b Journal follow-up", .serialized)
struct T026bJournalTests {
    @Test("P3: corrupt mode still thaws known-boot groups despite their close record")
    func corruptKnownBootRecovery() throws {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 0)
        let group = UUID()
        var data = try JournalRecord(op: .open, boot: "A").encodedLine()
        data.append(try JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_089, start: 9, role: .root)]).encodedLine())
        data.append(Data("{not json}\n".utf8))
        data.append(try JournalRecord(op: .open, boot: "A").encodedLine())
        data.append(try JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_090, start: 10, role: .helper)]).encodedLine())
        data.append(try JournalRecord(op: .thaw, group: group).encodedLine())
        try data.write(to: URL(fileURLWithPath: paths.journal))
        let signaler = T026bRecoverySignaler()
        let report = JournalRecovery.run(lock: lock, owner: JournalPid(pid: getpid(), start: 0),
                                         consumeNotices: false, signaler: signaler)
        #expect(report.corrupt && signaler.continued == [990_090, 990_089])
        #expect(JournalReader.read(path: paths.journal).openGroups().isEmpty)
    }

    @Test("P2-1: explicit resolution must retain a verified process whose undo fails")
    func verifiedUndoFailureIsRetained() throws {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        paths.ensureDirectory()
        let group = UUID()
        let records = [JournalRecord(op: .open, boot: "A"),
                       JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_086, start: 6, role: .root)])]
        try records.reduce(into: Data()) { $0.append(try $1.encodedLine()) }.write(to: URL(fileURLWithPath: paths.journal))
        let signaler = T026bRecoverySignaler(); signaler.error = EPERM
        let report = try JournalSession.thawAll(paths: paths, signaler: signaler)
        #expect(report.forcedClosedGroups.isEmpty && report.unresolved.map(\.pid) == [990_086])
        #expect(report.needsRetry && JournalReader.read(path: paths.journal).openGroups().map(\.group) == [group])
    }

    @Test("P3: a damaged segment extension makes an existing group's boot uncertain")
    func corruptExtensionProvenance() throws {
        let group = UUID()
        var data = try JournalRecord(op: .open, boot: "old").encodedLine()
        data.append(try JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_087, start: 7)]).encodedLine())
        data.append(Data("{broken open}\n".utf8))
        data.append(try JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_088, start: 8)]).encodedLine())
        #expect(JournalReader.parse(data).openGroups().first?.boot == nil)
    }

    @Test("P2-1: EPERM uid fallback only drops a proven different user")
    func permissionUIDFallback() {
        #expect(ProcessProbe.failedIdentityProbe(error: EPERM, uid: { 502 }, ownUID: 501) == .mismatch)
        #expect(ProcessProbe.failedIdentityProbe(error: EPERM, uid: { 501 }, ownUID: 501) == .unknown(EPERM))
        #expect(ProcessProbe.failedIdentityProbe(error: EPERM, uid: { nil }, ownUID: 501) == .unknown(EPERM))
        #expect(ProcessProbe.failedIdentityProbe(error: EIO, uid: { 502 }, ownUID: 501) == .unknown(EIO))
        #expect(ProcessProbe.failedIdentityProbe(error: ESRCH, uid: { nil }, ownUID: 501) == .gone)
    }

    @Test("P2-1: user resolution closes missing boot and unknown identity, keeps audited reasons")
    func forceUserResolution() throws {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 0)
        let missing = UUID(), unknown = UUID(), live = UUID()
        let owner = JournalPid(pid: getpid(), start: 0)
        let records = [
            JournalRecord(op: .freeze, group: missing, pids: [JournalPid(pid: 990_081, start: 1)]),
            JournalRecord(op: .open, boot: "A", owner: owner),
            JournalRecord(op: .ecore, group: unknown, pids: [JournalPid(pid: 990_082, start: 2)]),
            JournalRecord(op: .freeze, group: live, pids: [JournalPid(pid: 990_083, start: 3, role: .root)])
        ]
        try records.reduce(into: Data()) { $0.append(try $1.encodedLine()) }.write(to: URL(fileURLWithPath: paths.journal))
        lock.release()
        let signaler = T026bRecoverySignaler()
        signaler.unknown = [990_082]
        let report = try JournalSession.thawAll(paths: paths, signaler: signaler)
        #expect(report.forcedClosedGroups == [missing, unknown])
        #expect(signaler.continued == [990_083] && signaler.cleared.isEmpty)
        #expect(!report.blocksEffects)
        let snapshot = JournalReader.read(path: paths.journal)
        #expect(snapshot.openGroups().isEmpty)
        #expect(snapshot.records.filter { $0.reason == "userForcedUnverified" }.map(\.group) == [missing, unknown])
    }

    @Test("P2-5: held-lock recovery refreshes boot and reopens the renamed writer")
    func heldLockRecovery() throws {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        paths.ensureDirectory()
        let group = UUID()
        let records = [JournalRecord(op: .open, boot: "A"),
                       JournalRecord(op: .freeze, group: group, pids: [JournalPid(pid: 990_084, start: 4, role: .root)])]
        try records.reduce(into: Data()) { $0.append(try $1.encodedLine()) }.write(to: URL(fileURLWithPath: paths.journal))
        let signaler = T026bRecoverySignaler(); signaler.boot = nil
        let (journal, first) = try JournalSession.open(paths: paths, ownerLockRetry: 0, signaler: signaler)
        #expect(first.needsRetry && journal.boot == nil)
        #expect(FileLock.isHeldByAnother(path: paths.ownerLock))
        let unchanged = try #require(try journal.retryRecovery())
        #expect(unchanged.needsRetry && !unchanged.rewritePerformed)
        signaler.boot = "A"
        let recovered = try #require(try JournalSession.retryRecovery(journal: journal))
        #expect(recovered.thawed.map(\.pid) == [990_084] && !recovered.blocksEffects)
        #expect(journal.boot == "A" && FileLock.isHeldByAnother(path: paths.ownerLock))
        let fresh = UUID()
        try journal.append(JournalRecord(op: .ecore, group: fresh, pids: [JournalPid(pid: 990_085, start: 5)]), sync: true)
        let snapshot = JournalReader.read(path: paths.journal)
        #expect(snapshot.openGroups().map(\.group) == [fresh])
        #expect(snapshot.openGroups().first?.boot == "A")
        #expect(snapshot.records.map(\.seq) == Array(1...UInt64(snapshot.records.count)))
    }

    @Test("P2-1: absent recorded boot needs user resolution, not endless retries")
    func missingBootDoesNotRetry() throws {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 0)
        let entry = JournalPid(pid: 990_071, start: 1)
        try JournalRecord(op: .freeze, group: UUID(), pids: [entry]).encodedLine()
            .write(to: URL(fileURLWithPath: paths.journal))
        let owner = JournalPid(pid: getpid(), start: 0)
        let report = JournalRecovery.run(lock: lock, owner: owner, consumeNotices: false)
        #expect(!report.needsRetry)
        #expect(JournalReader.read(path: paths.journal).openGroups().first?.pids == [entry])
        let before = try Data(contentsOf: URL(fileURLWithPath: paths.journal))
        _ = JournalRecovery.run(lock: lock, owner: owner, consumeNotices: false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.journal)) == before)
    }

    @Test("P2-1: persistent failures increase backoff to five minutes")
    func persistentBackoff() {
        let paths = JournalPaths(directory: NSTemporaryDirectory() + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        paths.ensureDirectory()
        var report = RecoveryReport(); report.rewriteFailed = true
        var attempts = 0
        var delays: [Double] = []
        var logs: [String] = []
        ThawWatcher.spawnedLoop(paths: paths, recover: { attempts += 1; return report },
                                pause: { delays.append($0) }, emitLog: { logs.append($0) }, shouldStop: { attempts == 16 })
        #expect(delays.last == 300)
        #expect(delays.allSatisfy { $0 <= 300 })
        #expect(attempts == 16 && logs.count == 2)
        #expect(logs.last?.contains("budget exhausted") == true)
    }

    @Test("P3: corrupt open must not attribute later groups to an older boot")
    func corruptOpenProvenance() throws {
        let old = UUID(), current = UUID(), restored = UUID()
        var data = try JournalRecord(op: .open, boot: "old").encodedLine()
        data.append(try JournalRecord(op: .freeze, group: old, pids: []).encodedLine())
        data.append(Data("{\"op\":\"open\",\"boot\":\"current\",BROKEN}\n".utf8))
        data.append(try JournalRecord(op: .freeze, group: current, pids: []).encodedLine())
        data.append(try JournalRecord(op: .open, boot: "current").encodedLine())
        data.append(try JournalRecord(op: .ecore, group: restored, pids: []).encodedLine())
        let snapshot = JournalReader.parse(data)
        #expect(snapshot.corrupt)
        #expect(snapshot.openGroups().map(\.boot) == ["old", nil, "current"])
    }
}

private final class T026bRecoverySignaler: RecoverySignaling {
    var boot: String? = "A"
    var unknown: Set<Int32> = []
    var continued: [Int32] = []
    var cleared: [Int32] = []
    var error: Int32 = 0
    func bootSessionUUID() -> String? { boot }
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus {
        unknown.contains(id.pid) ? .unknown(EPERM) : .match
    }
    func sendCont(_ pid: Int32) -> Int32 { continued.append(pid); return error }
    func clearBackground(_ pid: Int32) -> Int32 { cleared.append(pid); return error }
}

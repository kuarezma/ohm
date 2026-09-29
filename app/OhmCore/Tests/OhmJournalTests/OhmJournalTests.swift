import COhmSys
import Darwin
import Foundation
import OhmJournal
import OhmModel
import Testing

// Signals only reach processes these tests spawn; teardown always sends SIGCONT, then SIGKILL.

@discardableResult
private func safeKill(_ pid: Int32, _ sig: Int32) -> Int32 {
    precondition(pid > 1, "refusing kill(\(pid))")
    return Darwin.kill(pid, sig)
}

private final class Spawned {
    private(set) var pids: [Int32] = []
    func sleep() -> Int32 {
        var pid: pid_t = 0
        let argv = (["/bin/sleep", "120"] as [String]).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        precondition(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0)
        pids.append(pid)
        for _ in 0..<200 where ProcessProbe.startAbs(pid) == nil { usleep(5_000) }
        return pid
    }
    func stop(_ pid: Int32) {
        safeKill(pid, SIGSTOP)
        for _ in 0..<200 where !ProcessProbe.isStopped(pid) { usleep(2_000) }
    }
    func cleanup() {
        for p in pids { safeKill(p, SIGCONT); safeKill(p, SIGKILL); waitpid(p, nil, 0) }
    }
}

private func tmp(_ tag: String) -> JournalPaths {
    let d = NSTemporaryDirectory() + "ohm-t023-j-\(tag)-\(UUID().uuidString.prefix(8))"
    let p = JournalPaths(directory: d)
    p.ensureDirectory()
    return p
}

private func line(_ r: JournalRecord) -> String { String(decoding: try! r.encodedLine(), as: UTF8.self) }
private func pidEntry(_ pid: Int32, _ role: JournalRole = .root, startDelta: UInt64 = 0) -> JournalPid {
    JournalPid(pid: pid, start: ProcessProbe.startAbs(pid)! + startDelta, role: role)
}
private let me = JournalPid(pid: getpid(), start: 0)

@Suite("ADR 0004 § 5 — journal and recovery", .serialized)
struct OhmJournalTests {

    @Test("4: interrupted last line is ignored; the other groups are thawed")
    func t04_truncatedTail() throws {
        let sp = Spawned(); defer { sp.cleanup() }
        let paths = tmp("t04")
        let a = sp.sleep(), b = sp.sleep(), c = sp.sleep()
        [a, b, c].forEach(sp.stop)
        let boot = ProcessProbe.bootSessionUUID()
        var body = line(JournalRecord(op: .open, boot: boot, owner: me))
        body += line(JournalRecord(op: .freeze, group: UUID(), app: "x", pids: [pidEntry(a)]))
        body += line(JournalRecord(op: .freeze, group: UUID(), app: "y", pids: [pidEntry(b)]))
        let partial = line(JournalRecord(op: .freeze, group: UUID(), app: "z", pids: [pidEntry(c)]))
        body += String(partial.dropLast(12))   // writer died mid-write(): no "\n"
        try body.write(toFile: paths.journal, atomically: false, encoding: .utf8)
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 1)
        let r = JournalRecovery.run(lock: lock, owner: me, consumeNotices: true)
        print("T-023 test4: ignoredTail=\(r.ignoredTail) thawed=\(r.thawed.map(\.pid)) a=\(ProcessProbe.isStopped(a) ? "T" : "S") b=\(ProcessProbe.isStopped(b) ? "T" : "S") c(ignored line)=\(ProcessProbe.isStopped(c) ? "T" : "S")")
        #expect(r.ignoredTail && !r.corrupt)
        #expect(!ProcessProbe.isStopped(a) && !ProcessProbe.isStopped(b))
        #expect(ProcessProbe.isStopped(c))   // D1: that record never completed, so recovery must not act on it
        #expect(JournalReader.read(path: paths.journal).openGroups().isEmpty)
    }

    @Test("5: journal from another boot session is discarded without any signal")
    func t05_otherBoot() throws {
        let sp = Spawned(); defer { sp.cleanup() }
        let paths = tmp("t05")
        let a = sp.sleep()
        sp.stop(a)
        var body = line(JournalRecord(op: .open, boot: "00000000-0000-0000-0000-000000000000", owner: me))
        body += line(JournalRecord(op: .freeze, group: UUID(), app: "x", pids: [pidEntry(a)]))
        try body.write(toFile: paths.journal, atomically: false, encoding: .utf8)
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 1)
        let r = JournalRecovery.run(lock: lock, owner: me, consumeNotices: true)
        let snap = JournalReader.read(path: paths.journal)
        print("T-023 test5: discardedForBoot=\(r.discardedForBoot) thawed=\(r.thawed.count) a=\(ProcessProbe.isStopped(a) ? "T" : "S") records after=\(snap.records.map(\.op))")
        #expect(r.discardedForBoot && r.thawed.isEmpty)
        #expect(ProcessProbe.isStopped(a))
        #expect(snap.records.map(\.op) == [.open] && snap.records.first?.boot == ProcessProbe.bootSessionUUID())
    }

    @Test("6: pid matches but start time differs → no signal")
    func t06_pidReuse() throws {
        let sp = Spawned(); defer { sp.cleanup() }
        let paths = tmp("t06")
        let a = sp.sleep()
        sp.stop(a)
        var body = line(JournalRecord(op: .open, boot: ProcessProbe.bootSessionUUID(), owner: me))
        body += line(JournalRecord(op: .freeze, group: UUID(), app: "x", pids: [pidEntry(a, startDelta: 7)]))
        try body.write(toFile: paths.journal, atomically: false, encoding: .utf8)
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 1)
        let r = JournalRecovery.run(lock: lock, owner: me, consumeNotices: true)
        print("T-023 test6: skippedIdentity=\(r.skippedIdentity.map(\.pid)) thawed=\(r.thawed.count) a=\(ProcessProbe.isStopped(a) ? "T" : "S")")
        #expect(r.thawed.isEmpty && r.skippedIdentity.map(\.pid) == [a])
        #expect(ProcessProbe.isStopped(a))
    }

    @Test("corrupt middle line → conservative: thawed even if a thaw record follows; helpers before root")
    func corruptMiddle() throws {
        let sp = Spawned(); defer { sp.cleanup() }
        let paths = tmp("corrupt")
        let root = sp.sleep(), helper = sp.sleep()
        [root, helper].forEach(sp.stop)
        let g = UUID()
        var body = line(JournalRecord(op: .open, boot: ProcessProbe.bootSessionUUID(), owner: me))
        body += line(JournalRecord(op: .freeze, group: g, app: "x", pids: [pidEntry(root)]))
        body += "{not json\n"
        body += line(JournalRecord(op: .freeze, group: g, app: "x", pids: [pidEntry(helper, .helper)]))
        body += line(JournalRecord(op: .thaw, group: g, reason: "user"))
        try body.write(toFile: paths.journal, atomically: false, encoding: .utf8)
        let lock = try OwnerLock.acquire(paths: paths, retryFor: 1)
        let r = JournalRecovery.run(lock: lock, owner: me, consumeNotices: true)
        #expect(r.corrupt)
        #expect(r.thawed.map(\.pid) == [helper, root])
        #expect(!ProcessProbe.isStopped(root) && !ProcessProbe.isStopped(helper))
    }

    @Test("E-core group: recovery removes PRIO_DARWIN_BG; recovered notice kept for the UI")
    func eCoreRecovery() throws {
        let sp = Spawned(); defer { sp.cleanup() }
        let paths = tmp("ecore")
        let a = sp.sleep()
        #expect(setpriority(PRIO_DARWIN_PROCESS, id_t(a), PRIO_DARWIN_BG) == 0)
        var body = line(JournalRecord(op: .open, boot: ProcessProbe.bootSessionUUID(), owner: me))
        body += line(JournalRecord(op: .ecore, group: UUID(), app: "dev.ohmtest.y", pids: [pidEntry(a)]))
        try body.write(toFile: paths.journal, atomically: false, encoding: .utf8)
        do {
            let lock = try OwnerLock.acquire(paths: paths, retryFor: 1)
            let r = JournalRecovery.run(lock: lock, owner: me, consumeNotices: false)
            #expect(r.eCoreCleared.map(\.pid) == [a])
        }
        let lock2 = try OwnerLock.acquire(paths: paths, retryFor: 1)
        let r2 = JournalRecovery.run(lock: lock2, owner: me, consumeNotices: true)
        #expect(r2.notices.first?.count == 1 && r2.notices.first?.apps == ["dev.ohmtest.y"])
        #expect(JournalReader.read(path: paths.journal).records.map(\.op) == [.open])
    }

    @Test("D6: owner.lock has a single holder; thawd.lock probe; writer appends one line per record")
    func locksAndWriter() throws {
        let paths = tmp("locks")
        let (journal, _) = try JournalSession.open(paths: paths, ownerLockRetry: 1)
        #expect(throws: OwnerLock.Failure.heldByAnother) { try OwnerLock.acquire(paths: paths, retryFor: 0.2) }
        #expect(!FileLock.isHeldByAnother(path: paths.thawdLock))
        let t = try FileLock(path: paths.thawdLock)
        #expect(t.tryLockExclusive())
        #expect(FileLock.isHeldByAnother(path: paths.thawdLock))
        let g = UUID()
        try journal.append(JournalRecord(op: .freeze, group: g, app: "x", pids: [JournalPid(pid: 1, start: 2, role: .root)]), sync: true)
        try journal.append(JournalRecord(op: .thaw, group: g, reason: "user"), sync: false)
        let snap = JournalReader.read(path: paths.journal)
        #expect(snap.records.map(\.op) == [.open, .freeze, .thaw])
        #expect(snap.records.map(\.seq) == [1, 2, 3])
        #expect(snap.openGroups().isEmpty && !snap.corrupt && !snap.ignoredTail)
        let raw = try String(contentsOfFile: paths.journal, encoding: .utf8)
        #expect(raw.hasSuffix("\n") && raw.contains("\"op\":\"freeze\"") && raw.contains("\"role\":\"root\""))
        var big = JournalRecord(op: .freeze, group: g)
        big.pids = (0..<200).map { JournalPid(pid: Int32($0), start: UInt64.max, role: .helper) }
        #expect(throws: JournalError.self) { try big.encodedLine() }
    }

    // The table is process-global and the Governor suite may run concurrently, so this test neither
    // fills it nor calls thaw_all (which would continue the other suite's processes). Test 3 covers
    // the signal path in a separate process.
    @Test("thaw table: idempotent add, contains, remove")
    func thawTable() {
        let fake: Int32 = 4_000_123   // above kern.maxproc; never signalled
        #expect(ohm_thaw_table_add(fake) == 0)
        #expect(ohm_thaw_table_add(fake) == 0)
        #expect(ohm_thaw_table_contains(fake) == 1)
        #expect(ohm_thaw_table_remove(fake) == 1)
        #expect(ohm_thaw_table_contains(fake) == 0)
        #expect(ohm_thaw_table_add(0) == -1)
    }
}

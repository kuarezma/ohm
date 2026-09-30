import Darwin
import Foundation
import OhmModel

/// The Governor's view of the journal. Tests inject failures through this seam (ADR 0004 test 17).
public protocol FreezeJournaling: AnyObject {
    /// Appends one record (assigning `seq` and `ts`). `sync` → `fsync` before returning (D1).
    func append(_ record: JournalRecord, sync: Bool) throws
    /// Rewrites the journal to a fresh `open` record when no group is open and the file has grown.
    /// Throws if the renewal failed; the journal is then unusable (T-024 #2).
    func compactIfIdle() throws
    var boot: String? { get }
    var recoveryReport: RecoveryReport? { get }
    /// Retries with the writer's already-held owner lock, refreshing its fd after any rename.
    func retryRecovery(forceCloseUnverifiable: Bool) throws -> RecoveryReport?
}

extension FreezeJournaling {
    public var recoveryReport: RecoveryReport? { nil }
    public func retryRecovery(forceCloseUnverifiable: Bool) throws -> RecoveryReport? { nil }
}

/// Single writer of `journal.jsonl` (ADR 0004 § 5, D6). Holding an `OwnerLock` is a precondition.
/// After any failed write, fsync or renewal the writer is broken for good: a later record would be
/// glued onto a partial line, become unparsable, and its SIGSTOP could never be recovered.
public final class FreezeJournal: FreezeJournaling {
    public let paths: JournalPaths
    public private(set) var boot: String?
    public private(set) var recoveryReport: RecoveryReport?
    private let recoverySignaler: any RecoverySignaling
    private let ownerLock: OwnerLock
    private let owner: JournalPid
    private var fd: Int32
    private var seq: UInt64
    public private(set) var broken: JournalError?
    /// Compaction threshold for `compactIfIdle`.
    public var compactThresholdBytes: Int = 64 * 1024

    /// Opens for append. Call `JournalRecovery.run` first: it leaves the file with an `open` record.
    /// Refuses a file whose last line is unterminated (appending would glue onto it).
    public init(paths: JournalPaths, ownerLock: OwnerLock, owner: JournalPid,
                recoveryReport: RecoveryReport? = nil,
                recoverySignaler: any RecoverySignaling = LiveRecoverySignaler()) throws {
        self.paths = paths
        self.ownerLock = ownerLock
        self.owner = owner
        self.recoveryReport = recoveryReport
        self.recoverySignaler = recoverySignaler
        let snapshot = JournalReader.read(path: paths.journal)
        let currentBoot = recoverySignaler.bootSessionUUID()
        // The writer must append under a verified open segment, even if boot probing starts
        // succeeding between recovery and opening this writer.
        boot = snapshot.records.last(where: { $0.op == .open })?.boot == currentBoot ? currentBoot : nil
        if let d = FileManager.default.contents(atPath: paths.journal), let last = d.last, last != 0x0A {
            throw JournalError.unterminatedTail
        }
        fd = open(paths.journal, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 { throw JournalError.open(errno) }
        seq = snapshot.lastSeq
    }

    deinit { if fd >= 0 { close(fd) } }

    public func retryRecovery(forceCloseUnverifiable: Bool = false) throws -> RecoveryReport? {
        if let broken { throw broken }
        // All active Governor groups must be undone before invoking recovery on the whole journal.
        close(fd)
        fd = -1
        let report = JournalRecovery.run(lock: ownerLock, owner: owner, consumeNotices: false,
                                         signaler: recoverySignaler,
                                         forceCloseUnverifiable: forceCloseUnverifiable)
        recoveryReport = report
        if report.rewriteFailed {
            broken = .rewriteFailed
            throw JournalError.rewriteFailed
        }
        let snapshot = JournalReader.read(path: paths.journal)
        let currentBoot = recoverySignaler.bootSessionUUID()
        boot = snapshot.records.last(where: { $0.op == .open })?.boot == currentBoot ? currentBoot : nil
        fd = open(paths.journal, O_WRONLY | O_APPEND | O_CLOEXEC)
        if fd < 0 {
            let error = JournalError.open(errno)
            broken = error
            throw error
        }
        seq = snapshot.lastSeq
        return report
    }

    public func append(_ record: JournalRecord, sync: Bool) throws {
        if let broken { throw broken }
        var r = record
        seq += 1
        r.seq = seq
        r.ts = Int64(Date().timeIntervalSince1970 * 1000)
        let line = try r.encodedLine()
        do {
            try Self.writeAll(fd, line)
            if sync, fsync(fd) != 0 { throw JournalError.fsync(errno) }
        } catch let e as JournalError {
            broken = e
            throw e
        }
    }

    public func compactIfIdle() throws {
        if let broken { throw broken }
        var st = stat()
        guard fstat(fd, &st) == 0, Int(st.st_size) > compactThresholdBytes else { return }
        guard JournalReader.read(path: paths.journal).openGroups().isEmpty else { return }
        guard ftruncate(fd, 0) == 0 else { return }   // nothing changed: file still valid
        seq = 0
        try append(JournalRecord(op: .open, boot: boot, owner: owner), sync: true)
    }

    /// One `write()` per record (§ 5). A short write is an error.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 { throw JournalError.write(errno) }
        if n != data.count { throw JournalError.shortWrite }
    }
}

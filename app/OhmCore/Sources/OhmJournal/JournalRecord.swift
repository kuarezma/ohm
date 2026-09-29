import Foundation
import OhmModel

public enum JournalOp: String, Codable, Sendable {
    case open, freeze, thaw, ecore, ecoreOff, recovered
}

public enum JournalRole: String, Codable, Sendable { case root, helper }

public struct JournalPid: Codable, Sendable, Hashable {
    public var pid: Int32
    /// `ri_proc_start_abstime`; only meaningful within the `boot` session of the segment.
    public var start: UInt64
    public var role: JournalRole?

    public init(pid: Int32, start: UInt64, role: JournalRole? = nil) {
        self.pid = pid
        self.start = start
        self.role = role
    }

    public init(_ id: ProcessIdentity, role: JournalRole? = nil) {
        self.init(pid: id.pid, start: id.startAbsTime, role: role)
    }

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startAbsTime: start) }
}

/// One JSON Lines record (ADR 0004 § 5). Absent optionals are omitted from the encoding.
public struct JournalRecord: Codable, Sendable, Equatable {
    public var v: Int = 1
    public var seq: UInt64 = 0
    public var ts: Int64 = 0
    public var op: JournalOp
    public var boot: String?
    public var owner: JournalPid?
    public var group: UUID?
    public var app: String?
    public var origin: String?
    public var pids: [JournalPid]?
    public var reason: String?
    public var hiddenByOhm: Bool?
    /// `recovered` only: how many processes were signalled and which apps (§ 5 step 6).
    public var count: Int?
    public var apps: [String]?

    public init(op: JournalOp, boot: String? = nil, owner: JournalPid? = nil, group: UUID? = nil,
                app: String? = nil, origin: String? = nil, pids: [JournalPid]? = nil,
                reason: String? = nil, hiddenByOhm: Bool? = nil, count: Int? = nil, apps: [String]? = nil) {
        self.op = op
        self.boot = boot
        self.owner = owner
        self.group = group
        self.app = app
        self.origin = origin
        self.pids = pids
        self.reason = reason
        self.hiddenByOhm = hiddenByOhm
        self.count = count
        self.apps = apps
    }

    static let maxLineBytes = 4000

    /// Single line terminated by `\n`, < 4 KB (§ 5: one `write()` per record).
    public func encodedLine() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        var d = try enc.encode(self)
        d.append(0x0A)
        guard d.count < Self.maxLineBytes else { throw JournalError.recordTooLarge(d.count) }
        return d
    }
}

public enum JournalError: Error, Equatable {
    case open(Int32)
    case write(Int32)
    case shortWrite
    case fsync(Int32)
    case encode
    case recordTooLarge(Int)
    case injected
    case unterminatedTail
    case rewriteFailed
}

/// Parsed journal (ADR 0004 § 5 reading rules 3 and 4).
public struct JournalSnapshot: Sendable {
    public var records: [JournalRecord] = []
    /// Boot session of the `open` record preceding each record (nil before any `open`).
    public var recordBoots: [String?] = []
    /// A middle line could not be parsed: conservative recovery (§ 5 rule 4).
    public var corrupt = false
    /// The last line was incomplete or unparsable and was ignored (§ 5 rule 3).
    public var ignoredTail = false
    public var isEmpty: Bool { records.isEmpty && !corrupt }

    public var lastSeq: UInt64 { records.last?.seq ?? 0 }
}

public enum OpenGroupKind: Sendable { case freeze, eCore }

public struct OpenGroup: Sendable {
    public var kind: OpenGroupKind
    public var group: UUID
    public var app: String?
    public var boot: String?
    /// In journal order (root first for freeze groups).
    public var pids: [JournalPid]
}

public enum JournalReader {
    public static func read(path: String) -> JournalSnapshot {
        guard let data = FileManager.default.contents(atPath: path) else { return JournalSnapshot() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> JournalSnapshot {
        var snap = JournalSnapshot()
        guard !data.isEmpty else { return snap }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        // Text after the final "\n" (or the whole file if it has none) is an interrupted write.
        if let last = lines.last {
            if !last.isEmpty { snap.ignoredTail = true }
            lines.removeLast()
        }
        let dec = JSONDecoder()
        var boot: String?
        for (i, line) in lines.enumerated() {
            guard let r = try? dec.decode(JournalRecord.self, from: line) else {
                let isLastComplete = i == lines.count - 1
                if isLastComplete && !snap.ignoredTail {
                    snap.ignoredTail = true
                } else {
                    snap.corrupt = true
                }
                continue
            }
            if r.op == .open { boot = r.boot }
            snap.records.append(r)
            snap.recordBoots.append(boot)
        }
        return snap
    }
}

extension JournalSnapshot {
    /// Groups that still have effects according to the journal. In corrupt mode every parsed
    /// `freeze`/`ecore` group counts as open, even if a `thaw` follows (§ 5 rule 4).
    public func openGroups() -> [OpenGroup] {
        var order: [UUID] = []
        var groups: [UUID: OpenGroup] = [:]
        for (i, r) in records.enumerated() {
            switch r.op {
            case .freeze, .ecore:
                guard let g = r.group else { continue }
                let kind: OpenGroupKind = r.op == .freeze ? .freeze : .eCore
                if groups[g] == nil {
                    groups[g] = OpenGroup(kind: kind, group: g, app: r.app, boot: recordBoots[i], pids: [])
                    order.append(g)
                }
                groups[g]?.pids.append(contentsOf: r.pids ?? [])
            case .thaw, .ecoreOff:
                guard !corrupt, let g = r.group else { continue }
                groups[g] = nil
            case .recovered:
                // Everything before a completed recovery was already signalled.
                guard !corrupt else { continue }
                groups.removeAll()
            case .open:
                continue
            }
        }
        return order.compactMap { groups[$0] }
    }
}

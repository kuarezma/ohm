import Darwin
import Foundation

/// ADR 0004 § 5: `~/Library/Application Support/Ohm/Freeze/` (0700), not the App Group container.
public struct JournalPaths: Sendable, Equatable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    public static var standard: JournalPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return JournalPaths(directory: home + "/Library/Application Support/Ohm/Freeze")
    }

    public var journal: String { directory + "/journal.jsonl" }
    public var journalTmp: String { directory + "/journal.jsonl.tmp" }
    public var ownerLock: String { directory + "/owner.lock" }
    public var thawdLock: String { directory + "/thawd.lock" }

    /// Creates the directory (and parents) with mode 0700. Returns false if it cannot be created.
    @discardableResult
    public func ensureDirectory() -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDir) { return isDir.boolValue }
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }
}

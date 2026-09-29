import Foundation

// ADR 0001 § 2 / ADR 0002: persistent attribution key. Kept in its own file so a parallel task that
// needs the same type can merge by keeping exactly one copy.
public enum AttributionKind: Int, Sendable, Codable { case bundleID = 0, executableName = 1, processName = 2 }

public struct AppKey: Hashable, Sendable, Codable {
    public var kind: AttributionKind
    public var value: String

    public init(kind: AttributionKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func bundle(_ id: String) -> AppKey { AppKey(kind: .bundleID, value: id) }
}

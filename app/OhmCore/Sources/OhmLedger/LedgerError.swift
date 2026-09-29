import Foundation

public enum LedgerError: Error, Sendable, CustomStringConvertible, Equatable {
    case sqliteError(code: Int32, message: String)
    case incompatibleReader(requiredVersion: Int, currentVersion: Int)
    case unsupportedSchemaVersion(version: Int)
    case databaseCorrupt(reason: String)
    case readOnlyViolation
    case closed
    case invalidParameter(String)

    public var description: String {
        switch self {
        case let .sqliteError(code, message):
            return "SQLite error (\(code)): \(message)"
        case let .incompatibleReader(required, current):
            return "Incompatible ledger database schema: reader requires version <= \(current), found \(required). Please update Ohm."
        case let .unsupportedSchemaVersion(version):
            return "Unsupported schema version: \(version)"
        case let .databaseCorrupt(reason):
            return "Ledger database is corrupt: \(reason)"
        case .readOnlyViolation:
            return "Attempted a write operation on a read-only ledger connection."
        case .closed:
            return "Ledger database connection is closed."
        case let .invalidParameter(param):
            return "Invalid parameter: \(param)"
        }
    }
}

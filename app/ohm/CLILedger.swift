import Foundation
import OhmLedger
import OhmModel
import Security
import SQLite3

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CLILedger {
    static func appGroupIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups.first { $0.hasSuffix(".dev.ohm") }
    }

    static func receipt(history: Bool) throws -> Receipt {
        let container = appGroupIdentifier().flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        return try receipt(history: history, container: container, local: EnergyLedger.localDataDirectory())
    }

    static func receipt(history: Bool, container: URL?, local: URL, now: Date = Date()) throws -> Receipt {
        let start = history ? now.addingTimeInterval(-7 * 86400) : Calendar.current.startOfDay(for: now)
        let interval = DateInterval(start: start, end: now)
        // Read only: neither path lookup nor a missing receipt creates a directory/database.
        if let container {
            let path = container.appendingPathComponent("ledger.sqlite").path
            if FileManager.default.fileExists(atPath: path) {
                do { return try LedgerReader(path: path).receipt(for: interval) }
                catch {
                    // Fall back only on access errors; a corrupt shared ledger must remain visible.
                    if case LedgerError.sqliteError(let code, _) = error,
                       code & 0xff == SQLITE_CANTOPEN || code & 0xff == SQLITE_PERM {
                        // The shared container/WAL is inaccessible to this preview CLI.
                    } else if FileManager.default.isReadableFile(atPath: path) {
                        throw error
                    }
                }
            }
        }
        let localPath = local.appendingPathComponent("ledger.sqlite").path
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw CLIError(message: "Enerji fişi bulunamadı: App Group ve yerel depolamada veri yok. Ohm'u açıp ölçüm yapılmasını bekleyin.")
        }
        return try LedgerReader(path: localPath).receipt(for: interval)
    }
}

import Foundation
import OhmLedger
import OhmModel
import Security

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
        guard let group = appGroupIdentifier(),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CLIError(message: "CLI App Group yetkisi okunamadı; Ohm paketindeki imzalı ohm aracını kullanın.")
        }
        let now = Date()
        let start = history ? now.addingTimeInterval(-7 * 86400) : Calendar.current.startOfDay(for: now)
        let interval = DateInterval(start: start, end: now)
        let path = container.appendingPathComponent("ledger.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return Receipt(interval: interval) }
        // Never fall back to EnergyLedger.defaultDatabasePath: that path can create a directory.
        let reader = try LedgerReader(path: path)
        return try reader.receipt(for: interval)
    }
}

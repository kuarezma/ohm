import Foundation
import Security
import OhmLedger
import OhmModel

public enum WidgetDataLoader {
    public static func appGroupIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) else {
            return nil
        }
        guard let groups = value as? [String] else { return nil }
        return groups.first { $0.hasSuffix(".dev.ohm") }
    }

    public static func loadCurrentEntry(at date: Date = Date()) -> ReceiptEntry {
        guard let groupID = appGroupIdentifier(),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID),
              FileManager.default.isReadableFile(atPath: container.path) else {
            return ReceiptEntry(date: date, data: nil, storageUnavailable: true)
        }
        let dbPath = container.appendingPathComponent("ledger.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ReceiptEntry(date: date, data: nil)
        }
        do {
            let reader = try LedgerReader(path: dbPath)
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: date)
            let interval = DateInterval(start: startOfDay, end: date)
            let receipt = try reader.receipt(for: interval)
            return buildEntry(from: receipt, at: date)
        } catch {
            return ReceiptEntry(date: date, data: nil)
        }
    }

    public static func buildEntry(from receipt: Receipt, at date: Date) -> ReceiptEntry {
        let candidateRows = receipt.rows.isEmpty ? receipt.allRows : receipt.rows
        let topApps = candidateRows.prefix(3)
        guard !topApps.isEmpty else {
            return ReceiptEntry(date: date, data: nil)
        }

        let appItems: [WidgetAppItem] = topApps.map { row in
            WidgetAppItem(
                id: row.id,
                displayName: row.displayName,
                batteryMinutes: (row.batteryMinutes != nil && row.batteryMinutes! > 0) ? row.batteryMinutes : nil,
                chargingWh: row.chargingWh,
                totalEnergyWh: Double(row.energy_uj) * 1e-6 / 3600.0
            )
        }

        let totalBatteryMinutes: Double? = {
            let mins = receipt.allRows.compactMap(\.batteryMinutes).filter { $0 > 0 }
            guard !mins.isEmpty else { return nil }
            let total = mins.reduce(0, +)
            return total > 0 ? total : nil
        }()

        let totalAcWh: Double? = {
            let acList = receipt.allRows.compactMap(\.chargingWh).filter { $0 > 0 }
            guard !acList.isEmpty else { return nil }
            let total = acList.reduce(0, +)
            return total > 0 ? total : nil
        }()

        let totalUj = receipt.measuredSystemEnergy_uj > 0
            ? receipt.measuredSystemEnergy_uj
            : receipt.allRows.map(\.energy_uj).reduce(0, +)
        let totalEnergyWh = Double(totalUj) * 1e-6 / 3600.0

        guard totalEnergyWh > 0 || (totalBatteryMinutes != nil && totalBatteryMinutes! > 0) else {
            return ReceiptEntry(date: date, data: nil)
        }

        let widgetData = ReceiptWidgetData(
            topApps: Array(appItems),
            totalBatteryMinutes: totalBatteryMinutes,
            totalAcWh: totalAcWh,
            totalEnergyWh: totalEnergyWh,
            hasData: true
        )

        return ReceiptEntry(date: date, data: widgetData)
    }
}

import Foundation
import WidgetKit

public struct WidgetAppItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let batteryMinutes: Double?
    public let chargingWh: Double?
    public let totalEnergyWh: Double

    public init(
        id: String,
        displayName: String,
        batteryMinutes: Double? = nil,
        chargingWh: Double? = nil,
        totalEnergyWh: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.batteryMinutes = batteryMinutes
        self.chargingWh = chargingWh
        self.totalEnergyWh = totalEnergyWh
    }
}

public struct ReceiptWidgetData: Sendable, Equatable {
    public let topApps: [WidgetAppItem]
    public let totalBatteryMinutes: Double?
    public let totalAcWh: Double?
    public let totalEnergyWh: Double
    public let hasData: Bool

    public init(
        topApps: [WidgetAppItem],
        totalBatteryMinutes: Double? = nil,
        totalAcWh: Double? = nil,
        totalEnergyWh: Double = 0.0,
        hasData: Bool = true
    ) {
        self.topApps = topApps
        self.totalBatteryMinutes = totalBatteryMinutes
        self.totalAcWh = totalAcWh
        self.totalEnergyWh = totalEnergyWh
        self.hasData = hasData
    }
}

public struct ReceiptEntry: TimelineEntry, Sendable {
    public let date: Date
    public let data: ReceiptWidgetData?

    public init(date: Date, data: ReceiptWidgetData?) {
        self.date = date
        self.data = data
    }

    public static var placeholder: ReceiptEntry {
        previewSample
    }

    public static var previewSample: ReceiptEntry {
        ReceiptEntry(
            date: Date(),
            data: ReceiptWidgetData(
                topApps: [
                    WidgetAppItem(
                        id: "1",
                        displayName: "Xcode",
                        batteryMinutes: 54.0,
                        chargingWh: nil,
                        totalEnergyWh: 4.5
                    ),
                    WidgetAppItem(
                        id: "2",
                        displayName: "Safari",
                        batteryMinutes: 32.0,
                        chargingWh: nil,
                        totalEnergyWh: 2.7
                    ),
                    WidgetAppItem(
                        id: "3",
                        displayName: "Slack",
                        batteryMinutes: 18.0,
                        chargingWh: nil,
                        totalEnergyWh: 1.5
                    )
                ],
                totalBatteryMinutes: 104.0,
                totalAcWh: nil,
                totalEnergyWh: 8.7,
                hasData: true
            )
        )
    }

    public static var empty: ReceiptEntry {
        ReceiptEntry(date: Date(), data: nil)
    }
}

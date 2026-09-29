import Foundation

public enum LedgerResolution: String, Sendable, Codable, Equatable {
    case minute
    case hour
}

public enum ReceiptDiscrepancyStatus: String, Sendable, Codable, Equatable {
    case exactConservation
    case withinToleranceOverAttribution
    case inconsistent
}

public struct ReceiptAppRow: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(appKey.kind.rawValue):\(appKey.value)" }
    public var appKey: AppKey
    public var displayName: String
    public var bundlePath: String?
    public var category: AppCategory
    public var energy_uj: Int64
    public var pEnergy_uj: Int64
    public var cpuTime_ms: Int64
    public var batteryMinutes: Double?
    public var batteryPercent: Double?
    public var chargingWh: Double?

    public init(
        appKey: AppKey,
        displayName: String,
        bundlePath: String? = nil,
        category: AppCategory = .userApp,
        energy_uj: Int64,
        pEnergy_uj: Int64 = 0,
        cpuTime_ms: Int64 = 0,
        batteryMinutes: Double? = nil,
        batteryPercent: Double? = nil,
        chargingWh: Double? = nil
    ) {
        self.appKey = appKey
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.category = category
        self.energy_uj = energy_uj
        self.pEnergy_uj = pEnergy_uj
        self.cpuTime_ms = cpuTime_ms
        self.batteryMinutes = batteryMinutes
        self.batteryPercent = batteryPercent
        self.chargingWh = chargingWh
    }
}

public struct Receipt: Sendable, Codable, Equatable {
    public var interval: DateInterval
    public var powerSource: PowerSourceKind?
    public var rows: [ReceiptAppRow]
    public var macOSServices: [ReceiptAppRow]
    public var tail_uj: Int64
    public var unreadableSystem_uj: Int64
    public var isUnreadableEstimated: Bool
    public var unreadableProcessRatio: Double?
    public var other_uj: Int64
    public var gpu_uj: Int64
    public var measuredSystemEnergy_uj: Int64
    public var attributedCoveredEnergy_uj: Int64
    public var residualSigned_uj: Int64
    public var discrepancyStatus: ReceiptDiscrepancyStatus
    public var pRefWatts: Double?
    public var eFullJoules: Double?

    public var residual_uj: Int64 {
        residualSigned_uj
    }

    public var isOverAttributed: Bool {
        residualSigned_uj < 0
    }

    public var isFlagged: Bool {
        isOverAttributed
    }

    public var apps: [ReceiptAppRow] {
        rows
    }

    public var allRows: [ReceiptAppRow] {
        (rows + macOSServices).sorted { $0.energy_uj > $1.energy_uj }
    }

    public init(
        interval: DateInterval,
        powerSource: PowerSourceKind? = nil,
        rows: [ReceiptAppRow] = [],
        macOSServices: [ReceiptAppRow] = [],
        tail_uj: Int64 = 0,
        unreadableSystem_uj: Int64 = 0,
        isUnreadableEstimated: Bool = false,
        unreadableProcessRatio: Double? = nil,
        other_uj: Int64 = 0,
        gpu_uj: Int64 = 0,
        measuredSystemEnergy_uj: Int64 = 0,
        attributedCoveredEnergy_uj: Int64 = 0,
        residualSigned_uj: Int64 = 0,
        discrepancyStatus: ReceiptDiscrepancyStatus = .exactConservation,
        pRefWatts: Double? = nil,
        eFullJoules: Double? = nil
    ) {
        self.interval = interval
        self.powerSource = powerSource
        self.rows = rows
        self.macOSServices = macOSServices
        self.tail_uj = tail_uj
        self.unreadableSystem_uj = unreadableSystem_uj
        self.isUnreadableEstimated = isUnreadableEstimated
        self.unreadableProcessRatio = unreadableProcessRatio
        self.other_uj = other_uj
        self.gpu_uj = gpu_uj
        self.measuredSystemEnergy_uj = measuredSystemEnergy_uj
        self.attributedCoveredEnergy_uj = attributedCoveredEnergy_uj
        self.residualSigned_uj = residualSigned_uj
        self.discrepancyStatus = discrepancyStatus
        self.pRefWatts = pRefWatts
        self.eFullJoules = eFullJoules
    }
}

public struct SystemPoint: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var source: PowerSourceKind
    public var coveredMs: Int
    public var systemEnergy_uj: Int64?
    public var attributedEnergy_uj: Int64
    public var tailEnergy_uj: Int64
    public var residual_uj: Int64?
    public var gpuEnergy_uj: Int64?
    public var batteryPercent: Int?
    public var voltage_mv: Int?
    public var thermalMax: ThermalLevel?

    public init(
        timestamp: Date,
        source: PowerSourceKind,
        coveredMs: Int,
        systemEnergy_uj: Int64? = nil,
        attributedEnergy_uj: Int64 = 0,
        tailEnergy_uj: Int64 = 0,
        residual_uj: Int64? = nil,
        gpuEnergy_uj: Int64? = nil,
        batteryPercent: Int? = nil,
        voltage_mv: Int? = nil,
        thermalMax: ThermalLevel? = nil
    ) {
        self.timestamp = timestamp
        self.source = source
        self.coveredMs = coveredMs
        self.systemEnergy_uj = systemEnergy_uj
        self.attributedEnergy_uj = attributedEnergy_uj
        self.tailEnergy_uj = tailEnergy_uj
        self.residual_uj = residual_uj
        self.gpuEnergy_uj = gpuEnergy_uj
        self.batteryPercent = batteryPercent
        self.voltage_mv = voltage_mv
        self.thermalMax = thermalMax
    }
}

public enum PRefCalculator {
    public static func calculatePRef(sys_uj: Int64, sys_cov_ms: Int64) -> Double? {
        guard sys_cov_ms > 0 else { return nil }
        let joules = Double(sys_uj) * 1e-6
        let seconds = Double(sys_cov_ms) * 1e-3
        guard seconds > 0 else { return nil }
        return joules / seconds
    }

    public static func calculateBatteryMinutes(energy_uj: Int64, pRef: Double) -> Double? {
        guard pRef > 0 else { return nil }
        let eAppJoules = Double(energy_uj) * 1e-6
        return eAppJoules / pRef / 60.0
    }

    public static func calculateBatteryPercent(energy_uj: Int64, fcc_mah: Int, averageVoltage_mv: Int) -> Double? {
        let vBar = Double(averageVoltage_mv) / 1000.0
        let eFullJoules = Double(fcc_mah) * vBar * 3.6
        guard eFullJoules > 0 else { return nil }
        let eAppJoules = Double(energy_uj) * 1e-6
        return 100.0 * eAppJoules / eFullJoules
    }
}

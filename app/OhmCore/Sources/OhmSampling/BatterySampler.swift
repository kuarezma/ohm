import Foundation
import IOKit
import OhmModel

extension BatteryState {
    /// No battery present (desktop Mac) or the gauge could not be read.
    public static let unavailable = BatteryState(source: .unknown, percent: 0, voltage_mV: 0, amperage_mA: 0)
}

/// Raw `AppleSmartBattery` registry values (M3 / macOS 27 key layout, T-010 and T-021).
public struct SmartBatterySnapshot: Sendable, Equatable {
    public var externalConnected: Bool?
    public var isCharging: Bool?
    public var voltage_mV: Int?
    /// Negative while discharging.
    public var amperage_mA: Int?
    /// On Apple Silicon `CurrentCapacity` / `MaxCapacity` are percent (MaxCapacity = 100).
    public var currentCapacity: Int?
    public var maxCapacity: Int?
    /// `BatteryData.RemainingCapacity` (mAh; `AppleRawCurrentCapacity` on older systems).
    public var remainingCapacity_mAh: Int?
    /// `BatteryData.FullChargeCapacity` (mAh, health adjusted; `AppleRawMaxCapacity` on older systems).
    public var fullChargeCapacity_mAh: Int?
    /// `PowerTelemetryData.SystemLoad` (mW); valid on battery and on AC. Absent on some chips/OSes.
    public var systemLoad_mW: Int?
    /// `UpdateTime`: unix seconds of the gauge's last update (~20 s cadence).
    public var updateTime: Int?

    public init(externalConnected: Bool? = nil, isCharging: Bool? = nil, voltage_mV: Int? = nil,
                amperage_mA: Int? = nil, currentCapacity: Int? = nil, maxCapacity: Int? = nil,
                remainingCapacity_mAh: Int? = nil, fullChargeCapacity_mAh: Int? = nil,
                systemLoad_mW: Int? = nil, updateTime: Int? = nil) {
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.voltage_mV = voltage_mV
        self.amperage_mA = amperage_mA
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
        self.remainingCapacity_mAh = remainingCapacity_mAh
        self.fullChargeCapacity_mAh = fullChargeCapacity_mAh
        self.systemLoad_mW = systemLoad_mW
        self.updateTime = updateTime
    }

    public var isDischarging: Bool {
        externalConnected == false && (amperage_mA ?? 0) < 0
    }
}

/// Seam over IOKit. Not Sendable.
public protocol SmartBatteryRegistry: AnyObject {
    /// nil when there is no battery (desktop Mac) or it cannot be read.
    func snapshot() -> SmartBatterySnapshot?
}

public final class IOKitSmartBattery: SmartBatteryRegistry {
    private var service: io_service_t = 0

    public init() {}

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    public func snapshot() -> SmartBatterySnapshot? {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service == 0 { return nil }
        }
        let batteryData = dictionary("BatteryData")
        let telemetry = dictionary("PowerTelemetryData")
        return SmartBatterySnapshot(
            externalConnected: bool("ExternalConnected"),
            isCharging: bool("IsCharging"),
            voltage_mV: int("Voltage"),
            amperage_mA: int("Amperage"),
            currentCapacity: int("CurrentCapacity"),
            maxCapacity: int("MaxCapacity"),
            remainingCapacity_mAh: (batteryData?["RemainingCapacity"] as? NSNumber)?.intValue
                ?? int("AppleRawCurrentCapacity"),
            fullChargeCapacity_mAh: (batteryData?["FullChargeCapacity"] as? NSNumber)?.intValue
                ?? int("AppleRawMaxCapacity"),
            systemLoad_mW: (telemetry?["SystemLoad"] as? NSNumber)?.intValue,
            updateTime: int("UpdateTime"))
    }

    private func property(_ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func int(_ key: String) -> Int? { (property(key) as? NSNumber).map { Int($0.int64Value) } }
    private func bool(_ key: String) -> Bool? { (property(key) as? NSNumber)?.boolValue }
    private func dictionary(_ key: String) -> [String: Any]? { property(key) as? [String: Any] }
}

/// Pure mapping from registry snapshot to the ADR value types.
public enum BatteryMapping {
    public static func state(_ s: SmartBatterySnapshot?) -> BatteryState {
        guard let s else { return .unavailable }
        let percent: Int
        if let cur = s.currentCapacity, let max = s.maxCapacity, max > 0 {
            percent = Int((Double(cur) * 100 / Double(max)).rounded())
        } else {
            percent = 0
        }
        let source: PowerSourceKind = switch s.externalConnected {
        case true?: .ac
        case false?: .battery
        case nil: .unknown
        }
        return BatteryState(source: source, percent: percent, voltage_mV: s.voltage_mV ?? 0,
                            amperage_mA: s.amperage_mA ?? 0, systemLoad_mW: s.systemLoad_mW,
                            rawCurrentCapacity_mAh: s.remainingCapacity_mAh,
                            fullChargeCapacity_mAh: s.fullChargeCapacity_mAh,
                            isCharging: s.isCharging ?? false)
    }

    /// ADR 0002 § 5 source choice: SystemLoad when present; otherwise V × I, but only while
    /// discharging (on AC it is charger power, not system power).
    public static func systemLoad(_ s: SmartBatterySnapshot?, nowUnix: Double)
        -> (watts: Double?, source: SystemEnergySource, age: Duration?) {
        guard let s else { return (nil, .none, nil) }
        let age = s.updateTime.map { Duration.seconds(max(0, nowUnix - Double($0))) }
        if let mW = s.systemLoad_mW, mW >= 0 {
            return (Double(mW) / 1e3, .systemLoad, age)
        }
        if s.isDischarging, let mV = s.voltage_mV, let mA = s.amperage_mA {
            return (-Double(mV) * Double(mA) / 1e6, .batteryVI, age)
        }
        return (nil, .none, nil)
    }
}

public final class BatterySampler: BatterySampling {
    private let registry: any SmartBatteryRegistry

    public init(registry: any SmartBatteryRegistry = IOKitSmartBattery()) {
        self.registry = registry
    }

    public func read() -> BatteryState { BatteryMapping.state(registry.snapshot()) }
}

public final class SystemLoadSampler: SystemLoadSampling {
    private let registry: any SmartBatteryRegistry
    private let nowUnix: () -> Double

    public init(registry: any SmartBatteryRegistry = IOKitSmartBattery(),
                nowUnix: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.registry = registry
        self.nowUnix = nowUnix
    }

    public func read() -> (watts: Double?, source: SystemEnergySource, age: Duration?) {
        BatteryMapping.systemLoad(registry.snapshot(), nowUnix: nowUnix())
    }
}

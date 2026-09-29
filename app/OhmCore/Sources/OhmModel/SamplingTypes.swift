import Foundation

public enum PowerSourceKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case battery
    case ac
    case unknown

    public var sqliteValue: Int {
        switch self {
        case .ac: return 0
        case .battery: return 1
        case .unknown: return 2
        }
    }

    public init(sqliteValue: Int) {
        switch sqliteValue {
        case 0: self = .ac
        case 1: self = .battery
        default: self = .unknown
        }
    }
}

public enum ThermalLevel: Int, Sendable, Codable, Comparable, Equatable, Hashable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ClusterResidency: Sendable, Codable, Equatable {
    public var pActiveRatio: Double
    public var eActiveRatio: Double

    public init(pActiveRatio: Double, eActiveRatio: Double) {
        self.pActiveRatio = pActiveRatio
        self.eActiveRatio = eActiveRatio
    }
}

public enum SystemEnergySource: Int, Sendable, Codable, Equatable, Hashable {
    case systemLoad = 0
    case batteryVI = 1
    case none = 2
}

public struct EnergyBurst: Sendable, Codable, Equatable {
    public var window: DateInterval
    public var cpu_mJ: Double?
    public var dram_mJ: Double?
    public var ane_mJ: Double?

    public init(
        window: DateInterval,
        cpu_mJ: Double? = nil,
        dram_mJ: Double? = nil,
        ane_mJ: Double? = nil
    ) {
        self.window = window
        self.cpu_mJ = cpu_mJ
        self.dram_mJ = dram_mJ
        self.ane_mJ = ane_mJ
    }
}

public struct BatteryState: Sendable, Codable, Equatable {
    public var source: PowerSourceKind
    public var percent: Int
    public var voltage_mV: Int
    public var amperage_mA: Int
    public var systemLoad_mW: Int?
    public var rawCurrentCapacity_mAh: Int?
    public var fullChargeCapacity_mAh: Int?
    public var isCharging: Bool

    public init(
        source: PowerSourceKind,
        percent: Int,
        voltage_mV: Int,
        amperage_mA: Int,
        systemLoad_mW: Int? = nil,
        rawCurrentCapacity_mAh: Int? = nil,
        fullChargeCapacity_mAh: Int? = nil,
        isCharging: Bool = false
    ) {
        self.source = source
        self.percent = percent
        self.voltage_mV = voltage_mV
        self.amperage_mA = amperage_mA
        self.systemLoad_mW = systemLoad_mW
        self.rawCurrentCapacity_mAh = rawCurrentCapacity_mAh
        self.fullChargeCapacity_mAh = fullChargeCapacity_mAh
        self.isCharging = isCharging
    }
}

public struct SystemPower: Sendable, Equatable {
    public var cpuP: Double
    public var cpuE: Double
    public var gpu: Double?
    public var systemLoad: Double?
    public var systemLoadAge: Duration?
    public var clusterActive: ClusterResidency?
    /// Which source `systemLoad` came from: SystemLoad, or V × I while discharging (ADR 0002 § 5 `sys_src`).
    public var systemSource: SystemEnergySource
    /// IOReport's own measurement interval for `gpu` (awake time); GPU energy = gpu × gpuInterval.
    public var gpuInterval: Duration?

    public init(
        cpuP: Double,
        cpuE: Double,
        gpu: Double? = nil,
        systemLoad: Double? = nil,
        systemLoadAge: Duration? = nil,
        clusterActive: ClusterResidency? = nil,
        systemSource: SystemEnergySource? = nil,
        gpuInterval: Duration? = nil
    ) {
        self.cpuP = cpuP
        self.cpuE = cpuE
        self.gpu = gpu
        self.systemLoad = systemLoad
        self.systemLoadAge = systemLoadAge
        self.clusterActive = clusterActive
        self.systemSource = systemSource ?? (systemLoad != nil ? .systemLoad : .none)
        self.gpuInterval = gpuInterval
    }
}

public struct ProcessDelta: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var app: AppKey
    public var energy_nJ: UInt64
    public var pEnergy_nJ: UInt64
    public var cpuTime_ns: UInt64
    /// Ledger `app.display_name`, `app.bundle_path`, `app.category`; only AttributionResolver knows them.
    public var displayName: String
    public var bundlePath: String?
    public var category: AppCategory

    public init(
        identity: ProcessIdentity,
        app: AppKey,
        energy_nJ: UInt64,
        pEnergy_nJ: UInt64,
        cpuTime_ns: UInt64,
        displayName: String? = nil,
        bundlePath: String? = nil,
        category: AppCategory = .userApp
    ) {
        self.identity = identity
        self.app = app
        self.energy_nJ = energy_nJ
        self.pEnergy_nJ = pEnergy_nJ
        self.cpuTime_ns = cpuTime_ns
        self.displayName = displayName ?? app.value
        self.bundlePath = bundlePath
        self.category = category
    }
}

public struct UnreadableSummary: Sendable, Codable, Equatable {
    public var readableCount: Int
    public var unreadableCount: Int

    public init(readableCount: Int, unreadableCount: Int) {
        self.readableCount = readableCount
        self.unreadableCount = unreadableCount
    }
}

public struct SampleTick: Sendable {
    public var wallClock: Date
    /// Awake time since the previous tick (mach_absolute_time; stops during system sleep). Power
    /// values are averages over this interval, so power × interval is energy (T-024 #8).
    public var interval: Duration
    /// System sleep inside this tick's span; not part of `interval` (ledger `sampling_gap`, 'sleep').
    public var asleep: Duration
    public var system: SystemPower
    public var burst: EnergyBurst?
    public var battery: BatteryState
    public var thermal: ThermalLevel
    public var processes: [ProcessDelta]
    public var unreadable: UnreadableSummary

    public init(
        wallClock: Date,
        interval: Duration,
        system: SystemPower,
        burst: EnergyBurst? = nil,
        battery: BatteryState,
        thermal: ThermalLevel,
        processes: [ProcessDelta],
        unreadable: UnreadableSummary,
        asleep: Duration = .zero
    ) {
        self.wallClock = wallClock
        self.interval = interval
        self.asleep = asleep
        self.system = system
        self.burst = burst
        self.battery = battery
        self.thermal = thermal
        self.processes = processes
        self.unreadable = unreadable
    }
}

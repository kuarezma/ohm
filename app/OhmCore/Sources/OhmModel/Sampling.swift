import Foundation

// Value types and sampler contracts from ADR 0001 § 2. Everything that crosses an isolation
// boundary is a Sendable value type; the sampler protocols are deliberately NOT Sendable
// (ADR 0001 § 3: implementations are confined to the SamplingEngine actor).

/// ADR 0002 § 1: persistent attribution key kind. Raw values are stored in the ledger.
public enum AttributionKind: Int, Sendable, Codable {
    case bundleID = 0
    case executableName = 1
    case processName = 2
}

/// ADR 0002 § 1: persistent attribution key (`app.kind`, `app.key`).
public struct AppKey: Hashable, Sendable, Codable {
    public var kind: AttributionKind
    public var value: String

    public init(kind: AttributionKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// ADR 0002 § 1 `app.category`. Raw values are stored in the ledger.
public enum AppCategory: Int, Sendable, Codable {
    case userApp = 0
    case systemService = 1
}

public enum PowerSourceKind: String, Sendable, Codable {
    case battery, ac, unknown
}

public enum ThermalLevel: Int, Sendable, Codable, Comparable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// IOReport "CPU Stats" active residency per cluster, as a fraction in 0...1.
public struct ClusterResidency: Sendable, Equatable, Codable {
    public var pActive: Double
    public var eActive: Double

    public init(pActive: Double, eActive: Double) {
        self.pActive = pActive
        self.eActive = eActive
    }
}

/// ADR 0002 § 5: the single effective system-energy source.
public enum SystemEnergySource: Int, Sendable, Codable {
    case systemLoad = 0
    case batteryVI = 1
    case none = 2
}

/// Average power over one tick interval, in watts.
public struct SystemPower: Sendable, Equatable {
    /// Σ Δri_penergy_nj of readable processes ("apps' CPU power", not total CPU power).
    public var cpuP: Double
    /// Σ Δ(ri_energy_nj − ri_penergy_nj) of readable processes.
    public var cpuE: Double
    /// IOReport "GPU Energy" (live); nil when IOReport is unavailable.
    public var gpu: Double?
    /// PowerTelemetryData.SystemLoad, or V × I while discharging; see `systemSource`.
    public var systemLoad: Double?
    /// Which source `systemLoad` came from (not in the ADR 0001 sketch; the ledger needs it for `sys_src`).
    public var systemSource: SystemEnergySource
    /// Time since the battery gauge last updated the value.
    public var systemLoadAge: Duration?
    public var clusterActive: ClusterResidency?

    public init(cpuP: Double, cpuE: Double, gpu: Double?, systemLoad: Double?,
                systemSource: SystemEnergySource, systemLoadAge: Duration?,
                clusterActive: ClusterResidency?) {
        self.cpuP = cpuP
        self.cpuE = cpuE
        self.gpu = gpu
        self.systemLoad = systemLoad
        self.systemSource = systemSource
        self.systemLoadAge = systemLoadAge
        self.clusterActive = clusterActive
    }
}

/// IOReport "Energy Model" burst: sparse, long window (previous burst → this burst).
public struct EnergyBurst: Sendable, Equatable {
    public var window: DateInterval
    public var cpu_mJ: Double?
    public var dram_mJ: Double?
    public var ane_mJ: Double?

    public init(window: DateInterval, cpu_mJ: Double?, dram_mJ: Double?, ane_mJ: Double?) {
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
    /// PowerTelemetryData.SystemLoad; valid on battery and on AC.
    public var systemLoad_mW: Int?
    public var rawCurrentCapacity_mAh: Int?
    public var fullChargeCapacity_mAh: Int?
    public var isCharging: Bool

    public init(source: PowerSourceKind, percent: Int, voltage_mV: Int, amperage_mA: Int,
                systemLoad_mW: Int?, rawCurrentCapacity_mAh: Int?, fullChargeCapacity_mAh: Int?,
                isCharging: Bool) {
        self.source = source
        self.percent = percent
        self.voltage_mV = voltage_mV
        self.amperage_mA = amperage_mA
        self.systemLoad_mW = systemLoad_mW
        self.rawCurrentCapacity_mAh = rawCurrentCapacity_mAh
        self.fullChargeCapacity_mAh = fullChargeCapacity_mAh
        self.isCharging = isCharging
    }

    /// No battery present (desktop Mac) or the gauge could not be read.
    public static let unavailable = BatteryState(
        source: .unknown, percent: 0, voltage_mV: 0, amperage_mA: 0, systemLoad_mW: nil,
        rawCurrentCapacity_mAh: nil, fullChargeCapacity_mAh: nil, isCharging: false)
}

/// One process's counter delta over one tick, already attributed (helper → app).
public struct ProcessDelta: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var app: AppKey
    /// Ledger `app.display_name`, `app.bundle_path`, `app.category` (not in the ADR 0001 sketch;
    /// only the resolver knows them, and T-022 needs them for the `app` table).
    public var displayName: String
    public var bundlePath: String?
    public var category: AppCategory
    public var energy_nJ: UInt64
    public var pEnergy_nJ: UInt64
    public var cpuTime_ns: UInt64

    public init(identity: ProcessIdentity, app: AppKey, displayName: String, bundlePath: String?,
                category: AppCategory, energy_nJ: UInt64, pEnergy_nJ: UInt64, cpuTime_ns: UInt64) {
        self.identity = identity
        self.app = app
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.category = category
        self.energy_nJ = energy_nJ
        self.pEnergy_nJ = pEnergy_nJ
        self.cpuTime_ns = cpuTime_ns
    }
}

/// Process-scan coverage for one tick (ledger `readable_count` / `unreadable_count`).
public struct UnreadableSummary: Sendable, Equatable, Codable {
    /// Processes whose counters were read this tick.
    public var readable: Int
    /// Processes that returned EPERM (root and other users).
    public var unreadable: Int
    /// Listed but gone before they could be read.
    public var vanished: Int

    public init(readable: Int, unreadable: Int, vanished: Int) {
        self.readable = readable
        self.unreadable = unreadable
        self.vanished = vanished
    }
}

public struct SampleTick: Sendable {
    public var wallClock: Date
    /// Since the previous tick, monotonic (ContinuousClock, includes system sleep).
    public var interval: Duration
    public var system: SystemPower
    public var burst: EnergyBurst?
    public var battery: BatteryState
    public var thermal: ThermalLevel
    /// Only processes with a non-zero energy or CPU-time delta.
    public var processes: [ProcessDelta]
    public var unreadable: UnreadableSummary

    public init(wallClock: Date, interval: Duration, system: SystemPower, burst: EnergyBurst?,
                battery: BatteryState, thermal: ThermalLevel, processes: [ProcessDelta],
                unreadable: UnreadableSummary) {
        self.wallClock = wallClock
        self.interval = interval
        self.system = system
        self.burst = burst
        self.battery = battery
        self.thermal = thermal
        self.processes = processes
        self.unreadable = unreadable
    }
}

public enum SamplingCadence: Sendable, Equatable {
    /// Popover open: 1 s.
    case interactive
    /// Popover closed: 10 s.
    case ambient
    /// Screen or system asleep: no counter reads.
    case suspended
}

// MARK: Sampler contracts (ADR 0001 § 2). Not Sendable, synchronous; owned by SamplingEngine.

public protocol SystemLoadSampling: AnyObject {
    func read() -> (watts: Double?, source: SystemEnergySource, age: Duration?)
}

public protocol ComponentSampling: AnyObject {
    func sample() -> (gpuWatts: Double?, residency: ClusterResidency?, burst: EnergyBurst?)
}

public protocol ProcessEnergySampling: AnyObject {
    func sample() -> (deltas: [ProcessDelta], unreadable: UnreadableSummary)
}

public protocol BatterySampling: AnyObject {
    func read() -> BatteryState
}

public protocol SamplingEngineProtocol: Actor {
    func setCadence(_ cadence: SamplingCadence)
    /// Single consumer: OhmRuntime.
    nonisolated var ticks: AsyncStream<SampleTick> { get }
}

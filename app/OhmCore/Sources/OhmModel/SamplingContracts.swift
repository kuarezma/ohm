import Foundation

// ADR 0001 § 2 sampler contracts. Not Sendable, synchronous; implementations are owned by the
// SamplingEngine actor and handed over with `sending` (ADR 0001 § 3).

public enum SamplingCadence: Sendable, Equatable {
    /// Popover open: 1 s.
    case interactive
    /// Popover closed: 10 s.
    case ambient
    /// Screen or system asleep: no counter reads.
    case suspended
}

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

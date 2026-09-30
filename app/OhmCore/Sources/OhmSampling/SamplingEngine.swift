import Darwin
import Dispatch
import Foundation
import OhmModel

/// The two time bases a tick needs, injectable for tests. Nanoseconds since an arbitrary origin.
public struct SamplingClocks: Sendable {
    /// Stops during system sleep (mach_absolute_time), like the IOReport and rusage counters' activity.
    public var awake: @Sendable () -> UInt64
    /// Keeps running during sleep (mach_continuous_time).
    public var continuous: @Sendable () -> UInt64

    public init(awake: @escaping @Sendable () -> UInt64, continuous: @escaping @Sendable () -> UInt64) {
        self.awake = awake
        self.continuous = continuous
    }

    public static let system = SamplingClocks(
        awake: { MachTimebase.current.nanoseconds(mach_absolute_time()) },
        continuous: { MachTimebase.current.nanoseconds(mach_continuous_time()) })
}

/// Periodic sampler (ADR 0001 § 3–4). Runs on its own `.utility` serial queue because the samplers
/// make short blocking syscalls; the non-Sendable samplers are handed over with `sending` and never
/// leave the actor. Emits one `SampleTick` per interval on `ticks` (lossless, single consumer).
public actor SamplingEngine: SamplingEngineProtocol {
    /// SystemLoad and battery fields: the gauge updates only every ~20 s (ADR 0001 § 4).
    public static let slowReadPeriod: Duration = .seconds(10)

    public static func interval(for cadence: SamplingCadence) -> Duration? {
        switch cadence {
        case .interactive: .seconds(1)
        case .ambient: .seconds(10)
        case .suspended: nil
        }
    }

    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public nonisolated let ticks: AsyncStream<SampleTick>
    private let tickBuffer: TickBuffer
    public var pendingTickCount: Int { tickBuffer.count }

    private let process: any ProcessEnergySampling
    private let component: any ComponentSampling
    private let systemLoad: any SystemLoadSampling
    private let battery: any BatterySampling
    private let thermal: @Sendable () -> ThermalLevel
    private let clocks: SamplingClocks

    private struct Stamp {
        var awake: UInt64
        var continuous: UInt64
    }

    private struct SlowReading {
        var at: UInt64  // continuous ns
        var load: (watts: Double?, source: SystemEnergySource, age: Duration?)
        var battery: BatteryState
    }

    private var cadence: SamplingCadence
    private var lastTick: Stamp?
    private var slow: SlowReading?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, any Error>?

    public private(set) var tickCount = 0

    public init(process: sending any ProcessEnergySampling,
                component: sending any ComponentSampling,
                systemLoad: sending any SystemLoadSampling,
                battery: sending any BatterySampling,
                thermal: @escaping @Sendable () -> ThermalLevel = ThermalSampler.current,
                cadence: SamplingCadence = .ambient,
                clocks: SamplingClocks = .system,
                pendingTickLimit: Int = 4) {
        queue = DispatchSerialQueue(label: "dev.ohm.sampling", qos: .utility)
        self.process = process
        self.component = component
        self.systemLoad = systemLoad
        self.battery = battery
        self.thermal = thermal
        self.clocks = clocks
        self.cadence = cadence
        let buffer = TickBuffer(capacity: pendingTickLimit)
        tickBuffer = buffer
        ticks = AsyncStream(unfolding: { await buffer.next() })
    }

    /// Production composition: IOReport when available, otherwise `NullComponentSampler`.
    public static func makeDefault(cadence: SamplingCadence = .ambient) -> SamplingEngine {
        SamplingEngine(process: ProcessEnergySampler(), component: IOReportSampler.makeDefault(),
                       systemLoad: SystemLoadSampler(), battery: BatterySampler(), cadence: cadence)
    }

    deinit {
        loop?.cancel()
        sleeper?.cancel()
        tickBuffer.finish()
    }

    // MARK: Control

    /// Takes the baseline sample and starts the timer loop. Idempotent.
    public func start() {
        guard loop == nil else { return }
        prime()
        loop = Task(priority: .utility) { await self.run() }
    }

    /// Stops the loop (keeps the stream open; `start()` resumes with a fresh baseline interval).
    public func stop() {
        loop?.cancel()
        sleeper?.cancel()
        loop = nil
    }

    public func setCadence(_ newValue: SamplingCadence) {
        let old = cadence
        cadence = newValue
        // Wake the sleeping loop when the new cadence is faster (popover opened, wake from sleep).
        let oldInterval = Self.interval(for: old) ?? .seconds(Int64.max)
        let newInterval = Self.interval(for: newValue) ?? .seconds(Int64.max)
        if newInterval < oldInterval { sleeper?.cancel() }
    }

    public var currentCadence: SamplingCadence { cadence }

    // MARK: Sampling

    /// Reads every sampler once and emits a tick. The first call after construction only takes the
    /// baseline and returns nil.
    @discardableResult
    public func sampleNow() -> SampleTick? {
        guard let last = lastTick else {
            prime()
            return nil
        }
        let now = stamp()
        lastTick = now
        let (deltas, unreadable) = process.sample()
        let parts = component.sample()
        let slowReading = refreshSlowIfDue(now: now.continuous)
        let load = (watts: slowReading.load.watts, source: slowReading.load.source,
                    age: slowReading.load.age.map { $0 + .nanoseconds(Int64(now.continuous &- slowReading.at)) })
        let (interval, asleep) = Self.split(from: last, to: now)
        let tick = Self.makeTick(wallClock: Date(), interval: interval, asleep: asleep, deltas: deltas,
                                 unreadable: unreadable, component: parts, systemLoad: load,
                                 battery: slowReading.battery, thermal: thermal())
        tickCount += 1
        tickBuffer.offer(tick)
        return tick
    }

    private func prime() {
        _ = process.sample()
        _ = component.sample()
        lastTick = stamp()
    }

    private func stamp() -> Stamp { Stamp(awake: clocks.awake(), continuous: clocks.continuous()) }

    /// Tick span → (measurement interval, time asleep). The interval is awake time: the counters and
    /// IOReport only advance while awake, and wake power must not be spread over the sleep (T-024 #8).
    private static func split(from a: Stamp, to b: Stamp) -> (Duration, Duration) {
        let awake = b.awake >= a.awake ? b.awake - a.awake : 0
        let wall = b.continuous >= a.continuous ? b.continuous - a.continuous : 0
        let asleep = wall > awake ? wall - awake : 0
        return (.nanoseconds(Int64(awake)), .nanoseconds(Int64(asleep)))
    }

    private func refreshSlowIfDue(now: UInt64) -> SlowReading {
        // Small slack so a 10 s cadence with timer tolerance does not skip every other read.
        if let slow, now >= slow.at, Duration.nanoseconds(Int64(now - slow.at)) < Self.slowReadPeriod - .milliseconds(500) {
            return slow
        }
        let fresh = SlowReading(at: now, load: systemLoad.read(), battery: battery.read())
        slow = fresh
        return fresh
    }

    private func run() async {
        while !Task.isCancelled {
            // Suspended: long nap, cut short by setCadence; then tick at once without another wait.
            await nap(Self.interval(for: cadence) ?? .seconds(3600))
            if Task.isCancelled { break }
            if Self.interval(for: cadence) != nil { sampleNow() }
        }
    }

    /// `ContinuousClock` sleep with 10 % tolerance so the kernel can coalesce wakeups (ADR 0001 § 4).
    private func nap(_ duration: Duration) async {
        let sleep = Task { try await Task.sleep(for: duration, tolerance: duration / 10, clock: .continuous) }
        sleeper = sleep
        await withTaskCancellationHandler {
            _ = try? await sleep.value
        } onCancel: {
            sleep.cancel()
        }
        sleeper = nil
    }

    // MARK: Pure assembly

    static func makeTick(wallClock: Date, interval: Duration, asleep: Duration = .zero, deltas: [ProcessDelta],
                         unreadable: UnreadableSummary,
                         component: (gpuWatts: Double?, gpuInterval: Duration?, residency: ClusterResidency?,
                                     burst: EnergyBurst?),
                         systemLoad: (watts: Double?, source: SystemEnergySource, age: Duration?),
                         battery: BatteryState, thermal: ThermalLevel) -> SampleTick {
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        var pJ = 0.0, eJ = 0.0
        for d in deltas {
            pJ += Double(d.pEnergy_nJ) / 1e9
            eJ += Double(d.energy_nJ - min(d.pEnergy_nJ, d.energy_nJ)) / 1e9
        }
        let power = SystemPower(cpuP: seconds > 0 ? pJ / seconds : 0, cpuE: seconds > 0 ? eJ / seconds : 0,
                                gpu: component.gpuWatts, systemLoad: systemLoad.watts,
                                systemLoadAge: systemLoad.age, clusterActive: component.residency,
                                systemSource: systemLoad.source, gpuInterval: component.gpuInterval)
        return SampleTick(wallClock: wallClock, interval: interval, system: power, burst: component.burst,
                          battery: battery, thermal: thermal, processes: deltas, unreadable: unreadable,
                          asleep: asleep)
    }
}

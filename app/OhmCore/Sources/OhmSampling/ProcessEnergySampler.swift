import COhmSys
import Darwin
import OhmModel
import os

/// Raw cumulative counters of one process (`proc_pid_rusage(RUSAGE_INFO_V6)`).
public struct ProcessCounters: Sendable, Equatable {
    public var energy_nJ: UInt64
    public var pEnergy_nJ: UInt64
    /// ri_user_time + ri_system_time, mach ticks.
    public var cpuTicks: UInt64
    /// ri_proc_start_abstime, mach absolute time.
    public var startAbs: UInt64

    public init(energy_nJ: UInt64, pEnergy_nJ: UInt64, cpuTicks: UInt64, startAbs: UInt64) {
        self.energy_nJ = energy_nJ
        self.pEnergy_nJ = pEnergy_nJ
        self.cpuTicks = cpuTicks
        self.startAbs = startAbs
    }
}

public enum ProcessReadResult: Sendable, Equatable {
    case counters(ProcessCounters)
    /// EPERM: root or another user's process.
    case denied
    /// ESRCH or any other error: the process is gone.
    case gone
}

/// Seam over the kernel so the delta logic is testable with fakes. Not Sendable (ADR 0001 § 3).
public protocol ProcessCounterSource: AnyObject {
    /// Current mach absolute time (same clock as `ri_proc_start_abstime`).
    func now() -> UInt64
    func listPIDs() -> [Int32]
    func read(_ pid: Int32) -> ProcessReadResult
}

public final class SystemProcessCounterSource: ProcessCounterSource {
    private var buffer: [Int32] = []

    public init() {}

    public func now() -> UInt64 { mach_absolute_time() }

    public func listPIDs() -> [Int32] {
        if buffer.isEmpty {
            buffer = [Int32](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 256)
        }
        while true {
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { raw in
                Int(proc_listallpids(raw.baseAddress, Int32(raw.count)))
            }
            if count <= 0 { return [] }
            if count < capacity { return Array(buffer[0..<count]) }
            buffer = [Int32](repeating: 0, count: capacity * 2)  // possibly truncated: grow and retry
        }
    }

    public func read(_ pid: Int32) -> ProcessReadResult {
        var raw = ohm_proc_counters()
        switch ohm_proc_read(pid, &raw) {
        case 0:
            return .counters(ProcessCounters(energy_nJ: raw.energy_nj, pEnergy_nJ: raw.penergy_nj,
                                             cpuTicks: raw.cpu_time_abs, startAbs: raw.start_abstime))
        case EPERM:
            return .denied
        default:
            return .gone
        }
    }
}

/// Counter delta for one identity over one tick. Units as in `ProcessCounters`.
public struct CounterDelta: Sendable, Equatable {
    public var energy_nJ: UInt64
    public var pEnergy_nJ: UInt64
    public var cpuTicks: UInt64

    public static let zero = CounterDelta(energy_nJ: 0, pEnergy_nJ: 0, cpuTicks: 0)

    public var isZero: Bool { energy_nJ == 0 && cpuTicks == 0 }
}

/// ADR 0002 § 2 "Sayaçtan deltaya": pure delta rules.
public enum ProcessDeltaMath {
    public enum Event: Sendable, Equatable {
        /// Same identity as last tick: ordinary difference.
        case continued
        /// First sighting of a process that started after the previous tick: whole counter counts.
        case started
        /// First sighting of an older process (Ohm just started, pid newly readable): baseline only.
        case baseline
        /// A counter went backwards: delta 0, new baseline, logged.
        case counterReset
    }

    /// - Parameters:
    ///   - previous: last counters seen for this pid (any identity), or nil.
    ///   - previousSampleAbs: mach time at which the previous scan began, nil on the first scan.
    public static func step(previous: ProcessCounters?, current: ProcessCounters,
                            previousSampleAbs: UInt64?) -> (delta: CounterDelta, event: Event) {
        if let previous, previous.startAbs == current.startAbs {
            guard current.energy_nJ >= previous.energy_nJ,
                  current.pEnergy_nJ >= previous.pEnergy_nJ,
                  current.cpuTicks >= previous.cpuTicks else {
                return (.zero, .counterReset)
            }
            return (clamped(energy: current.energy_nJ - previous.energy_nJ,
                            pEnergy: current.pEnergy_nJ - previous.pEnergy_nJ,
                            cpu: current.cpuTicks - previous.cpuTicks), .continued)
        }
        // New identity: never seen, or the pid was reused (different start time).
        if let previousSampleAbs, current.startAbs >= previousSampleAbs {
            return (clamped(energy: current.energy_nJ, pEnergy: current.pEnergy_nJ,
                            cpu: current.cpuTicks), .started)
        }
        return (.zero, .baseline)
    }

    /// The P share is a subset of the total; clamp so that E = total − P never goes negative.
    private static func clamped(energy: UInt64, pEnergy: UInt64, cpu: UInt64) -> CounterDelta {
        CounterDelta(energy_nJ: energy, pEnergy_nJ: min(pEnergy, energy), cpuTicks: cpu)
    }
}

/// Scans every pid each tick and turns cumulative `ri_energy_nj` / `ri_penergy_nj` counters into
/// attributed per-tick deltas (ADR 0001 § 4, ADR 0002 § 2). Confined to SamplingEngine.
public final class ProcessEnergySampler: ProcessEnergySampling {
    /// EPERM pids are not retried until they exit or this much time has passed (ADR 0001 § 4:
    /// "until the next attribution-cache refresh").
    public static let deniedRetryInterval: Duration = .seconds(300)

    private struct Tracked {
        var counters: ProcessCounters
        var seenInScan: UInt64
    }

    private let source: any ProcessCounterSource
    private let resolver: AttributionResolver
    private let timebase: MachTimebase
    private let logger = Logger(subsystem: "dev.ohm", category: "sampling")

    private var tracked: [Int32: Tracked] = [:]
    private var denied: [Int32: UInt64] = [:]  // pid → scan number of the last EPERM
    private var deniedRetryAbs: UInt64?
    private var previousSampleAbs: UInt64?
    private var scan: UInt64 = 0

    /// Counter resets observed so far (expected to stay 0; ADR 0002 § 2).
    public private(set) var counterResets = 0
    /// proc_pid_rusage calls made by the last scan (EPERM pids are skipped).
    public private(set) var lastScanReads = 0

    public init(source: any ProcessCounterSource = SystemProcessCounterSource(),
                resolver: AttributionResolver = AttributionResolver(),
                timebase: MachTimebase = .current) {
        self.source = source
        self.resolver = resolver
        self.timebase = timebase
    }

    public func sample() -> (deltas: [ProcessDelta], unreadable: UnreadableSummary) {
        scan &+= 1
        let now = source.now()  // before listing: a process starting mid-scan counts as "started"
        refreshDeniedIfDue(now: now)
        let pids = source.listPIDs()
        var deltas: [ProcessDelta] = []
        var readable = 0, unreadable = 0, vanished = 0, reads = 0
        var live = Set<ProcessIdentity>()
        live.reserveCapacity(pids.count)

        for pid in pids {
            if denied[pid] != nil {
                denied[pid] = scan
                unreadable += 1
                continue
            }
            reads += 1
            switch source.read(pid) {
            case .denied:
                denied[pid] = scan
                unreadable += 1
            case .gone:
                vanished += 1
            case .counters(let current):
                readable += 1
                let identity = ProcessIdentity(pid: pid, startAbsTime: current.startAbs)
                live.insert(identity)
                let (delta, event) = ProcessDeltaMath.step(previous: tracked[pid]?.counters, current: current,
                                                           previousSampleAbs: previousSampleAbs)
                tracked[pid] = Tracked(counters: current, seenInScan: scan)
                if event == .counterReset {
                    counterResets += 1
                    logger.notice("counter went backwards for pid \(pid); rebaselined")
                }
                guard !delta.isZero else { continue }
                let who = resolver.resolve(identity)
                deltas.append(ProcessDelta(identity: identity, app: who.key, displayName: who.displayName,
                                           bundlePath: who.bundlePath, category: who.category,
                                           energy_nJ: delta.energy_nJ, pEnergy_nJ: delta.pEnergy_nJ,
                                           cpuTime_ns: timebase.nanoseconds(delta.cpuTicks)))
            }
        }

        // Dead pids leave both tables; a reused pid is then retried and gets a fresh identity.
        tracked = tracked.filter { $0.value.seenInScan == scan }
        denied = denied.filter { $0.value == scan }
        resolver.prune(keeping: live)
        previousSampleAbs = now
        lastScanReads = reads
        return (deltas, UnreadableSummary(readable: readable, unreadable: unreadable, vanished: vanished))
    }

    private func refreshDeniedIfDue(now: UInt64) {
        let (seconds, attoseconds) = Self.deniedRetryInterval.components
        let intervalNs = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
        guard let since = deniedRetryAbs else {
            deniedRetryAbs = now
            return
        }
        if now >= since, timebase.nanoseconds(now - since) >= intervalNs {
            denied.removeAll(keepingCapacity: true)
            deniedRetryAbs = now
        }
    }
}

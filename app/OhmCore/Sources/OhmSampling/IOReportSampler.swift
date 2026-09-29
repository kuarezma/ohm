import COhmSys
import Foundation
import OhmModel
import os

/// One channel of an IOReport delta, as a plain value (decoded from `ohm_ior_channel`).
public struct IOReportChannel: Sendable, Equatable {
    public var group: String
    public var name: String
    public var unit: String
    /// Simple channel delta in `unit`.
    public var value: Int64
    /// State channel residency (nil for simple channels).
    public var residency: (active: Int64, total: Int64)?

    public init(group: String, name: String, unit: String, value: Int64,
                residency: (active: Int64, total: Int64)? = nil) {
        self.group = group
        self.name = name
        self.unit = unit
        self.value = value
        self.residency = residency
    }

    public static func == (a: IOReportChannel, b: IOReportChannel) -> Bool {
        a.group == b.group && a.name == b.name && a.unit == b.unit && a.value == b.value
            && a.residency?.active == b.residency?.active && a.residency?.total == b.residency?.total
    }
}

/// Energy per interval extracted from one IOReport delta, in joules.
public struct IOReportReading: Sendable, Equatable {
    /// "GPU Energy" (nJ channel, live each second on macOS 27). nil if the channel is absent.
    public var gpuJ: Double?
    /// Coarse "Energy Model" counters, published only in sparse bursts (T-010).
    public var cpuJ: Double = 0
    public var dramJ: Double = 0
    public var aneJ: Double = 0
    public var residency: ClusterResidency?
}

/// Pure decoding rules for the M3 / macOS 27 channel layout (spikes/README.md, T-010).
public enum IOReportDecoder {
    /// Energy unit label → joules per unit; nil for anything that is not an energy unit.
    public static func joulesPerUnit(_ label: String) -> Double? {
        switch label {
        case "J": return 1
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        case "nJ": return 1e-9
        default: return nil
        }
    }

    public static func decode(_ channels: [IOReportChannel]) -> IOReportReading {
        var r = IOReportReading()
        var pActive: Int64 = 0, pTotal: Int64 = 0, eActive: Int64 = 0, eTotal: Int64 = 0
        var sawResidency = false
        for ch in channels {
            if let res = ch.residency {
                if ch.name.hasPrefix("PCPU") {
                    pActive += res.active; pTotal += res.total; sawResidency = true
                } else if ch.name.hasPrefix("ECPU") {
                    eActive += res.active; eTotal += res.total; sawResidency = true
                }
                continue
            }
            guard ch.group == "Energy Model", let k = joulesPerUnit(ch.unit) else { continue }
            let joules = Double(ch.value) * k
            switch ch.name {
            case "GPU Energy": r.gpuJ = (r.gpuJ ?? 0) + joules
            case "CPU Energy": r.cpuJ += joules
            case "DRAM": r.dramJ += joules
            case "ANE": r.aneJ += joules
            default: break  // per-core, SRAM, "GPU" (sparse mJ), SoC blocks: not used
            }
        }
        if sawResidency {
            r.residency = ClusterResidency(pActive: pTotal > 0 ? Double(pActive) / Double(pTotal) : 0,
                                           eActive: eTotal > 0 ? Double(eActive) / Double(eTotal) : 0)
        }
        return r
    }
}

/// Catches the sparse "Energy Model" bursts (ADR 0001 § 4, ADR 0002 `energy_burst`). A burst is the
/// tick in which "CPU Energy" moves; its energy covers the time since the previous burst. The first
/// burst after subscribing is discarded because its window start is unknown.
public struct BurstCatcher: Sendable {
    private var lastBurst: Date?
    private var pendingDRAM = 0.0
    private var pendingANE = 0.0

    public init() {}

    public mutating func observe(_ reading: IOReportReading, at now: Date) -> EnergyBurst? {
        pendingDRAM += reading.dramJ
        pendingANE += reading.aneJ
        guard reading.cpuJ > 0 else { return nil }
        defer {
            lastBurst = now
            pendingDRAM = 0
            pendingANE = 0
        }
        guard let start = lastBurst, now > start else { return nil }
        return EnergyBurst(window: DateInterval(start: start, end: now), cpu_mJ: reading.cpuJ * 1e3,
                           dram_mJ: pendingDRAM * 1e3, ane_mJ: pendingANE * 1e3)
    }
}

/// Live GPU watts and P/E residency each tick, plus the burst catcher. Owns the IOReport
/// subscription; confined to SamplingEngine (CF objects never leave the C handle).
public final class IOReportSampler: ComponentSampling {
    private static let capacity = 512
    private let handle: OpaquePointer
    private let timebase: MachTimebase
    private let now: () -> Date
    private var buffer: [ohm_ior_channel]
    private var bursts = BurstCatcher()

    /// nil when IOReport cannot be loaded or subscribed; `error` gets the `OHM_IOR_ERR_*` stage.
    public init?(timebase: MachTimebase = .current, now: @escaping () -> Date = { Date() },
                 error: UnsafeMutablePointer<Int32>? = nil) {
        var stage: Int32 = 0
        let opened = ohm_ior_open(&stage)
        error?.pointee = stage
        guard let h = opened else {
            Logger(subsystem: "dev.ohm", category: "sampling")
                .error("IOReport unavailable (stage \(stage)); GPU watts and residency disabled")
            return nil
        }
        handle = h
        self.timebase = timebase
        self.now = now
        buffer = [ohm_ior_channel](repeating: ohm_ior_channel(), count: Self.capacity)
    }

    deinit { ohm_ior_close(handle) }

    /// IOReport if available, otherwise `NullComponentSampler` (ADR 0001 § Sonuçlar).
    public static func makeDefault() -> any ComponentSampling {
        IOReportSampler() ?? NullComponentSampler()
    }

    public func sample() -> (gpuWatts: Double?, residency: ClusterResidency?, burst: EnergyBurst?) {
        let reading = readDelta()
        guard let (r, dt) = reading, dt > 0 else { return (nil, nil, nil) }
        let burst = bursts.observe(r, at: now())
        return (r.gpuJ.map { $0 / dt }, r.residency, burst)
    }

    /// Raw decoded delta since the previous call and its length in seconds (also used by the
    /// GPU-overlap measurement).
    public func readDelta() -> (IOReportReading, Double)? {
        var dtAbs: UInt64 = 0
        let n = buffer.withUnsafeMutableBufferPointer {
            ohm_ior_sample(handle, $0.baseAddress, Int32($0.count), &dtAbs)
        }
        guard n >= 0 else { return nil }
        var channels: [IOReportChannel] = []
        channels.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let c = buffer[i]
            channels.append(IOReportChannel(
                group: Self.string(c.group), name: Self.string(c.name), unit: Self.string(c.unit),
                value: c.value, residency: c.is_state != 0 ? (c.active, c.total) : nil))
        }
        return (IOReportDecoder.decode(channels), timebase.seconds(dtAbs))
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Used when IOReport is missing: no GPU watts, no residency, no bursts.
public final class NullComponentSampler: ComponentSampling {
    public init() {}
    public func sample() -> (gpuWatts: Double?, residency: ClusterResidency?, burst: EnergyBurst?) {
        (nil, nil, nil)
    }
}

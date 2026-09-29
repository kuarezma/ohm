import Darwin

/// mach absolute time → nanoseconds. The ratio is 125/3 on M3 (ADR 0001 § 4) and must not be hard-coded.
public struct MachTimebase: Sendable, Equatable {
    public var numer: UInt64
    public var denom: UInt64

    public init(numer: UInt64, denom: UInt64) {
        precondition(denom > 0, "timebase denominator must be positive")
        self.numer = numer
        self.denom = denom
    }

    public static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTimebase(numer: UInt64(info.numer), denom: UInt64(max(info.denom, 1)))
    }()

    /// Overflow-safe for any 64-bit tick count whose result fits in 64 bits.
    public func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let whole = ticks / denom
        let rest = ticks % denom
        return whole &* numer &+ (rest &* numer) / denom
    }

    public func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1e9
    }
}

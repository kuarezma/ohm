import Foundation

public protocol EnergyLedgerWriting: Actor {
    func record(_ tick: SampleTick) async throws
    func flush() async throws
    func maintain(now: Date) async throws
}

public protocol EnergyLedgerReading: AnyObject {
    func receipt(for interval: DateInterval, source: PowerSourceKind?) throws -> Receipt
    func systemSeries(for interval: DateInterval, resolution: LedgerResolution) throws -> [SystemPoint]
}

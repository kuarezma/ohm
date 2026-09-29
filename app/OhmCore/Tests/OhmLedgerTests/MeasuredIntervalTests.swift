import Foundation
import SQLite3
import Testing
@testable import OhmLedger
@testable import OhmModel

/// T-024 #8: each energy value is integrated over its own measured interval; sleep is a gap.
@Suite("OhmLedger measured intervals")
struct MeasuredIntervalTests {
    @Test func gpuUsesItsOwnIntervalAndSleepBecomesGap() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("t021_gap_\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let wall = Date(timeIntervalSince1970: 1_800_000_030)
        let tick = SampleTick(
            wallClock: wall, interval: .seconds(1),
            system: SystemPower(cpuP: 0, cpuE: 0, gpu: 2, gpuInterval: .milliseconds(500)),
            battery: BatteryState(source: .ac, percent: 80, voltage_mV: 12_000, amperage_mA: 0),
            thermal: .nominal, processes: [], unreadable: UnreadableSummary(readableCount: 1, unreadableCount: 0),
            asleep: .seconds(3600))
        let ledger = try EnergyLedger(path: path)
        try await ledger.record(tick)
        try await ledger.flush()

        let receipt = try LedgerReader(path: path).receipt(for: DateInterval(start: wall.addingTimeInterval(-60), duration: 180))
        #expect(receipt.gpu_uj == 1_000_000)   // 2 W × 0.5 s (IOReport's interval), not × the tick interval

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT start_s, end_s, reason FROM sampling_gap", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int64(stmt, 1) - sqlite3_column_int64(stmt, 0) == 3600)
        #expect(sqlite3_column_int64(stmt, 1) == 1_800_000_029)  // sleep ended one awake second before the tick
        #expect(String(cString: sqlite3_column_text(stmt, 2)) == "sleep")
    }
}

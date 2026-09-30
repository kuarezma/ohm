import Foundation
import SQLite3
import Testing
@testable import OhmLedger
@testable import OhmModel

@Suite("OhmLedger T-027 correctness")
struct LedgerCorrectnessTests {
    private let app = AppKey(kind: .bundleID, value: "test.app")
    private func path() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("t027-\(UUID()).sqlite").path
    }
    private func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    private func scalar(_ path: String, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw LedgerError.closed }
        defer { sqlite3_close(db) }
        let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
        defer { SQLiteBridge.finalize(stmt: stmt) }
        _ = try SQLiteBridge.step(stmt: stmt, db: db)
        return SQLiteBridge.columnInt64(stmt: stmt, index: 0)
    }
    private func tick(end: Double, seconds: Int = 10, energy: UInt64 = 10_000_000_000,
                      systemSource: SystemEnergySource = .systemLoad, burst: EnergyBurst? = nil,
                      gpu: Double? = nil, gpuInterval: Duration? = nil) -> SampleTick {
        SampleTick(wallClock: Date(timeIntervalSince1970: end), interval: .seconds(seconds),
                   system: SystemPower(cpuP: 0, cpuE: 0, gpu: gpu, systemLoad: 2,
                                       systemSource: systemSource, gpuInterval: gpuInterval), burst: burst,
                   battery: BatteryState(source: .battery, percent: 80, voltage_mV: 12_000, amperage_mA: -100),
                   thermal: .nominal,
                   processes: [ProcessDelta(identity: ProcessIdentity(pid: 1, startAbsTime: 1), app: app,
                                            energy_nJ: energy, pEnergy_nJ: energy / 2, cpuTime_ns: 1_000_000_000)],
                   unreadable: UnreadableSummary(readableCount: 1, unreadableCount: 1))
    }
    private func minute(_ ledger: EnergyLedger, _ minute: Int64, coverage: Int = 60_000,
                        energy: Int64 = 60_000_000, source: PowerSourceKind = .battery) async throws {
        try await ledger.recordRawSystemMinute(t_min: minute, source: source, covered_ms: coverage,
            sysload_uj: energy, sysload_cov_ms: coverage, attributed_uj: energy / 2,
            voltage_mv: 12_000, fcc_mah: 5000)
        try await ledger.recordRawSlice(t_min: minute, app: app, displayName: "Test", source: source, energy_uj: energy / 2)
    }

    // #10: tail five seconds belong to the new day; integers and coverage are conserved.
    @Test func minuteBoundaryAndMidnight() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 86_405))
        try await ledger.flush()
        let reader = try LedgerReader(path: p)
        let before = try reader.receipt(for: DateInterval(start: Date(timeIntervalSince1970: 86_340), duration: 60))
        let after = try reader.receipt(for: DateInterval(start: Date(timeIntervalSince1970: 86_400), duration: 60))
        #expect(before.rows.first?.energy_uj == 5_000_000)
        #expect(after.rows.first?.energy_uj == 5_000_000)
        #expect(try scalar(p, "SELECT covered_ms FROM system_1m WHERE t_min=1439") == 5000)
        #expect(try scalar(p, "SELECT SUM(covered_ms) FROM system_1m") == 10_000)
        #expect(before.measuredSystemEnergy_uj == 10_000_000)
        #expect(after.measuredSystemEnergy_uj == 10_000_000)
    }
    // #11: hours skipped during downtime must roll up before pruning, even without slices.
    @Test func rollupResumesAfterDowntime() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await minute(ledger, 6000)
        try await ledger.recordRawSystemMinute(t_min: 6060, source: .ac, covered_ms: 60_000,
                                              sysload_uj: 90_000_000, sysload_cov_ms: 60_000)
        try await ledger.maintain(now: Date(timeIntervalSince1970: 160 * 3600))
        #expect(try scalar(p, "SELECT energy_uj FROM slice_1h WHERE t_hour=100") == 30_000_000)
        #expect(try scalar(p, "SELECT sys_uj FROM system_1h WHERE t_hour=101") == 90_000_000)
        #expect(try scalar(p, "SELECT COUNT(*) FROM slice_1m") == 0)
        try await ledger.maintain(now: Date(timeIntervalSince1970: 161 * 3600))
        #expect(try scalar(p, "SELECT SUM(energy_uj) FROM slice_1h") == 30_000_000)
    }
    // #12: overlapping rollups are not counted twice; older hours feed the seven-day reference.
    @Test func receiptAndReferenceMergeHoursAndMinutes() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        for m in 6000..<6060 { try await minute(ledger, Int64(m)) }
        try await ledger.maintain(now: Date(timeIntervalSince1970: 160 * 3600))
        try await minute(ledger, 9599)
        try await ledger.maintain(now: Date(timeIntervalSince1970: 160 * 3600))
        let reader = try LedgerReader(path: p)
        let receipt = try reader.receipt(for: DateInterval(start: Date(timeIntervalSince1970: 100 * 3600), end: Date(timeIntervalSince1970: 160 * 3600)))
        #expect(receipt.rows.first?.energy_uj == 1_830_000_000)
        #expect(receipt.measuredSystemEnergy_uj == 3_660_000_000)
        #expect(receipt.pRefWatts == 1)
        #expect(receipt.eFullJoules == 216_000)
    }
    // #13: AC must not inflate battery minutes or percentages in an unfiltered receipt.
    @Test func mixedReceiptAndReferenceThresholds() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let base = Int64(day.timeIntervalSince1970 / 60) + 20
        for m in base..<(base + 10) { try await minute(ledger, m) }
        try await minute(ledger, base + 10, energy: 7_200_000_000, source: .ac)
        let reader = try LedgerReader(path: p)
        let interval = DateInterval(start: day, end: day.addingTimeInterval(3600))
        let receipt = try reader.receipt(for: interval)
        #expect(receipt.pRefWatts == 1)
        #expect(receipt.rows.first?.batteryMinutes == 5)
        #expect(receipt.rows.first?.chargingWh == 1)
        #expect(abs((receipt.rows.first?.batteryPercent ?? -1) - 100 * 300.0 / 216_000) < 1e-9)
        let q = path(); defer { remove(q) }
        let short = try EnergyLedger(path: q)
        try await minute(short, base)
        let insufficient = try LedgerReader(path: q).receipt(for: interval)
        #expect(insufficient.pRefWatts == nil)
        #expect(insufficient.rows.first?.batteryMinutes == nil)
        #expect(insufficient.rows.first?.batteryPercent != nil)
    }
    // #14: Sampling's V×I fallback must preserve its provenance.
    @Test func voltageCurrentFallbackIdentity() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 86_430, systemSource: .batteryVI))
        try await ledger.flush()
        #expect(try scalar(p, "SELECT sys_src FROM system_1m") == 1)
        #expect(try scalar(p, "SELECT sysload_cov_ms FROM system_1m") == 0)
        #expect(try scalar(p, "SELECT sys_uj FROM system_1m") == 20_000_000)
    }
    // #15: subtract readable CPU over the exact burst window; missing CPU is not zero.
    @Test func burstUsesReadableWindowAndMissingCPUIsUnknown() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 110))
        try await ledger.record(tick(end: 120, burst: EnergyBurst(window: DateInterval(start: Date(timeIntervalSince1970: 100), duration: 20), cpu_mJ: 30_000)))
        try await ledger.flush()
        #expect(try scalar(p, "SELECT readable_cpu_uj FROM energy_burst") == 20_000_000)
        let receipt = try LedgerReader(path: p).receipt(for: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 120))
        #expect(receipt.unreadableSystem_uj == 10_000_000)
        let q = path(); defer { remove(q) }
        let unknown = try EnergyLedger(path: q)
        try await minute(unknown, 1)
        try await unknown.recordEnergyBurst(start_s: 60, end_s: 120, cpu_uj: nil, dram_uj: 1_000_000,
                                          ane_uj: nil, readable_cpu_uj: 0, covered_ms: 60_000)
        let missing = try LedgerReader(path: q).receipt(for: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 60))
        #expect(!missing.isUnreadableEstimated)
    }
    // #16: backup failure leaves the original DB and sidecars untouched.
    @Test func backupFailurePreservesSidecars() async throws {
        let p = path(); defer { remove(p) }
        let now = Date(timeIntervalSince1970: 1000)
        let ledger = try EnergyLedger(path: p)
        try await ledger.executeRawSQLForTesting("PRAGMA user_version=99;")
        let backup = p + ".v99.1000.bak"
        try FileManager.default.createDirectory(atPath: backup, withIntermediateDirectories: false)
        try Data([1]).write(to: URL(fileURLWithPath: backup + "/occupied"))
        defer { try? FileManager.default.removeItem(atPath: backup) }
        let wal = Data([2, 3, 4]); let shm = Data([5, 6])
        // Invalid DB header avoids SQLite consuming our synthetic sidecars during the probe.
        let corrupt = path(); defer { remove(corrupt) }
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: corrupt))
        try wal.write(to: URL(fileURLWithPath: corrupt + "-wal"))
        try shm.write(to: URL(fileURLWithPath: corrupt + "-shm"))
        let blocked = corrupt + ".corrupt.1000.bak"
        try FileManager.default.createDirectory(atPath: blocked, withIntermediateDirectories: false)
        try Data([1]).write(to: URL(fileURLWithPath: blocked + "/occupied"))
        defer { try? FileManager.default.removeItem(atPath: blocked) }
        #expect(throws: (any Error).self) { _ = try EnergyLedger(path: corrupt, clock: { now }) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: corrupt + "-wal")) == wal)
        #expect(try Data(contentsOf: URL(fileURLWithPath: corrupt + "-shm")) == shm)
        #expect(throws: (any Error).self) { _ = try EnergyLedger(path: p, clock: { now }) }
    }
    // #18: GPU is a separate conserved total under the T-021 measured decision.
    @Test func gpuIsSeparateFromOther() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.recordRawSystemMinute(t_min: 1, source: .battery, covered_ms: 60_000,
            sysload_uj: 100_000_000, sysload_cov_ms: 60_000, gpu_uj: 20_000_000, attributed_uj: 30_000_000)
        let receipt = try LedgerReader(path: p).receipt(for: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 60))
        #expect(receipt.other_uj == 50_000_000)
        #expect(receipt.attributedCoveredEnergy_uj + receipt.other_uj + receipt.gpu_uj == receipt.measuredSystemEnergy_uj)
    }
    @Test func retentionSeamConservesEveryColumn() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await minute(ledger, 6005)
        try await minute(ledger, 6035, energy: 120_000_000)
        try await ledger.maintain(now: Date(timeIntervalSince1970: 101 * 3600))
        try await ledger.maintain(now: Date(timeIntervalSince1970: (6006 + 2880) * 60))
        #expect(try scalar(p, "SELECT COUNT(*) FROM system_1m") == 1)
        let interval = DateInterval(start: Date(timeIntervalSince1970: 6000 * 60), duration: 3600)
        let receipt = try LedgerReader(path: p).receipt(for: interval)
        #expect(receipt.rows.first?.energy_uj == 90_000_000)
        #expect(receipt.measuredSystemEnergy_uj == 180_000_000)
        #expect(receipt.attributedCoveredEnergy_uj == 90_000_000)
        try await ledger.maintain(now: Date(timeIntervalSince1970: (6007 + 2880) * 60))
        let again = try LedgerReader(path: p).receipt(for: interval)
        #expect(again.measuredSystemEnergy_uj == receipt.measuredSystemEnergy_uj)
        #expect(again.rows.first?.energy_uj == receipt.rows.first?.energy_uj)
    }

    @Test func separateGPUWindowAndIntegerRemainders() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 86_402, seconds: 5, energy: 10_000_001_000,
                                    gpu: 2, gpuInterval: .seconds(10)))
        try await ledger.flush()
        #expect(try scalar(p, "SELECT energy_uj FROM slice_1m WHERE t_min=1439") == 6_000_001)
        #expect(try scalar(p, "SELECT energy_uj FROM slice_1m WHERE t_min=1440") == 4_000_000)
        #expect(try scalar(p, "SELECT SUM(energy_uj) FROM slice_1m") == 10_000_001)
        #expect(try scalar(p, "SELECT SUM(penergy_uj) FROM slice_1m") == 5_000_000)
        #expect(try scalar(p, "SELECT SUM(cpu_ms) FROM slice_1m") == 1000)
        #expect(try scalar(p, "SELECT gpu_uj FROM system_1m WHERE t_min=1439") == 16_000_000)
        #expect(try scalar(p, "SELECT gpu_uj FROM system_1m WHERE t_min=1440") == 4_000_000)
    }

    @Test func mixedSystemSourcesKeepEffectiveCoverageAcrossFlushes() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 86_420))
        try await ledger.flush()
        try await ledger.record(tick(end: 86_430, systemSource: .batteryVI))
        try await ledger.flush()
        #expect(try scalar(p, "SELECT sys_src FROM system_1m") == 0)
        #expect(try scalar(p, "SELECT sys_vi_ms FROM system_1m") == 10_000)
        #expect(try scalar(p, "SELECT sys_cov_ms FROM system_1m") == 20_000)
        #expect(try scalar(p, "SELECT sys_uj FROM system_1m") == 40_000_000)
        try await ledger.maintain(now: Date(timeIntervalSince1970: 25 * 3600))
        #expect(try scalar(p, "SELECT sys_vi_ms FROM system_1h") == 10_000)
    }

    @Test func burstClipsProcessWindowsAndExcludesKnownSleep() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 110))
        var next = tick(end: 130, burst: EnergyBurst(window: DateInterval(start: Date(timeIntervalSince1970: 105), duration: 25), cpu_mJ: 25_000))
        next.asleep = .seconds(10)
        try await ledger.record(next)
        #expect(try scalar(p, "SELECT readable_cpu_uj FROM energy_burst") == 15_000_000)
        #expect(try scalar(p, "SELECT covered_ms FROM energy_burst") == 15_000)
        #expect(try scalar(p, "SELECT readable_cpu_valid FROM energy_burst") == 1)
        let q = path(); defer { remove(q) }
        let incomplete = try EnergyLedger(path: q)
        try await incomplete.record(tick(end: 130, burst: EnergyBurst(window: DateInterval(start: Date(timeIntervalSince1970: 100), duration: 30), cpu_mJ: 25_000)))
        #expect(try scalar(q, "SELECT readable_cpu_valid FROM energy_burst") == 0)
        try await incomplete.flush()
        let receipt = try LedgerReader(path: q).receipt(for: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 120))
        #expect(!receipt.isUnreadableEstimated)
    }

    @Test func migrationPreservesV1AndInvalidatesLegacyBursts() async throws {
        let p = path(); defer { remove(p) }
        var db: OpaquePointer?
        guard sqlite3_open(p, &db) == SQLITE_OK else { throw LedgerError.closed }
        try SQLiteBridge.exec(db: db, sql: SchemaManager.schemaV1)
        try SQLiteBridge.exec(db: db, sql: """
            INSERT INTO meta VALUES ('reader_compat', '1'), ('rolled_through_hour', '0');
            INSERT INTO energy_burst VALUES (60,120,10000000,NULL,NULL,0,60000);
            INSERT INTO system_1m (t_min,source,covered_ms,batt_vi_uj,batt_vi_cov_ms,sys_src,sys_uj,
              sys_cov_ms,attributed_uj,tail_uj,readable_count,unreadable_count)
              VALUES (2,1,10000,12000000,10000,1,12000000,10000,0,0,1,1);
            PRAGMA user_version=1;
            """)
        sqlite3_close(db)
        let ledger = try EnergyLedger(path: p)
        #expect(try await ledger.userVersion() == 2)
        #expect(try scalar(p, "SELECT cpu_uj FROM energy_burst") == 10_000_000)
        #expect(try scalar(p, "SELECT readable_cpu_valid FROM energy_burst") == 0)
        #expect(try scalar(p, "SELECT sys_vi_ms FROM system_1m WHERE t_min=2") == 10000)
        try await minute(ledger, 1)
        let receipt = try LedgerReader(path: p).receipt(for: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 60))
        #expect(!receipt.isUnreadableEstimated)
    }

    @Test func backupCopiesSidecarsAndRollsBackPartialCopy() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        for failedSuffix in [nil, "-wal", "-shm"] as [String?] {
            let p = path(); defer { remove(p) }
            let main = Data("corrupt".utf8), wal = Data([2, 3, 4]), shm = Data([5, 6])
            try main.write(to: URL(fileURLWithPath: p))
            try wal.write(to: URL(fileURLWithPath: p + "-wal"))
            try shm.write(to: URL(fileURLWithPath: p + "-shm"))
            let backup = p + ".corrupt.1000.bak"
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: backup + suffix) } }
            if let failedSuffix {
                try FileManager.default.createDirectory(atPath: backup + failedSuffix, withIntermediateDirectories: false)
                try Data([1]).write(to: URL(fileURLWithPath: backup + failedSuffix + "/occupied"))
                #expect(throws: (any Error).self) { _ = try EnergyLedger(path: p, clock: { now }) }
                #expect(try Data(contentsOf: URL(fileURLWithPath: p)) == main)
                #expect(try Data(contentsOf: URL(fileURLWithPath: p + "-wal")) == wal)
                #expect(try Data(contentsOf: URL(fileURLWithPath: p + "-shm")) == shm)
                #expect(!FileManager.default.fileExists(atPath: backup))
            } else {
                let ledger = try EnergyLedger(path: p, clock: { now })
                #expect(try await ledger.userVersion() == 2)
                #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == main)
                #expect(try Data(contentsOf: URL(fileURLWithPath: backup + "-wal")) == wal)
                #expect(try Data(contentsOf: URL(fileURLWithPath: backup + "-shm")) == shm)
            }
        }
    }

    @Test func gpuOverAttributionIsDisclosedAndReferenceHasUpperBound() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.recordRawSystemMinute(t_min: 1, source: .battery, covered_ms: 60_000,
            sysload_uj: 100_000_000, sysload_cov_ms: 60_000, gpu_uj: 74_000_000, attributed_uj: 30_000_000)
        for m in 10..<70 { try await minute(ledger, Int64(m), energy: 600_000_000) }
        let receipt = try LedgerReader(path: p).receipt(for: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 60))
        #expect(receipt.discrepancyStatus == .withinToleranceOverAttribution)
        #expect(receipt.other_uj == 0)
        #expect(receipt.pRefWatts == nil) // Future data cannot satisfy this earlier receipt's threshold.
        #expect(receipt.residualSigned_uj - receipt.gpu_uj == -4_000_000)
    }

    @Test func futureDatabaseWALBackupRetainsCommittedRows() async throws {
        let p = path(); defer { remove(p) }
        let now = Date(timeIntervalSince1970: 1000)
        let oldWriter = try EnergyLedger(path: p)
        defer { withExtendedLifetime(oldWriter) {} }
        try await minute(oldWriter, 1)
        try await oldWriter.executeRawSQLForTesting("PRAGMA user_version=99;")
        #expect(FileManager.default.fileExists(atPath: p + "-wal"))
        let backup = p + ".v99.1000.bak"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: backup + suffix) } }
        let replacement = try EnergyLedger(path: p, clock: { now })
        #expect(try await replacement.userVersion() == 2)
        #expect(try scalar(p, "SELECT COUNT(*) FROM slice_1m") == 0)
        #expect(FileManager.default.fileExists(atPath: backup + "-wal"))
        #expect(FileManager.default.fileExists(atPath: backup + "-shm"))
        #expect(try scalar(backup, "SELECT SUM(energy_uj) FROM slice_1m") == 30_000_000)
    }

    @Test func measuredAttributionUsesTheSameTickParts() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        let known = SampleTick(wallClock: Date(timeIntervalSince1970: 90), interval: .seconds(10),
            system: SystemPower(cpuP: 0, cpuE: 0, systemLoad: 2, systemSource: .systemLoad),
            battery: BatteryState(source: .ac, percent: 80, voltage_mV: 12000, amperage_mA: 0),
            thermal: .nominal,
            processes: [ProcessDelta(identity: ProcessIdentity(pid: 1, startAbsTime: 1), app: app, energy_nJ: 10_000_000_000, pEnergy_nJ: 0, cpuTime_ns: 0)],
            unreadable: UnreadableSummary(readableCount: 1, unreadableCount: 0))
        let unknown = SampleTick(wallClock: Date(timeIntervalSince1970: 100), interval: .seconds(10),
            system: SystemPower(cpuP: 0, cpuE: 0),
            battery: known.battery, thermal: .nominal,
            processes: [ProcessDelta(identity: ProcessIdentity(pid: 1, startAbsTime: 1), app: app, energy_nJ: 30_000_000_000, pEnergy_nJ: 0, cpuTime_ns: 0)],
            unreadable: known.unreadable)
        try await ledger.record(known)
        try await ledger.record(unknown)
        try await ledger.flush()
        #expect(try scalar(p, "SELECT att_cov_uj FROM system_1m") == 10_000_000)
        #expect(try scalar(p, "SELECT attributed_uj FROM system_1m") == 40_000_000)
    }

    @Test func retentionSeamDoesNotLeakOldEnergyIntoRecentInterval() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await minute(ledger, 6005)
        try await minute(ledger, 6035, energy: 120_000_000)
        try await ledger.maintain(now: Date(timeIntervalSince1970: (6006 + 2880) * 60))
        let receipt = try LedgerReader(path: p).receipt(for: DateInterval(
            start: Date(timeIntervalSince1970: 6035 * 60), duration: 60))
        #expect(receipt.rows.first?.energy_uj == 60_000_000)
        #expect(receipt.measuredSystemEnergy_uj == 120_000_000)
    }

    @Test func longIntervalSplitsAcrossEveryMinute() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        try await ledger.record(tick(end: 180, seconds: 125, energy: 125_000_001_000))
        try await ledger.flush()
        #expect(try scalar(p, "SELECT COUNT(*) FROM system_1m") == 3)
        #expect(try scalar(p, "SELECT SUM(covered_ms) FROM system_1m") == 125000)
        #expect(try scalar(p, "SELECT SUM(sys_cov_ms) FROM system_1m") == 125000)
        #expect(try scalar(p, "SELECT SUM(energy_uj) FROM slice_1m") == 125000001)
        #expect(try scalar(p, "SELECT SUM(att_cov_uj) FROM system_1m") == 125000001)
        #expect(try scalar(p, "SELECT SUM(sys_uj) FROM system_1m") == 250000000)
    }

    @Test func referenceRejectsFiftyNineHistoricalMinutesButAcceptsSixty() async throws {
        let p = path(); defer { remove(p) }
        let ledger = try EnergyLedger(path: p)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let base = Int64(day.timeIntervalSince1970 / 60) - 120
        for m in base..<(base + 59) { try await minute(ledger, m) }
        let interval = DateInterval(start: day, duration: 3600)
        #expect(try LedgerReader(path: p).receipt(for: interval).pRefWatts == nil)
        try await minute(ledger, base + 59)
        #expect(try LedgerReader(path: p).receipt(for: interval).pRefWatts == 1)
    }

}

import Foundation
import Testing
@testable import OhmModel
@testable import OhmLedger

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ date: Date) {
        self._now = date
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _now = newValue
        }
    }
}

@Suite("OhmLedger Tests")
struct OhmLedgerTests {

    private func createTempDatabasePath(prefix: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString).sqlite")
            .path
    }

    // 1. Schema creation + migration from empty; PRAGMA user_version equals the ADR's version; reader_compat behavior as specified.
    @Test func testSchemaCreationAndReaderCompat() async throws {
        let path = createTempDatabasePath(prefix: "test1")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        // Schema creation from empty
        let ledger = try EnergyLedger(path: path)
        let version = try await ledger.userVersion()
        #expect(version == 1, "PRAGMA user_version must equal 1 per ADR 0002 §3")

        // Reader compat: reader with current version opens normally
        let reader = try LedgerReader(path: path)
        let initialReceipt = try reader.receipt(for: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600))
        #expect(initialReceipt.rows.isEmpty)

        // Reader compat: when reader_compat > reader version, throw incompatibleReader
        try await ledger.executeRawSQLForTesting("UPDATE meta SET value = '99' WHERE key = 'reader_compat';")
        #expect(throws: LedgerError.self) {
            _ = try LedgerReader(path: path)
        }

        // Reader handles empty database (user_version == 0) gracefully
        let emptyPath = createTempDatabasePath(prefix: "test1_empty")
        defer { try? FileManager.default.removeItem(atPath: emptyPath) }
        FileManager.default.createFile(atPath: emptyPath, contents: Data())
        let emptyReader = try LedgerReader(path: emptyPath)
        let emptyReceipt = try emptyReader.receipt(for: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600))
        #expect(emptyReceipt.rows.isEmpty)
    }

    // 2. UPSERT of per-minute slices and hourly rollup; retention (48 h minute slices, 90 days hourly) — use injected clock.
    @Test func testUpsertRollupAndRetention() async throws {
        let path = createTempDatabasePath(prefix: "test2")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        let testClock = TestClock(Date(timeIntervalSince1970: 3600.0 * 200.0))
        let ledger = try EnergyLedger(path: path, clock: { testClock.now })

        // UPSERT of per-minute slices
        let t_min: Int64 = 1000
        let safariKey = AppKey(kind: .bundleID, value: "com.apple.Safari")

        // First write: 10 J
        try await ledger.recordRawSlice(
            t_min: t_min,
            app: safariKey,
            displayName: "Safari",
            category: .userApp,
            source: .battery,
            energy_uj: 10_000_000,
            penergy_uj: 8_000_000,
            cpu_ms: 500
        )
        // Second write in same minute: 15 J (should UPSERT to 25 J)
        try await ledger.recordRawSlice(
            t_min: t_min,
            app: safariKey,
            displayName: "Safari",
            category: .userApp,
            source: .battery,
            energy_uj: 15_000_000,
            penergy_uj: 12_000_000,
            cpu_ms: 300
        )
        try await ledger.flush()

        let reader = try LedgerReader(path: path)
        let interval1m = DateInterval(
            start: Date(timeIntervalSince1970: Double(t_min * 60)),
            duration: 60
        )
        let receipt1m = try reader.receipt(for: interval1m, source: .battery)
        #expect(receipt1m.rows.count == 1)
        #expect(receipt1m.rows.first?.energy_uj == 25_000_000)
        #expect(receipt1m.rows.first?.pEnergy_uj == 20_000_000)
        #expect(receipt1m.rows.first?.cpuTime_ms == 800)

        // Hourly rollup
        let hour: Int64 = 100
        let min1 = hour * 60 + 5
        let min2 = hour * 60 + 35
        try await ledger.recordRawSlice(
            t_min: min1,
            app: safariKey,
            displayName: "Safari",
            category: .userApp,
            source: .battery,
            energy_uj: 5_000_000,
            penergy_uj: 4_000_000,
            cpu_ms: 200
        )
        try await ledger.recordRawSlice(
            t_min: min2,
            app: safariKey,
            displayName: "Safari",
            category: .userApp,
            source: .battery,
            energy_uj: 7_000_000,
            penergy_uj: 6_000_000,
            cpu_ms: 400
        )
        try await ledger.recordRawSystemMinute(
            t_min: min1,
            source: .battery,
            covered_ms: 60_000,
            sysload_uj: 50_000_000,
            sysload_cov_ms: 60_000,
            attributed_uj: 5_000_000
        )
        try await ledger.recordRawSystemMinute(
            t_min: min2,
            source: .battery,
            covered_ms: 60_000,
            sysload_uj: 70_000_000,
            sysload_cov_ms: 60_000,
            attributed_uj: 7_000_000
        )
        try await ledger.flush()

        // Advance clock to hour + 1 and maintain
        testClock.now = Date(timeIntervalSince1970: Double((hour + 1) * 3600 + 300))
        try await ledger.maintain(now: testClock.now)

        let hourInterval = DateInterval(
            start: Date(timeIntervalSince1970: Double(hour * 3600)),
            duration: 3600
        )
        let series = try reader.systemSeries(for: hourInterval, resolution: .hour)
        #expect(series.count == 1)
        #expect(series.first?.systemEnergy_uj == 120_000_000)
        #expect(series.first?.coveredMs == 120_000)

        // Retention: 48 h (2880 min) for minute slices, 90 days (2160 hours) for hourly
        // Set simulated clock 50 hours ahead of min1 (min1 should be pruned)
        let retentionClock48h = Date(timeIntervalSince1970: Double((min1 + 2881) * 60))
        try await ledger.maintain(now: retentionClock48h)
        let seriesAfter48h = try reader.systemSeries(
            for: DateInterval(start: Date(timeIntervalSince1970: Double(min1 * 60)), duration: 60),
            resolution: .minute
        )
        #expect(seriesAfter48h.isEmpty, "Minute slices older than 48 hours must be pruned")

        // Set simulated clock 91 days ahead of hour (hour should be pruned)
        let retentionClock90d = Date(timeIntervalSince1970: Double((hour + 2161) * 3600))
        try await ledger.maintain(now: retentionClock90d)
        let seriesAfter90d = try reader.systemSeries(for: hourInterval, resolution: .hour)
        #expect(seriesAfter90d.isEmpty, "Hourly slices older than 90 days must be pruned")
    }

    // 3. P_ref unit test exactly as in ADR 0002 § 5: sys_uj = 60 000 000, sys_cov_ms = 60 000 → P_ref = 1 W; with E_app = 30 J → battery minutes = 0.5.
    @Test func testPRefAndBatteryMinutesExact() async throws {
        // Direct formula verification
        let sysUj: Int64 = 60_000_000
        let sysCovMs: Int64 = 60_000
        let pRef = PRefCalculator.calculatePRef(sys_uj: sysUj, sys_cov_ms: sysCovMs)
        #expect(pRef != nil)
        #expect(pRef == 1.0, "sys_uj = 60 000 000, sys_cov_ms = 60 000 must result in P_ref = 1.0 W")

        let eAppUj: Int64 = 30_000_000 // 30 J
        let batteryMinutes = PRefCalculator.calculateBatteryMinutes(energy_uj: eAppUj, pRef: pRef!)
        #expect(batteryMinutes != nil)
        #expect(batteryMinutes == 0.5, "E_app = 30 J with P_ref = 1.0 W must result in 0.5 battery minutes")

        // End-to-end receipt integration verification
        let path = createTempDatabasePath(prefix: "test3")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        let ledger = try EnergyLedger(path: path)
        let t_min: Int64 = 500
        let appKey = AppKey(kind: .bundleID, value: "com.example.App")

        try await ledger.recordRawSystemMinute(
            t_min: t_min,
            source: .battery,
            covered_ms: 60_000,
            sysload_uj: 60_000_000,
            sysload_cov_ms: 60_000,
            attributed_uj: 30_000_000
        )
        try await ledger.recordRawSlice(
            t_min: t_min,
            app: appKey,
            displayName: "App",
            category: .userApp,
            source: .battery,
            energy_uj: 30_000_000
        )
        try await ledger.flush()

        let reader = try LedgerReader(path: path)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: Double(t_min * 60)),
            duration: 60
        )
        let receipt = try reader.receipt(for: interval, source: .battery)
        #expect(receipt.pRefWatts == 1.0)
        #expect(receipt.rows.count == 1)
        #expect(receipt.rows.first?.batteryMinutes == 0.5)
    }

    // 4. "Other" residual and signed discrepancy (residual_uj / residualSigned_uj) including the over-attribution case (104 J attributed vs 100 J measured → Other 0, signed −4 J, flagged).
    @Test func testOtherResidualAndSignedDiscrepancy() async throws {
        let path = createTempDatabasePath(prefix: "test4")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        let ledger = try EnergyLedger(path: path)
        let t_min: Int64 = 600

        // Over-attribution case: 104 J attributed vs 100 J measured
        let measuredSysUj: Int64 = 100_000_000 // 100 J
        let attributedUj: Int64 = 104_000_000  // 104 J
        let appKey = AppKey(kind: .executableName, value: "heavy_task")

        try await ledger.recordRawSystemMinute(
            t_min: t_min,
            source: .battery,
            covered_ms: 60_000,
            sysload_uj: measuredSysUj,
            sysload_cov_ms: 60_000,
            attributed_uj: attributedUj
        )
        try await ledger.recordRawSlice(
            t_min: t_min,
            app: appKey,
            displayName: "heavy_task",
            category: .userApp,
            source: .battery,
            energy_uj: attributedUj
        )
        try await ledger.flush()

        let reader = try LedgerReader(path: path)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: Double(t_min * 60)),
            duration: 60
        )
        let receipt = try reader.receipt(for: interval, source: .battery)

        #expect(receipt.residualSigned_uj == -4_000_000, "Signed discrepancy must be -4 J (-4 000 000 µJ)")
        #expect(Double(receipt.residualSigned_uj) / 1e6 == -4.0)
        #expect(receipt.residual_uj == -4_000_000)
        #expect(receipt.other_uj == 0, "Other must be 0 in over-attribution case")
        #expect(receipt.isOverAttributed == true)
        #expect(receipt.isFlagged == true)
        #expect(receipt.discrepancyStatus == .withinToleranceOverAttribution)

        // Normal conservation check: 100 J measured vs 70 J attributed
        let t_min_normal: Int64 = 601
        try await ledger.recordRawSystemMinute(
            t_min: t_min_normal,
            source: .battery,
            covered_ms: 60_000,
            sysload_uj: 100_000_000,
            sysload_cov_ms: 60_000,
            attributed_uj: 70_000_000
        )
        try await ledger.recordRawSlice(
            t_min: t_min_normal,
            app: appKey,
            displayName: "heavy_task",
            category: .userApp,
            source: .battery,
            energy_uj: 70_000_000
        )
        try await ledger.flush()

        let intervalNormal = DateInterval(
            start: Date(timeIntervalSince1970: Double(t_min_normal * 60)),
            duration: 60
        )
        let normalReceipt = try reader.receipt(for: intervalNormal, source: .battery)
        #expect(normalReceipt.residualSigned_uj == 30_000_000)
        #expect(normalReceipt.other_uj == 30_000_000)
        #expect(normalReceipt.isOverAttributed == false)
        #expect(normalReceipt.isFlagged == false)
        #expect(normalReceipt.discrepancyStatus == .exactConservation)
    }

    // 5. Receipt query for "today" returns rows sorted by energy with battery minutes and percent; GPU is informational only (not subtracted, not attributed) per the ADR's GPU decision.
    @Test func testReceiptTodayQuerySortedAndGpuInformational() async throws {
        let path = createTempDatabasePath(prefix: "test5")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        let ledger = try EnergyLedger(path: path)
        let now = Date()
        let t_min = Int64(floor(now.timeIntervalSince1970 / 60.0))

        let appA = AppKey(kind: .bundleID, value: "com.apple.Music")
        let appB = AppKey(kind: .bundleID, value: "com.google.Chrome")
        let appC = AppKey(kind: .bundleID, value: "com.mitchellh.ghostty")

        // Chrome: 80 J, Music: 30 J, Ghostty: 50 J
        try await ledger.recordRawSlice(t_min: t_min, app: appA, displayName: "Music", category: .userApp, source: .battery, energy_uj: 30_000_000)
        try await ledger.recordRawSlice(t_min: t_min, app: appB, displayName: "Chrome", category: .userApp, source: .battery, energy_uj: 80_000_000)
        try await ledger.recordRawSlice(t_min: t_min, app: appC, displayName: "Ghostty", category: .userApp, source: .battery, energy_uj: 50_000_000)

        // System: 200 J, GPU: 25 J, Battery: fcc = 5000 mAh, voltage = 12000 mV (E_full = 5000 * 12 * 3.6 = 216 000 J)
        try await ledger.recordRawSystemMinute(
            t_min: t_min,
            source: .battery,
            covered_ms: 60_000,
            sysload_uj: 200_000_000,
            sysload_cov_ms: 60_000,
            gpu_uj: 25_000_000,
            attributed_uj: 160_000_000,
            voltage_mv: 12_000,
            fcc_mah: 5000
        )
        try await ledger.flush()

        let reader = try LedgerReader(path: path)
        let todayInterval = DateInterval(
            start: Calendar.current.startOfDay(for: now),
            end: now
        )
        let receipt = try reader.receipt(for: todayInterval, source: .battery)

        // Rows must be sorted by energy DESC
        #expect(receipt.rows.count == 3)
        #expect(receipt.rows[0].displayName == "Chrome")
        #expect(receipt.rows[0].energy_uj == 80_000_000)
        #expect(receipt.rows[1].displayName == "Ghostty")
        #expect(receipt.rows[1].energy_uj == 50_000_000)
        #expect(receipt.rows[2].displayName == "Music")
        #expect(receipt.rows[2].energy_uj == 30_000_000)

        // Battery minutes and percent must be computed
        // P_ref = 200 J / 60 s = 3.333333... W
        // Chrome (80 J) -> minutes = 80 / (200/60) / 60 = 80 / 200 = 0.4 min
        #expect(receipt.rows[0].batteryMinutes != nil)
        #expect(abs(receipt.rows[0].batteryMinutes! - 0.4) < 0.001)

        // Battery percent = 100 * 80 / 216 000 = 0.037037... %
        #expect(receipt.rows[0].batteryPercent != nil)
        #expect(abs(receipt.rows[0].batteryPercent! - (100.0 * 80.0 / 216_000.0)) < 0.001)

        // GPU decision: informational only (not subtracted, not attributed)
        #expect(receipt.gpu_uj == 25_000_000)
        // Other = 200 J - 160 J = 40 J. It must NOT subtract GPU (25 J)!
        #expect(receipt.other_uj == 40_000_000)
    }

    // 6. LedgerReader opens read-only (writes fail) and sees committed data from the writer (WAL).
    @Test func testLedgerReaderReadOnlyAndWal() async throws {
        let path = createTempDatabasePath(prefix: "test6")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        let ledger = try EnergyLedger(path: path)
        let t_min: Int64 = 800
        let app1 = AppKey(kind: .bundleID, value: "com.apple.dt.Xcode")

        try await ledger.recordRawSlice(
            t_min: t_min,
            app: app1,
            displayName: "Xcode",
            category: .userApp,
            source: .battery,
            energy_uj: 12_000_000
        )
        try await ledger.flush()

        // LedgerReader opens read-only
        let reader = try LedgerReader(path: path)

        // Writes fail on reader
        #expect(throws: LedgerError.self) {
            try reader.assertReadOnly()
        }

        // Reader sees committed data
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: Double(t_min * 60)),
            duration: 120
        )
        var receipt = try reader.receipt(for: interval, source: .battery)
        #expect(receipt.rows.count == 1)
        #expect(receipt.rows.first?.displayName == "Xcode")
        #expect(receipt.rows.first?.energy_uj == 12_000_000)

        // Writer commits more data in WAL mode
        let app2 = AppKey(kind: .bundleID, value: "com.sublimetext.4")
        try await ledger.recordRawSlice(
            t_min: t_min + 1,
            app: app2,
            displayName: "Sublime",
            category: .userApp,
            source: .battery,
            energy_uj: 18_000_000
        )
        try await ledger.flush()

        // Reader sees newly committed WAL data without reopening connection
        receipt = try reader.receipt(for: interval, source: .battery)
        #expect(receipt.rows.count == 2)
        #expect(receipt.rows.contains { $0.displayName == "Sublime" && $0.energy_uj == 18_000_000 })
    }

    // Additional test: SampleTick buffering & flush
    @Test func testSampleTickBufferingAndFlush() async throws {
        let path = createTempDatabasePath(prefix: "test_tick")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }

        let ledger = try EnergyLedger(path: path)
        let now = Date()
        let identity = ProcessIdentity(pid: 1234, startAbs: 5678)
        let appKey = AppKey(kind: .bundleID, value: "com.apple.finder")
        let delta = ProcessDelta(identity: identity, app: appKey, energy_nJ: 5_000_000_000, pEnergy_nJ: 3_000_000_000, cpuTime_ns: 100_000_000)

        let tick = SampleTick(
            wallClock: now,
            interval: .seconds(1),
            system: SystemPower(cpuP: 3.0, cpuE: 1.0, gpu: 0.5, systemLoad: 5.0),
            burst: nil,
            battery: BatteryState(source: .battery, percent: 80, voltage_mV: 11_500, amperage_mA: -1200),
            thermal: .nominal,
            processes: [delta],
            unreadable: UnreadableSummary(readableCount: 150, unreadableCount: 50)
        )

        try await ledger.record(tick)
        try await ledger.flush()

        let reader = try LedgerReader(path: path)
        let interval = DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))
        let receipt = try reader.receipt(for: interval, source: .battery)
        #expect(receipt.rows.count == 1)
        #expect(receipt.rows.first?.displayName == "com.apple.finder")
        #expect(receipt.rows.first?.energy_uj == 5_000_000) // 5 J
    }
}

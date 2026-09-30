import Foundation
import Dispatch
import SQLite3
import OhmModel

public actor EnergyLedger: EnergyLedgerWriting {
    public typealias Clock = @Sendable () -> Date

    public static let currentSchemaVersion = SchemaManager.currentVersion
    public static let currentReaderCompatVersion = SchemaManager.readerCompatVersion

    private let queue = DispatchSerialQueue(label: "dev.ohm.ledger", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var db: OpaquePointer?
    private let path: String
    private let clock: Clock

    // In-memory buffering structure
    private struct BucketKey: Hashable {
        let t_min: Int64
        let source: Int
    }

    private struct AppDeltaAccumulator {
        var displayName: String
        var bundlePath: String?
        var category: AppCategory
        var energyUj: Int64 = 0
        var pEnergyUj: Int64 = 0
        var cpuMs: Int64 = 0
        var lastSeen: Int64 = 0
    }

    private struct MinuteBucket {
        var coveredMs: Int = 0
        var sysloadUj: Int64? = nil
        var sysloadCovMs: Int = 0
        var battViUj: Int64? = nil
        var battViCovMs: Int = 0
        var gpuUj: Int64? = nil
        var effectiveUj: Int64? = nil
        var effectiveCovMs: Int = 0
        var effectiveViMs: Int = 0
        var attributedCoveredUj: Int64 = 0
        var readableCount: Int = 0
        var unreadableCount: Int = 0
        var batteryPct: Int? = nil
        var voltageMv: Int? = nil
        var rawChargeMah: Int? = nil
        var fccMah: Int? = nil
        var thermalMax: Int? = nil
        var appDeltas: [AppKey: AppDeltaAccumulator] = [:]
    }

    private struct ReadableWindow {
        let start: Double
        let end: Double
        let energyUj: Int64
        let isAwake: Bool
    }
    // Bounded history; a burst extending beyond it is explicitly unavailable.
    private var readableWindows: [ReadableWindow] = []

    private var memoryBuckets: [BucketKey: MinuteBucket] = [:]

    public init(path: String = ":memory:", clock: @escaping Clock = { Date() }) throws {
        self.path = path
        self.clock = clock
        self.db = try Self.openAndInitializeDatabase(path: path, clock: clock)
    }

    public init(url: URL, clock: @escaping Clock = { Date() }) throws {
        let p = url.path
        self.path = p
        self.clock = clock
        self.db = try Self.openAndInitializeDatabase(path: p, clock: clock)
    }

    public init(inMemory: Bool = false, clock: @escaping Clock = { Date() }) throws {
        let p = inMemory ? ":memory:" : Self.defaultDatabasePath()
        self.path = p
        self.clock = clock
        self.db = try Self.openAndInitializeDatabase(path: p, clock: clock)
    }

    isolated deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    public static func defaultDatabasePath() -> String {
        let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.ohm")
        if let appGroup = appGroup {
            return appGroup.appendingPathComponent("ledger.sqlite").path
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.ohm")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("ledger.sqlite").path
    }

    private static func openAndInitializeDatabase(path: String, clock: Clock) throws -> OpaquePointer {
        if path != ":memory:" {
            let fileURL = URL(fileURLWithPath: path)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // If file already exists, check integrity & version
            if FileManager.default.fileExists(atPath: path) {
                // Probe a copy: even a read-only WAL connection can alter SHM on close.
                let probeDir = FileManager.default.temporaryDirectory.appendingPathComponent("ohm-probe-\(UUID())")
                try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: probeDir) }
                let probePath = probeDir.appendingPathComponent("ledger.sqlite").path
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                    try FileManager.default.copyItem(atPath: path + suffix, toPath: probePath + suffix)
                }
                var testDb: OpaquePointer?
                let rc = sqlite3_open_v2(probePath, &testDb, SQLITE_OPEN_READONLY, nil)
                if rc == SQLITE_OK, let testDb = testDb {
                    let isClean = (try? SchemaManager.quickCheck(db: testDb)) ?? false
                    let ver = (try? SchemaManager.getUserVersion(db: testDb)) ?? 0
                    sqlite3_close(testDb)

                    if !isClean {
                        try backupAndReset(path: path, reason: "corrupt", clock: clock)
                    } else if ver > SchemaManager.currentVersion {
                        try backupAndReset(path: path, reason: "v\(ver)", clock: clock)
                    }
                } else {
                    if let testDb { sqlite3_close(testDb) }
                    throw LedgerError.sqliteError(code: rc, message: "Veritabanı denetim için açılamadı")
                }
            }
        }

        var newDb: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(path, &newDb, flags, nil)
        guard rc == SQLITE_OK, let validDb = newDb else {
            let msg = newDb != nil ? String(cString: sqlite3_errmsg(newDb)) : "Failed to open sqlite3 database at \(path)"
            if let newDb = newDb { sqlite3_close(newDb) }
            throw LedgerError.sqliteError(code: rc, message: msg)
        }

        do {
            try SchemaManager.applyPragmasWriter(db: validDb)
            try SchemaManager.migrateWriter(db: validDb, now: clock())
            return validDb
        } catch {
            sqlite3_close(validDb)
            throw error
        }
    }

    private static func backupAndReset(path: String, reason: String, clock: Clock) throws {
        guard path != ":memory:" else { return }
        let nowS = Int64(floor(clock().timeIntervalSince1970))
        let bakPath = "\(path).\(reason).\(nowS).bak"
        let manager = FileManager.default
        let suffixes = ["", "-wal", "-shm"].filter { manager.fileExists(atPath: path + $0) }
        var copied: [String] = []
        do {
            for suffix in suffixes {
                try manager.copyItem(atPath: path + suffix, toPath: bakPath + suffix)
                copied.append(suffix)
            }
        } catch {
            for suffix in copied { try? manager.removeItem(atPath: bakPath + suffix) }
            throw error
        }
        // Do not remove any originals until all three backup copies succeed.
        for suffix in suffixes.reversed() { try manager.removeItem(atPath: path + suffix) }
    }

    // MARK: - EnergyLedgerWriting Protocol Implementation

    public func record(_ tick: SampleTick) async throws {
        let durationMs = Self.milliseconds(tick.interval)
        guard durationMs > 0 else { return }
        let endMs = Int64((tick.wallClock.timeIntervalSince1970 * 1000).rounded())
        let startMs = endMs - durationMs
        let source = tick.battery.source.sqliteValue
        let parts = Self.minuteParts(startMs: startMs, endMs: endMs)
        for part in parts {
            let key = BucketKey(t_min: part.minute, source: source)
            var bucket = memoryBuckets[key] ?? MinuteBucket()
            let ms = Int(part.end - part.start)
            bucket.coveredMs = min(60_000, bucket.coveredMs + ms)
            let measuredCoverage: Int64
            if let coverage = tick.system.effectiveCoverage {
                // Coalesced energy and coverage are independent; never infer them from latest battery.
                measuredCoverage = Self.milliseconds(coverage)
                func energyPart(_ joules: Double?) -> Int64? {
                    joules.map { Self.portion(Int64(($0 * 1_000_000).rounded()), part: part,
                                             start: startMs, duration: durationMs) }
                }
                func coveragePart(_ duration: Duration?) -> Int {
                    Int(Self.portion(Self.milliseconds(duration ?? .zero), part: part,
                                     start: startMs, duration: durationMs))
                }
                if let energy = energyPart(tick.system.systemLoadEnergyJ) {
                    bucket.sysloadUj = (bucket.sysloadUj ?? 0) + energy
                }
                bucket.sysloadCovMs += coveragePart(tick.system.systemLoadCoverage)
                if let energy = energyPart(tick.system.batteryVIEnergyJ) {
                    bucket.battViUj = (bucket.battViUj ?? 0) + energy
                }
                bucket.battViCovMs += coveragePart(tick.system.batteryVICoverage)
                if let energy = energyPart(tick.system.effectiveEnergyJ) {
                    bucket.effectiveUj = (bucket.effectiveUj ?? 0) + energy
                }
                bucket.effectiveCovMs += coveragePart(coverage)
                bucket.effectiveViMs += coveragePart(tick.system.effectiveVICoverage)
            } else {
                let measuredLoad = tick.system.systemSource == .systemLoad ? tick.system.systemLoad : nil
                let load = measuredLoad ?? tick.battery.systemLoad_mW.map { Double($0) / 1000 }
                if let load {
                    let energy = Self.portion(Int64(load * Double(durationMs) * 1000), part: part, start: startMs, duration: durationMs)
                    bucket.sysloadUj = (bucket.sysloadUj ?? 0) + energy
                    bucket.sysloadCovMs += ms
                    bucket.effectiveUj = (bucket.effectiveUj ?? 0) + energy
                    bucket.effectiveCovMs += ms
                }
                let discharging = tick.battery.source == .battery && !tick.battery.isCharging
                if discharging {
                    let vi = tick.system.systemSource == .batteryVI ? tick.system.systemLoad : nil
                    let watts = vi ?? Double(tick.battery.voltage_mV) * Double(abs(tick.battery.amperage_mA)) / 1_000_000
                    let energy = Self.portion(Int64(watts * Double(durationMs) * 1000), part: part, start: startMs, duration: durationMs)
                    bucket.battViUj = (bucket.battViUj ?? 0) + energy
                    bucket.battViCovMs += ms
                    if load == nil {
                        bucket.effectiveUj = (bucket.effectiveUj ?? 0) + energy
                        bucket.effectiveCovMs += ms
                        bucket.effectiveViMs += ms
                    }
                }
                measuredCoverage = load != nil || discharging ? durationMs : 0
            }
            bucket.readableCount = tick.unreadable.readableCount
            bucket.unreadableCount = tick.unreadable.unreadableCount
            bucket.batteryPct = tick.battery.percent
            bucket.voltageMv = tick.battery.voltage_mV
            bucket.rawChargeMah = tick.battery.rawCurrentCapacity_mAh
            bucket.fccMah = tick.battery.fullChargeCapacity_mAh
            bucket.thermalMax = max(bucket.thermalMax ?? 0, tick.thermal.rawValue)
            for process in tick.processes {
                var acc = bucket.appDeltas[process.app] ?? AppDeltaAccumulator(
                    displayName: process.displayName, bundlePath: process.bundlePath,
                    category: process.category, lastSeen: endMs / 1000)
                let energyUj = Self.portion(Int64(process.energy_nJ / 1000), part: part, start: startMs, duration: durationMs)
                acc.energyUj += energyUj
                let totalEnergyUj = Int64(process.energy_nJ / 1000)
                let coveredEnergy = measuredCoverage == durationMs ? totalEnergyUj
                    : Int64(Double(totalEnergyUj) * Double(measuredCoverage) / Double(durationMs))
                bucket.attributedCoveredUj += Self.portion(coveredEnergy, part: part,
                                                          start: startMs, duration: durationMs)
                acc.pEnergyUj += Self.portion(Int64(process.pEnergy_nJ / 1000), part: part, start: startMs, duration: durationMs)
                acc.cpuMs += Self.portion(Int64(process.cpuTime_ns / 1_000_000), part: part, start: startMs, duration: durationMs)
                acc.lastSeen = max(acc.lastSeen, endMs / 1000)
                bucket.appDeltas[process.app] = acc
            }
            memoryBuckets[key] = bucket
        }
        // GPU has its own measurement window and can cross a different minute boundary.
        if let gpu = tick.system.gpu {
            let gpuMs = Self.milliseconds(tick.system.gpuInterval ?? tick.interval)
            if gpuMs > 0 {
                let gpuStart = endMs - gpuMs
                let energy = Int64(gpu * Double(gpuMs) * 1000)
                for part in Self.minuteParts(startMs: gpuStart, endMs: endMs) {
                    let key = BucketKey(t_min: part.minute, source: source)
                    var bucket = memoryBuckets[key] ?? MinuteBucket()
                    bucket.gpuUj = (bucket.gpuUj ?? 0) + Self.portion(energy, part: part, start: gpuStart, duration: gpuMs)
                    memoryBuckets[key] = bucket
                }
            }
        }
        let sleepMs = Self.milliseconds(tick.asleep)
        if sleepMs > 0 {
            readableWindows.append(ReadableWindow(start: Double(startMs - sleepMs) / 1000,
                end: Double(startMs) / 1000, energyUj: 0, isAwake: false))
        }
        readableWindows.append(ReadableWindow(start: Double(startMs) / 1000, end: Double(endMs) / 1000,
            energyUj: tick.processes.reduce(0) { $0 + Int64($1.energy_nJ / 1000) }, isAwake: true))
        if readableWindows.count > 4096 { readableWindows.removeFirst(1024) }

        // tick.interval is awake time; sleep inside the tick is recorded as a gap, not as coverage.
        // Placement assumes the awake part is the tail (the timer fires right after wake).
        let sleptS = tick.asleep.components.seconds
        if sleptS >= 1 {
            let awakeEnd = tick.wallClock.timeIntervalSince1970 - Double(durationMs) / 1000.0
            let endS = Int64(floor(awakeEnd))
            try recordSamplingGap(start_s: endS - sleptS, end_s: endS, reason: "sleep")
        }

        if let burst = tick.burst {
            let startS = Int64(floor(burst.window.start.timeIntervalSince1970))
            let endS = Int64(ceil(burst.window.end.timeIntervalSince1970))
            if endS > startS {
                let cpuUj = burst.cpu_mJ.map { Int64($0 * 1000.0) }
                let dramUj = burst.dram_mJ.map { Int64($0 * 1000.0) }
                let aneUj = burst.ane_mJ.map { Int64($0 * 1000.0) }
                let windowStart = burst.window.start.timeIntervalSince1970
                let windowEnd = burst.window.end.timeIntervalSince1970
                var readableUj: Int64 = 0
                var coveredSeconds = 0.0
                var cursor = windowStart
                var complete = true
                for window in readableWindows where window.end > windowStart && window.start < windowEnd {
                    let start = max(window.start, windowStart)
                    let end = min(window.end, windowEnd)
                    if start > cursor + 0.001 { complete = false }
                    let seconds = max(0, end - max(start, cursor))
                    readableUj += Int64((Double(window.energyUj) * seconds / (window.end - window.start)).rounded())
                    if window.isAwake { coveredSeconds += seconds }
                    cursor = max(cursor, end)
                }
                complete = complete && cursor >= windowEnd - 0.001
                try recordEnergyBurst(start_s: startS, end_s: endS, cpu_uj: cpuUj,
                    dram_uj: dramUj, ane_uj: aneUj, readable_cpu_uj: complete ? readableUj : nil,
                    covered_ms: Int((coveredSeconds * 1000).rounded()))
            }
        }
    }

    private struct MinutePart {
        let minute: Int64
        let start: Int64
        let end: Int64
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return max(0, components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private static func minuteParts(startMs: Int64, endMs: Int64) -> [MinutePart] {
        var result: [MinutePart] = []
        var cursor = startMs
        while cursor < endMs {
            let minute = Int64(floor(Double(cursor) / 60_000))
            let end = min(endMs, (minute + 1) * 60_000)
            result.append(MinutePart(minute: minute, start: cursor, end: end))
            cursor = end
        }
        return result
    }

    // Cumulative rounding conserves every integer across the boundary.
    private static func portion(_ total: Int64, part: MinutePart, start: Int64, duration: Int64) -> Int64 {
        let endValue = Int64((Double(total) * Double(part.end - start) / Double(duration)).rounded())
        let startValue = Int64((Double(total) * Double(part.start - start) / Double(duration)).rounded())
        return endValue - startValue
    }

    public func flush() async throws {
        guard !memoryBuckets.isEmpty else { return }
        try SQLiteBridge.exec(db: db, sql: "BEGIN IMMEDIATE;")
        do {
            for (key, bucket) in memoryBuckets {
                try flushBucket(key: key, bucket: bucket)
            }
            try SQLiteBridge.exec(db: db, sql: "COMMIT;")
            memoryBuckets.removeAll()
        } catch {
            _ = try? SQLiteBridge.exec(db: db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func flushBucket(key: BucketKey, bucket: MinuteBucket) throws {
        var attributedUj: Int64 = 0
        var tailUj: Int64 = 0

        for (appKey, acc) in bucket.appDeltas {
            let appId = try resolveOrInsertApp(
                key: appKey,
                displayName: acc.displayName,
                bundlePath: acc.bundlePath,
                category: acc.category,
                seenTime: acc.lastSeen
            )

            if acc.energyUj >= 1000 {
                try insertOrUpdateSlice1m(
                    t_min: key.t_min,
                    appId: appId,
                    source: key.source,
                    energyUj: acc.energyUj,
                    pEnergyUj: acc.pEnergyUj,
                    cpuMs: acc.cpuMs
                )
                attributedUj += acc.energyUj
            } else {
                tailUj += acc.energyUj
            }
        }

        let sys_src: Int
        let sys_uj: Int64?
        let sys_cov_ms: Int
        sys_src = bucket.effectiveCovMs == 0 ? 2 : (bucket.sysloadCovMs > 0 ? 0 : 1)
        sys_uj = bucket.effectiveUj
        sys_cov_ms = bucket.effectiveCovMs

        // Attributed energy follows the measured tick parts, not a minute-wide average.
        let att_cov_uj = bucket.attributedCoveredUj

        try insertOrUpdateSystem1m(
            t_min: key.t_min,
            source: key.source,
            covered_ms: bucket.coveredMs,
            sysload_uj: bucket.sysloadUj,
            sysload_cov_ms: bucket.sysloadCovMs,
            batt_vi_uj: bucket.battViUj,
            batt_vi_cov_ms: bucket.battViCovMs,
            sys_src: sys_src,
            sys_uj: sys_uj,
            sys_cov_ms: sys_cov_ms,
            att_cov_uj: att_cov_uj,
            gpu_uj: bucket.gpuUj,
            attributed_uj: attributedUj,
            tail_uj: tailUj,
            readable_count: bucket.readableCount,
            unreadable_count: bucket.unreadableCount,
            battery_pct: bucket.batteryPct,
            voltage_mv: bucket.voltageMv,
            raw_charge_mah: bucket.rawChargeMah,
            fcc_mah: bucket.fccMah,
            thermal_max: bucket.thermalMax,
            sys_vi_ms: bucket.effectiveViMs
        )
    }

    public func maintain(now: Date) async throws {
        try await flush()

        let nowMin = Int64(floor(now.timeIntervalSince1970 / 60.0))
        let nowHour = Int64(floor(now.timeIntervalSince1970 / 3600.0))
        let nowSec = Int64(floor(now.timeIntervalSince1970))

        try SQLiteBridge.exec(db: db, sql: "BEGIN IMMEDIATE;")
        do {
            // Resume the durable watermark and revisit the recent three hours.
            let marker: Int64
            do {
                let markerStmt = try SQLiteBridge.prepare(db: db, sql: "SELECT value FROM meta WHERE key='rolled_through_hour';")
                defer { SQLiteBridge.finalize(stmt: markerStmt) }
                if try SQLiteBridge.step(stmt: markerStmt, db: db) {
                    marker = Int64(SQLiteBridge.columnText(stmt: markerStmt, index: 0)) ?? 0
                } else {
                    marker = 0
                }
            }
            let firstHour = min(marker + 1, nowHour - 3)
            let hoursStmt = try SQLiteBridge.prepare(db: db, sql: """
                SELECT t_min / 60 AS hour FROM system_1m
                UNION SELECT t_min / 60 AS hour FROM slice_1m
                ORDER BY hour;
                """)
            defer { SQLiteBridge.finalize(stmt: hoursStmt) }
            var hours: [Int64] = []
            while try SQLiteBridge.step(stmt: hoursStmt, db: db) {
                let hour = SQLiteBridge.columnInt64(stmt: hoursStmt, index: 0)
                if hour < nowHour {
                    if hour >= firstHour {
                        hours.append(hour)
                    } else {
                        let missing = try SQLiteBridge.prepare(db: db, sql: """
                            SELECT EXISTS(SELECT 1 FROM system_1m m WHERE m.t_min >= \(hour * 60) AND m.t_min < \((hour + 1) * 60)
                              AND NOT EXISTS(SELECT 1 FROM system_1h h WHERE h.t_hour = \(hour) AND h.source = m.source))
                            OR EXISTS(SELECT 1 FROM slice_1m m WHERE m.t_min >= \(hour * 60) AND m.t_min < \((hour + 1) * 60)
                              AND NOT EXISTS(SELECT 1 FROM slice_1h h WHERE h.t_hour = \(hour) AND h.app_id=m.app_id AND h.source=m.source));
                            """)
                        defer { SQLiteBridge.finalize(stmt: missing) }
                        if try SQLiteBridge.step(stmt: missing, db: db), SQLiteBridge.columnInt64(stmt: missing, index: 0) != 0 {
                            hours.append(hour)
                        }
                    }
                }
            }
            for hour in hours { try rollupHour(hour) }
            try SQLiteBridge.exec(db: db, sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('rolled_through_hour', '\(max(marker, nowHour - 1))');")

            // 2. Retention Pruning
            // 48 h minute slices = 2880 minutes
            let minuteRetentionMin = nowMin - 2880
            try SQLiteBridge.exec(db: db, sql: "DELETE FROM slice_1m WHERE t_min < \(minuteRetentionMin) AND EXISTS (SELECT 1 FROM slice_1h h WHERE h.t_hour = slice_1m.t_min / 60 AND h.app_id = slice_1m.app_id AND h.source = slice_1m.source);")
            try SQLiteBridge.exec(db: db, sql: "DELETE FROM system_1m WHERE t_min < \(minuteRetentionMin) AND EXISTS (SELECT 1 FROM system_1h h WHERE h.t_hour = system_1m.t_min / 60 AND h.source = system_1m.source);")

            // Keep the time extent of the hourly remainder distinct from surviving minutes.
            try SQLiteBridge.exec(db: db, sql: """
                INSERT INTO meta (key, value) VALUES ('minutes_pruned_before', '\(minuteRetentionMin)')
                ON CONFLICT(key) DO UPDATE SET value = CAST(MAX(CAST(meta.value AS INTEGER), \(minuteRetentionMin)) AS TEXT);
                """)

            // 90 days hourly = 90 * 24 = 2160 hours
            let hourRetentionHour = nowHour - 2160
            try SQLiteBridge.exec(db: db, sql: "DELETE FROM slice_1h WHERE t_hour < \(hourRetentionHour);")
            try SQLiteBridge.exec(db: db, sql: "DELETE FROM system_1h WHERE t_hour < \(hourRetentionHour);")

            // 90 days bursts and gaps = 90 * 86400 = 7776000 seconds
            let burstRetentionSec = nowSec - 7776000
            try SQLiteBridge.exec(db: db, sql: "DELETE FROM sampling_gap WHERE end_s < \(burstRetentionSec);")
            try SQLiteBridge.exec(db: db, sql: "DELETE FROM energy_burst WHERE end_s < \(burstRetentionSec);")

            // App cleanup: unreferenced apps older than 90 days
            let appCleanupSql = """
            DELETE FROM app
            WHERE last_seen < \(burstRetentionSec)
              AND id NOT IN (SELECT DISTINCT app_id FROM slice_1m)
              AND id NOT IN (SELECT DISTINCT app_id FROM slice_1h);
            """
            try SQLiteBridge.exec(db: db, sql: appCleanupSql)

            try SQLiteBridge.exec(db: db, sql: "COMMIT;")
        } catch {
            _ = try? SQLiteBridge.exec(db: db, sql: "ROLLBACK;")
            throw error
        }

        // 3. Space recovery outside transaction
        _ = try? SQLiteBridge.exec(db: db, sql: "PRAGMA incremental_vacuum(256);")
        _ = try? SQLiteBridge.exec(db: db, sql: "PRAGMA wal_checkpoint(PASSIVE);")
    }

    private func rollupHour(_ hour: Int64) throws {
        let startMin = hour * 60
        let endMin = (hour + 1) * 60

        let rollupSliceSql = """
        INSERT INTO slice_1h (t_hour, app_id, source, energy_uj, penergy_uj, cpu_ms)
        SELECT ?, app_id, source, SUM(energy_uj), SUM(penergy_uj), SUM(cpu_ms)
        FROM slice_1m
        WHERE t_min >= ? AND t_min < ?
        GROUP BY app_id, source
        ON CONFLICT (t_hour, app_id, source) DO UPDATE SET
          energy_uj  = excluded.energy_uj,
          penergy_uj = excluded.penergy_uj,
          cpu_ms     = excluded.cpu_ms;
        """
        let stmt1 = try SQLiteBridge.prepare(db: db, sql: rollupSliceSql)
        defer { SQLiteBridge.finalize(stmt: stmt1) }
        try SQLiteBridge.bindInt64(stmt: stmt1, index: 1, value: hour)
        try SQLiteBridge.bindInt64(stmt: stmt1, index: 2, value: startMin)
        try SQLiteBridge.bindInt64(stmt: stmt1, index: 3, value: endMin)
        try SQLiteBridge.stepDone(stmt: stmt1, db: db)

        let rollupSysSql = """
        INSERT INTO system_1h (
          t_hour, source, covered_ms,
          sysload_uj, sysload_cov_ms,
          batt_vi_uj, batt_vi_cov_ms,
          sys_uj, sys_cov_ms, sys_vi_ms, att_cov_uj,
          gpu_uj, attributed_uj, tail_uj,
          readable_avg, unreadable_avg,
          charge_used_mah, voltage_mv_avg, fcc_mah, thermal_max
        )
        SELECT
          ?,
          source,
          SUM(covered_ms),
          SUM(sysload_uj),
          SUM(sysload_cov_ms),
          SUM(batt_vi_uj),
          SUM(batt_vi_cov_ms),
          SUM(sys_uj),
          SUM(sys_cov_ms),
          SUM(sys_vi_ms),
          SUM(att_cov_uj),
          SUM(gpu_uj),
          SUM(attributed_uj),
          SUM(tail_uj),
          CAST(ROUND(AVG(readable_count)) AS INTEGER),
          CAST(ROUND(AVG(unreadable_count)) AS INTEGER),
          0,
          CAST(ROUND(AVG(voltage_mv)) AS INTEGER),
          (SELECT fcc_mah FROM system_1m WHERE t_min >= ? AND t_min < ? AND source = s.source AND fcc_mah IS NOT NULL ORDER BY t_min DESC LIMIT 1),
          MAX(thermal_max)
        FROM system_1m AS s
        WHERE t_min >= ? AND t_min < ?
        GROUP BY source
        ON CONFLICT (t_hour, source) DO UPDATE SET
          covered_ms = excluded.covered_ms,
          sysload_uj = excluded.sysload_uj,
          sysload_cov_ms = excluded.sysload_cov_ms,
          batt_vi_uj = excluded.batt_vi_uj,
          batt_vi_cov_ms = excluded.batt_vi_cov_ms,
          sys_uj = excluded.sys_uj,
          sys_cov_ms = excluded.sys_cov_ms,
          sys_vi_ms = excluded.sys_vi_ms,
          att_cov_uj = excluded.att_cov_uj,
          gpu_uj = excluded.gpu_uj,
          attributed_uj = excluded.attributed_uj,
          tail_uj = excluded.tail_uj,
          readable_avg = excluded.readable_avg,
          unreadable_avg = excluded.unreadable_avg,
          charge_used_mah = excluded.charge_used_mah,
          voltage_mv_avg = excluded.voltage_mv_avg,
          fcc_mah = excluded.fcc_mah,
          thermal_max = excluded.thermal_max;
        """
        let stmt2 = try SQLiteBridge.prepare(db: db, sql: rollupSysSql)
        defer { SQLiteBridge.finalize(stmt: stmt2) }
        try SQLiteBridge.bindInt64(stmt: stmt2, index: 1, value: hour)
        try SQLiteBridge.bindInt64(stmt: stmt2, index: 2, value: startMin)
        try SQLiteBridge.bindInt64(stmt: stmt2, index: 3, value: endMin)
        try SQLiteBridge.bindInt64(stmt: stmt2, index: 4, value: startMin)
        try SQLiteBridge.bindInt64(stmt: stmt2, index: 5, value: endMin)
        try SQLiteBridge.stepDone(stmt: stmt2, db: db)
    }

    // MARK: - App Resolution & Upsert Helpers

    private func resolveOrInsertApp(
        key: AppKey,
        displayName: String,
        bundlePath: String?,
        category: AppCategory,
        seenTime: Int64
    ) throws -> Int64 {
        let sql = """
        INSERT INTO app (kind, key, display_name, bundle_path, category, first_seen, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (kind, key) DO UPDATE SET
          display_name = excluded.display_name,
          bundle_path = COALESCE(excluded.bundle_path, app.bundle_path),
          last_seen = MAX(app.last_seen, excluded.last_seen)
        RETURNING id;
        """
        let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
        defer { SQLiteBridge.finalize(stmt: stmt) }
        try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: Int64(key.kind.rawValue))
        try SQLiteBridge.bindText(stmt: stmt, index: 2, value: key.value)
        try SQLiteBridge.bindText(stmt: stmt, index: 3, value: displayName)
        try SQLiteBridge.bindTextOrNil(stmt: stmt, index: 4, value: bundlePath)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 5, value: Int64(category.rawValue))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 6, value: seenTime)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 7, value: seenTime)

        if try SQLiteBridge.step(stmt: stmt, db: db) {
            return SQLiteBridge.columnInt64(stmt: stmt, index: 0)
        }
        throw LedgerError.sqliteError(code: -1, message: "RETURNING id returned no rows for app \(key.value)")
    }

    private func insertOrUpdateSlice1m(
        t_min: Int64,
        appId: Int64,
        source: Int,
        energyUj: Int64,
        pEnergyUj: Int64,
        cpuMs: Int64
    ) throws {
        let sql = """
        INSERT INTO slice_1m (t_min, app_id, source, energy_uj, penergy_uj, cpu_ms)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (t_min, app_id, source) DO UPDATE SET
          energy_uj  = energy_uj  + excluded.energy_uj,
          penergy_uj = penergy_uj + excluded.penergy_uj,
          cpu_ms     = cpu_ms     + excluded.cpu_ms;
        """
        let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
        defer { SQLiteBridge.finalize(stmt: stmt) }
        try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: t_min)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 2, value: appId)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 3, value: Int64(source))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 4, value: energyUj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 5, value: pEnergyUj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 6, value: cpuMs)
        try SQLiteBridge.stepDone(stmt: stmt, db: db)
    }

    private func insertOrUpdateSystem1m(
        t_min: Int64,
        source: Int,
        covered_ms: Int,
        sysload_uj: Int64?,
        sysload_cov_ms: Int,
        batt_vi_uj: Int64?,
        batt_vi_cov_ms: Int,
        sys_src: Int,
        sys_uj: Int64?,
        sys_cov_ms: Int,
        att_cov_uj: Int64,
        gpu_uj: Int64?,
        attributed_uj: Int64,
        tail_uj: Int64,
        readable_count: Int,
        unreadable_count: Int,
        battery_pct: Int?,
        voltage_mv: Int?,
        raw_charge_mah: Int?,
        fcc_mah: Int?,
        thermal_max: Int?,
        sys_vi_ms: Int
    ) throws {
        let sql = """
        INSERT INTO system_1m (
          t_min, source, covered_ms,
          sysload_uj, sysload_cov_ms,
          batt_vi_uj, batt_vi_cov_ms,
          sys_src, sys_uj, sys_cov_ms, att_cov_uj,
          gpu_uj, attributed_uj, tail_uj,
          readable_count, unreadable_count,
          battery_pct, voltage_mv, raw_charge_mah, fcc_mah, thermal_max, sys_vi_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (t_min, source) DO UPDATE SET
          covered_ms = min(60000, system_1m.covered_ms + excluded.covered_ms),
          sysload_uj = CASE
            WHEN system_1m.sysload_uj IS NULL THEN excluded.sysload_uj
            WHEN excluded.sysload_uj IS NULL THEN system_1m.sysload_uj
            ELSE system_1m.sysload_uj + excluded.sysload_uj END,
          sysload_cov_ms = system_1m.sysload_cov_ms + excluded.sysload_cov_ms,
          batt_vi_uj = CASE
            WHEN system_1m.batt_vi_uj IS NULL THEN excluded.batt_vi_uj
            WHEN excluded.batt_vi_uj IS NULL THEN system_1m.batt_vi_uj
            ELSE system_1m.batt_vi_uj + excluded.batt_vi_uj END,
          batt_vi_cov_ms = system_1m.batt_vi_cov_ms + excluded.batt_vi_cov_ms,
          sys_src = CASE WHEN system_1m.sysload_cov_ms + excluded.sysload_cov_ms > 0 THEN 0
                         WHEN system_1m.batt_vi_cov_ms + excluded.batt_vi_cov_ms > 0 THEN 1 ELSE 2 END,
          sys_vi_ms = system_1m.sys_vi_ms + excluded.sys_vi_ms,
          sys_uj = CASE
            WHEN system_1m.sys_uj IS NULL THEN excluded.sys_uj
            WHEN excluded.sys_uj IS NULL THEN system_1m.sys_uj
            ELSE system_1m.sys_uj + excluded.sys_uj END,
          sys_cov_ms = system_1m.sys_cov_ms + excluded.sys_cov_ms,
          att_cov_uj = system_1m.att_cov_uj + excluded.att_cov_uj,
          gpu_uj = CASE
            WHEN system_1m.gpu_uj IS NULL THEN excluded.gpu_uj
            WHEN excluded.gpu_uj IS NULL THEN system_1m.gpu_uj
            ELSE system_1m.gpu_uj + excluded.gpu_uj END,
          attributed_uj = system_1m.attributed_uj + excluded.attributed_uj,
          tail_uj = system_1m.tail_uj + excluded.tail_uj,
          readable_count = excluded.readable_count,
          unreadable_count = excluded.unreadable_count,
          battery_pct = coalesce(excluded.battery_pct, system_1m.battery_pct),
          voltage_mv = coalesce(excluded.voltage_mv, system_1m.voltage_mv),
          raw_charge_mah = coalesce(excluded.raw_charge_mah, system_1m.raw_charge_mah),
          fcc_mah = coalesce(excluded.fcc_mah, system_1m.fcc_mah),
          thermal_max = max(coalesce(system_1m.thermal_max, 0), coalesce(excluded.thermal_max, 0));
        """
        let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
        defer { SQLiteBridge.finalize(stmt: stmt) }
        try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: t_min)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 2, value: Int64(source))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 3, value: Int64(covered_ms))
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 4, value: sysload_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 5, value: Int64(sysload_cov_ms))
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 6, value: batt_vi_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 7, value: Int64(batt_vi_cov_ms))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 8, value: Int64(sys_src))
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 9, value: sys_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 10, value: Int64(sys_cov_ms))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 11, value: att_cov_uj)
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 12, value: gpu_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 13, value: attributed_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 14, value: tail_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 15, value: Int64(readable_count))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 16, value: Int64(unreadable_count))
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 17, value: battery_pct.map { Int64($0) })
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 18, value: voltage_mv.map { Int64($0) })
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 19, value: raw_charge_mah.map { Int64($0) })
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 20, value: fcc_mah.map { Int64($0) })
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 21, value: thermal_max.map { Int64($0) })
        try SQLiteBridge.bindInt64(stmt: stmt, index: 22, value: Int64(sys_vi_ms))
        try SQLiteBridge.stepDone(stmt: stmt, db: db)
    }

    // MARK: - Direct / Raw Recording Helpers

    public func recordRawSlice(
        t_min: Int64,
        app: AppKey,
        displayName: String,
        bundlePath: String? = nil,
        category: AppCategory = .userApp,
        source: PowerSourceKind,
        energy_uj: Int64,
        penergy_uj: Int64 = 0,
        cpu_ms: Int64 = 0
    ) throws {
        let seenTime = t_min * 60
        let appId = try resolveOrInsertApp(
            key: app,
            displayName: displayName,
            bundlePath: bundlePath,
            category: category,
            seenTime: seenTime
        )
        try insertOrUpdateSlice1m(
            t_min: t_min,
            appId: appId,
            source: source.sqliteValue,
            energyUj: energy_uj,
            pEnergyUj: penergy_uj,
            cpuMs: cpu_ms
        )
    }

    public func recordRawSystemMinute(
        t_min: Int64,
        source: PowerSourceKind,
        covered_ms: Int,
        sysload_uj: Int64? = nil,
        sysload_cov_ms: Int = 0,
        batt_vi_uj: Int64? = nil,
        batt_vi_cov_ms: Int = 0,
        gpu_uj: Int64? = nil,
        attributed_uj: Int64 = 0,
        tail_uj: Int64 = 0,
        readable_count: Int = 0,
        unreadable_count: Int = 0,
        battery_pct: Int? = nil,
        voltage_mv: Int? = nil,
        raw_charge_mah: Int? = nil,
        fcc_mah: Int? = nil,
        thermal_max: Int? = nil
    ) throws {
        let sys_src: Int
        let sys_uj: Int64?
        let sys_cov_ms: Int
        if sysload_cov_ms > 0 {
            sys_src = 0
            sys_uj = sysload_uj
            sys_cov_ms = sysload_cov_ms
        } else if source == .battery && batt_vi_cov_ms > 0 {
            sys_src = 1
            sys_uj = batt_vi_uj
            sys_cov_ms = batt_vi_cov_ms
        } else {
            sys_src = 2
            sys_uj = nil
            sys_cov_ms = 0
        }

        let totalAttributed = attributed_uj + tail_uj
        let att_cov_uj: Int64
        if covered_ms > 0 && sys_cov_ms > 0 {
            att_cov_uj = Int64(round(Double(totalAttributed) * Double(sys_cov_ms) / Double(covered_ms)))
        } else {
            att_cov_uj = 0
        }

        try insertOrUpdateSystem1m(
            t_min: t_min,
            source: source.sqliteValue,
            covered_ms: covered_ms,
            sysload_uj: sysload_uj,
            sysload_cov_ms: sysload_cov_ms,
            batt_vi_uj: batt_vi_uj,
            batt_vi_cov_ms: batt_vi_cov_ms,
            sys_src: sys_src,
            sys_uj: sys_uj,
            sys_cov_ms: sys_cov_ms,
            att_cov_uj: att_cov_uj,
            gpu_uj: gpu_uj,
            attributed_uj: attributed_uj,
            tail_uj: tail_uj,
            readable_count: readable_count,
            unreadable_count: unreadable_count,
            battery_pct: battery_pct,
            voltage_mv: voltage_mv,
            raw_charge_mah: raw_charge_mah,
            fcc_mah: fcc_mah,
            thermal_max: thermal_max,
            sys_vi_ms: sys_src == 1 ? sys_cov_ms : 0
        )
    }

    public func recordEnergyBurst(
        start_s: Int64,
        end_s: Int64,
        cpu_uj: Int64?,
        dram_uj: Int64?,
        ane_uj: Int64?,
        readable_cpu_uj: Int64?,
        covered_ms: Int
    ) throws {
        let sql = """
        INSERT INTO energy_burst (start_s, end_s, cpu_uj, dram_uj, ane_uj, readable_cpu_uj, covered_ms, readable_cpu_valid)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (start_s) DO UPDATE SET
          end_s = excluded.end_s,
          cpu_uj = excluded.cpu_uj,
          dram_uj = excluded.dram_uj,
          ane_uj = excluded.ane_uj,
          readable_cpu_uj = excluded.readable_cpu_uj,
          readable_cpu_valid = excluded.readable_cpu_valid,
          covered_ms = excluded.covered_ms;
        """
        let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
        defer { SQLiteBridge.finalize(stmt: stmt) }
        try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: start_s)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 2, value: end_s)
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 3, value: cpu_uj)
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 4, value: dram_uj)
        try SQLiteBridge.bindInt64OrNil(stmt: stmt, index: 5, value: ane_uj)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 6, value: readable_cpu_uj ?? 0)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 7, value: Int64(covered_ms))
        try SQLiteBridge.bindInt64(stmt: stmt, index: 8, value: readable_cpu_uj == nil ? 0 : 1)
        try SQLiteBridge.stepDone(stmt: stmt, db: db)
    }

    public func recordSamplingGap(
        start_s: Int64,
        end_s: Int64,
        reason: String
    ) throws {
        let sql = """
        INSERT INTO sampling_gap (start_s, end_s, reason)
        VALUES (?, ?, ?)
        ON CONFLICT (start_s, reason) DO UPDATE SET
          end_s = excluded.end_s;
        """
        let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
        defer { SQLiteBridge.finalize(stmt: stmt) }
        try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: start_s)
        try SQLiteBridge.bindInt64(stmt: stmt, index: 2, value: end_s)
        try SQLiteBridge.bindText(stmt: stmt, index: 3, value: reason)
        try SQLiteBridge.stepDone(stmt: stmt, db: db)
    }

    // Direct helper for tests to inspect schema version
    public func userVersion() throws -> Int {
        try SchemaManager.getUserVersion(db: db)
    }

    #if DEBUG
    public func executeRawSQLForTesting(_ sql: String) throws {
        try SQLiteBridge.exec(db: db, sql: sql)
    }
    #endif
}

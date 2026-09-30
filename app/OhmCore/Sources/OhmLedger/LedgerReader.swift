import Foundation
import SQLite3
import OhmModel

public final class LedgerReader: EnergyLedgerReading {
    public static let currentReaderVersion = SchemaManager.readerCompatVersion

    private var db: OpaquePointer?
    private let path: String
    private var isDatabaseEmpty: Bool = false
    private var schemaVersion: Int = 0

    public init(path: String) throws {
        self.path = path
        do {
            try self.openDatabase()
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() throws {
        var newDb: OpaquePointer?
        let rc = sqlite3_open_v2(path, &newDb, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let validDb = newDb else {
            let msg = newDb != nil ? String(cString: sqlite3_errmsg(newDb)) : "Failed to open read-only database at \(path)"
            if let newDb = newDb { sqlite3_close(newDb) }
            throw LedgerError.sqliteError(code: rc, message: msg)
        }
        self.db = validDb

        try SchemaManager.applyPragmasReader(db: validDb)

        // Compatibility check
        let userVer = try SchemaManager.getUserVersion(db: validDb)
        schemaVersion = userVer
        if userVer == 0 {
            self.isDatabaseEmpty = true
        } else {
            self.isDatabaseEmpty = false
            // Check reader_compat
            let sql = "SELECT value FROM meta WHERE key = 'reader_compat';"
            let stmt = try SQLiteBridge.prepare(db: validDb, sql: sql)
            defer { SQLiteBridge.finalize(stmt: stmt) }
            if try SQLiteBridge.step(stmt: stmt, db: validDb) {
                let valStr = SQLiteBridge.columnText(stmt: stmt, index: 0)
                if let requiredVer = Int(valStr), requiredVer > Self.currentReaderVersion {
                    throw LedgerError.incompatibleReader(
                        requiredVersion: requiredVer,
                        currentVersion: Self.currentReaderVersion
                    )
                }
            }
        }
    }

    // The retention seam may cut an hour: hourly minus surviving minutes is the older part.
    // Recent rollups are thus excluded without duplicating any retained minute energy.
    private var historyCTE: String {
        """
        WITH retention AS (
          SELECT COALESCE(
            (SELECT CAST(value AS INTEGER) FROM meta WHERE key='minutes_pruned_before'),
            (SELECT MIN(t_min) FROM (SELECT t_min FROM system_1m UNION ALL SELECT t_min FROM slice_1m)),
            9223372036854775807) AS cutoff
        ), minute_system_totals AS (
          SELECT t_min / 60 AS t_hour, source, SUM(covered_ms) AS covered_ms,
                 SUM(sys_uj) AS sys_uj, SUM(sys_cov_ms) AS sys_cov_ms,
                 SUM(att_cov_uj) AS att_cov_uj, SUM(attributed_uj) AS attributed_uj,
                 SUM(tail_uj) AS tail_uj, SUM(gpu_uj) AS gpu_uj
          FROM system_1m GROUP BY t_min / 60, source
        ), system_hours AS (
          SELECT h.t_hour * 60 AS t_min, MIN(60, MAX(0, (SELECT cutoff FROM retention) - h.t_hour * 60)) AS span_min, h.source,
                 h.covered_ms - COALESCE(m.covered_ms, 0) AS covered_ms,
                 h.sys_uj - COALESCE(m.sys_uj, 0) AS sys_uj,
                 h.sys_cov_ms - COALESCE(m.sys_cov_ms, 0) AS sys_cov_ms,
                 h.att_cov_uj - COALESCE(m.att_cov_uj, 0) AS att_cov_uj,
                 h.attributed_uj - COALESCE(m.attributed_uj, 0) AS attributed_uj,
                 h.tail_uj - COALESCE(m.tail_uj, 0) AS tail_uj,
                 h.gpu_uj - COALESCE(m.gpu_uj, 0) AS gpu_uj,
                 h.readable_avg AS readable_count, h.unreadable_avg AS unreadable_count,
                 h.fcc_mah, h.voltage_mv_avg AS voltage_mv
          FROM system_1h h LEFT JOIN minute_system_totals m ON m.t_hour=h.t_hour AND m.source=h.source
        ), systems AS (
          SELECT t_min, 1 AS span_min, source, covered_ms, sys_uj, sys_cov_ms, att_cov_uj,
                 attributed_uj, tail_uj, gpu_uj, readable_count, unreadable_count, fcc_mah, voltage_mv
          FROM system_1m
          UNION ALL
          SELECT * FROM system_hours
          WHERE span_min > 0 AND (covered_ms > 0 OR sys_cov_ms > 0 OR attributed_uj > 0 OR tail_uj > 0 OR gpu_uj > 0)
        ), slice_hours AS (
          SELECT h.t_hour * 60 AS t_min, MIN(60, MAX(0, (SELECT cutoff FROM retention) - h.t_hour * 60)) AS span_min, h.app_id, h.source,
                 h.energy_uj - COALESCE(SUM(m.energy_uj), 0) AS energy_uj,
                 h.penergy_uj - COALESCE(SUM(m.penergy_uj), 0) AS penergy_uj,
                 h.cpu_ms - COALESCE(SUM(m.cpu_ms), 0) AS cpu_ms
          FROM slice_1h h LEFT JOIN slice_1m m
            ON m.t_min >= h.t_hour * 60 AND m.t_min < (h.t_hour + 1) * 60
               AND m.app_id=h.app_id AND m.source=h.source
          GROUP BY h.t_hour, h.app_id, h.source
        ), slices AS (
          SELECT t_min, 1 AS span_min, app_id, source, energy_uj, penergy_uj, cpu_ms FROM slice_1m
          UNION ALL
          SELECT * FROM slice_hours WHERE span_min > 0 AND energy_uj > 0 AND penergy_uj >= 0 AND cpu_ms >= 0
        )
        """
    }

    // MARK: - EnergyLedgerReading Protocol Implementation

    public func receipt(for interval: DateInterval, source: PowerSourceKind? = nil) throws -> Receipt {
        guard let db = db else { throw LedgerError.closed }
        if isDatabaseEmpty {
            return Receipt(interval: interval, powerSource: source)
        }

        // All aggregates in a receipt must see the same WAL snapshot.
        try SQLiteBridge.exec(db: db, sql: "BEGIN;")
        defer { _ = try? SQLiteBridge.exec(db: db, sql: "ROLLBACK;") }

        let startMin = Int64(floor(interval.start.timeIntervalSince1970 / 60.0))
        let endMin = max(startMin + 1, Int64(ceil(interval.end.timeIntervalSince1970 / 60.0)))
        let sevenDaysAgoS = Int64(floor(interval.end.timeIntervalSince1970)) - (7 * 86400)

        // 1. Query system_1m aggregates for the interval
        let sysSql = historyCTE + """
        SELECT
          COALESCE(SUM(covered_ms), 0),
          COALESCE(SUM(sys_uj), 0),
          COALESCE(SUM(sys_cov_ms), 0),
          COALESCE(SUM(att_cov_uj), 0),
          COALESCE(SUM(attributed_uj), 0),
          COALESCE(SUM(tail_uj), 0),
          COALESCE(SUM(gpu_uj), 0),
          COALESCE(SUM(readable_count), 0),
          COALESCE(SUM(unreadable_count), 0)
        FROM systems
        WHERE t_min + span_min > ? AND t_min < ?
          AND (? IS NULL OR source = ?);
        """
        let sysStmt = try SQLiteBridge.prepare(db: db, sql: sysSql)
        defer { SQLiteBridge.finalize(stmt: sysStmt) }
        try SQLiteBridge.bindInt64(stmt: sysStmt, index: 1, value: startMin)
        try SQLiteBridge.bindInt64(stmt: sysStmt, index: 2, value: endMin)
        if let s = source {
            try SQLiteBridge.bindInt64(stmt: sysStmt, index: 3, value: Int64(s.sqliteValue))
            try SQLiteBridge.bindInt64(stmt: sysStmt, index: 4, value: Int64(s.sqliteValue))
        } else {
            try SQLiteBridge.bindNull(stmt: sysStmt, index: 3)
            try SQLiteBridge.bindNull(stmt: sysStmt, index: 4)
        }

        var totalSysUj: Int64 = 0
        var totalSysCovMs: Int64 = 0
        var totalAttCovUj: Int64 = 0
        var totalTailUj: Int64 = 0
        var totalGpuUj: Int64 = 0
        var totalReadable: Int64 = 0
        var totalUnreadable: Int64 = 0

        if try SQLiteBridge.step(stmt: sysStmt, db: db) {
            totalSysUj = SQLiteBridge.columnInt64(stmt: sysStmt, index: 1)
            totalSysCovMs = SQLiteBridge.columnInt64(stmt: sysStmt, index: 2)
            totalAttCovUj = SQLiteBridge.columnInt64(stmt: sysStmt, index: 3)
            totalTailUj = SQLiteBridge.columnInt64(stmt: sysStmt, index: 5)
            totalGpuUj = SQLiteBridge.columnInt64(stmt: sysStmt, index: 6)
            totalReadable = SQLiteBridge.columnInt64(stmt: sysStmt, index: 7)
            totalUnreadable = SQLiteBridge.columnInt64(stmt: sysStmt, index: 8)
        }

        let e_sys = totalSysUj
        let c = totalAttCovUj
        let residualSignedUj = e_sys - c
        let r = max(0, residualSignedUj)

        // 2. IOReport energy_bursts in the last 7 days for unreadable processes S
        var unreadableSystemUj: Int64 = 0
        var isUnreadableEstimated = false

        let burstSql = """
        SELECT
          COALESCE(SUM(MAX(0, cpu_uj - readable_cpu_uj)), 0),
          COALESCE(SUM(covered_ms), 0)
        FROM energy_burst
        WHERE end_s >= ? AND end_s <= ? AND cpu_uj IS NOT NULL
          AND \(schemaVersion >= 2 ? "readable_cpu_valid = 1" : "0") AND covered_ms > 0;
        """
        let burstStmt = try SQLiteBridge.prepare(db: db, sql: burstSql)
        defer { SQLiteBridge.finalize(stmt: burstStmt) }
        try SQLiteBridge.bindInt64(stmt: burstStmt, index: 1, value: sevenDaysAgoS)
        try SQLiteBridge.bindInt64(stmt: burstStmt, index: 2, value: Int64(interval.end.timeIntervalSince1970))
        if try SQLiteBridge.step(stmt: burstStmt, db: db) {
            let burstUnreadableUj = SQLiteBridge.columnInt64(stmt: burstStmt, index: 0)
            let burstCoveredMs = SQLiteBridge.columnInt64(stmt: burstStmt, index: 1)
            if burstCoveredMs > 0 {
                let rho = (Double(burstUnreadableUj) * 1e-6) / (Double(burstCoveredMs) * 1e-3)
                let t_cov = Double(totalSysCovMs) * 1e-3
                let sVal = min(max(0, r - totalGpuUj), Int64(round(rho * t_cov * 1e6)))
                unreadableSystemUj = sVal
                isUnreadableEstimated = true
            }
        }

        // 3. Discrepancy & Over-attribution status
        let discrepancyStatus: ReceiptDiscrepancyStatus
        var otherUj: Int64 = 0

        if residualSignedUj - totalGpuUj >= 0 {
            discrepancyStatus = .exactConservation
            otherUj = max(0, r - unreadableSystemUj - totalGpuUj)
        } else if Double(residualSignedUj - totalGpuUj) >= -0.05 * Double(e_sys) {
            discrepancyStatus = .withinToleranceOverAttribution
            unreadableSystemUj = 0
            otherUj = 0
        } else {
            discrepancyStatus = .inconsistent
            unreadableSystemUj = 0
            otherUj = 0
        }

        // 4. Calculate P_ref (watts) from last 7 days on battery
        var pRefWatts: Double? = nil
        let pRefSql = historyCTE + """
        SELECT COALESCE(SUM(sys_uj), 0), COALESCE(SUM(sys_cov_ms), 0)
        FROM systems
        WHERE source = 1 AND sys_cov_ms > 0 AND t_min + span_min > ? AND t_min < ?;
        """
        let pRefStmt = try SQLiteBridge.prepare(db: db, sql: pRefSql)
        defer { SQLiteBridge.finalize(stmt: pRefStmt) }
        try SQLiteBridge.bindInt64(stmt: pRefStmt, index: 1, value: sevenDaysAgoS / 60)
        try SQLiteBridge.bindInt64(stmt: pRefStmt, index: 2, value: endMin)
        if try SQLiteBridge.step(stmt: pRefStmt, db: db) {
            let energy = SQLiteBridge.columnInt64(stmt: pRefStmt, index: 0)
            let coverage = SQLiteBridge.columnInt64(stmt: pRefStmt, index: 1)
            if coverage >= 3_600_000 {
                pRefWatts = PRefCalculator.calculatePRef(sys_uj: energy, sys_cov_ms: coverage)
            }
        }
        if pRefWatts == nil {
            let today = Calendar.current.startOfDay(for: interval.end)
            let todayStmt = try SQLiteBridge.prepare(db: db, sql: pRefSql)
            defer { SQLiteBridge.finalize(stmt: todayStmt) }
            try SQLiteBridge.bindInt64(stmt: todayStmt, index: 1, value: Int64(today.timeIntervalSince1970 / 60))
            try SQLiteBridge.bindInt64(stmt: todayStmt, index: 2, value: endMin)
            if try SQLiteBridge.step(stmt: todayStmt, db: db) {
                let energy = SQLiteBridge.columnInt64(stmt: todayStmt, index: 0)
                let coverage = SQLiteBridge.columnInt64(stmt: todayStmt, index: 1)
                if coverage >= 600_000 {
                    pRefWatts = PRefCalculator.calculatePRef(sys_uj: energy, sys_cov_ms: coverage)
                }
            }
        }

        // 5. Calculate E_full (joules) from latest fcc_mah and average voltage
        var eFullJoules: Double? = nil
        let battParamSql = historyCTE + """
        SELECT
          (SELECT fcc_mah FROM systems WHERE source = 1 AND fcc_mah IS NOT NULL AND t_min >= ? AND t_min < \(endMin) ORDER BY t_min DESC LIMIT 1),
          (SELECT CAST(ROUND(AVG(voltage_mv)) AS INTEGER) FROM systems WHERE source = 1 AND voltage_mv IS NOT NULL AND t_min >= ? AND t_min < \(endMin))
        """
        let battStmt = try SQLiteBridge.prepare(db: db, sql: battParamSql)
        defer { SQLiteBridge.finalize(stmt: battStmt) }
        try SQLiteBridge.bindInt64(stmt: battStmt, index: 1, value: sevenDaysAgoS / 60)
        try SQLiteBridge.bindInt64(stmt: battStmt, index: 2, value: sevenDaysAgoS / 60)
        if try SQLiteBridge.step(stmt: battStmt, db: db) {
            let fccMah = SQLiteBridge.columnInt64OrNil(stmt: battStmt, index: 0)
            let avgVoltMv = SQLiteBridge.columnInt64OrNil(stmt: battStmt, index: 1)
            if let fcc = fccMah, let v = avgVoltMv, fcc > 0, v > 0 {
                eFullJoules = Double(fcc) * (Double(v) / 1000.0) * 3.6
            }
        }

        // 6. Query app slices for the interval
        let appsSql = historyCTE + """
        SELECT
          a.kind, a.key, a.display_name, a.bundle_path, a.category,
          SUM(s.energy_uj) AS energy_uj,
          SUM(s.penergy_uj) AS penergy_uj,
          SUM(s.cpu_ms) AS cpu_ms,
          SUM(CASE WHEN s.source = 1 THEN s.energy_uj ELSE 0 END) AS battery_uj,
          SUM(CASE WHEN s.source = 0 THEN s.energy_uj ELSE 0 END) AS ac_uj
        FROM slices AS s
        JOIN app AS a ON a.id = s.app_id
        WHERE s.t_min + s.span_min > ? AND s.t_min < ?
          AND (? IS NULL OR s.source = ?)
        GROUP BY s.app_id
        ORDER BY energy_uj DESC;
        """
        let appsStmt = try SQLiteBridge.prepare(db: db, sql: appsSql)
        defer { SQLiteBridge.finalize(stmt: appsStmt) }
        try SQLiteBridge.bindInt64(stmt: appsStmt, index: 1, value: startMin)
        try SQLiteBridge.bindInt64(stmt: appsStmt, index: 2, value: endMin)
        if let s = source {
            try SQLiteBridge.bindInt64(stmt: appsStmt, index: 3, value: Int64(s.sqliteValue))
            try SQLiteBridge.bindInt64(stmt: appsStmt, index: 4, value: Int64(s.sqliteValue))
        } else {
            try SQLiteBridge.bindNull(stmt: appsStmt, index: 3)
            try SQLiteBridge.bindNull(stmt: appsStmt, index: 4)
        }

        var userAppRows: [ReceiptAppRow] = []
        var macOSServiceRows: [ReceiptAppRow] = []

        while try SQLiteBridge.step(stmt: appsStmt, db: db) {
            let kindRaw = Int(SQLiteBridge.columnInt64(stmt: appsStmt, index: 0))
            let kind = AttributionKind(rawValue: kindRaw) ?? .executableName
            let keyStr = SQLiteBridge.columnText(stmt: appsStmt, index: 1)
            let displayName = SQLiteBridge.columnText(stmt: appsStmt, index: 2)
            let bundlePath = SQLiteBridge.columnTextOrNil(stmt: appsStmt, index: 3)
            let catRaw = Int(SQLiteBridge.columnInt64(stmt: appsStmt, index: 4))
            let category = AppCategory(rawValue: catRaw) ?? .userApp
            let energyUj = SQLiteBridge.columnInt64(stmt: appsStmt, index: 5)
            let pEnergyUj = SQLiteBridge.columnInt64(stmt: appsStmt, index: 6)
            let cpuMs = SQLiteBridge.columnInt64(stmt: appsStmt, index: 7)

            let batteryUj = SQLiteBridge.columnInt64(stmt: appsStmt, index: 8)
            let acUj = SQLiteBridge.columnInt64(stmt: appsStmt, index: 9)
            let appKey = AppKey(kind: kind, value: keyStr)

            var batteryMinutes: Double? = nil
            var batteryPercent: Double? = nil
            var chargingWh: Double? = nil

            if source == .battery || source == nil {
                if let pRef = pRefWatts {
                    batteryMinutes = PRefCalculator.calculateBatteryMinutes(energy_uj: batteryUj, pRef: pRef)
                }
                if let eFull = eFullJoules {
                    let eApp = Double(batteryUj) * 1e-6
                    batteryPercent = 100.0 * eApp / eFull
                }
            }
            if source == .ac || source == nil {
                chargingWh = (Double(acUj) * 1e-6) / 3600.0
            }

            let row = ReceiptAppRow(
                appKey: appKey,
                displayName: displayName,
                bundlePath: bundlePath,
                category: category,
                energy_uj: energyUj,
                pEnergy_uj: pEnergyUj,
                cpuTime_ms: cpuMs,
                batteryMinutes: batteryMinutes,
                batteryPercent: batteryPercent,
                chargingWh: chargingWh
            )

            if category == .macOSService {
                macOSServiceRows.append(row)
            } else {
                userAppRows.append(row)
            }
        }

        let totalProc = totalReadable + totalUnreadable
        let unreadableRatio: Double? = totalProc > 0 ? Double(totalUnreadable) / Double(totalProc) : nil

        return Receipt(
            interval: interval,
            powerSource: source,
            rows: userAppRows,
            macOSServices: macOSServiceRows,
            tail_uj: totalTailUj,
            unreadableSystem_uj: unreadableSystemUj,
            isUnreadableEstimated: isUnreadableEstimated,
            unreadableProcessRatio: unreadableRatio,
            other_uj: otherUj,
            gpu_uj: totalGpuUj,
            measuredSystemEnergy_uj: e_sys,
            attributedCoveredEnergy_uj: c,
            residualSigned_uj: residualSignedUj,
            discrepancyStatus: discrepancyStatus,
            pRefWatts: pRefWatts,
            eFullJoules: eFullJoules
        )
    }

    public func systemSeries(for interval: DateInterval, resolution: LedgerResolution) throws -> [SystemPoint] {
        guard let db = db else { throw LedgerError.closed }
        if isDatabaseEmpty {
            return []
        }

        switch resolution {
        case .minute:
            let startMin = Int64(floor(interval.start.timeIntervalSince1970 / 60.0))
            let endMin = max(startMin + 1, Int64(ceil(interval.end.timeIntervalSince1970 / 60.0)))
            let sql = """
            SELECT
              t_min, source, covered_ms, sys_uj, att_cov_uj, tail_uj,
              residual_uj, gpu_uj, battery_pct, voltage_mv, thermal_max
            FROM system_1m
            WHERE t_min >= ? AND t_min < ?
            ORDER BY t_min ASC, source ASC;
            """
            let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
            defer { SQLiteBridge.finalize(stmt: stmt) }
            try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: startMin)
            try SQLiteBridge.bindInt64(stmt: stmt, index: 2, value: endMin)

            var points: [SystemPoint] = []
            while try SQLiteBridge.step(stmt: stmt, db: db) {
                let tMin = SQLiteBridge.columnInt64(stmt: stmt, index: 0)
                let srcRaw = Int(SQLiteBridge.columnInt64(stmt: stmt, index: 1))
                let source = PowerSourceKind(sqliteValue: srcRaw)
                let coveredMs = Int(SQLiteBridge.columnInt64(stmt: stmt, index: 2))
                let sysUj = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 3)
                let attCovUj = SQLiteBridge.columnInt64(stmt: stmt, index: 4)
                let tailUj = SQLiteBridge.columnInt64(stmt: stmt, index: 5)
                let resUj = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 6)
                let gpuUj = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 7)
                let battPct = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 8).map { Int($0) }
                let voltMv = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 9).map { Int($0) }
                let thermRaw = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 10).map { Int($0) }
                let therm = thermRaw.flatMap { ThermalLevel(rawValue: $0) }

                let point = SystemPoint(
                    timestamp: Date(timeIntervalSince1970: Double(tMin * 60)),
                    source: source,
                    coveredMs: coveredMs,
                    systemEnergy_uj: sysUj,
                    attributedEnergy_uj: attCovUj,
                    tailEnergy_uj: tailUj,
                    residual_uj: resUj,
                    gpuEnergy_uj: gpuUj,
                    batteryPercent: battPct,
                    voltage_mv: voltMv,
                    thermalMax: therm
                )
                points.append(point)
            }
            return points

        case .hour:
            let startHour = Int64(floor(interval.start.timeIntervalSince1970 / 3600.0))
            let endHour = max(startHour + 1, Int64(ceil(interval.end.timeIntervalSince1970 / 3600.0)))
            let sql = """
            SELECT
              t_hour, source, covered_ms, sys_uj, att_cov_uj, tail_uj,
              residual_uj, gpu_uj, fcc_mah, voltage_mv_avg, thermal_max
            FROM system_1h
            WHERE t_hour >= ? AND t_hour < ?
            ORDER BY t_hour ASC, source ASC;
            """
            let stmt = try SQLiteBridge.prepare(db: db, sql: sql)
            defer { SQLiteBridge.finalize(stmt: stmt) }
            try SQLiteBridge.bindInt64(stmt: stmt, index: 1, value: startHour)
            try SQLiteBridge.bindInt64(stmt: stmt, index: 2, value: endHour)

            var points: [SystemPoint] = []
            while try SQLiteBridge.step(stmt: stmt, db: db) {
                let tHour = SQLiteBridge.columnInt64(stmt: stmt, index: 0)
                let srcRaw = Int(SQLiteBridge.columnInt64(stmt: stmt, index: 1))
                let source = PowerSourceKind(sqliteValue: srcRaw)
                let coveredMs = Int(SQLiteBridge.columnInt64(stmt: stmt, index: 2))
                let sysUj = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 3)
                let attCovUj = SQLiteBridge.columnInt64(stmt: stmt, index: 4)
                let tailUj = SQLiteBridge.columnInt64(stmt: stmt, index: 5)
                let resUj = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 6)
                let gpuUj = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 7)
                let voltMv = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 9).map { Int($0) }
                let thermRaw = SQLiteBridge.columnInt64OrNil(stmt: stmt, index: 10).map { Int($0) }
                let therm = thermRaw.flatMap { ThermalLevel(rawValue: $0) }

                let point = SystemPoint(
                    timestamp: Date(timeIntervalSince1970: Double(tHour * 3600)),
                    source: source,
                    coveredMs: coveredMs,
                    systemEnergy_uj: sysUj,
                    attributedEnergy_uj: attCovUj,
                    tailEnergy_uj: tailUj,
                    residual_uj: resUj,
                    gpuEnergy_uj: gpuUj,
                    batteryPercent: nil,
                    voltage_mv: voltMv,
                    thermalMax: therm
                )
                points.append(point)
            }
            return points
        }
    }

    /// Verifies that write operations fail on this read-only connection.
    public func assertReadOnly() throws {
        guard let db = db else { throw LedgerError.closed }
        _ = try SQLiteBridge.exec(db: db, sql: "INSERT INTO meta (key, value) VALUES ('test_ro', 'fail');")
    }

    public func executeRawWrite(_ sql: String) throws {
        guard let db = db else { throw LedgerError.closed }
        _ = try SQLiteBridge.exec(db: db, sql: sql)
    }
}

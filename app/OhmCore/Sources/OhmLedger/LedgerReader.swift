import Foundation
import SQLite3
import OhmModel

public final class LedgerReader: EnergyLedgerReading {
    public static let currentReaderVersion = SchemaManager.readerCompatVersion

    private var db: OpaquePointer?
    private let path: String
    private var isDatabaseEmpty: Bool = false

    public init(path: String) throws {
        self.path = path
        try self.openDatabase()
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

    // MARK: - EnergyLedgerReading Protocol Implementation

    public func receipt(for interval: DateInterval, source: PowerSourceKind? = nil) throws -> Receipt {
        guard let db = db else { throw LedgerError.closed }
        if isDatabaseEmpty {
            return Receipt(interval: interval, powerSource: source)
        }

        let startMin = Int64(floor(interval.start.timeIntervalSince1970 / 60.0))
        let endMin = max(startMin + 1, Int64(ceil(interval.end.timeIntervalSince1970 / 60.0)))
        let sevenDaysAgoS = Int64(floor(interval.end.timeIntervalSince1970)) - (7 * 86400)

        // 1. Query system_1m aggregates for the interval
        let sysSql = """
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
        FROM system_1m
        WHERE t_min >= ? AND t_min < ?
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
        WHERE end_s >= ?;
        """
        let burstStmt = try SQLiteBridge.prepare(db: db, sql: burstSql)
        defer { SQLiteBridge.finalize(stmt: burstStmt) }
        try SQLiteBridge.bindInt64(stmt: burstStmt, index: 1, value: sevenDaysAgoS)
        if try SQLiteBridge.step(stmt: burstStmt, db: db) {
            let burstUnreadableUj = SQLiteBridge.columnInt64(stmt: burstStmt, index: 0)
            let burstCoveredMs = SQLiteBridge.columnInt64(stmt: burstStmt, index: 1)
            if burstCoveredMs > 0 {
                let rho = (Double(burstUnreadableUj) * 1e-6) / (Double(burstCoveredMs) * 1e-3)
                let t_cov = Double(totalSysCovMs) * 1e-3
                let sVal = min(r, Int64(round(rho * t_cov * 1e6)))
                unreadableSystemUj = sVal
                isUnreadableEstimated = true
            }
        }

        // 3. Discrepancy & Over-attribution status
        let discrepancyStatus: ReceiptDiscrepancyStatus
        var otherUj: Int64 = 0

        if residualSignedUj >= 0 {
            discrepancyStatus = .exactConservation
            otherUj = max(0, r - unreadableSystemUj)
        } else if Double(residualSignedUj) >= -0.05 * Double(e_sys) {
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
        let pRefSql = """
        SELECT
          COALESCE(SUM(sys_uj), 0),
          COALESCE(SUM(sys_cov_ms), 0)
        FROM system_1m
        WHERE source = 1 AND sys_src != 2 AND t_min >= ?;
        """
        let pRefStmt = try SQLiteBridge.prepare(db: db, sql: pRefSql)
        defer { SQLiteBridge.finalize(stmt: pRefStmt) }
        try SQLiteBridge.bindInt64(stmt: pRefStmt, index: 1, value: sevenDaysAgoS / 60)
        if try SQLiteBridge.step(stmt: pRefStmt, db: db) {
            let pRefSysUj = SQLiteBridge.columnInt64(stmt: pRefStmt, index: 0)
            let pRefSysCovMs = SQLiteBridge.columnInt64(stmt: pRefStmt, index: 1)
            if pRefSysCovMs > 0 {
                pRefWatts = PRefCalculator.calculatePRef(sys_uj: pRefSysUj, sys_cov_ms: pRefSysCovMs)
            }
        }

        // Fallback for P_ref: if not in last 7 days, check interval itself
        if pRefWatts == nil && totalSysCovMs > 0 && (source == .battery || source == nil) {
            pRefWatts = PRefCalculator.calculatePRef(sys_uj: totalSysUj, sys_cov_ms: totalSysCovMs)
        }

        // 5. Calculate E_full (joules) from latest fcc_mah and average voltage
        var eFullJoules: Double? = nil
        let battParamSql = """
        SELECT
          (SELECT fcc_mah FROM system_1m WHERE source = 1 AND fcc_mah IS NOT NULL AND t_min >= ? ORDER BY t_min DESC LIMIT 1),
          (SELECT CAST(ROUND(AVG(voltage_mv)) AS INTEGER) FROM system_1m WHERE source = 1 AND voltage_mv IS NOT NULL AND t_min >= ?)
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
        let appsSql = """
        SELECT
          a.kind, a.key, a.display_name, a.bundle_path, a.category,
          SUM(s.energy_uj) AS energy_uj,
          SUM(s.penergy_uj) AS penergy_uj,
          SUM(s.cpu_ms) AS cpu_ms
        FROM slice_1m AS s
        JOIN app AS a ON a.id = s.app_id
        WHERE s.t_min >= ? AND s.t_min < ?
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

            let appKey = AppKey(kind: kind, value: keyStr)

            var batteryMinutes: Double? = nil
            var batteryPercent: Double? = nil
            var chargingWh: Double? = nil

            if source == .battery || (source == nil && pRefWatts != nil) {
                if let pRef = pRefWatts {
                    batteryMinutes = PRefCalculator.calculateBatteryMinutes(energy_uj: energyUj, pRef: pRef)
                }
                if let eFull = eFullJoules {
                    let eApp = Double(energyUj) * 1e-6
                    batteryPercent = 100.0 * eApp / eFull
                }
            } else if source == .ac {
                chargingWh = (Double(energyUj) * 1e-6) / 3600.0
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

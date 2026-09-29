import Foundation
import SQLite3

public struct Migration: Sendable {
    public let version: Int
    public let sql: String

    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

internal enum SchemaManager {
    static let currentVersion = 1
    static let readerCompatVersion = 1

    static let schemaV1 = """
    PRAGMA auto_vacuum = INCREMENTAL;
    PRAGMA journal_mode = WAL;

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) STRICT;

    CREATE TABLE IF NOT EXISTS app (
      id           INTEGER PRIMARY KEY,
      kind         INTEGER NOT NULL CHECK (kind IN (0, 1, 2)),
      key          TEXT    NOT NULL,
      display_name TEXT    NOT NULL,
      bundle_path  TEXT,
      category     INTEGER NOT NULL DEFAULT 0 CHECK (category IN (0, 1)),
      first_seen   INTEGER NOT NULL,
      last_seen    INTEGER NOT NULL,
      UNIQUE (kind, key)
    ) STRICT;

    CREATE TABLE IF NOT EXISTS slice_1m (
      t_min      INTEGER NOT NULL,
      app_id     INTEGER NOT NULL REFERENCES app(id),
      source     INTEGER NOT NULL CHECK (source IN (0, 1, 2)),
      energy_uj  INTEGER NOT NULL CHECK (energy_uj  >= 0),
      penergy_uj INTEGER NOT NULL CHECK (penergy_uj >= 0),
      cpu_ms     INTEGER NOT NULL CHECK (cpu_ms     >= 0),
      PRIMARY KEY (t_min, app_id, source)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS system_1m (
      t_min            INTEGER NOT NULL,
      source           INTEGER NOT NULL CHECK (source IN (0, 1, 2)),
      covered_ms       INTEGER NOT NULL CHECK (covered_ms BETWEEN 0 AND 60000),
      sysload_uj       INTEGER,
      sysload_cov_ms   INTEGER NOT NULL DEFAULT 0,
      batt_vi_uj       INTEGER,
      batt_vi_cov_ms   INTEGER NOT NULL DEFAULT 0,
      sys_src          INTEGER NOT NULL CHECK (sys_src IN (0, 1, 2)),
      sys_uj           INTEGER,
      sys_cov_ms       INTEGER NOT NULL DEFAULT 0,
      att_cov_uj       INTEGER NOT NULL DEFAULT 0,
      gpu_uj           INTEGER,
      attributed_uj    INTEGER NOT NULL,
      tail_uj          INTEGER NOT NULL,
      residual_uj      INTEGER GENERATED ALWAYS AS (sys_uj - att_cov_uj) VIRTUAL,
      readable_count   INTEGER NOT NULL,
      unreadable_count INTEGER NOT NULL,
      battery_pct      INTEGER,
      voltage_mv       INTEGER,
      raw_charge_mah   INTEGER,
      fcc_mah          INTEGER,
      thermal_max      INTEGER,
      PRIMARY KEY (t_min, source)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS slice_1h (
      t_hour     INTEGER NOT NULL,
      app_id     INTEGER NOT NULL REFERENCES app(id),
      source     INTEGER NOT NULL,
      energy_uj  INTEGER NOT NULL,
      penergy_uj INTEGER NOT NULL,
      cpu_ms     INTEGER NOT NULL,
      PRIMARY KEY (t_hour, app_id, source)
    ) STRICT, WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS slice_1h_by_app ON slice_1h (app_id, t_hour);

    CREATE TABLE IF NOT EXISTS system_1h (
      t_hour           INTEGER NOT NULL,
      source           INTEGER NOT NULL,
      covered_ms       INTEGER NOT NULL,
      sysload_uj       INTEGER,
      sysload_cov_ms   INTEGER NOT NULL,
      batt_vi_uj       INTEGER,
      batt_vi_cov_ms   INTEGER NOT NULL,
      sys_uj           INTEGER,
      sys_cov_ms       INTEGER NOT NULL,
      sys_vi_ms        INTEGER NOT NULL,
      att_cov_uj       INTEGER NOT NULL,
      gpu_uj           INTEGER,
      attributed_uj    INTEGER NOT NULL,
      tail_uj          INTEGER NOT NULL,
      residual_uj      INTEGER GENERATED ALWAYS AS (sys_uj - att_cov_uj) VIRTUAL,
      readable_avg     INTEGER NOT NULL,
      unreadable_avg   INTEGER NOT NULL,
      charge_used_mah  INTEGER,
      voltage_mv_avg   INTEGER,
      fcc_mah          INTEGER,
      thermal_max      INTEGER,
      PRIMARY KEY (t_hour, source)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS energy_burst (
      start_s          INTEGER NOT NULL,
      end_s            INTEGER NOT NULL CHECK (end_s > start_s),
      cpu_uj           INTEGER,
      dram_uj          INTEGER,
      ane_uj           INTEGER,
      readable_cpu_uj  INTEGER NOT NULL,
      covered_ms       INTEGER NOT NULL,
      PRIMARY KEY (start_s)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS sampling_gap (
      start_s INTEGER NOT NULL,
      end_s   INTEGER NOT NULL CHECK (end_s >= start_s),
      reason  TEXT NOT NULL CHECK (reason IN ('sleep', 'suspended', 'not_running', 'clock_jump')),
      PRIMARY KEY (start_s, reason)
    ) STRICT, WITHOUT ROWID;
    """

    static let migrations: [Migration] = [
        Migration(version: 1, sql: schemaV1)
    ]

    static func applyPragmasWriter(db: OpaquePointer?) throws {
        try SQLiteBridge.exec(db: db, sql: "PRAGMA synchronous = NORMAL;")
        try SQLiteBridge.exec(db: db, sql: "PRAGMA foreign_keys = ON;")
        try SQLiteBridge.exec(db: db, sql: "PRAGMA cache_size = -512;")
    }

    static func applyPragmasReader(db: OpaquePointer?) throws {
        try SQLiteBridge.exec(db: db, sql: "PRAGMA query_only = 1;")
        try SQLiteBridge.exec(db: db, sql: "PRAGMA busy_timeout = 2000;")
    }

    static func getUserVersion(db: OpaquePointer?) throws -> Int {
        let stmt = try SQLiteBridge.prepare(db: db, sql: "PRAGMA user_version;")
        defer { SQLiteBridge.finalize(stmt: stmt) }
        if try SQLiteBridge.step(stmt: stmt, db: db) {
            return Int(SQLiteBridge.columnInt64(stmt: stmt, index: 0))
        }
        return 0
    }

    static func setUserVersion(db: OpaquePointer?, version: Int) throws {
        try SQLiteBridge.exec(db: db, sql: "PRAGMA user_version = \(version);")
    }

    static func quickCheck(db: OpaquePointer?) throws -> Bool {
        let stmt = try SQLiteBridge.prepare(db: db, sql: "PRAGMA quick_check;")
        defer { SQLiteBridge.finalize(stmt: stmt) }
        if try SQLiteBridge.step(stmt: stmt, db: db) {
            let res = SQLiteBridge.columnText(stmt: stmt, index: 0)
            return res.lowercased() == "ok"
        }
        return false
    }

    static func migrateWriter(db: OpaquePointer?, now: Date) throws {
        let version = try getUserVersion(db: db)
        if version > currentVersion {
            throw LedgerError.unsupportedSchemaVersion(version: version)
        }

        for migration in migrations where migration.version > version {
            try SQLiteBridge.exec(db: db, sql: "BEGIN IMMEDIATE;")
            do {
                try SQLiteBridge.exec(db: db, sql: migration.sql)
                if migration.version == 1 {
                    let nowS = Int64(floor(now.timeIntervalSince1970))
                    try SQLiteBridge.exec(db: db, sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('reader_compat', '\(readerCompatVersion)');")
                    try SQLiteBridge.exec(db: db, sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('rolled_through_hour', '0');")
                    try SQLiteBridge.exec(db: db, sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('created_at', '\(nowS)');")
                }
                try setUserVersion(db: db, version: migration.version)
                try SQLiteBridge.exec(db: db, sql: "COMMIT;")
            } catch {
                _ = try? SQLiteBridge.exec(db: db, sql: "ROLLBACK;")
                throw error
            }
        }
    }
}

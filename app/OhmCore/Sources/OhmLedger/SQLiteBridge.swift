import Foundation
import SQLite3

internal let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

internal enum SQLiteBridge {
    @discardableResult
    static func exec(db: OpaquePointer?, sql: String) throws -> Int32 {
        guard let db = db else { throw LedgerError.closed }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message: String
            if let errMsg = errMsg {
                message = String(cString: errMsg)
                sqlite3_free(errMsg)
            } else {
                message = String(cString: sqlite3_errmsg(db))
            }
            if rc == SQLITE_READONLY {
                throw LedgerError.readOnlyViolation
            }
            throw LedgerError.sqliteError(code: rc, message: message)
        }
        return rc
    }

    static func prepare(db: OpaquePointer?, sql: String) throws -> OpaquePointer {
        guard let db = db else { throw LedgerError.closed }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt = stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            if rc == SQLITE_READONLY {
                throw LedgerError.readOnlyViolation
            }
            throw LedgerError.sqliteError(code: rc, message: message)
        }
        return stmt
    }

    static func bindInt64(stmt: OpaquePointer?, index: Int32, value: Int64) throws {
        guard let stmt = stmt else { throw LedgerError.closed }
        let rc = sqlite3_bind_int64(stmt, index, value)
        if rc != SQLITE_OK {
            throw LedgerError.sqliteError(code: rc, message: "sqlite3_bind_int64 failed at index \(index)")
        }
    }

    static func bindInt64OrNil(stmt: OpaquePointer?, index: Int32, value: Int64?) throws {
        if let val = value {
            try bindInt64(stmt: stmt, index: index, value: val)
        } else {
            try bindNull(stmt: stmt, index: index)
        }
    }

    static func bindDouble(stmt: OpaquePointer?, index: Int32, value: Double) throws {
        guard let stmt = stmt else { throw LedgerError.closed }
        let rc = sqlite3_bind_double(stmt, index, value)
        if rc != SQLITE_OK {
            throw LedgerError.sqliteError(code: rc, message: "sqlite3_bind_double failed at index \(index)")
        }
    }

    static func bindDoubleOrNil(stmt: OpaquePointer?, index: Int32, value: Double?) throws {
        if let val = value {
            try bindDouble(stmt: stmt, index: index, value: val)
        } else {
            try bindNull(stmt: stmt, index: index)
        }
    }

    static func bindText(stmt: OpaquePointer?, index: Int32, value: String) throws {
        guard let stmt = stmt else { throw LedgerError.closed }
        let rc = sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        if rc != SQLITE_OK {
            throw LedgerError.sqliteError(code: rc, message: "sqlite3_bind_text failed at index \(index)")
        }
    }

    static func bindTextOrNil(stmt: OpaquePointer?, index: Int32, value: String?) throws {
        if let val = value {
            try bindText(stmt: stmt, index: index, value: val)
        } else {
            try bindNull(stmt: stmt, index: index)
        }
    }

    static func bindNull(stmt: OpaquePointer?, index: Int32) throws {
        guard let stmt = stmt else { throw LedgerError.closed }
        let rc = sqlite3_bind_null(stmt, index)
        if rc != SQLITE_OK {
            throw LedgerError.sqliteError(code: rc, message: "sqlite3_bind_null failed at index \(index)")
        }
    }

    static func step(stmt: OpaquePointer?, db: OpaquePointer?) throws -> Bool {
        guard let stmt = stmt else { throw LedgerError.closed }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return true
        } else if rc == SQLITE_DONE {
            return false
        } else {
            let message = db != nil ? String(cString: sqlite3_errmsg(db)) : "Step failed with code \(rc)"
            if rc == SQLITE_READONLY {
                throw LedgerError.readOnlyViolation
            }
            throw LedgerError.sqliteError(code: rc, message: message)
        }
    }

    static func stepDone(stmt: OpaquePointer?, db: OpaquePointer?) throws {
        _ = try step(stmt: stmt, db: db)
    }

    static func columnType(stmt: OpaquePointer?, index: Int32) -> Int32 {
        guard let stmt = stmt else { return SQLITE_NULL }
        return sqlite3_column_type(stmt, index)
    }

    static func columnInt64(stmt: OpaquePointer?, index: Int32) -> Int64 {
        guard let stmt = stmt else { return 0 }
        return sqlite3_column_int64(stmt, index)
    }

    static func columnInt64OrNil(stmt: OpaquePointer?, index: Int32) -> Int64? {
        if columnType(stmt: stmt, index: index) == SQLITE_NULL {
            return nil
        }
        return columnInt64(stmt: stmt, index: index)
    }

    static func columnDouble(stmt: OpaquePointer?, index: Int32) -> Double {
        guard let stmt = stmt else { return 0.0 }
        return sqlite3_column_double(stmt, index)
    }

    static func columnDoubleOrNil(stmt: OpaquePointer?, index: Int32) -> Double? {
        if columnType(stmt: stmt, index: index) == SQLITE_NULL {
            return nil
        }
        return columnDouble(stmt: stmt, index: index)
    }

    static func columnText(stmt: OpaquePointer?, index: Int32) -> String {
        guard let stmt = stmt, let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    static func columnTextOrNil(stmt: OpaquePointer?, index: Int32) -> String? {
        if columnType(stmt: stmt, index: index) == SQLITE_NULL {
            return nil
        }
        return columnText(stmt: stmt, index: index)
    }

    static func finalize(stmt: OpaquePointer?) {
        if let stmt = stmt {
            sqlite3_finalize(stmt)
        }
    }
}

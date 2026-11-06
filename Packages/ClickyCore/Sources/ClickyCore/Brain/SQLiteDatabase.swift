import Foundation
import SQLite3

/// A value bound to a `?` placeholder.
enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

/// What can go wrong opening or using the brain index database.
public enum BrainIndexError: Error, Equatable, LocalizedError {
    case databaseMissing(path: String)
    case sqlite(message: String)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing(let path):
            return "The brain index has not been built yet (no file at \(path))."
        case .sqlite(let message):
            return "The brain index failed: \(message)"
        }
    }
}

/// One result row, read column by column while the statement is stepping.
struct SQLiteRow {
    fileprivate let statementHandle: OpaquePointer

    func integer(at columnIndex: Int32) -> Int64 { sqlite3_column_int64(statementHandle, columnIndex) }
    func real(at columnIndex: Int32) -> Double { sqlite3_column_double(statementHandle, columnIndex) }
    func isNull(at columnIndex: Int32) -> Bool { sqlite3_column_type(statementHandle, columnIndex) == SQLITE_NULL }
    func text(at columnIndex: Int32) -> String? {
        guard let rawText = sqlite3_column_text(statementHandle, columnIndex) else { return nil }
        return String(cString: rawText)
    }
}

/// A prepared statement that can be run many times (the bulk insert of chunks reuses one).
final class SQLiteStatement {
    private var handle: OpaquePointer?
    private unowned let database: SQLiteDatabase

    fileprivate init(database: SQLiteDatabase, sql: String) throws {
        self.database = database
        guard sqlite3_prepare_v2(database.handle, sql, -1, &handle, nil) == SQLITE_OK else {
            throw database.lastError()
        }
    }

    deinit { sqlite3_finalize(handle) }

    private func bind(_ parameters: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        // SQLite must copy bound text: the Swift string is gone after the call.
        let copyTheBytes = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for parameterIndex in 0..<parameters.count {
            let position = Int32(parameterIndex + 1)
            let resultCode: Int32
            switch parameters[parameterIndex] {
            case .integer(let value): resultCode = sqlite3_bind_int64(handle, position, value)
            case .real(let value): resultCode = sqlite3_bind_double(handle, position, value)
            case .text(let value): resultCode = sqlite3_bind_text(handle, position, value, -1, copyTheBytes)
            case .null: resultCode = sqlite3_bind_null(handle, position)
            }
            guard resultCode == SQLITE_OK else { throw database.lastError() }
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ parameters: [SQLiteValue] = []) throws {
        try bind(parameters)
        let resultCode = sqlite3_step(handle)
        sqlite3_reset(handle)
        guard resultCode == SQLITE_DONE || resultCode == SQLITE_ROW else { throw database.lastError() }
    }

    /// Runs a statement and hands each row to `handleRow`.
    func rows(_ parameters: [SQLiteValue] = [], handleRow: (SQLiteRow) throws -> Void) throws {
        try bind(parameters)
        defer { sqlite3_reset(handle) }
        while true {
            let resultCode = sqlite3_step(handle)
            if resultCode == SQLITE_DONE { return }
            guard resultCode == SQLITE_ROW, let handle else { throw database.lastError() }
            try handleRow(SQLiteRow(statementHandle: handle))
        }
    }
}

/// A thin wrapper over the system SQLite. Not thread safe on its own: `BrainIndex` serialises calls.
final class SQLiteDatabase {
    fileprivate var handle: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        let openFlags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, openFlags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(url.path)"
            sqlite3_close(handle)
            throw BrainIndexError.sqlite(message: message)
        }
        // A helper that reads while the app writes waits a moment instead of failing.
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    func lastError() -> BrainIndexError {
        BrainIndexError.sqlite(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

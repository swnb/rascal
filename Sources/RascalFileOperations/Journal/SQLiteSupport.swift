import Foundation
import SQLite3

package struct SQLiteJournalError: Error, Sendable, Equatable {
    package let code: Int32
    package let message: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

package final class SQLiteStatement {
    private let connection: OpaquePointer
    private let statement: OpaquePointer

    package init(connection: OpaquePointer, sql: String) throws {
        self.connection = connection
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            throw SQLiteJournalError(
                code: result,
                message: String(cString: sqlite3_errmsg(connection))
            )
        }
        statement = prepared
    }

    deinit {
        sqlite3_finalize(statement)
    }

    package func bindNull(_ index: Int32) throws {
        try check(sqlite3_bind_null(statement, index))
    }

    package func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    package func bind(_ value: String, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        try check(result)
    }

    package func bind(_ value: Data, at index: Int32) throws {
        if value.isEmpty {
            try check(sqlite3_bind_zeroblob(statement, index, 0))
            return
        }
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
        }
        try check(result)
    }

    package func step() throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SQLiteJournalError(
                code: result,
                message: String(cString: sqlite3_errmsg(connection))
            )
        }
        return result
    }

    package func reset() throws {
        try check(sqlite3_reset(statement))
        try check(sqlite3_clear_bindings(statement))
    }

    package func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    package func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    package func text(at column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    package func data(at column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteJournalError(
                code: result,
                message: String(cString: sqlite3_errmsg(connection))
            )
        }
    }
}

package final class SQLiteConnection {
    private let handle: OpaquePointer

    package init(url: URL, readOnly: Bool = false) throws {
        var opened: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned no handle"
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteJournalError(code: result, message: message)
        }
        handle = opened
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    package func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
                sqlite3_free(errorMessage)
            } else {
                message = String(cString: sqlite3_errmsg(handle))
            }
            throw SQLiteJournalError(code: result, message: message)
        }
    }

    package func statement(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(connection: handle, sql: sql)
    }

    package var runtimeVersion: String {
        String(cString: sqlite3_libversion())
    }
}

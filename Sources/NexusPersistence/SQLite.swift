import CSQLite
import Foundation

enum SQLValue: Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map(SQLValue.text) ?? .null }
}

extension Optional where Wrapped == Double {
    var sql: SQLValue { map(SQLValue.real) ?? .null }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite connection. Not thread-safe; `NexusStore` serializes access.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(handle)
            throw StoreError.sqlite(code: code, message: message)
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if code != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw StoreError.sqlite(code: code, message: message)
        }
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], row: (Statement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try row(statement))
        }
        return rows
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: code, message: lastErrorMessage)
        }
        return Statement(statement, connection: self)
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    final class Statement {
        private let handle: OpaquePointer
        private let connection: SQLiteConnection

        fileprivate init(_ handle: OpaquePointer, connection: SQLiteConnection) {
            self.handle = handle
            self.connection = connection
        }

        deinit {
            sqlite3_finalize(handle)
        }

        func bind(_ values: [SQLValue]) throws {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch value {
                case .null: code = sqlite3_bind_null(handle, index)
                case .int(let int): code = sqlite3_bind_int64(handle, index, int)
                case .real(let real): code = sqlite3_bind_double(handle, index, real)
                case .text(let text): code = sqlite3_bind_text(handle, index, text, -1, transient)
                }
                guard code == SQLITE_OK else {
                    throw StoreError.sqlite(code: code, message: connection.lastErrorMessage)
                }
            }
        }

        /// Advances the statement. Returns true while a row is available.
        func step() throws -> Bool {
            let code = sqlite3_step(handle)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw StoreError.sqlite(code: code, message: connection.lastErrorMessage)
            }
        }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(handle, column)
        }

        func real(_ column: Int32) -> Double {
            sqlite3_column_double(handle, column)
        }
    }
}

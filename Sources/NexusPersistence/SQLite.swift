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
///
/// `run` and `query` keep compiled statements in a small cache keyed by SQL
/// text and reset them after each use, so the store's constant SQL is parsed
/// once per connection rather than once per call.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]
    /// Upper bound on cached statements. Store SQL comes from a small closed
    /// set; the bound only matters for generated `IN (?, ?, …)` lists.
    static let cacheLimit = 128

    init(path: String, readOnly: Bool = false) throws {
        let flags =
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(handle)
            throw StoreError.sqlite(code: code, message: message)
        }
    }

    deinit {
        // Statements must be finalized before the connection closes.
        cache.removeAll()
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
        try withStatement(sql) { statement in
            try statement.bind(values)
            while try statement.step() {}
        }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], row: (Statement) throws -> T) throws -> [T] {
        try withStatement(sql) { statement in
            try statement.bind(values)
            var rows: [T] = []
            while try statement.step() {
                rows.append(try row(statement))
            }
            return rows
        }
    }

    /// Borrows a cached statement for `sql`, compiling it on first use, and
    /// resets it afterwards. A statement already in use further up the stack
    /// (a re-entrant query with the same text) gets a private, uncached copy.
    private func withStatement<T>(_ sql: String, _ body: (Statement) throws -> T) throws -> T {
        let statement: Statement
        if let cached = cache[sql], !cached.inUse {
            statement = cached
        } else {
            statement = try prepare(sql)
            if cache[sql] == nil {
                if cache.count >= Self.cacheLimit {
                    cache = cache.filter { $0.value.inUse }
                }
                cache[sql] = statement
            }
        }
        statement.inUse = true
        defer {
            statement.reset()
            statement.inUse = false
        }
        return try body(statement)
    }

    /// Drops every cached statement, e.g. before closing or after a schema change.
    func clearStatementCache() {
        cache = cache.filter { $0.value.inUse }
    }

    var cachedStatementCount: Int { cache.count }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: code, message: lastErrorMessage)
        }
        return Statement(statement)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    final class Statement {
        private let handle: OpaquePointer
        fileprivate var inUse = false

        fileprivate init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        deinit {
            sqlite3_finalize(handle)
        }

        private var lastErrorMessage: String {
            sqlite3_db_handle(handle).map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
        }

        fileprivate func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
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
                    throw StoreError.sqlite(code: code, message: lastErrorMessage)
                }
            }
        }

        /// Advances the statement. Returns true while a row is available.
        func step() throws -> Bool {
            let code = sqlite3_step(handle)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw StoreError.sqlite(code: code, message: lastErrorMessage)
            }
        }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: pointer)
        }

        /// The column's UTF-8 bytes, copied once, for decoding JSON without an
        /// intermediate `String`.
        func data(_ column: Int32) -> Data? {
            guard let pointer = sqlite3_column_text(handle, column) else { return nil }
            let count = Int(sqlite3_column_bytes(handle, column))
            return Data(bytes: pointer, count: count)
        }

        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(handle, column) == SQLITE_NULL
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(handle, column)
        }

        func real(_ column: Int32) -> Double {
            sqlite3_column_double(handle, column)
        }
    }
}

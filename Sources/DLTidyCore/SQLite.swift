import Foundation
import SQLite3

// Thin wrapper over the SQLite C API. One `Database` per connection, used from one isolation
// domain only (the Engine actor or a CLI invocation).

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite \(code): \(message)" }
}

enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Int32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue {
        switch self {
        case .none: return .null
        case .some(let v): return v.sqlValue
        }
    }
}

final class Statement {
    let handle: OpaquePointer
    private unowned let db: Database

    init(db: Database, sql: String) throws {
        self.db = db
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw db.error(rc, context: sql) }
        handle = stmt
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ args: [any SQLBindable]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            let rc: Int32
            switch arg.sqlValue {
            case .null: rc = sqlite3_bind_null(handle, i)
            case .int(let v): rc = sqlite3_bind_int64(handle, i, v)
            case .double(let v): rc = sqlite3_bind_double(handle, i, v)
            case .text(let v): rc = sqlite3_bind_text(handle, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(handle, i, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard rc == SQLITE_OK else { throw db.error(rc, context: "bind") }
        }
    }

    /// True when a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw db.error(rc, context: String(cString: sqlite3_sql(handle)))
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(handle, i) else { return "" }
        return String(cString: c)
    }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
}

final class Database {
    let handle: OpaquePointer
    let path: String
    private var cache: [String: Statement] = [:]
    private var depth = 0
    private var savepointCounter = 0

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: "\(msg) (\(path))")
        }
        handle = db
        sqlite3_busy_timeout(db, 10_000)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    func error(_ rc: Int32, context: String) -> SQLiteError {
        SQLiteError(code: rc, message: "\(String(cString: sqlite3_errmsg(handle))) [\(context.prefix(120))]")
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: "\(msg) [\(sql.prefix(120))]")
        }
    }

    private func statement(_ sql: String) throws -> Statement {
        if let s = cache[sql] { return s }
        let s = try Statement(db: self, sql: sql)
        cache[sql] = s
        return s
    }

    @discardableResult
    func run(_ sql: String, _ args: any SQLBindable...) throws -> Int {
        try runArgs(sql, args)
    }

    @discardableResult
    func runArgs(_ sql: String, _ args: [any SQLBindable]) throws -> Int {
        let s = try statement(sql)
        try s.bind(args)
        defer { sqlite3_reset(s.handle) }
        while try s.step() {}
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ args: [any SQLBindable] = [], _ map: (Statement) throws -> T) throws -> [T] {
        let s = try statement(sql)
        try s.bind(args)
        defer { sqlite3_reset(s.handle) }
        var out: [T] = []
        while try s.step() { out.append(try map(s)) }
        return out
    }

    func scalarInt(_ sql: String, _ args: any SQLBindable...) throws -> Int64? {
        try query(sql, args) { $0.optInt(0) }.first ?? nil
    }

    func scalarDouble(_ sql: String, _ args: any SQLBindable...) throws -> Double? {
        try query(sql, args) { $0.optDouble(0) }.first ?? nil
    }

    func scalarText(_ sql: String, _ args: any SQLBindable...) throws -> String? {
        try query(sql, args) { $0.optText(0) }.first ?? nil
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` in a transaction (BEGIN IMMEDIATE at the outer level, a savepoint when nested).
    /// A thrown error rolls back.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth == 0 {
            try execute("BEGIN IMMEDIATE")
            depth = 1
            do {
                let value = try body()
                depth = 0
                try execute("COMMIT")
                return value
            } catch {
                depth = 0
                try? execute("ROLLBACK")
                throw error
            }
        }
        savepointCounter += 1
        let name = "sp\(savepointCounter)"
        try execute("SAVEPOINT \(name)")
        depth += 1
        do {
            let value = try body()
            depth -= 1
            try execute("RELEASE \(name)")
            return value
        } catch {
            depth -= 1
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    func quickCheck() -> Bool {
        (try? query("PRAGMA quick_check") { $0.text(0) }) == ["ok"]
    }
}

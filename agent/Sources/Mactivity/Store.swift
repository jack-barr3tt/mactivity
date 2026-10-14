import Foundation
import SQLite3

struct Snapshot: Equatable {
    var appName: String
    var bundleID: String
    var windowTitle: String?
    var url: String?
    var hostname: String?
}

final class Store {
    private var db: OpaquePointer?
    private var last: Snapshot?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    convenience init() throws {
        try self.init(databasePath: Self.databasePath(), schemaPath: try Self.schemaPath())
    }

    init(databasePath: String, schemaPath: String) throws {
        let path = databasePath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let opened = sqlite3_open_v2(path, &handle, flags, nil)
        guard opened == SQLITE_OK, let openedHandle = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
            if let handle {
                sqlite3_close(handle)
            }
            throw StoreError.open(message)
        }
        db = openedHandle

        try exec("PRAGMA journal_mode=WAL")
        sqlite3_busy_timeout(openedHandle, 5000)
        try exec(try String(contentsOfFile: schemaPath, encoding: .utf8))
        try closeOpen(at: Self.now())
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func stop() {
        try? closeOpen(at: Self.now())
        last = nil
    }

    @discardableResult
    func record(_ snapshot: Snapshot) throws -> Bool {
        if last == snapshot {
            return false
        }
        let ms = Self.now()
        try exec("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        try closeOpen(at: ms)
        try insert(snapshot, startedAt: ms)
        try exec("COMMIT")
        committed = true
        last = snapshot
        return true
    }

    private func closeOpen(at ms: Int64) throws {
        let sql = "UPDATE segments SET ended_at = ? WHERE ended_at IS NULL"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ms)
        try stepDone(stmt)
    }

    private func insert(_ snapshot: Snapshot, startedAt ms: Int64) throws {
        let sql = """
        INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname)
        VALUES (?, NULL, ?, ?, ?, ?, ?)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ms)
        bindText(stmt, 2, snapshot.appName)
        bindText(stmt, 3, snapshot.bundleID)
        bindText(stmt, 4, snapshot.windowTitle)
        bindText(stmt, 5, snapshot.url)
        bindText(stmt, 6, snapshot.hostname)
        try stepDone(stmt)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(message())
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqlite(message())
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(message())
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        _ = value.withCString { cString in
            sqlite3_bind_text(stmt, index, cString, -1, transient)
        }
    }

    private func message() -> String {
        guard let db else { return "sqlite closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func databasePath() -> String {
        if let override = ProcessInfo.processInfo.environment["MACTIVITY_DB"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/mactivity/activity.db")
            .path
    }

    private static func schemaPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MACTIVITY_SCHEMA"], !override.isEmpty {
            return override
        }
        if let bundled = Bundle.main.url(forResource: "schema", withExtension: "sql") {
            return bundled.path
        }
        throw StoreError.schema("schema.sql is not in the app bundle")
    }
}

enum StoreError: Error, CustomStringConvertible, LocalizedError {
    case open(String)
    case sqlite(String)
    case schema(String)

    var description: String {
        switch self {
        case .open(let message):
            return "open database: \(message)"
        case .sqlite(let message):
            return message
        case .schema(let message):
            return message
        }
    }

    var errorDescription: String? { description }
}

import Foundation
import SQLite3

struct Snapshot: Equatable {
    var appName: String
    var bundleID: String
    var windowTitle: String?
    var url: String?
    var hostname: String?
}

struct WrittenSegment {
    var id: Int64
    var label: WindowLabel?
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
        try ensureLabelColumns()
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

    func endOpen(at ms: Int64) throws {
        try exec("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        try closeOpen(at: ms, clampToStart: true)
        try exec("COMMIT")
        committed = true
        last = nil
    }

    @discardableResult
    func record(_ snapshot: Snapshot, reuseLabel: Bool = true) throws -> WrittenSegment? {
        if last == snapshot {
            return nil
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
        let label = reuseLabel ? try cachedLabel(snapshot) : nil
        let id = try insert(snapshot, startedAt: ms, label: label)
        try exec("COMMIT")
        committed = true
        last = snapshot
        return WrittenSegment(id: id, label: label)
    }

    func needsLabel(id: Int64) throws -> Bool {
        let stmt = try prepare("SELECT category IS NULL OR work_related IS NULL FROM segments WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) != 0
    }

    func applyCachedLabel(id: Int64, snapshot: Snapshot) throws -> WindowLabel? {
        guard try needsLabel(id: id), let label = try cachedLabel(snapshot) else { return nil }
        try setLabel(id: id, label)
        return label
    }

    func setLabel(id: Int64, _ label: WindowLabel) throws {
        let stmt = try prepare("UPDATE segments SET category = ?, work_related = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, label.category)
        sqlite3_bind_int64(stmt, 2, label.workRelated ? 1 : 0)
        sqlite3_bind_int64(stmt, 3, id)
        try stepDone(stmt)
    }

    private func closeOpen(at ms: Int64, clampToStart: Bool = false) throws {
        let sql = clampToStart
            ? "UPDATE segments SET ended_at = MAX(?, started_at) WHERE ended_at IS NULL"
            : "UPDATE segments SET ended_at = ? WHERE ended_at IS NULL"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ms)
        try stepDone(stmt)
    }

    private func insert(_ snapshot: Snapshot, startedAt ms: Int64, label: WindowLabel?) throws -> Int64 {
        let sql = """
        INSERT INTO segments (
            started_at, ended_at, app_name, bundle_id, window_title, url, hostname, category, work_related
        )
        VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ms)
        bindText(stmt, 2, snapshot.appName)
        bindText(stmt, 3, snapshot.bundleID)
        bindText(stmt, 4, snapshot.windowTitle)
        bindText(stmt, 5, snapshot.url)
        bindText(stmt, 6, snapshot.hostname)
        bindText(stmt, 7, label?.category)
        if let label {
            sqlite3_bind_int64(stmt, 8, label.workRelated ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        try stepDone(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    private func cachedLabel(_ snapshot: Snapshot) throws -> WindowLabel? {
        let sql = """
        SELECT category, work_related FROM segments
        WHERE app_name = ? AND bundle_id = ?
          AND window_title IS ? AND url IS ? AND hostname IS ?
          AND category IS NOT NULL AND work_related IS NOT NULL
        ORDER BY id DESC
        LIMIT 1
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, snapshot.appName)
        bindText(stmt, 2, snapshot.bundleID)
        bindText(stmt, 3, snapshot.windowTitle)
        bindText(stmt, 4, snapshot.url)
        bindText(stmt, 5, snapshot.hostname)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let raw = sqlite3_column_text(stmt, 0) else { return nil }
        return WindowLabel(category: String(cString: raw), workRelated: sqlite3_column_int64(stmt, 1) != 0)
    }

    private func ensureLabelColumns() throws {
        let present = try columnNames()
        if !present.contains("category") {
            try exec("ALTER TABLE segments ADD COLUMN category TEXT")
        }
        if !present.contains("work_related") {
            try exec("ALTER TABLE segments ADD COLUMN work_related INTEGER")
        }
    }

    private func columnNames() throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(segments)")
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 1) else { continue }
            names.insert(String(cString: raw))
        }
        return names
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

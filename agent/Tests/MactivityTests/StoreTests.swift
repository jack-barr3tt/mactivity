import SQLite3
import XCTest

@testable import Mactivity

final class StoreTests: XCTestCase {
    func testRecordClosesPreviousSegment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schema = root.appendingPathComponent("db/schema.sql").path
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactivity-\(UUID().uuidString).db")
            .path
        let store = try Store(databasePath: database, schemaPath: schema)

        let first = Snapshot(appName: "Slack", bundleID: "com.slack", windowTitle: "general", url: nil, hostname: nil)
        let second = Snapshot(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Jira",
            url: "https://acme.atlassian.net/jira",
            hostname: "acme.atlassian.net"
        )
        XCTAssertNotNil(try store.record(first))
        XCTAssertNil(try store.record(first))
        XCTAssertNotNil(try store.record(second))
        store.stop()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "SELECT COUNT(*), SUM(ended_at IS NULL) FROM segments", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 2)
        XCTAssertEqual(sqlite3_column_int(stmt, 1), 0)
    }

    func testEndOpenAllowsSameSnapshotAgain() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Spotify", bundleID: "com.spotify.client", windowTitle: "track", url: nil, hostname: nil)
        XCTAssertNotNil(try store.record(snapshot))
        try store.endOpen(at: 9_000_000_000_000)
        XCTAssertNotNil(try store.record(snapshot))

        let rows = try segments(database)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[0].ended)
        XCTAssertNil(rows[1].ended)
        XCTAssertGreaterThan(rows[0].ended ?? 0, rows[0].started)
    }

    func testEndOpenTwiceDoesNotInsert() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        XCTAssertNotNil(try store.record(snapshot))
        try store.endOpen(at: 9_000_000_000_000)
        try store.endOpen(at: 9_000_000_000_001)
        let rows = try segments(database)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].ended)
    }

    func testEndOpenClampsBeforeStart() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        XCTAssertNotNil(try store.record(snapshot))
        try store.endOpen(at: 1)
        let rows = try segments(database)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ended, rows[0].started)
    }

    func testRecordLeavesLabelEmpty() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        let written = try XCTUnwrap(store.record(snapshot))
        XCTAssertNil(written.label)
        XCTAssertTrue(try store.needsLabel(id: written.id))
        let rows = try labels(database)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].category)
        XCTAssertNil(rows[0].work)
    }

    func testRecordCopiesPreviousLabel() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(
            appName: "Slack",
            bundleID: "com.slack",
            windowTitle: "general",
            url: nil,
            hostname: nil
        )
        let first = try XCTUnwrap(store.record(snapshot))
        try store.setLabel(id: first.id, WindowLabel(category: "communication", workRelated: true))
        try store.endOpen(at: 9_000_000_000_000)
        let second = try XCTUnwrap(store.record(snapshot))
        XCTAssertEqual(second.label, WindowLabel(category: "communication", workRelated: true))
        XCTAssertFalse(try store.needsLabel(id: second.id))
        let rows = try labels(database)
        XCTAssertEqual(rows[1].category, "communication")
        XCTAssertEqual(rows[1].work, true)
    }

    func testRecordSkipsCachedLabelWhenReuseIsOff() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Slack", bundleID: "com.slack", windowTitle: "general", url: nil, hostname: nil)
        let first = try XCTUnwrap(store.record(snapshot))
        try store.setLabel(id: first.id, WindowLabel(category: "communication", workRelated: true))
        try store.endOpen(at: 9_000_000_000_000)
        let second = try XCTUnwrap(store.record(snapshot, reuseLabel: false))
        XCTAssertNil(second.label)
        let rows = try labels(database)
        XCTAssertNil(rows[1].category)
        let copied = try store.applyCachedLabel(id: second.id, snapshot: snapshot)
        XCTAssertEqual(copied, WindowLabel(category: "communication", workRelated: true))
    }

    func testDifferentTitleDoesNotCopyLabel() throws {
        let (store, database) = try makeStore()
        let first = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        let written = try XCTUnwrap(store.record(first))
        try store.setLabel(id: written.id, WindowLabel(category: "code", workRelated: true))
        try store.endOpen(at: 9_000_000_000_000)
        let renamed = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "other", url: nil, hostname: nil)
        let next = try XCTUnwrap(store.record(renamed))
        XCTAssertNil(next.label)
        let rows = try labels(database)
        XCTAssertNil(rows[1].category)
    }

    func testSetLabelUpdatesClosedSegment() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        let written = try XCTUnwrap(store.record(snapshot))
        try store.endOpen(at: 9_000_000_000_000)
        try store.setLabel(id: written.id, WindowLabel(category: "code", workRelated: false))
        let rows = try labels(database)
        XCTAssertEqual(rows[0].category, "code")
        XCTAssertEqual(rows[0].work, false)
        XCTAssertFalse(try store.needsLabel(id: written.id))
    }

    func testOpenAddsLabelColumns() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactivity-\(UUID().uuidString).db")
            .path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let legacy = """
        CREATE TABLE segments (
            id INTEGER PRIMARY KEY,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            app_name TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            window_title TEXT,
            url TEXT,
            hostname TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let (store, _) = try makeStore(database: database)
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        let written = try XCTUnwrap(store.record(snapshot))
        try store.setLabel(id: written.id, WindowLabel(category: "docs", workRelated: true))
        let rows = try labels(database)
        XCTAssertEqual(rows[0].category, "docs")
        XCTAssertEqual(rows[0].work, true)
    }

    private func makeStore() throws -> (Store, String) {
        try makeStore(database: nil)
    }

    private func makeStore(database override: String?) throws -> (Store, String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schema = root.appendingPathComponent("db/schema.sql").path
        let database = override ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("mactivity-\(UUID().uuidString).db")
            .path
        return (try Store(databasePath: database, schemaPath: schema), database)
    }

    private func labels(_ database: String) throws -> [(category: String?, work: Bool?)] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "SELECT category, work_related FROM segments ORDER BY id", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        var rows: [(category: String?, work: Bool?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let category: String?
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
                category = nil
            } else if let raw = sqlite3_column_text(stmt, 0) {
                category = String(cString: raw)
            } else {
                category = nil
            }
            let work: Bool? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 1) != 0
            rows.append((category, work))
        }
        return rows
    }

    private func segments(_ database: String) throws -> [(started: Int64, ended: Int64?)] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "SELECT started_at, ended_at FROM segments ORDER BY id", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        var rows: [(started: Int64, ended: Int64?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let started = sqlite3_column_int64(stmt, 0)
            let ended: Int64? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
            rows.append((started, ended))
        }
        return rows
    }
}

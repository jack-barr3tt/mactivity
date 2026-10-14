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
        XCTAssertTrue(try store.record(first))
        XCTAssertFalse(try store.record(first))
        XCTAssertTrue(try store.record(second))
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
        XCTAssertTrue(try store.record(snapshot))
        try store.endOpen(at: 9_000_000_000_000)
        XCTAssertTrue(try store.record(snapshot))

        let rows = try segments(database)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[0].ended)
        XCTAssertNil(rows[1].ended)
        XCTAssertGreaterThan(rows[0].ended ?? 0, rows[0].started)
    }

    func testEndOpenTwiceDoesNotInsert() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        XCTAssertTrue(try store.record(snapshot))
        try store.endOpen(at: 9_000_000_000_000)
        try store.endOpen(at: 9_000_000_000_001)
        let rows = try segments(database)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].ended)
    }

    func testEndOpenClampsBeforeStart() throws {
        let (store, database) = try makeStore()
        let snapshot = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
        XCTAssertTrue(try store.record(snapshot))
        try store.endOpen(at: 1)
        let rows = try segments(database)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ended, rows[0].started)
    }

    private func makeStore() throws -> (Store, String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schema = root.appendingPathComponent("db/schema.sql").path
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactivity-\(UUID().uuidString).db")
            .path
        return (try Store(databasePath: database, schemaPath: schema), database)
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

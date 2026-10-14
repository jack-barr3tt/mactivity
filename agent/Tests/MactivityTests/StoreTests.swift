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
}

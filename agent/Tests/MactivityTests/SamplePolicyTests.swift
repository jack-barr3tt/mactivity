import XCTest

@testable import Mactivity

final class SamplePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let timeout: TimeInterval = 120
    private let cursor = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
    private let spotify = Snapshot(appName: "Spotify", bundleID: "com.spotify.client", windowTitle: "track", url: nil, hostname: nil)

    func testActiveSameSnapshotDoesNothing() {
        let state = SampleState(open: true, heldForVideo: false, last: cursor)
        let (next, action) = step(state, cursor, idle: 10, video: false)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(next, state)
    }

    func testActiveChangeRecords() {
        let state = SampleState(open: true, heldForVideo: true, last: cursor)
        let (next, action) = step(state, spotify, idle: 1, video: true)
        XCTAssertEqual(action, .record(spotify))
        XCTAssertEqual(next, SampleState(open: true, heldForVideo: false, last: spotify))
    }

    func testResumeAfterIdleRecords() {
        let (next, action) = step(SampleState(), cursor, idle: 0, video: false)
        XCTAssertEqual(action, .record(cursor))
        XCTAssertTrue(next.open)
        XCTAssertFalse(next.heldForVideo)
    }

    func testIdleWithoutVideoEndsAtLastInputPlusTimeout() {
        let state = SampleState(open: true, heldForVideo: false, last: spotify)
        let (next, action) = step(state, spotify, idle: 125, video: false)
        XCTAssertEqual(action, .end(at: now.addingTimeInterval(-5)))
        XCTAssertEqual(next, SampleState())
    }

    func testIdleEndsAtGraceRatherThanTheFullTimeout() {
        let state = SampleState(open: true, heldForVideo: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(snapshot: spotify, now: now, idle: 310, video: false, timeout: 300, grace: 120)
        )
        XCTAssertEqual(action, .end(at: now.addingTimeInterval(120 - 310)))
        XCTAssertEqual(next, SampleState())
    }

    func testGraceDoesNotCutBeforeTheIdleTimeout() {
        let state = SampleState(open: true, heldForVideo: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(snapshot: spotify, now: now, idle: 180, video: false, timeout: 300, grace: 120)
        )
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
    }

    func testIdleTitleChangeDoesNotOpenSegment() {
        let (next, action) = step(SampleState(), spotify, idle: 200, video: false)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(next.open)
    }

    func testFocusedVideoHoldsOpenSegment() {
        let state = SampleState(open: true, heldForVideo: false, last: cursor)
        let (next, action) = step(state, cursor, idle: 400, video: true)
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
        XCTAssertTrue(next.heldForVideo)
    }

    func testVideoWhileIdleOpensSegment() {
        let (next, action) = step(SampleState(), cursor, idle: 400, video: true)
        XCTAssertEqual(action, .record(cursor))
        XCTAssertTrue(next.heldForVideo)
    }

    func testVideoStopEndsAtSampleTime() {
        let state = SampleState(open: true, heldForVideo: true, last: cursor)
        let (next, action) = step(state, cursor, idle: 400, video: false)
        XCTAssertEqual(action, .end(at: now))
        XCTAssertEqual(next, SampleState())
    }

    private func step(
        _ state: SampleState,
        _ snapshot: Snapshot,
        idle: TimeInterval,
        video: Bool
    ) -> (SampleState, SampleAction) {
        SamplePolicy.step(
            state: state,
            input: SampleInput(snapshot: snapshot, now: now, idle: idle, video: video, timeout: timeout, grace: timeout)
        )
    }
}

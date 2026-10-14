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
            input: SampleInput(
                snapshot: spotify, now: now, idle: 310, video: false, timeout: 300, grace: 120, undoWindow: nil
            )
        )
        XCTAssertEqual(action, .end(at: now.addingTimeInterval(120 - 310)))
        XCTAssertEqual(next, SampleState())
    }

    func testGraceDoesNotCutBeforeTheIdleTimeout() {
        let state = SampleState(open: true, heldForVideo: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: spotify, now: now, idle: 180, video: false, timeout: 300, grace: 120, undoWindow: nil
            )
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

    func testVideoStopWithUndoNotifiesAtSampleTime() {
        let state = SampleState(open: true, heldForVideo: true, last: cursor)
        let (next, action) = step(state, cursor, idle: 400, video: false, undo: 10)
        XCTAssertEqual(action, .notifyIdle(endAt: now))
        XCTAssertEqual(next.pendingEnd, now)
        XCTAssertTrue(next.open)
        XCTAssertEqual(next.last, cursor)
    }

    func testIdleWithUndoNotifiesWithoutEnding() {
        let state = SampleState(open: true, heldForVideo: false, last: spotify)
        let (next, action) = step(state, spotify, idle: 125, video: false, undo: 10)
        let end = now.addingTimeInterval(-5)
        XCTAssertEqual(action, .notifyIdle(endAt: end))
        XCTAssertEqual(next.pendingEnd, end)
        XCTAssertEqual(next.pendingUntil, now.addingTimeInterval(10))
        XCTAssertTrue(next.open)
        XCTAssertEqual(next.last, spotify)
    }

    func testUndoWaitDoesNotNotifyAgain() {
        let pending = pendingSpotify()
        let (next, action) = step(pending, spotify, idle: 129, video: false, at: now.addingTimeInterval(4), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(next.pendingEnd, pending.pendingEnd)
        XCTAssertEqual(next.pendingUntil, pending.pendingUntil)
        XCTAssertEqual(next.last, spotify)
    }

    func testActivityDuringUndoKeepsSameSegment() {
        let (next, action) = step(pendingSpotify(), spotify, idle: 0, video: false, at: now.addingTimeInterval(3), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
        XCTAssertNil(next.pendingEnd)
        XCTAssertNil(next.pendingUntil)
        XCTAssertEqual(next.last, spotify)
    }

    func testFocusChangeDuringUndoRecords() {
        let (next, action) = step(pendingSpotify(), cursor, idle: 0, video: false, at: now.addingTimeInterval(3), undo: 10)
        XCTAssertEqual(action, .record(cursor))
        XCTAssertNil(next.pendingEnd)
        XCTAssertEqual(next.last, cursor)
        XCTAssertTrue(next.open)
    }

    func testTitleChangeDuringUndoDoesNotCancel() {
        let renamed = Snapshot(
            appName: "Spotify",
            bundleID: "com.spotify.client",
            windowTitle: "other",
            url: nil,
            hostname: nil
        )
        let pending = pendingSpotify()
        let (next, action) = step(pending, renamed, idle: 140, video: false, at: now.addingTimeInterval(3), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(next.last, spotify)
        XCTAssertEqual(next.pendingEnd, pending.pendingEnd)
        XCTAssertEqual(next.pendingUntil, pending.pendingUntil)
    }

    func testUndoDeadlineEndsAtOriginalCutoff() {
        let end = now.addingTimeInterval(-5)
        let (next, action) = step(
            pendingSpotify(),
            spotify,
            idle: 135,
            video: false,
            at: now.addingTimeInterval(10),
            undo: 10
        )
        XCTAssertEqual(action, .end(at: end))
        XCTAssertEqual(next, SampleState())
    }

    func testVideoDuringUndoCancels() {
        let (next, action) = step(pendingSpotify(), spotify, idle: 130, video: true, at: now.addingTimeInterval(3), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
        XCTAssertTrue(next.heldForVideo)
        XCTAssertNil(next.pendingEnd)
        XCTAssertEqual(next.last, spotify)
    }

    func testIdleWithUndoUsesGraceForTheCutoff() {
        let state = SampleState(open: true, heldForVideo: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: spotify,
                now: now,
                idle: 310,
                video: false,
                timeout: 300,
                grace: 120,
                undoWindow: 10
            )
        )
        let end = now.addingTimeInterval(120 - 310)
        XCTAssertEqual(action, .notifyIdle(endAt: end))
        XCTAssertEqual(next.pendingEnd, end)
        XCTAssertTrue(next.open)
    }

    private func pendingSpotify() -> SampleState {
        SampleState(
            open: true,
            heldForVideo: false,
            last: spotify,
            pendingEnd: now.addingTimeInterval(-5),
            pendingUntil: now.addingTimeInterval(10)
        )
    }

    private func step(
        _ state: SampleState,
        _ snapshot: Snapshot,
        idle: TimeInterval,
        video: Bool,
        at time: Date? = nil,
        undo: TimeInterval? = nil
    ) -> (SampleState, SampleAction) {
        SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: snapshot,
                now: time ?? now,
                idle: idle,
                video: video,
                timeout: timeout,
                grace: timeout,
                undoWindow: undo
            )
        )
    }
}

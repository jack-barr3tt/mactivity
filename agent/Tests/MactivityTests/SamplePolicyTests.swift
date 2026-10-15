import XCTest

@testable import Mactivity

final class SamplePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let timeout: TimeInterval = 120
    private let cursor = Snapshot(appName: "Cursor", bundleID: "com.cursor", windowTitle: "main", url: nil, hostname: nil)
    private let spotify = Snapshot(appName: "Spotify", bundleID: "com.spotify.client", windowTitle: "track", url: nil, hostname: nil)

    func testActiveSameSnapshotDoesNothing() {
        let state = SampleState(open: true, held: false, last: cursor)
        let (next, action) = step(state, cursor, idle: 10, hold: [])
        XCTAssertEqual(action, .none)
        XCTAssertEqual(next, state)
    }

    func testActiveChangeRecords() {
        let state = SampleState(open: true, held: true, last: cursor)
        let (next, action) = step(state, spotify, idle: 1, hold: .focusedVideo)
        XCTAssertEqual(action, .record(spotify))
        XCTAssertEqual(next, SampleState(open: true, held: false, last: spotify))
    }

    func testResumeAfterIdleRecords() {
        let (next, action) = step(SampleState(), cursor, idle: 0, hold: [])
        XCTAssertEqual(action, .record(cursor))
        XCTAssertTrue(next.open)
        XCTAssertFalse(next.held)
    }

    func testIdleWithoutVideoEndsAtLastInputPlusTimeout() {
        let state = SampleState(open: true, held: false, last: spotify)
        let (next, action) = step(state, spotify, idle: 125, hold: [])
        XCTAssertEqual(action, .end(at: now.addingTimeInterval(-5)))
        XCTAssertEqual(next, SampleState())
    }

    func testIdleEndsAtGraceRatherThanTheFullTimeout() {
        let state = SampleState(open: true, held: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: spotify, now: now, idle: 310, hold: [], timeout: 300, grace: 120, undoWindow: nil
            )
        )
        XCTAssertEqual(action, .end(at: now.addingTimeInterval(120 - 310)))
        XCTAssertEqual(next, SampleState())
    }

    func testGraceDoesNotCutBeforeTheIdleTimeout() {
        let state = SampleState(open: true, held: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: spotify, now: now, idle: 180, hold: [], timeout: 300, grace: 120, undoWindow: nil
            )
        )
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
    }

    func testIdleTitleChangeDoesNotOpenSegment() {
        let (next, action) = step(SampleState(), spotify, idle: 200, hold: [])
        XCTAssertEqual(action, .none)
        XCTAssertFalse(next.open)
    }

    func testFocusedVideoHoldsOpenSegment() {
        let state = SampleState(open: true, held: false, last: cursor)
        let (next, action) = step(state, cursor, idle: 400, hold: .focusedVideo)
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
        XCTAssertTrue(next.held)
    }

    func testVideoWhileIdleOpensSegment() {
        let (next, action) = step(SampleState(), cursor, idle: 400, hold: .focusedVideo)
        XCTAssertEqual(action, .record(cursor))
        XCTAssertTrue(next.held)
    }

    func testVideoStopEndsAtSampleTime() {
        let state = SampleState(open: true, held: true, last: cursor)
        let (next, action) = step(state, cursor, idle: 400, hold: [])
        XCTAssertEqual(action, .end(at: now))
        XCTAssertEqual(next, SampleState())
    }

    func testVideoStopWithUndoNotifiesAtSampleTime() {
        let state = SampleState(open: true, held: true, last: cursor)
        let (next, action) = step(state, cursor, idle: 400, hold: [], undo: 10)
        XCTAssertEqual(action, .notifyIdle(endAt: now))
        XCTAssertEqual(next.pendingEnd, now)
        XCTAssertTrue(next.open)
        XCTAssertEqual(next.last, cursor)
    }

    func testIdleWithUndoNotifiesWithoutEnding() {
        let state = SampleState(open: true, held: false, last: spotify)
        let (next, action) = step(state, spotify, idle: 125, hold: [], undo: 10)
        let end = now.addingTimeInterval(-5)
        XCTAssertEqual(action, .notifyIdle(endAt: end))
        XCTAssertEqual(next.pendingEnd, end)
        XCTAssertEqual(next.pendingUntil, now.addingTimeInterval(10))
        XCTAssertTrue(next.open)
        XCTAssertEqual(next.last, spotify)
    }

    func testUndoWaitDoesNotNotifyAgain() {
        let pending = pendingSpotify()
        let (next, action) = step(pending, spotify, idle: 129, hold: [], at: now.addingTimeInterval(4), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertEqual(next.pendingEnd, pending.pendingEnd)
        XCTAssertEqual(next.pendingUntil, pending.pendingUntil)
        XCTAssertEqual(next.last, spotify)
    }

    func testActivityDuringUndoKeepsSameSegment() {
        let (next, action) = step(pendingSpotify(), spotify, idle: 0, hold: [], at: now.addingTimeInterval(3), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
        XCTAssertNil(next.pendingEnd)
        XCTAssertNil(next.pendingUntil)
        XCTAssertEqual(next.last, spotify)
    }

    func testFocusChangeDuringUndoRecords() {
        let (next, action) = step(pendingSpotify(), cursor, idle: 0, hold: [], at: now.addingTimeInterval(3), undo: 10)
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
        let (next, action) = step(pending, renamed, idle: 140, hold: [], at: now.addingTimeInterval(3), undo: 10)
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
            hold: [],
            at: now.addingTimeInterval(10),
            undo: 10
        )
        XCTAssertEqual(action, .end(at: end))
        XCTAssertEqual(next, SampleState())
    }

    func testVideoDuringUndoCancels() {
        let (next, action) = step(pendingSpotify(), spotify, idle: 130, hold: .focusedVideo, at: now.addingTimeInterval(3), undo: 10)
        XCTAssertEqual(action, .none)
        XCTAssertTrue(next.open)
        XCTAssertTrue(next.held)
        XCTAssertNil(next.pendingEnd)
        XCTAssertEqual(next.last, spotify)
    }

    func testCameraHoldUndoCancelAndEndAtSampleTime() {
        let (held, holdAction) = step(
            SampleState(open: true, held: false, last: cursor),
            cursor,
            idle: 400,
            hold: .camera
        )
        XCTAssertEqual(holdAction, .none)
        XCTAssertTrue(held.open)
        XCTAssertTrue(held.held)

        let (cancelled, cancelAction) = step(
            pendingSpotify(),
            spotify,
            idle: 130,
            hold: .camera,
            at: now.addingTimeInterval(3),
            undo: 10
        )
        XCTAssertEqual(cancelAction, .none)
        XCTAssertTrue(cancelled.open)
        XCTAssertTrue(cancelled.held)
        XCTAssertNil(cancelled.pendingEnd)
        XCTAssertEqual(cancelled.last, spotify)

        let (ended, endAction) = step(SampleState(open: true, held: true, last: cursor), cursor, idle: 400)
        XCTAssertEqual(endAction, .end(at: now))
        XCTAssertEqual(ended, SampleState())
    }

    func testIdleWithUndoUsesGraceForTheCutoff() {
        let state = SampleState(open: true, held: false, last: spotify)
        let (next, action) = SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: spotify,
                now: now,
                idle: 310,
                hold: [],
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
            held: false,
            last: spotify,
            pendingEnd: now.addingTimeInterval(-5),
            pendingUntil: now.addingTimeInterval(10)
        )
    }

    private func step(
        _ state: SampleState,
        _ snapshot: Snapshot,
        idle: TimeInterval,
        hold: IdleHold = [],
        at time: Date? = nil,
        undo: TimeInterval? = nil
    ) -> (SampleState, SampleAction) {
        SamplePolicy.step(
            state: state,
            input: SampleInput(
                snapshot: snapshot,
                now: time ?? now,
                idle: idle,
                hold: hold,
                timeout: timeout,
                grace: timeout,
                undoWindow: undo
            )
        )
    }
}

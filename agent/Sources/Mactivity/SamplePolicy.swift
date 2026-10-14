import Foundation

struct SampleState: Equatable {
    var open = false
    var heldForVideo = false
    var last: Snapshot?
    var pendingEnd: Date?
    var pendingUntil: Date?
}

enum SampleAction: Equatable {
    case none
    case record(Snapshot)
    case end(at: Date)
    case notifyIdle(endAt: Date)
}

struct SampleInput: Equatable {
    var snapshot: Snapshot
    var now: Date
    var idle: TimeInterval
    var video: Bool
    var timeout: TimeInterval
    var grace: TimeInterval
    var undoWindow: TimeInterval?
}

enum SamplePolicy {
    static func step(state: SampleState, input: SampleInput) -> (SampleState, SampleAction) {
        if state.pendingEnd != nil {
            return stepPending(state, input)
        }
        if input.idle < input.timeout {
            return recordIfChanged(state, input.snapshot, heldForVideo: false)
        }
        if input.video {
            return recordIfChanged(state, input.snapshot, heldForVideo: true)
        }
        guard state.open else {
            var idleState = state
            idleState.heldForVideo = false
            return (idleState, .none)
        }
        return beginCutoff(state, input)
    }

    private static func stepPending(_ state: SampleState, _ input: SampleInput) -> (SampleState, SampleAction) {
        if input.idle < input.timeout || input.video {
            let holding = input.video && input.idle >= input.timeout
            return recordIfChanged(state, input.snapshot, heldForVideo: holding)
        }
        if let until = state.pendingUntil, let end = state.pendingEnd, input.now >= until {
            return (SampleState(), .end(at: end))
        }
        var waiting = state
        waiting.heldForVideo = false
        return (waiting, .none)
    }

    private static func beginCutoff(_ state: SampleState, _ input: SampleInput) -> (SampleState, SampleAction) {
        let counted = min(input.grace, input.timeout)
        let end = state.heldForVideo ? input.now : input.now.addingTimeInterval(counted - input.idle)
        guard let window = input.undoWindow else {
            return (SampleState(), .end(at: end))
        }
        var pending = state
        pending.open = true
        pending.heldForVideo = false
        pending.pendingEnd = end
        pending.pendingUntil = input.now.addingTimeInterval(window)
        return (pending, .notifyIdle(endAt: end))
    }

    private static func recordIfChanged(
        _ state: SampleState,
        _ snapshot: Snapshot,
        heldForVideo: Bool
    ) -> (SampleState, SampleAction) {
        var next = state
        next.heldForVideo = heldForVideo
        next.pendingEnd = nil
        next.pendingUntil = nil
        if state.open && state.last == snapshot {
            return (next, .none)
        }
        next.open = true
        next.last = snapshot
        return (next, .record(snapshot))
    }
}

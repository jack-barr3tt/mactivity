import Foundation

struct SampleState: Equatable {
    var open = false
    var heldForVideo = false
    var last: Snapshot?
}

enum SampleAction: Equatable {
    case none
    case record(Snapshot)
    case end(at: Date)
}

struct SampleInput: Equatable {
    var snapshot: Snapshot
    var now: Date
    var idle: TimeInterval
    var video: Bool
    var timeout: TimeInterval
    var grace: TimeInterval
}

enum SamplePolicy {
    static func step(state: SampleState, input: SampleInput) -> (SampleState, SampleAction) {
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
        let counted = min(input.grace, input.timeout)
        let end = state.heldForVideo ? input.now : input.now.addingTimeInterval(counted - input.idle)
        return (SampleState(), .end(at: end))
    }

    private static func recordIfChanged(
        _ state: SampleState,
        _ snapshot: Snapshot,
        heldForVideo: Bool
    ) -> (SampleState, SampleAction) {
        var next = state
        next.heldForVideo = heldForVideo
        if state.open && state.last == snapshot {
            return (next, .none)
        }
        next.open = true
        next.last = snapshot
        return (next, .record(snapshot))
    }
}

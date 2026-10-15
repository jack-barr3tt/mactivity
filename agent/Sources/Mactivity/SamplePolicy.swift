import Foundation

struct IdleHold: OptionSet, Equatable {
    let rawValue: UInt8

    static let focusedVideo = IdleHold(rawValue: 1 << 0)
    static let camera = IdleHold(rawValue: 1 << 1)
}

struct SampleState: Equatable {
    var open = false
    var held = false
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
    var hold: IdleHold
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
            return recordIfChanged(state, input.snapshot, held: false)
        }
        if !input.hold.isEmpty {
            return recordIfChanged(state, input.snapshot, held: true)
        }
        guard state.open else {
            var idleState = state
            idleState.held = false
            return (idleState, .none)
        }
        return beginCutoff(state, input)
    }

    private static func stepPending(_ state: SampleState, _ input: SampleInput) -> (SampleState, SampleAction) {
        if input.idle < input.timeout || !input.hold.isEmpty {
            let holding = !input.hold.isEmpty && input.idle >= input.timeout
            return recordIfChanged(state, input.snapshot, held: holding)
        }
        if let until = state.pendingUntil, let end = state.pendingEnd, input.now >= until {
            return (SampleState(), .end(at: end))
        }
        var waiting = state
        waiting.held = false
        return (waiting, .none)
    }

    private static func beginCutoff(_ state: SampleState, _ input: SampleInput) -> (SampleState, SampleAction) {
        let counted = min(input.grace, input.timeout)
        let end = state.held ? input.now : input.now.addingTimeInterval(counted - input.idle)
        guard let window = input.undoWindow else {
            return (SampleState(), .end(at: end))
        }
        var pending = state
        pending.open = true
        pending.held = false
        pending.pendingEnd = end
        pending.pendingUntil = input.now.addingTimeInterval(window)
        return (pending, .notifyIdle(endAt: end))
    }

    private static func recordIfChanged(
        _ state: SampleState,
        _ snapshot: Snapshot,
        held: Bool
    ) -> (SampleState, SampleAction) {
        var next = state
        next.held = held
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

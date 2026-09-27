import Foundation

/// "At `time` the object entered `state`": a valve opening, a motor tripping.
public struct StateEvent: Codable, Sendable, Hashable {
    public var time: Double
    public var state: String

    public init(time: Double, state: String) {
        self.time = time
        self.state = state
    }
}

/// States and transitions reconstructed from an event list, with how long
/// each state lasted and how often each transition happened.
public struct StateGraph: Codable, Sendable, Hashable {
    public struct State: Codable, Sendable, Hashable {
        public var name: String
        public var entries: Int
        /// Total time spent in the state within the observed window.
        public var dwell: Double
    }

    public struct Transition: Codable, Sendable, Hashable {
        public var from: String
        public var to: String
        public var count: Int
    }

    /// States in order of first appearance.
    public var states: [State]
    /// Transitions in order of first occurrence.
    public var transitions: [Transition]
    /// The run-length-compressed sequence of states.
    public var sequence: [StateEvent]
    /// The state at the end of the window.
    public var finalState: String?

    /// Builds the graph from `events` (sorted here by time). Consecutive
    /// events with the same state are merged, since nothing changed. Dwell of
    /// the last state runs to `end`, or stops at its entry when `end` is nil.
    public init(events: [StateEvent], end: Double? = nil) {
        let ordered = events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        var sequence: [StateEvent] = []
        for event in ordered where sequence.last?.state != event.state {
            sequence.append(event)
        }

        var states: [State] = []
        var stateIndex: [String: Int] = [:]
        var transitions: [Transition] = []
        var transitionIndex: [String: Int] = [:]
        for (offset, event) in sequence.enumerated() {
            let until = offset + 1 < sequence.count ? sequence[offset + 1].time : (end ?? event.time)
            let dwell = max(0, until - event.time)
            if let index = stateIndex[event.state] {
                states[index].entries += 1
                states[index].dwell += dwell
            } else {
                stateIndex[event.state] = states.count
                states.append(State(name: event.state, entries: 1, dwell: dwell))
            }
            if offset > 0 {
                let from = sequence[offset - 1].state
                let key = "\(from)\u{1F}\(event.state)"
                if let index = transitionIndex[key] {
                    transitions[index].count += 1
                } else {
                    transitionIndex[key] = transitions.count
                    transitions.append(Transition(from: from, to: event.state, count: 1))
                }
            }
        }
        self.states = states
        self.transitions = transitions
        self.sequence = sequence
        self.finalState = sequence.last?.state
    }

    /// Derives state events from a numeric series by naming each value, e.g.
    /// `0 → "Stopped"`, `1 → "Running"`. Values `name` maps to nil are skipped.
    public static func events(from points: [DataPoint], name: (Double) -> String?) -> [StateEvent] {
        points.compactMap { point in name(point.y).map { StateEvent(time: point.x, state: $0) } }
    }
}

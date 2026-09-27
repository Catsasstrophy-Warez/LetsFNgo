import Foundation
import NexusCore
import NexusModel

/// Something that happened during a run. Events are modeled truth, like every
/// other simulation output, and ride along in the snapshot of the tick they
/// happened on.
public struct SimulationEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case faultInjected
        case faultCleared
        case thresholdCrossed
        case firstDivergence
    }

    public var kind: Kind
    public var tick: Int
    public var seconds: Double
    /// The quantity involved: the faulted parameter, the watched value, or
    /// the diverging signal.
    public var key: StateKey?
    /// The value after the event: the fault's override, the crossing value,
    /// or the actual value at divergence.
    public var value: Double?
    /// The threshold level, or the reference value at divergence.
    public var reference: Double?
    public var summary: String

    public init(kind: Kind, tick: Int, seconds: Double, key: StateKey?, value: Double?, reference: Double? = nil, summary: String) {
        self.kind = kind
        self.tick = tick
        self.seconds = seconds
        self.key = key
        self.value = value
        self.reference = reference
        self.summary = summary
    }

    /// A timeline event for the store: modeled truth attributed to `run`,
    /// stamped `startedAt` plus the event's simulated seconds. Subjects are the
    /// event's object plus `extraSubjects` (the simulation object, say); the
    /// store requires every subject to exist.
    public func timelineEvent(run: ObjectID, startedAt: Date, extraSubjects: [ObjectID] = []) -> Event {
        var payload: [String: Value] = ["tick": .int(Int64(tick)), "seconds": .double(seconds), "kind": .string(kind.rawValue)]
        if let key {
            payload["object"] = .reference(key.object)
            payload["quantity"] = .string(key.quantity)
        }
        if let value { payload["value"] = .double(value) }
        if let reference { payload["reference"] = .double(reference) }
        let at = startedAt.addingTimeInterval(seconds)
        return Event(
            at: at, kind: kind.eventKind, subjects: (key.map { [$0.object] } ?? []) + extraSubjects, summary: summary, payload: payload,
            provenance: Provenance(origin: .simulation(run: run), truth: .modeled, timestamp: at, method: "simulation event, tick \(tick)")
        )
    }
}

extension SimulationEvent.Kind {
    public var eventKind: EventKind {
        switch self {
        case .faultInjected: .faultInjected
        case .faultCleared: .faultCleared
        case .thresholdCrossed: .thresholdCrossed
        case .firstDivergence: .firstDivergence
        }
    }
}

extension EventKind {
    public static let faultCleared: EventKind = "faultCleared"
    public static let thresholdCrossed: EventKind = "thresholdCrossed"
    public static let firstDivergence: EventKind = "firstDivergence"
}

/// A level to watch on one value. Crossing it emits a `thresholdCrossed` event.
public struct SimulationThreshold: Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable, Hashable {
        case rising
        case falling
        case either
    }

    public var name: String
    public var key: StateKey
    public var level: Double
    public var direction: Direction

    public init(name: String, key: StateKey, level: Double, direction: Direction = .either) {
        self.name = name
        self.key = key
        self.level = level
        self.direction = direction
    }

    /// The direction crossed going from `previous` to `current`, if any.
    /// Rising means `previous < level <= current`; falling `previous > level >= current`.
    func crossing(from previous: Double, to current: Double) -> Direction? {
        if previous < level, current >= level, direction != .falling { return .rising }
        if previous > level, current <= level, direction != .rising { return .falling }
        return nil
    }
}

/// A reference run to compare against tick by tick. When attached, the
/// runtime emits one `firstDivergence` event at the earliest departure.
public struct DivergenceWatch: Sendable {
    public var signalPath: [StateKey]
    public var tolerances: [StateKey: Double]
    public var defaultTolerance: Double
    let reference: [Int: Snapshot]

    public init(reference: [Snapshot], signalPath: [StateKey], tolerances: [StateKey: Double] = [:], defaultTolerance: Double = 1e-6) {
        self.reference = Dictionary(reference.map { ($0.tick, $0) }, uniquingKeysWith: { _, last in last })
        self.signalPath = signalPath
        self.tolerances = tolerances
        self.defaultTolerance = defaultTolerance
    }

    func check(_ snapshot: Snapshot) -> Divergence? {
        guard let expected = reference[snapshot.tick] else { return nil }
        return DivergenceDetector.firstDivergence(
            reference: [expected], actual: [snapshot], signalPath: signalPath, tolerances: tolerances, defaultTolerance: defaultTolerance
        )
    }
}

extension SimulationError: ClassifiableError {
    public var classified: ClassifiedError {
        switch self {
        case .missingParameter(let key):
            ClassifiedError(
                category: .dataSource, whatHappened: "The simulation has no value for the parameter \(key.quantity).",
                whatSurvived: ["The model and earlier results are unchanged."], nextActions: [NextAction("Set the parameter")]
            )
        case .missingValue(let key):
            ClassifiedError(
                category: .systemRuntime, whatHappened: "The simulation hasn't computed \(key.quantity) yet.",
                whatSurvived: ["The model is unchanged."], nextActions: [NextAction("Start the simulation first")]
            )
        case .invalidTimeStep(let dt):
            ClassifiedError(
                category: .userInput, whatHappened: "The time step \(dt) s isn't a positive number.", whatSurvived: ["Nothing was run."],
                nextActions: [NextAction("Choose a positive time step")]
            )
        }
    }
}

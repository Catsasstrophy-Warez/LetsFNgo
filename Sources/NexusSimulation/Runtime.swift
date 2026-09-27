import Foundation
import NexusCore
import NexusModel

/// Addresses one quantity on one canonical object: "terminal voltage at TB-4".
/// Simulation state is keyed by ObjectID, so every simulated value maps back
/// to the world model without a second identity scheme.
public struct StateKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var object: ObjectID
    public var quantity: String

    public init(_ object: ObjectID, _ quantity: String) {
        self.object = object
        self.quantity = quantity
    }

    public var description: String { "\(object).\(quantity)" }

    public static func < (lhs: StateKey, rhs: StateKey) -> Bool {
        (lhs.object, lhs.quantity) < (rhs.object, rhs.quantity)
    }
}

/// A parameter override representing a physical fault, e.g. 400 Ω of contact
/// resistance at a terminal. Faults change parameters; solvers stay honest.
public struct SimulatedFault: Hashable, Codable, Sendable, Identifiable {
    public var id: ObjectID
    public var parameter: StateKey
    public var value: Double
    public var summary: String

    public init(id: ObjectID = .make(), parameter: StateKey, value: Double, summary: String) {
        self.id = id
        self.parameter = parameter
        self.value = value
        self.summary = summary
    }
}

/// The complete simulated world at one instant.
public struct WorldState: Sendable, Hashable, Codable {
    /// Configuration: supply voltage, resistances, setpoints…
    public var parameters: [StateKey: Double] = [:]
    /// Dynamic values written by solvers each step.
    public var values: [StateKey: Double] = [:]
    public var faults: [SimulatedFault] = []

    public init(parameters: [StateKey: Double] = [:], values: [StateKey: Double] = [:]) {
        self.parameters = parameters
        self.values = values
    }

    /// A parameter with any active fault applied. The latest fault on a parameter wins.
    public func parameter(_ key: StateKey) throws -> Double {
        if let fault = faults.last(where: { $0.parameter == key }) {
            return fault.value
        }
        guard let value = parameters[key] else { throw SimulationError.missingParameter(key) }
        return value
    }

    /// A parameter with any active fault applied, or `fallback` when the state
    /// does not configure it. Used for parameters added after a model shipped,
    /// so older saved states keep solving exactly as before.
    public func parameter(_ key: StateKey, default fallback: Double) -> Double {
        if let fault = faults.last(where: { $0.parameter == key }) {
            return fault.value
        }
        return parameters[key] ?? fallback
    }

    public func value(_ key: StateKey) throws -> Double {
        guard let value = values[key] else { throw SimulationError.missingValue(key) }
        return value
    }
}

public enum SimulationError: Error, Equatable, Sendable {
    case missingParameter(StateKey)
    case missingValue(StateKey)
    case invalidTimeStep(Double)
}

/// One subsystem (electrical, process, control…). Solvers run in order each
/// tick, reading and writing the shared world state.
public protocol Solver: Sendable {
    var name: String { get }
    func step(_ state: inout WorldState, dt: Double) throws
}

/// Immutable view of the world after a tick. Renderers (RealityKit, Metal,
/// charts) consume snapshots; they never touch the runtime's state.
public struct Snapshot: Sendable, Hashable, Codable {
    public var tick: Int
    public var seconds: Double
    public var values: [StateKey: Double]
    /// What happened on this tick: faults injected or cleared since the last
    /// tick, thresholds crossed, the first divergence.
    public var events: [SimulationEvent]

    public init(tick: Int, seconds: Double, values: [StateKey: Double], events: [SimulationEvent] = []) {
        self.tick = tick
        self.seconds = seconds
        self.values = values
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case tick, seconds, values, events
    }

    /// Snapshots encoded before events existed decode with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tick = try container.decode(Int.self, forKey: .tick)
        seconds = try container.decode(Double.self, forKey: .seconds)
        values = try container.decode([StateKey: Double].self, forKey: .values)
        events = try container.decodeIfPresent([SimulationEvent].self, forKey: .events) ?? []
    }
}

/// Fixed-step deterministic simulation: SimulationClock → WorldState →
/// solvers → events → snapshot. Everything it produces is modeled truth.
public final class SimulationRuntime: @unchecked Sendable {
    public let run: ObjectID
    public let dt: Double
    public private(set) var tick = 0
    public private(set) var state: WorldState
    public private(set) var history: [Snapshot] = []
    /// Every event of the run, in order. Unlike `history`, never trimmed.
    public private(set) var events: [SimulationEvent] = []
    /// The first divergence from an attached reference, once found.
    public private(set) var firstDivergence: Divergence?

    private let solvers: [any Solver]
    private let historyLimit: Int
    private let lock = NSLock()
    private var thresholds: [SimulationThreshold] = []
    private var divergenceWatch: DivergenceWatch?
    /// Events raised between ticks (fault changes), delivered with the next snapshot.
    private var pendingEvents: [SimulationEvent] = []
    /// Values of the last recorded snapshot, for threshold crossings.
    private var lastValues: [StateKey: Double]?

    public init(
        run: ObjectID = .make(),
        dt: Double,
        state: WorldState,
        solvers: [any Solver],
        historyLimit: Int = 100_000
    ) throws {
        guard dt > 0, dt.isFinite else { throw SimulationError.invalidTimeStep(dt) }
        self.run = run
        self.dt = dt
        self.state = state
        self.solvers = solvers
        self.historyLimit = historyLimit
    }

    public var seconds: Double { Double(tick) * dt }

    /// Settles the solvers at t = 0 without advancing time, and records the
    /// initial snapshot. Call once before stepping.
    @discardableResult
    public func start() throws -> Snapshot {
        try lock.withLock {
            for solver in solvers {
                try solver.step(&state, dt: 0)
            }
            return record()
        }
    }

    @discardableResult
    public func step() throws -> Snapshot {
        try lock.withLock {
            var next = state
            for solver in solvers {
                try solver.step(&next, dt: dt)
            }
            state = next
            tick += 1
            return record()
        }
    }

    /// Steps until `seconds` of simulated time have elapsed.
    public func run(for duration: Double) throws {
        let ticks = Int((duration / dt).rounded())
        for _ in 0..<ticks {
            try step()
        }
    }

    /// Steps `ticks` times off the calling actor, reporting to `progress`
    /// (stage `stage`, one unit per tick) and checking for cancellation every
    /// `checkEvery` ticks. On cancellation the ticks already run are kept, the
    /// progress is marked cancelled, and `CancellationError` is thrown.
    /// Returns the last snapshot.
    @concurrent
    @discardableResult
    public func run(ticks: Int, progress: WorkProgress? = nil, stage: Int = 0, checkEvery: Int = 256) async throws -> Snapshot? {
        let batch = max(1, checkEvery)
        progress?.begin(stage: stage, total: ticks, item: "t = \(seconds) s")
        var last: Snapshot?
        var done = 0
        do {
            while done < ticks {
                try Task.checkCancellation()
                let count = min(batch, ticks - done)
                for _ in 0..<count {
                    last = try step()
                }
                done += count
                progress?.setCompleted(done, item: "t = \(seconds) s")
                await Task.yield()
            }
        } catch is CancellationError {
            progress?.cancel()
            throw CancellationError()
        } catch {
            progress?.fail(classify(error).whatHappened)
            throw error
        }
        progress?.completeStage()
        return last
    }

    public func inject(_ fault: SimulatedFault) {
        lock.withLock {
            state.faults.append(fault)
            pendingEvents.append(
                SimulationEvent(kind: .faultInjected, tick: tick, seconds: seconds, key: fault.parameter, value: fault.value, summary: fault.summary)
            )
        }
    }

    public func clear(_ faultID: ObjectID) {
        lock.withLock {
            let cleared = state.faults.filter { $0.id == faultID }
            state.faults.removeAll { $0.id == faultID }
            for fault in cleared {
                pendingEvents.append(
                    SimulationEvent(
                        kind: .faultCleared, tick: tick, seconds: seconds, key: fault.parameter, value: fault.value, summary: "Cleared: \(fault.summary)"
                    )
                )
            }
        }
    }

    /// Emits a `thresholdCrossed` event whenever `threshold.key` crosses its level.
    public func watch(_ threshold: SimulationThreshold) {
        lock.withLock { thresholds.append(threshold) }
    }

    /// Compares every following tick with `watch`'s reference run and emits
    /// one `firstDivergence` event at the earliest departure. Replaces any
    /// earlier detector and forgets its result.
    public func attach(_ watch: DivergenceWatch) {
        lock.withLock {
            divergenceWatch = watch
            firstDivergence = nil
        }
    }

    /// Changes a configuration parameter (a setpoint, a replaced part's rating).
    public func set(_ key: StateKey, to value: Double) {
        lock.withLock { state.parameters[key] = value }
    }

    public func value(_ key: StateKey) throws -> Double {
        try lock.withLock { try state.value(key) }
    }

    /// A modeled measurement of the current state, attributed to this run.
    public func measurement(
        of key: StateKey,
        unit: String,
        at date: Date,
        method: String = "simulation"
    ) throws -> MeasurementRecord {
        let value = try value(key)
        return MeasurementRecord(
            quantityName: key.quantity, value: Quantity(value, unit), testPoint: key.object, sampledAt: date,
            provenance: Provenance(
                origin: .simulation(run: run), truth: .modeled, timestamp: date,
                method: "\(method), t=\(seconds)s"
            )
        )
    }

    private func record() -> Snapshot {
        var raised = pendingEvents
        pendingEvents = []
        if let previous = lastValues {
            for threshold in thresholds {
                guard let before = previous[threshold.key], let after = state.values[threshold.key],
                    let direction = threshold.crossing(from: before, to: after)
                else { continue }
                let verb = direction == .rising ? "rose to" : "fell to"
                raised.append(
                    SimulationEvent(
                        kind: .thresholdCrossed, tick: tick, seconds: seconds, key: threshold.key, value: after, reference: threshold.level,
                        summary: "\(threshold.name): \(threshold.key.quantity) \(verb) \(after)"
                    )
                )
            }
        }
        var snapshot = Snapshot(tick: tick, seconds: seconds, values: state.values)
        if firstDivergence == nil, let watch = divergenceWatch, let divergence = watch.check(snapshot) {
            firstDivergence = divergence
            raised.append(
                SimulationEvent(
                    kind: .firstDivergence, tick: tick, seconds: seconds, key: divergence.key, value: divergence.actual, reference: divergence.expected,
                    summary: "First divergence: \(divergence.key.quantity) is \(divergence.actual), expected \(divergence.expected)"
                )
            )
        }
        snapshot.events = raised
        events += raised
        lastValues = state.values
        history.append(snapshot)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        return snapshot
    }
}

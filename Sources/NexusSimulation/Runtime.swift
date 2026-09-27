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

    public init(tick: Int, seconds: Double, values: [StateKey: Double]) {
        self.tick = tick
        self.seconds = seconds
        self.values = values
    }
}

/// Fixed-step deterministic simulation: SimulationClock → WorldState →
/// solvers → snapshot. Everything it produces is modeled truth.
public final class SimulationRuntime: @unchecked Sendable {
    public let run: ObjectID
    public let dt: Double
    public private(set) var tick = 0
    public private(set) var state: WorldState
    public private(set) var history: [Snapshot] = []

    private let solvers: [any Solver]
    private let historyLimit: Int
    private let lock = NSLock()

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

    public func inject(_ fault: SimulatedFault) {
        lock.withLock { state.faults.append(fault) }
    }

    public func clear(_ faultID: ObjectID) {
        lock.withLock { state.faults.removeAll { $0.id == faultID } }
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
        let snapshot = Snapshot(tick: tick, seconds: seconds, values: state.values)
        history.append(snapshot)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        return snapshot
    }
}

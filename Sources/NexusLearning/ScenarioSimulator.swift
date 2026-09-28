import Foundation
import NexusAutomotive
import NexusCore
import NexusInvestigation
import NexusModel
import NexusSimulation

/// Replays one domain's simulation for a training scenario: the faulted
/// field the learner diagnoses and the healthy twin it is compared with.
///
/// A simulator is plain data (object IDs, parameters, faults), so a
/// scenario can be stored as attributes and rebuilt after a reload. Every
/// replay is deterministic: the same simulator gives the same history.
///
/// Built in: `LoopScenarioSimulator` (instrument loop),
/// `ChargingScenarioSimulator` (12 V charging and starting circuit) and
/// `GenericScenarioSimulator` (any `WorldState` with solvers from
/// `SolverSpec` and faults).
public protocol ScenarioSimulator: Sendable {
    /// Stored with the scenario to pick the decoder.
    static var kind: String { get }
    /// What makes the field differ from the twin.
    var faults: [SimulatedFault] { get }
    /// A fresh faulted run, at the operating point where the symptom appeared.
    func makeField() throws -> SimulationRuntime
    /// The same run without faults.
    func makeTwin() throws -> SimulationRuntime
    /// What each test reads in the field (`faulted`) or the twin, by test
    /// title. Tests the simulation cannot answer are left out.
    func readings(for tests: [TestOption], faulted: Bool) throws -> [String: Double]
    /// Attribute encoding, without the kind.
    func encoded() -> [String: Value]
    init(decoding map: [String: Value]) throws
}

extension ScenarioSimulator {
    public var kind: String { Self.kind }

    /// Reads each test as the value its test point and quantity name in the
    /// final state of the run.
    public func readings(for tests: [TestOption], faulted: Bool) throws -> [String: Double] {
        let runtime = try faulted ? makeField() : makeTwin()
        let state = runtime.state
        var readings: [String: Double] = [:]
        for test in tests {
            if let value = state.values[StateKey(test.testPoint, test.quantity)] {
                readings[test.title] = value
            }
        }
        return readings
    }
}

/// The built-in simulator kinds, for decoding stored scenarios.
public enum ScenarioSimulators {
    public static let builtIn: [any ScenarioSimulator.Type] = [
        LoopScenarioSimulator.self, ChargingScenarioSimulator.self, GenericScenarioSimulator.self,
    ]

    static func decode(_ value: Value?, using types: [any ScenarioSimulator.Type]) throws -> any ScenarioSimulator {
        guard case .map(let map)? = value, case .string(let kind)? = map["kind"],
            let type = types.first(where: { $0.kind == kind })
        else { throw ScenarioCodingError.malformed }
        return try type.init(decoding: map)
    }

    static func encode(_ simulator: any ScenarioSimulator) -> Value {
        var map = simulator.encoded()
        map["kind"] = .string(simulator.kind)
        return .map(map)
    }
}

/// A stored simulator that could not be decoded.
public enum ScenarioCodingError: Error, Equatable, Sendable {
    case malformed
}

// MARK: Instrument loop

/// The instrument-loop slice: a healthy loop with the case's fault, settled
/// and run to where the symptom appeared.
public struct LoopScenarioSimulator: ScenarioSimulator, Hashable {
    public static let kind = "instrumentLoop"
    public var loop: InstrumentLoop
    public var faults: [SimulatedFault]
    public var dt: Double
    public var runSeconds: Double

    public init(loop: InstrumentLoop, faults: [SimulatedFault], dt: Double = 0.5, runSeconds: Double = 600) {
        self.loop = loop
        self.faults = faults
        self.dt = dt
        self.runSeconds = runSeconds
    }

    public func makeField() throws -> SimulationRuntime { try run(faults) }
    public func makeTwin() throws -> SimulationRuntime { try run([]) }

    func run(_ faults: [SimulatedFault]) throws -> SimulationRuntime {
        let runtime = try SimulationRuntime(dt: dt, state: loop.healthyState(), solvers: loop.solvers)
        for fault in faults {
            runtime.inject(fault)
        }
        try runtime.start()
        try runtime.run(for: runSeconds)
        return runtime
    }

    public func encoded() -> [String: Value] {
        [
            "loop": ScenarioCodec.encode(loop), "faults": .list(faults.map(ScenarioCodec.encode)), "dt": .double(dt),
            "runSeconds": .double(runSeconds),
        ]
    }

    public init(decoding map: [String: Value]) throws {
        let reader = MapReader(map)
        self.init(
            loop: try ScenarioCodec.loop(try reader.map("loop")), faults: try reader.list("faults").map(ScenarioCodec.fault),
            dt: try reader.double("dt"), runSeconds: try reader.double("runSeconds")
        )
    }
}

// MARK: Automotive charging system

/// The automotive slice: the standard charging-system check
/// (`ChargingProtocol`) on a vehicle's circuit with one cause at a severity.
public struct ChargingScenarioSimulator: ScenarioSimulator, Hashable {
    public static let kind = "chargingSystem"
    public var system: ChargingSystem
    public var cause: ChargingFaultKind
    /// 0 to 1, as in `ChargingFaultKind.faults(on:severity:)`.
    public var severity: Double
    public var stateOfCharge: Double

    public init(system: ChargingSystem, cause: ChargingFaultKind, severity: Double, stateOfCharge: Double = 0.75) {
        self.system = system
        self.cause = cause
        self.severity = severity
        self.stateOfCharge = stateOfCharge
    }

    public var faults: [SimulatedFault] {
        // Stable IDs, so two replays inject identical faults.
        cause.faults(on: system, severity: severity).enumerated().map { index, fault in
            var fault = fault
            fault.id = ScenarioCodec.derivedID(system.vehicle, salt: index)
            return fault
        }
    }

    public func run(faulted: Bool) throws -> ChargingRun {
        try ChargingProtocol.run(system, faults: faulted ? faults : [], stateOfCharge: stateOfCharge)
    }

    public func makeField() throws -> SimulationRuntime { try run(faulted: true).runtime }
    public func makeTwin() throws -> SimulationRuntime { try run(faulted: false).runtime }

    /// Each test's reading from the standard check, matched by quantity.
    public func readings(for tests: [TestOption], faulted: Bool) throws -> [String: Double] {
        let run = try run(faulted: faulted)
        var readings: [String: Double] = [:]
        for test in tests {
            if let kind = ChargingTest(quantity: test.quantity), let value = run.readings[kind] {
                readings[test.title] = value
            }
        }
        return readings
    }

    public func encoded() -> [String: Value] {
        [
            "system": ScenarioCodec.encode(system), "cause": .string(cause.rawValue), "severity": .double(severity), "stateOfCharge": .double(stateOfCharge),
        ]
    }

    public init(decoding map: [String: Value]) throws {
        let reader = MapReader(map)
        guard let cause = ChargingFaultKind(rawValue: try reader.string("cause")) else { throw ScenarioCodingError.malformed }
        self.init(
            system: try ScenarioCodec.chargingSystem(try reader.map("system")), cause: cause, severity: try reader.double("severity"),
            stateOfCharge: try reader.double("stateOfCharge")
        )
    }
}

// MARK: Generic

/// A solver the generic simulator can rebuild from stored data.
public enum SolverSpec: Sendable, Hashable {
    case instrumentLoop(InstrumentLoop)
    case chargingSystem(ChargingSystem)
    case thermal(ObjectID)
    case mechanical(ObjectID)
    /// The trainer's induction motor with its default spec.
    case inductionMotor(ObjectID)
    /// The trainer's contactor coil with its default spec.
    case contactorCoil(ObjectID)

    public var solvers: [any Solver] {
        switch self {
        case .instrumentLoop(let loop): loop.solvers
        case .chargingSystem(let system): system.solvers
        case .thermal(let object): [ThermalMass(object: object).solver]
        case .mechanical(let object): [RotatingInertia(object: object).solver]
        case .inductionMotor(let object): [InductionMotorSolver(motor: object)]
        case .contactorCoil(let object): [ContactorCoilSolver(coil: object)]
        }
    }

    var encoded: Value {
        switch self {
        case .instrumentLoop(let loop): .map(["kind": .string("instrumentLoop"), "loop": ScenarioCodec.encode(loop)])
        case .chargingSystem(let system): .map(["kind": .string("chargingSystem"), "system": ScenarioCodec.encode(system)])
        case .thermal(let object): .map(["kind": .string("thermal"), "object": .reference(object)])
        case .mechanical(let object): .map(["kind": .string("mechanical"), "object": .reference(object)])
        case .inductionMotor(let object): .map(["kind": .string("inductionMotor"), "object": .reference(object)])
        case .contactorCoil(let object): .map(["kind": .string("contactorCoil"), "object": .reference(object)])
        }
    }

    init(decoding value: Value) throws {
        guard case .map(let map) = value else { throw ScenarioCodingError.malformed }
        let reader = MapReader(map)
        switch try reader.string("kind") {
        case "instrumentLoop": self = .instrumentLoop(try ScenarioCodec.loop(try reader.map("loop")))
        case "chargingSystem": self = .chargingSystem(try ScenarioCodec.chargingSystem(try reader.map("system")))
        case "thermal": self = .thermal(try reader.reference("object"))
        case "mechanical": self = .mechanical(try reader.reference("object"))
        case "inductionMotor": self = .inductionMotor(try reader.reference("object"))
        case "contactorCoil": self = .contactorCoil(try reader.reference("object"))
        default: throw ScenarioCodingError.malformed
        }
    }
}

/// Any `SimulationRuntime` built from a starting state, solvers and faults:
/// start, then run `runSeconds` at `dt`.
public struct GenericScenarioSimulator: ScenarioSimulator, Hashable {
    public static let kind = "generic"
    public var state: WorldState
    public var solvers: [SolverSpec]
    public var faults: [SimulatedFault]
    public var dt: Double
    public var runSeconds: Double

    public init(state: WorldState, solvers: [SolverSpec], faults: [SimulatedFault], dt: Double, runSeconds: Double) {
        self.state = state
        self.solvers = solvers
        self.faults = faults
        self.dt = dt
        self.runSeconds = runSeconds
    }

    public func makeField() throws -> SimulationRuntime { try run(faults) }
    public func makeTwin() throws -> SimulationRuntime { try run([]) }

    func run(_ faults: [SimulatedFault]) throws -> SimulationRuntime {
        var initial = state
        initial.faults = []
        let runtime = try SimulationRuntime(dt: dt, state: initial, solvers: solvers.flatMap(\.solvers))
        for fault in faults {
            runtime.inject(fault)
        }
        try runtime.start()
        try runtime.run(for: runSeconds)
        return runtime
    }

    public func encoded() -> [String: Value] {
        [
            "parameters": ScenarioCodec.encode(state.parameters), "values": ScenarioCodec.encode(state.values),
            "solvers": .list(solvers.map(\.encoded)), "faults": .list(faults.map(ScenarioCodec.encode)), "dt": .double(dt),
            "runSeconds": .double(runSeconds),
        ]
    }

    public init(decoding map: [String: Value]) throws {
        let reader = MapReader(map)
        self.init(
            state: WorldState(
                parameters: try ScenarioCodec.stateMap(try reader.list("parameters")), values: try ScenarioCodec.stateMap(try reader.list("values"))
            ),
            solvers: try reader.list("solvers").map(SolverSpec.init(decoding:)), faults: try reader.list("faults").map(ScenarioCodec.fault),
            dt: try reader.double("dt"), runSeconds: try reader.double("runSeconds")
        )
    }
}

// MARK: Encoding helpers

struct MapReader {
    let map: [String: Value]

    init(_ map: [String: Value]) {
        self.map = map
    }

    func string(_ key: String) throws -> String {
        guard case .string(let text)? = map[key] else { throw ScenarioCodingError.malformed }
        return text
    }

    func double(_ key: String) throws -> Double {
        switch map[key] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: throw ScenarioCodingError.malformed
        }
    }

    func int(_ key: String) throws -> Int {
        guard case .int(let value)? = map[key] else { throw ScenarioCodingError.malformed }
        return Int(value)
    }

    func reference(_ key: String) throws -> ObjectID {
        guard case .reference(let id)? = map[key] else { throw ScenarioCodingError.malformed }
        return id
    }

    func list(_ key: String) throws -> [Value] {
        guard case .list(let values)? = map[key] else { throw ScenarioCodingError.malformed }
        return values
    }

    func map(_ key: String) throws -> [String: Value] {
        guard case .map(let values)? = map[key] else { throw ScenarioCodingError.malformed }
        return values
    }
}

enum ScenarioCodec {
    static func encode(_ loop: InstrumentLoop) -> Value {
        .map([
            "tank": .reference(loop.tank), "transmitter": .reference(loop.transmitter), "terminal": .reference(loop.terminal),
            "card": .reference(loop.card), "controller": .reference(loop.controller), "valve": .reference(loop.valve),
        ])
    }

    static func loop(_ map: [String: Value]) throws -> InstrumentLoop {
        let reader = MapReader(map)
        return InstrumentLoop(
            tank: try reader.reference("tank"), transmitter: try reader.reference("transmitter"), terminal: try reader.reference("terminal"),
            card: try reader.reference("card"), controller: try reader.reference("controller"), valve: try reader.reference("valve")
        )
    }

    static func encode(_ system: ChargingSystem) -> Value {
        .map([
            "vehicle": .reference(system.vehicle), "battery": .reference(system.battery), "alternator": .reference(system.alternator),
            "starter": .reference(system.starter), "groundStrap": .reference(system.groundStrap), "engine": .reference(system.engine),
        ])
    }

    static func chargingSystem(_ map: [String: Value]) throws -> ChargingSystem {
        let parts = MapReader(map)
        return ChargingSystem(
            vehicle: try parts.reference("vehicle"), battery: try parts.reference("battery"), alternator: try parts.reference("alternator"),
            starter: try parts.reference("starter"), groundStrap: try parts.reference("groundStrap"), engine: try parts.reference("engine")
        )
    }

    static func encode(_ fault: SimulatedFault) -> Value {
        .map([
            "id": .reference(fault.id), "object": .reference(fault.parameter.object), "parameter": .string(fault.parameter.quantity),
            "value": .double(fault.value), "summary": .string(fault.summary),
        ])
    }

    static func fault(_ value: Value) throws -> SimulatedFault {
        guard case .map(let map) = value else { throw ScenarioCodingError.malformed }
        let reader = MapReader(map)
        return SimulatedFault(
            id: try reader.reference("id"), parameter: StateKey(try reader.reference("object"), try reader.string("parameter")),
            value: try reader.double("value"), summary: try reader.string("summary")
        )
    }

    /// Sorted, so equal states encode identically.
    static func encode(_ values: [StateKey: Double]) -> Value {
        .list(
            values.sorted { $0.key < $1.key }.map { key, value in
                .map(["object": .reference(key.object), "quantity": .string(key.quantity), "value": .double(value)])
            })
    }

    static func stateMap(_ values: [Value]) throws -> [StateKey: Double] {
        var result: [StateKey: Double] = [:]
        for value in values {
            guard case .map(let map) = value else { throw ScenarioCodingError.malformed }
            let reader = MapReader(map)
            result[StateKey(try reader.reference("object"), try reader.string("quantity"))] = try reader.double("value")
        }
        return result
    }

    /// A fault ID derived from an object, so replays of the same scenario
    /// inject identical faults.
    static func derivedID(_ base: ObjectID, salt: Int) -> ObjectID {
        var bytes = withUnsafeBytes(of: base.uuid.uuid) { Array($0) }
        bytes[10] ^= 0xA5
        bytes[15] &+= UInt8(truncatingIfNeeded: salt + 1)
        return ObjectID(uuid: UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }))
    }
}

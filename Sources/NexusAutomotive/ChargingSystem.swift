import Foundation
import NexusCore
import NexusSimulation

/// Engine operating state, set as the `mode` parameter on the engine.
public enum EngineMode: Double, Sendable, CaseIterable {
    case off = 0
    case cranking = 1
    case running = 2
}

/// Binds a 12 V charging and starting circuit to canonical objects: battery,
/// alternator, starter, engine ground strap and engine, on one vehicle.
///
/// | Object | Parameters | Values |
/// |---|---|---|
/// | battery | `capacityAh`, `capacityFactor`, `internalOhms`, `polarizationOhms`, `initialStateOfCharge` | `stateOfCharge`, `emf` (V), `terminalVoltage` (V), `current` (A, + charging) |
/// | alternator | `ratedAmps`, `health`, `regulatorVolts` | `outputVolts` (V), `outputAmps` (A) |
/// | starter | `ohms` | `terminalVoltage` (V), `current` (A) |
/// | groundStrap | `ohms` | `voltageDrop` (V) |
/// | engine | `mode` (`EngineMode`), `rpm` | `crankingSpeed` (rpm) |
/// | vehicle | `keyOffDrawAmps`, `runningLoadAmps` | `batteryLight` (0/1) |
public struct ChargingSystem: Sendable, Hashable {
    public var vehicle: ObjectID
    public var battery: ObjectID
    public var alternator: ObjectID
    public var starter: ObjectID
    public var groundStrap: ObjectID
    public var engine: ObjectID

    public init(vehicle: ObjectID, battery: ObjectID, alternator: ObjectID, starter: ObjectID, groundStrap: ObjectID, engine: ObjectID) {
        self.vehicle = vehicle
        self.battery = battery
        self.alternator = alternator
        self.starter = starter
        self.groundStrap = groundStrap
        self.engine = engine
    }

    /// The circuit of a vehicle added through `VehicleRuntime`.
    public init?(_ vehicle: Vehicle) {
        guard let battery = vehicle.component(.battery), let alternator = vehicle.component(.alternator),
            let starter = vehicle.component(.starter), let ground = vehicle.component(.groundStrap), let engine = vehicle.component(.engine)
        else { return nil }
        self.init(vehicle: vehicle.id, battery: battery, alternator: alternator, starter: starter, groundStrap: ground, engine: engine)
    }

    /// Freshly made IDs, for predictions that do not depend on identity.
    public static func template() -> ChargingSystem {
        ChargingSystem(vehicle: .make(), battery: .make(), alternator: .make(), starter: .make(), groundStrap: .make(), engine: .make())
    }

    // Parameters.
    public var capacityAh: StateKey { StateKey(battery, "capacityAh") }
    public var capacityFactor: StateKey { StateKey(battery, "capacityFactor") }
    public var internalOhms: StateKey { StateKey(battery, "internalOhms") }
    public var polarizationOhms: StateKey { StateKey(battery, "polarizationOhms") }
    public var initialStateOfCharge: StateKey { StateKey(battery, "initialStateOfCharge") }
    public var ratedAmps: StateKey { StateKey(alternator, "ratedAmps") }
    public var alternatorHealth: StateKey { StateKey(alternator, "health") }
    public var regulatorVolts: StateKey { StateKey(alternator, "regulatorVolts") }
    public var starterOhms: StateKey { StateKey(starter, "ohms") }
    public var groundOhms: StateKey { StateKey(groundStrap, "ohms") }
    public var engineMode: StateKey { StateKey(engine, "mode") }
    public var engineRPM: StateKey { StateKey(engine, "rpm") }
    public var keyOffDrawAmps: StateKey { StateKey(vehicle, "keyOffDrawAmps") }
    public var runningLoadAmps: StateKey { StateKey(vehicle, "runningLoadAmps") }

    // Values.
    public var stateOfCharge: StateKey { StateKey(battery, "stateOfCharge") }
    public var emf: StateKey { StateKey(battery, "emf") }
    public var batteryVoltage: StateKey { StateKey(battery, "terminalVoltage") }
    public var batteryCurrent: StateKey { StateKey(battery, "current") }
    public var alternatorVolts: StateKey { StateKey(alternator, "outputVolts") }
    public var alternatorAmps: StateKey { StateKey(alternator, "outputAmps") }
    public var starterVolts: StateKey { StateKey(starter, "terminalVoltage") }
    public var starterAmps: StateKey { StateKey(starter, "current") }
    public var groundDrop: StateKey { StateKey(groundStrap, "voltageDrop") }
    public var crankingSpeed: StateKey { StateKey(engine, "crankingSpeed") }
    public var batteryLight: StateKey { StateKey(vehicle, "batteryLight") }

    /// A healthy mid-size car: 60 Ah battery with 12 mΩ internal resistance,
    /// a 120 A alternator regulating at 14.4 V, a starter drawing about 220 A,
    /// a 0.8 mΩ ground strap, 30 mA key-off draw and 30 A of running loads.
    public func healthyState(stateOfCharge: Double = 0.75, mode: EngineMode = .off, rpm: Double = 0) -> WorldState {
        WorldState(parameters: [
            capacityAh: 60, capacityFactor: 1, internalOhms: 0.012, polarizationOhms: 0.03, initialStateOfCharge: stateOfCharge,
            ratedAmps: 120, alternatorHealth: 1, regulatorVolts: 14.4,
            starterOhms: 0.045, groundOhms: 0.0008,
            engineMode: mode.rawValue, engineRPM: rpm,
            keyOffDrawAmps: 0.03, runningLoadAmps: 30,
        ])
    }

    public var solvers: [any Solver] { [ChargingSystemSolver(system: self)] }

    /// The unit of a solver value, by quantity name.
    public static func unit(of quantity: String) -> String {
        switch quantity {
        case "current", "outputAmps": "A"
        case "stateOfCharge", "batteryLight": "1"
        case "crankingSpeed": "rpm"
        default: "V"
        }
    }

    /// Open-circuit voltage of a lead-acid battery at a state of charge:
    /// 11.8 V empty to 12.7 V full, linear in between.
    public static func openCircuitVolts(stateOfCharge: Double) -> Double {
        11.8 + 0.9 * min(1, max(0, stateOfCharge))
    }

    /// Fraction of rated alternator output available at an engine speed:
    /// nothing below 600 rpm, 35 % at 600, full from 2000 rpm.
    public static func outputFraction(rpm: Double) -> Double {
        rpm < 600 ? 0 : min(1, 0.35 + 0.65 * (rpm - 600) / 1400)
    }
}

/// Lumped DC model of the charging and starting circuit.
///
/// The battery is an EMF set by its state of charge behind an internal
/// resistance. Charge acceptance falls as the battery fills, modeled as a
/// polarization resistance `R_pol / (1.02 − SoC)` that only acts while charging.
///
/// - **Off:** the key-off draw discharges the battery through its internal
///   resistance; the ground strap carries the same current.
/// - **Cranking:** the starter is a resistance in series with the battery and
///   the ground strap: `I = EMF / (R_int + R_ground + R_starter)`. Cranking
///   speed rises with the voltage left across the starter. A crank lasts a
///   few seconds, so it samples the state without draining the battery.
/// - **Running:** the alternator holds its regulator voltage (referenced to
///   the engine block) while it can supply the loads plus the battery's
///   charge current `(V_reg − EMF) / (R_int + R_pol + R_ground)`. When it
///   cannot, it delivers its maximum and the battery makes up the rest. The
///   charge current returns through the ground strap, so a bad strap lowers
///   the voltage at the battery posts. The battery light comes on when the
///   alternator's output falls below 13.5 V.
public struct ChargingSystemSolver: Solver {
    public let name = "charging system"
    let system: ChargingSystem

    /// Output below this lights the battery warning lamp.
    public static let lampThresholdVolts = 13.5

    public func step(_ state: inout WorldState, dt: Double) throws {
        let s = system
        var soc = try state.values[s.stateOfCharge] ?? state.parameter(s.initialStateOfCharge)
        let emf = ChargingSystem.openCircuitVolts(stateOfCharge: soc)
        let rInternal = try state.parameter(s.internalOhms)
        let ground = try state.parameter(s.groundOhms)
        let mode = EngineMode(rawValue: (try state.parameter(s.engineMode)).rounded()) ?? .off

        var batteryCurrent = 0.0
        var batteryVolts = emf
        var alternatorVolts = 0.0
        var alternatorAmps = 0.0
        var starterVolts = 0.0
        var starterAmps = 0.0
        var cranking = 0.0
        var light = 0.0

        switch mode {
        case .off:
            let draw = try state.parameter(s.keyOffDrawAmps)
            batteryCurrent = -draw
            batteryVolts = emf - draw * rInternal
        case .cranking:
            let starter = try state.parameter(s.starterOhms)
            let current = emf / (rInternal + ground + starter)
            batteryCurrent = -current
            batteryVolts = emf - current * rInternal
            starterAmps = current
            starterVolts = current * starter
            cranking = max(0, 60 * (starterVolts - 5.5))
        case .running:
            let polarization = try state.parameter(s.polarizationOhms) / max(0.02, 1.02 - min(1, soc))
            let chargePath = rInternal + polarization + ground
            let maximum =
                try state.parameter(s.ratedAmps) * state.parameter(s.alternatorHealth)
                * ChargingSystem.outputFraction(rpm: try state.parameter(s.engineRPM))
            let load = try state.parameter(s.runningLoadAmps)
            let regulated = try state.parameter(s.regulatorVolts)
            let wanted = (regulated - emf) / chargePath
            if wanted + load <= maximum {
                batteryCurrent = wanted
                alternatorVolts = regulated
                batteryVolts = emf + batteryCurrent * (rInternal + polarization)
            } else {
                batteryCurrent = maximum - load
                // Polarization only resists charging; a discharging battery sees its internal resistance.
                let batteryPath = batteryCurrent >= 0 ? rInternal + polarization : rInternal
                batteryVolts = emf + batteryCurrent * batteryPath
                alternatorVolts = batteryVolts + batteryCurrent * ground
            }
            alternatorAmps = max(0, batteryCurrent + load)
            light = alternatorVolts < ChargingSystemSolver.lampThresholdVolts ? 1 : 0
        }

        if dt > 0, mode != .cranking {
            let capacity = try state.parameter(s.capacityAh) * max(0.01, state.parameter(s.capacityFactor))
            soc = min(1, max(0, soc + batteryCurrent * dt / 3600 / capacity))
        }

        state.values[s.stateOfCharge] = soc
        state.values[s.emf] = emf
        state.values[s.batteryVoltage] = batteryVolts
        state.values[s.batteryCurrent] = batteryCurrent
        state.values[s.alternatorVolts] = alternatorVolts
        state.values[s.alternatorAmps] = alternatorAmps
        state.values[s.starterVolts] = starterVolts
        state.values[s.starterAmps] = starterAmps
        state.values[s.groundDrop] = abs(batteryCurrent) * ground
        state.values[s.crankingSpeed] = cranking
        state.values[s.batteryLight] = light
    }
}

// MARK: Faults

/// The four causes behind "cranks slowly / battery light on". Each is a set
/// of parameter overrides; the solver turns them into symptoms.
public enum ChargingFaultKind: String, Codable, Sendable, CaseIterable, Comparable {
    case weakBattery
    case failingAlternator
    case highResistanceGround
    case parasiticDraw

    public var statement: String {
        switch self {
        case .weakBattery: "Weak battery: sulfated plates raise internal resistance and cut capacity"
        case .failingAlternator: "Failing alternator: worn diodes or brushes limit charging output"
        case .highResistanceGround: "High-resistance engine ground strap starves the starter and the charge path"
        case .parasiticDraw: "Parasitic draw: a module stays awake and drains the battery with the key off"
        }
    }

    /// Overrides for a severity in [0, 1] (1 = worst).
    ///
    /// | Kind | Override |
    /// |---|---|
    /// | weakBattery | `internalOhms` = 0.03 + 0.03·s Ω, `capacityFactor` = 0.6 − 0.25·s |
    /// | failingAlternator | `health` = 0.3 − 0.2·s |
    /// | highResistanceGround | ground `ohms` = 0.012 + 0.023·s Ω |
    /// | parasiticDraw | `keyOffDrawAmps` = 0.3 + 0.9·s A |
    public func faults(on system: ChargingSystem, severity: Double) -> [SimulatedFault] {
        let s = min(1, max(0, severity))
        func fault(_ key: StateKey, _ value: Double, _ summary: String) -> SimulatedFault {
            SimulatedFault(parameter: key, value: value, summary: summary)
        }
        switch self {
        case .weakBattery:
            return [
                fault(system.internalOhms, 0.03 + 0.03 * s, "Sulfated battery: high internal resistance"),
                fault(system.capacityFactor, 0.6 - 0.25 * s, "Sulfated battery: reduced capacity"),
            ]
        case .failingAlternator:
            return [fault(system.alternatorHealth, 0.3 - 0.2 * s, "Alternator output limited")]
        case .highResistanceGround:
            return [fault(system.groundOhms, 0.012 + 0.023 * s, "Corroded engine ground strap")]
        case .parasiticDraw:
            return [fault(system.keyOffDrawAmps, 0.3 + 0.9 * s, "Module keeps drawing current with the key off")]
        }
    }

    public static func < (lhs: ChargingFaultKind, rhs: ChargingFaultKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: Test protocol

/// A measurement in the standard charging-system check.
public enum ChargingTest: String, Codable, Sendable, CaseIterable, Comparable {
    case restingVoltage
    case keyOffDraw
    case crankingVoltage
    case groundDrop
    case chargingVoltage

    public var title: String {
        switch self {
        case .restingVoltage: "Resting battery voltage after the car sat parked"
        case .keyOffDraw: "Key-off current draw at the battery"
        case .crankingVoltage: "Battery voltage while cranking"
        case .groundDrop: "Voltage drop across the engine ground strap while cranking"
        case .chargingVoltage: "Charging voltage at 2000 rpm with loads on"
        }
    }

    /// The quantity name the reading is stored under.
    public var quantity: String { rawValue }
    public var unit: String { self == .keyOffDraw ? "A" : "V" }

    public enum Site: String, Sendable {
        case battery
        case groundStrap
    }

    public var site: Site { self == .groundDrop ? .groundStrap : .battery }

    /// Minutes, including access. The draw test waits for modules to sleep.
    public var cost: Double {
        switch self {
        case .restingVoltage: 2
        case .keyOffDraw: 25
        case .crankingVoltage: 3
        case .groundDrop: 6
        case .chargingVoltage: 4
        }
    }

    /// Probing the strap while cranking puts hands near the running gear.
    public var isCaution: Bool { self == .groundDrop }

    /// Instrument tolerance used to pad predictions: a DMM on volts, a clamp on amps.
    public var tolerance: Double { self == .keyOffDraw ? 0.02 : 0.05 }

    public func testPoint(in system: ChargingSystem) -> ObjectID {
        site == .battery ? system.battery : system.groundStrap
    }

    public static func < (lhs: ChargingTest, rhs: ChargingTest) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One run of the standard check: an hour's drive at 2000 rpm with loads on,
/// 36 hours parked with the key off (a weekend), one crank, then five
/// minutes at 2000 rpm.
/// Readings are taken at the end of each phase.
public struct ChargingRun: Sendable {
    public var runtime: SimulationRuntime
    public var readings: [ChargingTest: Double]
    /// Cranking speed during the crank, rpm.
    public var crankingSpeed: Double
    /// Battery light while driving (1 = on), before the rest.
    public var lightWhileDriving: Double
    /// Alternator output while driving, V.
    public var drivingOutputVolts: Double

    public var history: [Snapshot] { runtime.history }
}

public enum ChargingProtocol {
    public static let dt = 60.0
    public static let driveSeconds = 3_600.0
    public static let restSeconds = 36 * 3_600.0
    public static let chargeSeconds = 300.0
    public static let testRPM = 2_000.0

    /// Signals watched for the first divergence, upstream first.
    public static func signalPath(_ system: ChargingSystem) -> [StateKey] {
        [
            system.alternatorVolts, system.groundDrop, system.alternatorAmps, system.batteryCurrent, system.batteryVoltage, system.starterVolts,
            system.stateOfCharge,
        ]
    }

    public static func tolerances(_ system: ChargingSystem) -> [StateKey: Double] {
        [
            system.alternatorVolts: 0.05, system.groundDrop: 0.05, system.alternatorAmps: 0.5, system.batteryCurrent: 0.05,
            system.batteryVoltage: 0.05, system.starterVolts: 0.05, system.stateOfCharge: 0.01,
        ]
    }

    public static func run(_ system: ChargingSystem, faults: [SimulatedFault] = [], stateOfCharge: Double = 0.75) throws -> ChargingRun {
        let runtime = try SimulationRuntime(
            dt: dt, state: system.healthyState(stateOfCharge: stateOfCharge, mode: .running, rpm: testRPM), solvers: system.solvers
        )
        for fault in faults {
            runtime.inject(fault)
        }
        try runtime.start()
        let light = try runtime.value(system.batteryLight)
        let output = try runtime.value(system.alternatorVolts)
        try runtime.run(for: driveSeconds)

        runtime.set(system.engineMode, to: EngineMode.off.rawValue)
        runtime.set(system.engineRPM, to: 0)
        try runtime.run(for: restSeconds)
        var readings: [ChargingTest: Double] = [:]
        readings[.restingVoltage] = try runtime.value(system.batteryVoltage)
        readings[.keyOffDraw] = -(try runtime.value(system.batteryCurrent))

        runtime.set(system.engineMode, to: EngineMode.cranking.rawValue)
        try runtime.step()
        readings[.crankingVoltage] = try runtime.value(system.batteryVoltage)
        readings[.groundDrop] = try runtime.value(system.groundDrop)
        let crank = try runtime.value(system.crankingSpeed)

        runtime.set(system.engineMode, to: EngineMode.running.rawValue)
        runtime.set(system.engineRPM, to: testRPM)
        try runtime.run(for: chargeSeconds)
        readings[.chargingVoltage] = try runtime.value(system.batteryVoltage)
        return ChargingRun(runtime: runtime, readings: readings, crankingSpeed: crank, lightWhileDriving: light, drivingOutputVolts: output)
    }
}

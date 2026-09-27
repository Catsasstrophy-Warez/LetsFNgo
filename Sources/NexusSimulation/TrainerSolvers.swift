import ControlsSimulation
import Foundation
import NexusCore

// Solver adapters around physics ported from the Controls Tech Trainer.
//
// Adapted (continuous, per-step models whose whole state is numeric, so it
// round-trips through `WorldState` keyed by ObjectID):
// - `InductionMotorTransientModel` → `InductionMotorSolver`
// - `ElectromagneticCoilModel` (relay/contactor coil) → `ContactorCoilSolver`
//
// Not adapted, and why:
// - `ClosedLoopPlantRuntime` / `FullyClosedLoopMachineRuntime`: driven by a
//   PLC project and string tag values, with its own fault list. It is a whole
//   machine, not a subsystem solver; adapting it would put a second world
//   model inside the runtime.
// - `IndustrialCircuitStateSolver`: nodes and branches are keyed by string ids
//   in a netlist. It fits as a solver only once netlists are built from
//   canonical topology objects, which doesn't exist yet.
// - `VFDTransientModel`: fits the pattern, but carries a trip reason string
//   that `WorldState` (numbers only) can't hold without a lossy code table.
//   Next candidate once events can carry it.
// - `TransientRCModel` / `TransientRLModel`: primitives the coil model already
//   uses; they gain nothing from being separate solvers.
// - Material flow, machine cycle, communication, MES, economics and scenario
//   runtimes: discrete-event or game logic with entities, messages and
//   money rather than continuous state, so they don't fit a fixed-step solver.
//
// Each adapter reads the trainer model's state from `values`, calls the
// model's own `advance` unchanged, and writes the state and outputs back.
// Inputs are parameters, so `SimulatedFault` overrides them (a supply sag, a
// jammed load) without touching the ported code.

/// Wraps the trainer's `InductionMotorTransientModel`.
///
/// | Parameters | Values |
/// |---|---|
/// | `lineVolts` (V), `frequencyHz`, `loadTorqueFraction` (of rated), `loadInertia` (kg·m²) | `speedRPM`, `synchronousRPM`, `slip`, `lineCurrent` (A), `electromagneticTorque` (N·m), `loadTorque` (N·m), `copperLoss` (W), `temperature` (°C), `peakCurrent` (A), `stalled` (0/1), `tripIntegral` |
///
/// Missing inputs default to the spec's rated line voltage and frequency, no
/// load, and the spec's load inertia.
public struct InductionMotorSolver: Solver {
    public var motor: ObjectID
    public var spec: InductionMotorTransientSpec
    public var name: String { "trainer induction motor" }

    public init(motor: ObjectID, spec: InductionMotorTransientSpec = InductionMotorTransientSpec()) {
        self.motor = motor
        self.spec = spec
    }

    public var lineVolts: StateKey { StateKey(motor, "lineVolts") }
    public var frequencyHz: StateKey { StateKey(motor, "frequencyHz") }
    public var loadTorqueFraction: StateKey { StateKey(motor, "loadTorqueFraction") }
    public var loadInertia: StateKey { StateKey(motor, "loadInertia") }
    public var speedRPM: StateKey { StateKey(motor, "speedRPM") }
    public var synchronousRPM: StateKey { StateKey(motor, "synchronousRPM") }
    public var slip: StateKey { StateKey(motor, "slip") }
    public var lineCurrent: StateKey { StateKey(motor, "lineCurrent") }
    public var electromagneticTorque: StateKey { StateKey(motor, "electromagneticTorque") }
    public var loadTorque: StateKey { StateKey(motor, "loadTorque") }
    public var copperLoss: StateKey { StateKey(motor, "copperLoss") }
    public var temperature: StateKey { StateKey(motor, "temperature") }
    public var peakCurrent: StateKey { StateKey(motor, "peakCurrent") }
    public var stalled: StateKey { StateKey(motor, "stalled") }
    public var tripIntegral: StateKey { StateKey(motor, "tripIntegral") }

    /// A stopped motor at 25 °C on rated supply with `load` of rated torque.
    public func state(load: Double = 0.5) -> WorldState {
        WorldState(
            parameters: [lineVolts: spec.ratedLineVolts, frequencyHz: spec.ratedHz, loadTorqueFraction: load, loadInertia: spec.loadInertiaKgM2],
            values: [speedRPM: 0, temperature: 25]
        )
    }

    public func step(_ state: inout WorldState, dt: Double) throws {
        var modelSpec = spec
        modelSpec.loadInertiaKgM2 = state.parameter(loadInertia, default: spec.loadInertiaKgM2)
        var model = InductionMotorTransientState()
        model.speedRPM = state.values[speedRPM] ?? 0
        model.temperatureC = state.values[temperature] ?? 25
        model.peakCurrentAmps = state.values[peakCurrent] ?? 0
        model.tripIntegral = state.values[tripIntegral] ?? 0

        let snapshot = InductionMotorTransientModel.advance(
            spec: modelSpec, state: &model, lineVolts: state.parameter(lineVolts, default: spec.ratedLineVolts),
            frequencyHz: state.parameter(frequencyHz, default: spec.ratedHz), loadTorqueFraction: state.parameter(loadTorqueFraction, default: 0),
            dt: dt
        )

        state.values[speedRPM] = model.speedRPM
        state.values[temperature] = model.temperatureC
        state.values[peakCurrent] = model.peakCurrentAmps
        state.values[tripIntegral] = model.tripIntegral
        state.values[synchronousRPM] = snapshot.synchronousRPM
        state.values[slip] = snapshot.slip
        state.values[lineCurrent] = snapshot.lineCurrentAmps
        state.values[electromagneticTorque] = snapshot.electromagneticTorqueNm
        state.values[loadTorque] = snapshot.loadTorqueNm
        state.values[copperLoss] = snapshot.copperLossWatts
        state.values[stalled] = snapshot.stalled ? 1 : 0
    }
}

/// Wraps the trainer's `ElectromagneticCoilModel` (relay or contactor coil
/// with armature travel, contact bounce and coil heating).
///
/// | Parameters | Values |
/// |---|---|
/// | `appliedVolts` (V), `ambient` (°C), `coilOhms` (Ω) | `current` (A), `armaturePosition` (0–1), `contactClosed` (0/1), `bouncing` (0/1), `bounceRemaining` (s), `temperature` (°C), `chatterCount`, `energizedSeconds`, `inrushMultiple`, `magneticForceIndex` |
///
/// `coilOhms` defaults to the spec's resistance; a fault can raise it (a
/// failing coil) or lower it (shorted turns).
public struct ContactorCoilSolver: Solver {
    public var coil: ObjectID
    public var spec: ElectromagneticCoilSpec
    public var name: String { "trainer contactor coil" }

    public init(coil: ObjectID, spec: ElectromagneticCoilSpec = ElectromagneticCoilSpec()) {
        self.coil = coil
        self.spec = spec
    }

    public var appliedVolts: StateKey { StateKey(coil, "appliedVolts") }
    public var ambient: StateKey { StateKey(coil, "ambient") }
    public var coilOhms: StateKey { StateKey(coil, "coilOhms") }
    public var current: StateKey { StateKey(coil, "current") }
    public var armaturePosition: StateKey { StateKey(coil, "armaturePosition") }
    public var contactClosed: StateKey { StateKey(coil, "contactClosed") }
    public var bouncing: StateKey { StateKey(coil, "bouncing") }
    public var bounceRemaining: StateKey { StateKey(coil, "bounceRemaining") }
    public var temperature: StateKey { StateKey(coil, "temperature") }
    public var chatterCount: StateKey { StateKey(coil, "chatterCount") }
    public var energizedSeconds: StateKey { StateKey(coil, "energizedSeconds") }
    public var inrushMultiple: StateKey { StateKey(coil, "inrushMultiple") }
    public var magneticForceIndex: StateKey { StateKey(coil, "magneticForceIndex") }

    /// A de-energized coil at ambient, with `volts` ready to apply.
    public func state(volts: Double, ambient: Double = 25) -> WorldState {
        WorldState(
            parameters: [appliedVolts: volts, self.ambient: ambient, coilOhms: spec.resistanceOhms],
            values: [current: 0, armaturePosition: 0, contactClosed: 0, temperature: ambient]
        )
    }

    public func step(_ state: inout WorldState, dt: Double) throws {
        var modelSpec = spec
        modelSpec.resistanceOhms = state.parameter(coilOhms, default: spec.resistanceOhms)
        let ambientC = state.parameter(ambient, default: 25)
        var model = ElectromagneticCoilState()
        model.currentAmps = state.values[current] ?? 0
        model.armaturePosition = state.values[armaturePosition] ?? 0
        model.contactClosed = (state.values[contactClosed] ?? 0) >= 0.5
        model.bounceRemaining = state.values[bounceRemaining] ?? 0
        model.temperatureC = state.values[temperature] ?? ambientC
        model.chatterCount = Int(state.values[chatterCount] ?? 0)
        model.energizedSeconds = state.values[energizedSeconds] ?? 0

        let snapshot = ElectromagneticCoilModel.advance(
            spec: modelSpec, state: &model, appliedVolts: state.parameter(appliedVolts, default: 0), ambientC: ambientC, dt: dt
        )

        state.values[current] = model.currentAmps
        state.values[armaturePosition] = model.armaturePosition
        state.values[contactClosed] = model.contactClosed ? 1 : 0
        state.values[bounceRemaining] = model.bounceRemaining
        state.values[temperature] = model.temperatureC
        state.values[chatterCount] = Double(model.chatterCount)
        state.values[energizedSeconds] = model.energizedSeconds
        state.values[bouncing] = snapshot.bouncing ? 1 : 0
        state.values[inrushMultiple] = snapshot.inrushMultiple
        state.values[magneticForceIndex] = snapshot.magneticForceIndex
    }
}

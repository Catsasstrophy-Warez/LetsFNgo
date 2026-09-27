import Foundation
import NexusCore

/// Binds a 4–20 mA level loop to canonical objects: tank → level transmitter →
/// field terminals (test point) → analog input card → PI controller → inlet valve.
///
/// Quantities, keyed on those objects:
///
/// | Object | Parameters | Values |
/// |---|---|---|
/// | tank | `inflowMaxPercentPerSecond`, `outflowPercentPerSecond` | `level` (%), `overflowing` (0/1) |
/// | transmitter | `liftOffVolts`, `rangeLow`, `rangeHigh` | `requestedCurrent` (mA) |
/// | terminal | `wireOhms`, `contactOhms` | `loopCurrent` (mA), `terminalVoltage` (V) |
/// | card | `supplyVolts`, `receiverOhms` | `inputVolts` (V), `measuredLevel` (%) |
/// | controller | `setpoint`, `kp`, `ki` | `output` (%), `integral` |
/// | valve | — | `position` (%) |
public struct InstrumentLoop: Sendable, Hashable {
    public var tank: ObjectID
    public var transmitter: ObjectID
    public var terminal: ObjectID
    public var card: ObjectID
    public var controller: ObjectID
    public var valve: ObjectID

    public init(tank: ObjectID, transmitter: ObjectID, terminal: ObjectID, card: ObjectID, controller: ObjectID, valve: ObjectID) {
        self.tank = tank
        self.transmitter = transmitter
        self.terminal = terminal
        self.card = card
        self.controller = controller
        self.valve = valve
    }

    // Keys used by the solvers and by callers taking measurements.
    public var level: StateKey { StateKey(tank, "level") }
    public var overflowing: StateKey { StateKey(tank, "overflowing") }
    public var requestedCurrent: StateKey { StateKey(transmitter, "requestedCurrent") }
    public var loopCurrent: StateKey { StateKey(terminal, "loopCurrent") }
    public var terminalVoltage: StateKey { StateKey(terminal, "terminalVoltage") }
    public var contactOhms: StateKey { StateKey(terminal, "contactOhms") }
    public var liftOffVolts: StateKey { StateKey(transmitter, "liftOffVolts") }
    public var supplyVolts: StateKey { StateKey(card, "supplyVolts") }
    public var inputVolts: StateKey { StateKey(card, "inputVolts") }
    public var measuredLevel: StateKey { StateKey(card, "measuredLevel") }
    public var setpoint: StateKey { StateKey(controller, "setpoint") }
    public var controllerOutput: StateKey { StateKey(controller, "output") }
    public var valvePosition: StateKey { StateKey(valve, "position") }

    /// A healthy loop at a steady operating point. Values are typical of a
    /// loop-powered transmitter on a 24 V card with a 250 Ω receiver.
    public func healthyState(initialLevel: Double = 50, setpoint: Double = 90) -> WorldState {
        WorldState(
            parameters: [
                StateKey(tank, "inflowMaxPercentPerSecond"): 2,
                StateKey(tank, "outflowPercentPerSecond"): 1,
                liftOffVolts: 12,
                StateKey(transmitter, "rangeLow"): 0,
                StateKey(transmitter, "rangeHigh"): 100,
                StateKey(terminal, "wireOhms"): 20,
                contactOhms: 0,
                supplyVolts: 24,
                StateKey(card, "receiverOhms"): 250,
                self.setpoint: setpoint,
                StateKey(controller, "kp"): 4,
                StateKey(controller, "ki"): 0.2,
            ],
            values: [level: initialLevel, valvePosition: 50, StateKey(controller, "integral"): 250]
        )
    }

    /// Solvers in execution order. The tank integrates using the valve position
    /// from the previous tick, so a tick is one pass around the loop.
    public var solvers: [any Solver] {
        [TankSolver(loop: self), CurrentLoopSolver(loop: self), AnalogInputSolver(loop: self), PIControllerSolver(loop: self), ValveSolver(loop: self)]
    }
}

/// Tank level: inflow through the inlet valve minus a constant draw.
public struct TankSolver: Solver {
    public let name = "tank"
    let loop: InstrumentLoop

    public func step(_ state: inout WorldState, dt: Double) throws {
        let inflow = try state.parameter(StateKey(loop.tank, "inflowMaxPercentPerSecond")) * state.value(loop.valvePosition) / 100
        let outflow = try state.parameter(StateKey(loop.tank, "outflowPercentPerSecond"))
        let level = min(100, max(0, try state.value(loop.level) + (inflow - outflow) * dt))
        state.values[loop.level] = level
        state.values[loop.overflowing] = level >= 100 ? 1 : 0
    }
}

/// Two-wire 4–20 mA loop. The transmitter asks for a current proportional to
/// level, but it can only regulate while the voltage across its terminals stays
/// at or above lift-off. Series resistance (receiver, wiring, a bad contact)
/// therefore caps the achievable current:
///
///     I_max = (V_supply − V_liftoff) / (R_receiver + R_wire + R_contact)
public struct CurrentLoopSolver: Solver {
    public let name = "current loop"
    let loop: InstrumentLoop

    /// NAMUR NE 43 signal limits for a healthy transmitter.
    static let saturationLow = 3.8
    static let saturationHigh = 20.5

    public func step(_ state: inout WorldState, dt: Double) throws {
        let low = try state.parameter(StateKey(loop.transmitter, "rangeLow"))
        let high = try state.parameter(StateKey(loop.transmitter, "rangeHigh"))
        let fraction = (try state.value(loop.level) - low) / (high - low)
        let requested = min(Self.saturationHigh, max(Self.saturationLow, 4 + 16 * fraction))

        let supply = try state.parameter(loop.supplyVolts)
        let liftOff = try state.parameter(loop.liftOffVolts)
        let resistance = try state.parameter(StateKey(loop.card, "receiverOhms"))
            + state.parameter(StateKey(loop.terminal, "wireOhms"))
            + state.parameter(loop.contactOhms)
        let maximum = max(0, (supply - liftOff) / resistance * 1000)
        let current = min(requested, maximum)

        state.values[loop.requestedCurrent] = requested
        state.values[loop.loopCurrent] = current
        state.values[loop.terminalVoltage] = supply - current / 1000 * resistance
    }
}

/// Analog input card: voltage across the receiver resistor, scaled to level.
public struct AnalogInputSolver: Solver {
    public let name = "analog input"
    let loop: InstrumentLoop

    public func step(_ state: inout WorldState, dt: Double) throws {
        let current = try state.value(loop.loopCurrent)
        let low = try state.parameter(StateKey(loop.transmitter, "rangeLow"))
        let high = try state.parameter(StateKey(loop.transmitter, "rangeHigh"))
        state.values[loop.inputVolts] = try current / 1000 * state.parameter(StateKey(loop.card, "receiverOhms"))
        state.values[loop.measuredLevel] = low + (current - 4) / 16 * (high - low)
    }
}

/// PI level controller acting on the *measured* level, with conditional
/// integration as anti-windup. It trusts the card, which is how a clamped
/// signal turns into an overflowing tank.
public struct PIControllerSolver: Solver {
    public let name = "PI controller"
    let loop: InstrumentLoop

    public func step(_ state: inout WorldState, dt: Double) throws {
        let integralKey = StateKey(loop.controller, "integral")
        let error = try state.parameter(loop.setpoint) - state.value(loop.measuredLevel)
        let kp = try state.parameter(StateKey(loop.controller, "kp"))
        let ki = try state.parameter(StateKey(loop.controller, "ki"))
        var integral = state.values[integralKey] ?? 0

        let unclamped = kp * error + ki * (integral + error * dt)
        let saturatedHigh = unclamped > 100 && error > 0
        let saturatedLow = unclamped < 0 && error < 0
        if !saturatedHigh && !saturatedLow {
            integral += error * dt
        }
        state.values[integralKey] = integral
        state.values[loop.controllerOutput] = min(100, max(0, kp * error + ki * integral))
    }
}

/// Inlet valve following the controller output.
public struct ValveSolver: Solver {
    public let name = "valve"
    let loop: InstrumentLoop

    public func step(_ state: inout WorldState, dt: Double) throws {
        state.values[loop.valvePosition] = try state.value(loop.controllerOutput)
    }
}

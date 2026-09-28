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
/// | transmitter | `liftOffVolts`, `rangeLow`, `rangeHigh`, `outputGain`, `outputOffset` (mA) | `requestedCurrent` (mA) |
/// | terminal | `wireOhms`, `contactOhms`, `openCircuit` (0/1), `intermittentOhms`, `intermittentPeriod` (s), `intermittentDuty`, `intermittentSeed` | `loopCurrent` (mA), `terminalVoltage` (V), `elapsed` (s), `effectiveContactOhms` (Ω) |
/// | card | `supplyVolts`, `receiverOhms`, `rangeLow`, `rangeHigh`, `channelGain`, `channelStuck` (0/1), `channelStuckMilliamps` | `inputVolts` (V), `readCurrent` (mA), `measuredLevel` (%), `underrange` (0/1), `overrange` (0/1) |
/// | controller | `setpoint`, `kp`, `ki` | `output` (%), `integral` |
/// | valve | — | `position` (%) |
///
/// Parameters added after the first release (transmitter output error, open
/// circuit, intermittent contact, card channel faults and card range) have
/// healthy defaults in `healthyState`, and the solvers fall back to the same
/// healthy values when a saved state lacks them. `LoopFaultKind` builds
/// faults on top of them.
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

    // Keys for the fault-capable parameters and the values they produce.
    public var transmitterRangeLow: StateKey { StateKey(transmitter, "rangeLow") }
    public var transmitterRangeHigh: StateKey { StateKey(transmitter, "rangeHigh") }
    public var outputGain: StateKey { StateKey(transmitter, "outputGain") }
    public var outputOffset: StateKey { StateKey(transmitter, "outputOffset") }
    public var wireOhms: StateKey { StateKey(terminal, "wireOhms") }
    public var openCircuit: StateKey { StateKey(terminal, "openCircuit") }
    public var intermittentOhms: StateKey { StateKey(terminal, "intermittentOhms") }
    public var intermittentPeriod: StateKey { StateKey(terminal, "intermittentPeriod") }
    public var intermittentDuty: StateKey { StateKey(terminal, "intermittentDuty") }
    public var intermittentSeed: StateKey { StateKey(terminal, "intermittentSeed") }
    public var elapsed: StateKey { StateKey(terminal, "elapsed") }
    public var effectiveContactOhms: StateKey { StateKey(terminal, "effectiveContactOhms") }
    public var receiverOhms: StateKey { StateKey(card, "receiverOhms") }
    public var cardRangeLow: StateKey { StateKey(card, "rangeLow") }
    public var cardRangeHigh: StateKey { StateKey(card, "rangeHigh") }
    public var channelGain: StateKey { StateKey(card, "channelGain") }
    public var channelStuck: StateKey { StateKey(card, "channelStuck") }
    public var channelStuckMilliamps: StateKey { StateKey(card, "channelStuckMilliamps") }
    public var readCurrent: StateKey { StateKey(card, "readCurrent") }
    public var underrange: StateKey { StateKey(card, "underrange") }
    public var overrange: StateKey { StateKey(card, "overrange") }

    /// A healthy loop at a steady operating point. Values are typical of a
    /// loop-powered transmitter on a 24 V card with a 250 Ω receiver.
    public func healthyState(initialLevel: Double = 50, setpoint: Double = 90) -> WorldState {
        WorldState(
            parameters: [
                StateKey(tank, "inflowMaxPercentPerSecond"): 2,
                StateKey(tank, "outflowPercentPerSecond"): 1,
                liftOffVolts: 12,
                transmitterRangeLow: 0,
                transmitterRangeHigh: 100,
                outputGain: 1,
                outputOffset: 0,
                wireOhms: 20,
                contactOhms: 0,
                openCircuit: 0,
                intermittentOhms: 0,
                intermittentPeriod: 2,
                intermittentDuty: 0.35,
                intermittentSeed: 0,
                supplyVolts: 24,
                receiverOhms: 250,
                cardRangeLow: 0,
                cardRangeHigh: 100,
                channelGain: 1,
                channelStuck: 0,
                channelStuckMilliamps: 12,
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
///
/// Fault behaviour, all driven by parameters:
/// - `outputGain` / `outputOffset` model a drifted transmitter. It requests
///   `I_ideal + (I_ideal − 4)(gain − 1) + offset` (a span error plus a zero
///   error), clamped to the NAMUR limits.
/// - `openCircuit` ≥ 0.5 is a broken wire on the supply side of the terminals:
///   no current flows and the transmitter terminals see 0 V.
/// - `intermittentOhms` is added to the contact resistance during the "open"
///   windows of an intermittent contact. Time is cut into windows of
///   `intermittentPeriod` seconds and `IntermittentContact.isOpen` decides each
///   one from `intermittentSeed`, so the schedule replays exactly.
public struct CurrentLoopSolver: Solver {
    public let name = "current loop"
    let loop: InstrumentLoop

    /// NAMUR NE 43 signal limits for a healthy transmitter.
    static let saturationLow = 3.8
    static let saturationHigh = 20.5

    public func step(_ state: inout WorldState, dt: Double) throws {
        let low = try state.parameter(loop.transmitterRangeLow)
        let high = try state.parameter(loop.transmitterRangeHigh)
        let fraction = (try state.value(loop.level) - low) / (high - low)
        let ideal = 4 + 16 * fraction
        let gain = state.parameter(loop.outputGain, default: 1)
        let offset = state.parameter(loop.outputOffset, default: 0)
        let requested = min(Self.saturationHigh, max(Self.saturationLow, ideal + (ideal - 4) * (gain - 1) + offset))

        let elapsed = (state.values[loop.elapsed] ?? 0) + dt
        state.values[loop.elapsed] = elapsed
        var contact = try state.parameter(loop.contactOhms)
        let intermittent = state.parameter(loop.intermittentOhms, default: 0)
        if intermittent > 0 {
            let period = max(state.parameter(loop.intermittentPeriod, default: 2), 1e-9)
            let window = Int((elapsed / period).rounded(.down))
            let seed = UInt64(max(0, state.parameter(loop.intermittentSeed, default: 0)))
            let duty = state.parameter(loop.intermittentDuty, default: 0.35)
            if IntermittentContact.isOpen(seed: seed, window: window, duty: duty) {
                contact += intermittent
            }
        }
        state.values[loop.effectiveContactOhms] = contact
        state.values[loop.requestedCurrent] = requested

        if state.parameter(loop.openCircuit, default: 0) >= 0.5 {
            state.values[loop.loopCurrent] = 0
            state.values[loop.terminalVoltage] = 0
            return
        }

        let supply = try state.parameter(loop.supplyVolts)
        let liftOff = try state.parameter(loop.liftOffVolts)
        let resistance = try state.parameter(loop.receiverOhms) + state.parameter(loop.wireOhms) + contact
        let maximum = max(0, (supply - liftOff) / resistance * 1000)
        let current = min(requested, maximum)

        state.values[loop.loopCurrent] = current
        state.values[loop.terminalVoltage] = supply - current / 1000 * resistance
    }
}

/// The deterministic schedule of an intermittent contact.
public enum IntermittentContact {
    /// Whether the contact is open (high resistance) during `window`. Each
    /// window is an independent draw with probability `duty`, hashed from the
    /// seed, so any window can be evaluated without replaying the others.
    public static func isOpen(seed: UInt64, window: Int, duty: Double) -> Bool {
        var generator = SplitMix64(seed: seed ^ SplitMix64.mix(UInt64(bitPattern: Int64(window))))
        return generator.nextUnit() < duty
    }
}

/// Analog input card: voltage across the receiver resistor, scaled to level.
///
/// The receiver voltage is physics and always follows the loop current. What
/// the card's converter *reports* (`readCurrent`) can be wrong: a stuck channel
/// reports `channelStuckMilliamps`, a drifted converter reports the current
/// times `channelGain`. The card scales its reading with its own configured
/// range (`card.rangeLow`/`rangeHigh`, defaulting to the transmitter's), which
/// is how a range that differs from the transmitter's produces a wrong level.
/// Readings under 3.6 mA or over 21 mA raise the NAMUR NE 43 underrange and
/// overrange diagnostics.
public struct AnalogInputSolver: Solver {
    public let name = "analog input"
    let loop: InstrumentLoop

    /// NAMUR NE 43 failure thresholds.
    public static let underrangeMilliamps = 3.6
    public static let overrangeMilliamps = 21.0

    public func step(_ state: inout WorldState, dt: Double) throws {
        let current = try state.value(loop.loopCurrent)
        state.values[loop.inputVolts] = try current / 1000 * state.parameter(loop.receiverOhms)
        let reading = Self.reading(of: current, in: state, loop: loop)
        state.values[loop.readCurrent] = reading
        state.values[loop.measuredLevel] = try Self.level(forReading: reading, in: state, loop: loop)
        state.values[loop.underrange] = reading < Self.underrangeMilliamps ? 1 : 0
        state.values[loop.overrange] = reading > Self.overrangeMilliamps ? 1 : 0
    }

    /// The current the card reports for a true input `current`, given the
    /// channel's (possibly faulted) parameters.
    public static func reading(of current: Double, in state: WorldState, loop: InstrumentLoop) -> Double {
        if state.parameter(loop.channelStuck, default: 0) >= 0.5 {
            return state.parameter(loop.channelStuckMilliamps, default: 12)
        }
        return current * state.parameter(loop.channelGain, default: 1)
    }

    /// The level the card shows for a converter reading, using its configured range.
    public static func level(forReading reading: Double, in state: WorldState, loop: InstrumentLoop) throws -> Double {
        let low = state.parameter(loop.cardRangeLow, default: try state.parameter(loop.transmitterRangeLow))
        let high = state.parameter(loop.cardRangeHigh, default: try state.parameter(loop.transmitterRangeHigh))
        return low + (reading - 4) / 16 * (high - low)
    }

    /// The level the card shows when a loop calibrator sources `current` into it.
    public static func level(forInjected current: Double, in state: WorldState, loop: InstrumentLoop) throws -> Double {
        try level(forReading: reading(of: current, in: state, loop: loop), in: state, loop: loop)
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

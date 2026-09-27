import Foundation
import NexusCore

/// A lumped thermal mass: a motor frame, a heat sink, a tank of water.
///
/// C·dT/dt = Q − h·(T − T_ambient)
///
/// | Parameters | Values |
/// |---|---|
/// | `heatInput` (W), `heatCapacity` (J/K), `lossCoefficient` (W/K, 1 / thermal resistance), `ambient` (°C) | `temperature` (°C), `heatLoss` (W) |
///
/// Inputs are held constant over a tick, so the solver uses the exact
/// exponential solution rather than Euler steps: large time steps stay
/// stable and hit the steady state Ta + Q/h exactly.
public struct ThermalMass: Sendable, Hashable {
    public var object: ObjectID

    public init(object: ObjectID) {
        self.object = object
    }

    public var heatInput: StateKey { StateKey(object, "heatInput") }
    public var heatCapacity: StateKey { StateKey(object, "heatCapacity") }
    public var lossCoefficient: StateKey { StateKey(object, "lossCoefficient") }
    public var ambient: StateKey { StateKey(object, "ambient") }
    public var temperature: StateKey { StateKey(object, "temperature") }
    public var heatLoss: StateKey { StateKey(object, "heatLoss") }

    /// Starts at ambient unless `initialTemperature` says otherwise.
    public func state(
        heatInput: Double, heatCapacity: Double, lossCoefficient: Double, ambient: Double = 25, initialTemperature: Double? = nil
    ) -> WorldState {
        WorldState(
            parameters: [
                self.heatInput: heatInput, self.heatCapacity: heatCapacity, self.lossCoefficient: lossCoefficient, self.ambient: ambient,
            ],
            values: [temperature: initialTemperature ?? ambient]
        )
    }

    /// Steady-state temperature for the current parameters, or nil without losses.
    public func steadyState(in state: WorldState) throws -> Double? {
        let h = try state.parameter(lossCoefficient)
        guard h > 0 else { return nil }
        return try state.parameter(ambient) + state.parameter(heatInput) / h
    }

    public var solver: ThermalSolver { ThermalSolver(mass: self) }
}

public struct ThermalSolver: Solver {
    public var mass: ThermalMass
    public var name: String { "thermal" }

    public init(mass: ThermalMass) {
        self.mass = mass
    }

    public func step(_ state: inout WorldState, dt: Double) throws {
        let q = try state.parameter(mass.heatInput)
        let c = max(1e-9, try state.parameter(mass.heatCapacity))
        let h = max(0, try state.parameter(mass.lossCoefficient))
        let ambient = try state.parameter(mass.ambient)
        let t = state.values[mass.temperature] ?? ambient

        let next: Double
        if h > 0 {
            let steady = ambient + q / h
            next = steady + (t - steady) * exp(-h * dt / c)
        } else {
            next = t + q * dt / c
        }
        state.values[mass.temperature] = next
        state.values[mass.heatLoss] = h * (next - ambient)
    }
}

/// A rotating inertia driven by a torque against viscous and Coulomb friction:
/// a conveyor drum, a pump impeller, a flywheel.
///
/// J·dω/dt = τ − b·ω − τc·sign(ω)
///
/// | Parameters | Values |
/// |---|---|
/// | `inertia` (kg·m²), `torque` (N·m), `viscousFriction` (N·m·s/rad), `coulombFriction` (N·m) | `speed` (rad/s), `rpm`, `angle` (rad), `frictionTorque` (N·m) |
///
/// At rest, Coulomb friction acts as stiction: a torque no larger than τc
/// doesn't start the inertia. When friction would reverse the motion within a
/// tick, the inertia stops instead.
public struct RotatingInertia: Sendable, Hashable {
    public var object: ObjectID

    public init(object: ObjectID) {
        self.object = object
    }

    public var inertia: StateKey { StateKey(object, "inertia") }
    public var torque: StateKey { StateKey(object, "torque") }
    public var viscousFriction: StateKey { StateKey(object, "viscousFriction") }
    public var coulombFriction: StateKey { StateKey(object, "coulombFriction") }
    public var speed: StateKey { StateKey(object, "speed") }
    public var rpm: StateKey { StateKey(object, "rpm") }
    public var angle: StateKey { StateKey(object, "angle") }
    public var frictionTorque: StateKey { StateKey(object, "frictionTorque") }

    public func state(inertia: Double, torque: Double, viscousFriction: Double, coulombFriction: Double = 0, initialSpeed: Double = 0) -> WorldState {
        WorldState(
            parameters: [
                self.inertia: inertia, self.torque: torque, self.viscousFriction: viscousFriction, self.coulombFriction: coulombFriction,
            ],
            values: [speed: initialSpeed, angle: 0]
        )
    }

    public var solver: MechanicalSolver { MechanicalSolver(body: self) }
}

public struct MechanicalSolver: Solver {
    public var body: RotatingInertia
    public var name: String { "mechanical" }

    public init(body: RotatingInertia) {
        self.body = body
    }

    public func step(_ state: inout WorldState, dt: Double) throws {
        let j = max(1e-12, try state.parameter(body.inertia))
        let tau = try state.parameter(body.torque)
        let b = max(0, try state.parameter(body.viscousFriction))
        let tauC = max(0, try state.parameter(body.coulombFriction))
        let omega = state.values[body.speed] ?? 0

        var next = omega
        var friction = 0.0
        if omega == 0 && abs(tau) <= tauC {
            // Stiction holds; friction exactly balances the applied torque.
            friction = -tau
        } else {
            let direction = omega != 0 ? (omega > 0 ? 1.0 : -1.0) : (tau > 0 ? 1.0 : -1.0)
            let drive = tau - tauC * direction
            if b > 0 {
                let steady = drive / b
                next = steady + (omega - steady) * exp(-b * dt / j)
            } else {
                next = omega + drive * dt / j
            }
            // Friction can stop the motion but never reverse it within a tick.
            if next * direction < 0 { next = 0 }
            friction = -b * next - tauC * (next == 0 ? 0 : direction)
        }
        let angle = state.values[body.angle] ?? 0
        state.values[body.speed] = next
        state.values[body.rpm] = next * 60 / (2 * Double.pi)
        state.values[body.angle] = angle + (omega + next) / 2 * dt
        state.values[body.frictionTorque] = friction
    }
}

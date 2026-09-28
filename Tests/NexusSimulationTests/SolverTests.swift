import ControlsSimulation
import Foundation
import NexusCore
import Testing

@testable import NexusSimulation

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

@Suite struct ThermalSolverTests {
    @Test func heatsToSteadyStateWithTheExpectedTimeConstant() throws {
        // C = 1000 J/K, h = 2 W/K → τ = 500 s; Q = 100 W → +50 K at steady state.
        let mass = ThermalMass(object: .make())
        let sim = try SimulationRuntime(dt: 1, state: mass.state(heatInput: 100, heatCapacity: 1_000, lossCoefficient: 2), solvers: [mass.solver])
        try sim.start()
        #expect(try sim.value(mass.temperature) == 25)
        #expect(try mass.steadyState(in: sim.state) == 75)

        try sim.run(for: 500)
        #expect(close(try sim.value(mass.temperature), 25 + 50 * (1 - exp(-1)), 1e-9), "63.2 % of the rise after one time constant")
        try sim.run(for: 10_000)
        #expect(close(try sim.value(mass.temperature), 75, 1e-6))
        #expect(close(try sim.value(mass.heatLoss), 100, 1e-6), "At steady state the loss equals the input")
    }

    @Test func largeStepsStayExactAndNoLossesRampLinearly() throws {
        let mass = ThermalMass(object: .make())
        var coarse = mass.state(heatInput: 100, heatCapacity: 1_000, lossCoefficient: 2)
        var fine = coarse
        try mass.solver.step(&coarse, dt: 500)
        for _ in 0..<500 { try mass.solver.step(&fine, dt: 1) }
        #expect(close(try coarse.value(mass.temperature), try fine.value(mass.temperature), 1e-9), "Exact integration: step size doesn't matter")

        var insulated = mass.state(heatInput: 50, heatCapacity: 1_000, lossCoefficient: 0, initialTemperature: 20)
        try mass.solver.step(&insulated, dt: 100)
        #expect(close(try insulated.value(mass.temperature), 25))

        var cooling = mass.state(heatInput: 0, heatCapacity: 1_000, lossCoefficient: 2, ambient: 20, initialTemperature: 80)
        try mass.solver.step(&cooling, dt: 10_000)
        #expect(close(try cooling.value(mass.temperature), 20, 1e-6))
    }

    @Test func aFouledHeatSinkIsAParameterFault() throws {
        let mass = ThermalMass(object: .make())
        let sim = try SimulationRuntime(dt: 10, state: mass.state(heatInput: 100, heatCapacity: 1_000, lossCoefficient: 2), solvers: [mass.solver])
        sim.inject(SimulatedFault(parameter: mass.lossCoefficient, value: 1, summary: "Fouled heat sink"))
        try sim.start()
        try sim.run(for: 20_000)
        #expect(close(try sim.value(mass.temperature), 125, 1e-6))
    }
}

@Suite struct MechanicalSolverTests {
    @Test func spinsUpToTorqueOverViscousFrictionWithTimeConstantJOverB() throws {
        // J = 0.5 kg·m², b = 0.1 N·m·s/rad → τ = 5 s; 2 N·m → 20 rad/s.
        let body = RotatingInertia(object: .make())
        let sim = try SimulationRuntime(dt: 0.01, state: body.state(inertia: 0.5, torque: 2, viscousFriction: 0.1), solvers: [body.solver])
        try sim.start()
        try sim.run(for: 5)
        #expect(close(try sim.value(body.speed), 20 * (1 - exp(-1)), 1e-9))
        try sim.run(for: 100)
        #expect(close(try sim.value(body.speed), 20, 1e-6))
        #expect(close(try sim.value(body.rpm), 20 * 60 / (2 * .pi), 1e-5))
        #expect(close(try sim.value(body.frictionTorque), -2, 1e-6), "At steady speed friction balances the drive")
        #expect(try sim.value(body.angle) > 20 * 90, "Angle integrates the speed")
    }

    @Test func stictionHoldsSmallTorquesAndCoastDownStops() throws {
        let body = RotatingInertia(object: .make())
        var state = body.state(inertia: 1, torque: 0.4, viscousFriction: 0, coulombFriction: 0.5)
        for _ in 0..<100 { try body.solver.step(&state, dt: 0.01) }
        #expect(try state.value(body.speed) == 0, "0.4 N·m can't break 0.5 N·m of stiction")
        #expect(try state.value(body.frictionTorque) == -0.4)

        // Coasting from 10 rad/s against 0.5 N·m Coulomb friction stops at t = 20 s and stays stopped.
        var coast = body.state(inertia: 1, torque: 0, viscousFriction: 0, coulombFriction: 0.5, initialSpeed: 10)
        for _ in 0..<1_000 { try body.solver.step(&coast, dt: 0.01) }
        #expect(close(try coast.value(body.speed), 5, 1e-9))
        for _ in 0..<2_000 { try body.solver.step(&coast, dt: 0.01) }
        #expect(try coast.value(body.speed) == 0)
        #expect(close(try coast.value(body.angle), 10 * 20 / 2, 1e-6), "Distance under constant deceleration")

        // Reverse torque above breakaway spins it backwards.
        var reverse = body.state(inertia: 1, torque: -1.5, viscousFriction: 0, coulombFriction: 0.5)
        try body.solver.step(&reverse, dt: 1)
        #expect(close(try reverse.value(body.speed), -1))
    }
}

@Suite struct TrainerSolverTests {
    @Test func motorAdapterMatchesTheTrainerModelStepForStep() throws {
        let spec = InductionMotorTransientSpec()
        let solver = InductionMotorSolver(motor: .make(), spec: spec)
        var world = solver.state(load: 0.6)
        var model = InductionMotorTransientState()
        for _ in 0..<500 {
            try solver.step(&world, dt: 0.01)
            let direct = InductionMotorTransientModel.advance(
                spec: spec, state: &model, lineVolts: spec.ratedLineVolts, frequencyHz: spec.ratedHz, loadTorqueFraction: 0.6, dt: 0.01
            )
            #expect(try world.value(solver.speedRPM) == direct.speedRPM)
            #expect(try world.value(solver.lineCurrent) == direct.lineCurrentAmps)
            #expect(try world.value(solver.temperature) == direct.temperatureC)
        }
    }

    @Test func motorStartsInTheRuntimeAndSagsUnderASupplyFault() throws {
        let solver = InductionMotorSolver(motor: .make())
        let sim = try SimulationRuntime(dt: 0.005, state: solver.state(load: 0.8), solvers: [solver])
        sim.watch(SimulationThreshold(name: "Up to speed", key: solver.speedRPM, level: 1_700, direction: .rising))
        try sim.start()
        let inrush = try sim.value(solver.lineCurrent)
        try sim.run(for: 5)
        let running = try sim.value(solver.speedRPM)
        #expect(running > 1_700 && running < 1_800, "Near synchronous speed under load")
        #expect(try sim.value(solver.lineCurrent) < inrush / 3, "Current falls from locked-rotor inrush")
        #expect(sim.events.contains { $0.kind == .thresholdCrossed && $0.key == solver.speedRPM })

        sim.inject(SimulatedFault(parameter: solver.lineVolts, value: 380, summary: "Supply sag"))
        try sim.run(for: 5)
        #expect(try sim.value(solver.speedRPM) < running, "Lower voltage, more slip")
        #expect(try sim.value(solver.slip) > 0)
    }

    @Test func coilAdapterMatchesTheTrainerModelAndPullsIn() throws {
        let spec = ElectromagneticCoilSpec()
        let solver = ContactorCoilSolver(coil: .make(), spec: spec)
        var world = solver.state(volts: 24)
        var model = ElectromagneticCoilState()
        for _ in 0..<200 {
            try solver.step(&world, dt: 0.001)
            let direct = ElectromagneticCoilModel.advance(spec: spec, state: &model, appliedVolts: 24, ambientC: 25, dt: 0.001)
            #expect(try world.value(solver.current) == direct.currentAmps)
            #expect(try world.value(solver.armaturePosition) == direct.armaturePosition)
            #expect(try world.value(solver.contactClosed) == (direct.contactClosed ? 1 : 0))
        }
        #expect(try world.value(solver.contactClosed) == 1, "24 V pulls the contactor in within 200 ms")
    }

    @Test func aFailingCoilNeverPullsIn() throws {
        let solver = ContactorCoilSolver(coil: .make())
        let sim = try SimulationRuntime(dt: 0.001, state: solver.state(volts: 24), solvers: [solver])
        sim.inject(SimulatedFault(parameter: solver.coilOhms, value: 400, summary: "Open-ish coil winding"))
        try sim.start()
        try sim.run(for: 0.5)
        #expect(try sim.value(solver.contactClosed) == 0, "24 V / 400 Ω = 60 mA is below the 0.23 A pickup")
        #expect(close(try sim.value(solver.current), 0.06, 1e-6))
    }
}

import Foundation
import NexusCore
import Testing
@testable import NexusSimulation

private func makeLoop() -> InstrumentLoop {
    InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())
}

private func runtime(_ loop: InstrumentLoop, fault: Double? = nil) throws -> SimulationRuntime {
    let runtime = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
    if let fault {
        runtime.inject(SimulatedFault(parameter: loop.contactOhms, value: fault, summary: "Corroded terminal"))
    }
    try runtime.start()
    return runtime
}

@Suite struct InstrumentLoopTests {
    @Test func loopPhysicsMatchesHandCalculation() throws {
        let loop = makeLoop()
        let sim = try runtime(loop)
        // Level 50 % → 12 mA; 24 V − 12 mA × (250 + 20) Ω = 20.76 V at the transmitter.
        #expect(abs(try sim.value(loop.loopCurrent) - 12) < 1e-9)
        #expect(abs(try sim.value(loop.terminalVoltage) - 20.76) < 1e-9)
        #expect(abs(try sim.value(loop.inputVolts) - 3) < 1e-9)
        #expect(abs(try sim.value(loop.measuredLevel) - 50) < 1e-9)
    }

    @Test func healthyLoopSettlesAtSetpointWithoutOverflow() throws {
        let loop = makeLoop()
        let sim = try runtime(loop)
        try sim.run(for: 600)
        #expect(abs(try sim.value(loop.level) - 90) < 0.5)
        #expect(abs(try sim.value(loop.measuredLevel) - 90) < 0.5)
        #expect(sim.history.allSatisfy { $0.values[loop.overflowing] == 0 })
    }

    @Test func contactResistanceClampsTheSignalAndOverflowsTheTank() throws {
        let loop = makeLoop()
        let sim = try runtime(loop, fault: 400)
        // I_max = (24 − 12) V / 670 Ω = 17.91 mA → the card can never read above 86.9 %.
        let ceiling = (12.0 / 670 * 1000 - 4) / 16 * 100
        try sim.run(for: 600)
        #expect(try sim.value(loop.overflowing) == 1)
        #expect(abs(try sim.value(loop.measuredLevel) - ceiling) < 1e-9)
        #expect(abs(try sim.value(loop.terminalVoltage) - 12) < 1e-9, "Transmitter pinned at lift-off")
        #expect(try sim.value(loop.requestedCurrent) > sim.value(loop.loopCurrent))

        // Clearing the fault lets the signal recover and the level come back down.
        let fault = try #require(sim.state.faults.first)
        sim.clear(fault.id)
        try sim.run(for: 900)
        #expect(try sim.value(loop.overflowing) == 0)
        #expect(abs(try sim.value(loop.level) - 90) < 0.5)
    }

    @Test func runsAreDeterministic() throws {
        let loop = makeLoop()
        let a = try runtime(loop, fault: 400)
        let b = try runtime(loop, fault: 400)
        try a.run(for: 120)
        try b.run(for: 120)
        #expect(a.history == b.history)
    }

    @Test func firstDivergenceIsTheUpstreamVoltageNotTheLevelReading() throws {
        let loop = makeLoop()
        let reference = try runtime(loop)
        let actual = try runtime(loop, fault: 400)
        try reference.run(for: 600)
        try actual.run(for: 600)

        let path = [loop.terminalVoltage, loop.loopCurrent, loop.measuredLevel, loop.level]
        let divergence = try #require(DivergenceDetector.firstDivergence(
            reference: reference.history, actual: actual.history, signalPath: path, defaultTolerance: 0.05
        ))
        // The voltage drop exists from t = 0, long before the level reading is wrong.
        #expect(divergence.tick == 0)
        #expect(divergence.key == loop.terminalVoltage)
        #expect(divergence.actual < divergence.expected)

        // Watching only the reading finds the later, downstream symptom.
        let late = try #require(DivergenceDetector.firstDivergence(
            reference: reference.history, actual: actual.history, signalPath: [loop.measuredLevel], defaultTolerance: 0.05
        ))
        #expect(late.tick > 0)
        #expect(DivergenceDetector.firstDivergence(
            reference: reference.history, actual: reference.history, signalPath: path
        ) == nil)
    }

    @Test func measurementsFromTheRuntimeAreModeledTruth() throws {
        let loop = makeLoop()
        let sim = try runtime(loop)
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let reading = try sim.measurement(of: loop.terminalVoltage, unit: "V", at: date)
        #expect(reading.truth == .modeled)
        #expect(reading.provenance.origin == .simulation(run: sim.run))
        #expect(reading.testPoint == loop.terminal)
        try reading.validate()
    }

    @Test func invalidConfigurationIsReported() throws {
        let loop = makeLoop()
        #expect(throws: SimulationError.invalidTimeStep(0)) {
            try SimulationRuntime(dt: 0, state: loop.healthyState(), solvers: loop.solvers)
        }
        var state = loop.healthyState()
        state.parameters[loop.supplyVolts] = nil
        let sim = try SimulationRuntime(dt: 1, state: state, solvers: loop.solvers)
        #expect(throws: SimulationError.missingParameter(loop.supplyVolts)) { try sim.start() }
    }
}

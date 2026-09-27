import Foundation
import NexusCore
import Testing
@testable import NexusSimulation

private func makeLoop() -> InstrumentLoop {
    InstrumentLoop(tank: .make(), transmitter: .make(), terminal: .make(), card: .make(), controller: .make(), valve: .make())
}

/// A loop at level 50 % (12 mA when healthy), settled at t = 0 with `faults` active.
private func started(_ loop: InstrumentLoop, _ faults: [SimulatedFault]) throws -> SimulationRuntime {
    let runtime = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
    for fault in faults {
        runtime.inject(fault)
    }
    try runtime.start()
    return runtime
}

private func close(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(actual - expected) <= tolerance
}

@Suite struct LoopFaultTests {
    @Test func openWireStopsLoopCurrentAndTheCardSeesUnderrange() throws {
        let loop = makeLoop()
        let sim = try started(loop, loop.faults(.openWire, severity: 1))
        // The transmitter still asks for 12 mA, but nothing flows.
        #expect(close(try sim.value(loop.requestedCurrent), 12))
        #expect(try sim.value(loop.loopCurrent) == 0)
        #expect(try sim.value(loop.terminalVoltage) == 0)
        #expect(try sim.value(loop.inputVolts) == 0)
        #expect(try sim.value(loop.readCurrent) < AnalogInputSolver.underrangeMilliamps)
        #expect(try sim.value(loop.underrange) == 1)
        // 0 mA scales to (0 − 4) / 16 × 100 = −25 %.
        #expect(close(try sim.value(loop.measuredLevel), -25))
    }

    @Test func transmitterDriftAppliesSpanAndZeroError() throws {
        let loop = makeLoop()
        let sim = try started(loop, loop.faults(.transmitterDrift, severity: 1))
        // Gain 0.7, offset −0.8 mA: 12 + (12 − 4)(0.7 − 1) − 0.8 = 8.8 mA.
        #expect(close(try sim.value(loop.requestedCurrent), 8.8))
        #expect(close(try sim.value(loop.loopCurrent), 8.8))
        // 24 V − 8.8 mA × 270 Ω = 21.624 V; the card shows (8.8 − 4) / 16 = 30 %.
        #expect(close(try sim.value(loop.terminalVoltage), 21.624))
        #expect(close(try sim.value(loop.measuredLevel), 30))
    }

    @Test func stuckChannelReportsAFixedValueWhileTheLoopIsHealthy() throws {
        let loop = makeLoop()
        let sim = try started(loop, loop.faults(.cardChannelStuck, severity: 0.5))
        // Stuck at 20 − 4 × 0.5 = 18 mA → 87.5 %; the receiver still carries 12 mA (3 V).
        #expect(close(try sim.value(loop.loopCurrent), 12))
        #expect(close(try sim.value(loop.inputVolts), 3))
        #expect(close(try sim.value(loop.readCurrent), 18))
        #expect(close(try sim.value(loop.measuredLevel), 87.5))
        try sim.run(for: 60)
        #expect(close(try sim.value(loop.measuredLevel), 87.5), "The reading never moves")
        #expect(try sim.value(loop.level) != 50)
    }

    @Test func channelGainErrorReadsLowByItsFactor() throws {
        let loop = makeLoop()
        let sim = try started(loop, loop.faults(.cardReadsLow, severity: 0.5))
        // Gain 0.8: 12 mA reads as 9.6 mA → (9.6 − 4) / 16 = 35 %.
        #expect(close(try sim.value(loop.readCurrent), 9.6))
        #expect(close(try sim.value(loop.measuredLevel), 35))
        #expect(close(try sim.value(loop.inputVolts), 3), "The receiver voltage is physics, not the card's opinion")
    }

    @Test func wrongScalingReadsHighAndTheControllerSettlesLow() throws {
        let loop = makeLoop()
        let sim = try started(loop, loop.faults(.wrongScaling, severity: 0.5))
        // Card range 0–120 % on a 0–100 % transmitter: 12 mA → 60 %.
        #expect(close(try sim.value(loop.loopCurrent), 12))
        #expect(close(try sim.value(loop.measuredLevel), 60))
        // The controller holds the reading at 90 %, so the tank sits at 90 / 1.2 = 75 %.
        try sim.run(for: 900)
        #expect(abs(try sim.value(loop.measuredLevel) - 90) < 0.5)
        #expect(abs(try sim.value(loop.level) - 75) < 0.5)
        #expect(close(try AnalogInputSolver.level(forInjected: 12, in: sim.state, loop: loop), 60))
    }

    @Test func supplySagLeavesTooLittleCompliance() throws {
        let loop = makeLoop()
        let partial = try started(loop, loop.faults(.supplySag, severity: 0.5))
        // 13 V supply: I_max = (13 − 12) V / 270 Ω = 3.7037 mA, pinned at lift-off.
        let ceiling = 1.0 / 270 * 1000
        #expect(close(try partial.value(loop.loopCurrent), ceiling))
        #expect(close(try partial.value(loop.terminalVoltage), 12))
        #expect(close(try partial.value(loop.measuredLevel), (ceiling - 4) / 16 * 100))
        #expect(try partial.value(loop.underrange) == 0, "3.70 mA is still above the 3.6 mA NAMUR limit")

        // 10 V supply is below lift-off: no current at all.
        let full = try started(loop, loop.faults(.supplySag, severity: 1))
        #expect(try full.value(loop.loopCurrent) == 0)
        #expect(close(try full.value(loop.terminalVoltage), 10))
        #expect(try full.value(loop.underrange) == 1)
    }

    @Test func contactResistanceSeverityMapsToOhms() throws {
        let loop = makeLoop()
        // 700 Ω: I_max = 12 V / 970 Ω = 12.37 mA, enough for 12 mA.
        let mild = try started(loop, loop.faults(.contactResistance, severity: 0))
        #expect(close(try mild.value(loop.loopCurrent), 12))
        #expect(close(try mild.value(loop.terminalVoltage), 24 - 0.012 * 970))
        // 2000 Ω: I_max = 12 V / 2270 Ω = 5.286 mA.
        let severe = try started(loop, loop.faults(.contactResistance, severity: 1))
        #expect(close(try severe.value(loop.loopCurrent), 12.0 / 2270 * 1000))
        #expect(close(try severe.value(loop.terminalVoltage), 12))
    }

    @Test func intermittentContactFollowsItsSeededSchedule() throws {
        let loop = makeLoop()
        let sim = try started(loop, loop.faults(.intermittentContact, severity: 0, seed: 7))
        try sim.run(for: 120)
        // 1000 Ω in series when open: I_max = 12 V / 1270 Ω = 9.449 mA.
        let ceiling = 12.0 / 1270 * 1000
        var open = 0
        for snapshot in sim.history {
            let elapsed = try #require(snapshot.values[loop.elapsed])
            let window = Int((elapsed / 2).rounded(.down))
            let requested = try #require(snapshot.values[loop.requestedCurrent])
            let current = try #require(snapshot.values[loop.loopCurrent])
            if IntermittentContact.isOpen(seed: 7, window: window, duty: 0.35) {
                open += 1
                #expect(snapshot.values[loop.effectiveContactOhms] == 1000)
                #expect(close(current, min(requested, ceiling)))
            } else {
                #expect(snapshot.values[loop.effectiveContactOhms] == 0)
                #expect(close(current, requested))
            }
        }
        #expect(open > 0 && open < sim.history.count, "Both states occur within two minutes")

        let again = try started(loop, loop.faults(.intermittentContact, severity: 0, seed: 7))
        try again.run(for: 120)
        #expect(again.history == sim.history)
        let other = try started(loop, loop.faults(.intermittentContact, severity: 0, seed: 8))
        try other.run(for: 120)
        #expect(other.history != sim.history)
    }

    @Test func faultKindsProduceTheDocumentedOverrides() {
        let loop = makeLoop()
        func overrides(_ kind: LoopFaultKind, _ severity: Double) -> [StateKey: Double] {
            Dictionary(uniqueKeysWithValues: loop.faults(kind, severity: severity, seed: 3).map { ($0.parameter, $0.value) })
        }
        func matches(_ kind: LoopFaultKind, _ severity: Double, _ expected: [StateKey: Double]) -> Bool {
            let actual = overrides(kind, severity)
            return Set(actual.keys) == Set(expected.keys) && expected.allSatisfy { close(actual[$0.key]!, $0.value, 1e-12) }
        }
        #expect(matches(.contactResistance, 0.5, [loop.contactOhms: 1350]))
        #expect(matches(.openWire, 0.2, [loop.openCircuit: 1]))
        #expect(matches(.transmitterDrift, 0.5, [loop.outputGain: 0.85, loop.outputOffset: -0.4]))
        #expect(matches(.cardChannelStuck, 1, [loop.channelStuck: 1, loop.channelStuckMilliamps: 16]))
        #expect(matches(.cardReadsLow, 1, [loop.channelGain: 0.6]))
        #expect(matches(.wrongScaling, 1, [loop.cardRangeHigh: 140]))
        #expect(matches(.supplySag, 0.5, [loop.supplyVolts: 13]))
        #expect(matches(.intermittentContact, 1, [loop.intermittentOhms: 4000, loop.intermittentSeed: 3]))
        // Severity is clamped to 0…1.
        #expect(overrides(.supplySag, 7) == overrides(.supplySag, 1))
        #expect(Set(LoopFaultKind.allCases.map(\.statement)).count == LoopFaultKind.allCases.count)
    }

    @Test func statesWithoutTheNewParametersSolveExactlyAsHealthy() throws {
        let loop = makeLoop()
        var legacy = loop.healthyState()
        for key in [
            loop.outputGain, loop.outputOffset, loop.openCircuit, loop.intermittentOhms, loop.intermittentPeriod,
            loop.intermittentDuty, loop.intermittentSeed, loop.cardRangeLow, loop.cardRangeHigh, loop.channelGain,
            loop.channelStuck, loop.channelStuckMilliamps,
        ] {
            legacy.parameters[key] = nil
        }
        let a = try SimulationRuntime(dt: 0.5, state: legacy, solvers: loop.solvers)
        let b = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        try a.start()
        try b.start()
        try a.run(for: 120)
        try b.run(for: 120)
        #expect(a.history == b.history)
    }

    @Test func splitMixIsDeterministicAndUniformEnough() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        let first = (0..<5).map { _ in a.next() }
        #expect(first == (0..<5).map { _ in b.next() })
        // Reference value of SplitMix64 seeded with 0.
        var zero = SplitMix64(seed: 0)
        #expect(zero.next() == 0xE220_A839_7B1D_CDAF)
        var unit = SplitMix64(seed: 1)
        let mean = (0..<10_000).map { _ in unit.nextUnit() }.reduce(0, +) / 10_000
        #expect(abs(mean - 0.5) < 0.02)
    }
}

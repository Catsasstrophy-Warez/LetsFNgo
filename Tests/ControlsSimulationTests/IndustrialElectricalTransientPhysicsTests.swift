import XCTest
@testable import ControlsSimulation

final class IndustrialElectricalTransientPhysicsTests: XCTestCase {
    func testCapacitorChargesExponentiallyAndStoresEnergy() {
        var v = 0.0
        var result = TransientRCResult(voltage: 0, currentAmps: 0, storedJoules: 0)
        for _ in 0..<1000 {
            result = TransientRCModel.advanceCapacitor(voltage: v, sourceVolts: 24, resistanceOhms: 1000, capacitanceFarads: 0.001, dt: 0.001)
            v = result.voltage
        }
        XCTAssertGreaterThan(v, 15)
        XCTAssertLessThan(v, 16)
        XCTAssertGreaterThan(result.storedJoules, 0.1)
    }

    func testInductorCurrentCannotChangeInstantaneously() {
        let first = TransientRLModel.advanceInductor(currentAmps: 0, sourceVolts: 24, resistanceOhms: 12, inductanceHenries: 1, dt: 0.001)
        XCTAssertGreaterThan(first.currentAmps, 0)
        XCTAssertLessThan(first.currentAmps, 0.03)
        XCTAssertGreaterThan(first.voltageAcrossInductor, 23)
    }

    func testCoilPullsInThenDropsOutWithHysteresis() {
        var state = ElectromagneticCoilState()
        let spec = ElectromagneticCoilSpec()
        var on: ElectromagneticCoilSnapshot!
        for _ in 0..<300 { on = ElectromagneticCoilModel.advance(spec: spec, state: &state, appliedVolts: 24, dt: 0.001) }
        XCTAssertTrue(on.contactClosed)
        XCTAssertGreaterThan(on.armaturePosition, 0.95)
        var off: ElectromagneticCoilSnapshot!
        for _ in 0..<300 { off = ElectromagneticCoilModel.advance(spec: spec, state: &state, appliedVolts: 0, dt: 0.001) }
        XCTAssertFalse(off.contactClosed)
        XCTAssertLessThan(off.armaturePosition, 0.05)
    }

    func testContactArcAccumulatesErosionWhenOpeningLoad() {
        var state = ContactArcState()
        let spec = ContactArcSpec(arcStrikeVolts: 18, arcHoldCurrentAmps: 0.01, arcResistanceOhms: 10, erosionJoulesToFailure: 20)
        var snap: ContactArcSnapshot!
        for _ in 0..<100 { snap = ContactArcModel.advance(spec: spec, state: &state, commandClosed: false, bouncing: false, sourceVolts: 48, loadResistanceOhms: 20, dt: 0.001) }
        XCTAssertTrue(snap.arcActive)
        XCTAssertGreaterThan(state.erosionJoules, 0)
    }

    func testTransformerClosingAngleCanProduceSaturationAndInrush() {
        var state = TransformerTransientState(residualFluxWebers: 1.2)
        let spec = TransformerTransientSpec(coreSaturationFluxWebers: 1.25, saturatedInductanceHenries: 0.05)
        var saturated = false
        for n in 0..<500 {
            let snap = TransformerTransientModel.advance(spec: spec, state: &state, time: Double(n) * 0.0001, closingAngleRadians: 0, dt: 0.0001)
            saturated = saturated || snap.saturated
        }
        XCTAssertTrue(saturated)
        XCTAssertGreaterThan(state.peakInrushAmps, 1)
    }

    func testMotorStartsWithHighCurrentAndAccelerates() {
        var state = InductionMotorTransientState()
        let spec = InductionMotorTransientSpec(ratedHP: 10)
        let initial = InductionMotorTransientModel.advance(spec: spec, state: &state, lineVolts: 480, frequencyHz: 60, loadTorqueFraction: 0.5, dt: 0.001)
        let initialCurrent = initial.lineCurrentAmps
        var last = initial
        for _ in 0..<5000 { last = InductionMotorTransientModel.advance(spec: spec, state: &state, lineVolts: 480, frequencyHz: 60, loadTorqueFraction: 0.5, dt: 0.001) }
        XCTAssertGreaterThan(last.speedRPM, 1000)
        XCTAssertLessThan(last.lineCurrentAmps, initialCurrent)
        XCTAssertGreaterThan(state.peakCurrentAmps, last.lineCurrentAmps)
    }

    func testVFDPrechargeBuildsBusAndPWMHasTwoLevels() {
        var state = VFDTransientState()
        let spec = VFDTransientSpec()
        var snap: VFDTransientSnapshot!
        for _ in 0..<3000 { snap = VFDTransientModel.advance(spec: spec, state: &state, lineRMSVolts: 480, commandHz: 30, loadPowerKW: 0, enable: false, dt: 0.0005) }
        XCTAssertTrue(state.prechargeComplete)
        XCTAssertGreaterThan(snap.dcBusVolts, 500)
        let a = VFDTransientModel.pwmSample(dcBusVolts: 680, modulationIndex: 0.8, electricalAngle: 0.7, carrierPhase: 0.1)
        let b = VFDTransientModel.pwmSample(dcBusVolts: 680, modulationIndex: 0.8, electricalAngle: 0.7, carrierPhase: 0.6)
        XCTAssertTrue(abs(a) == 340)
        XCTAssertTrue(abs(b) == 340)
    }

    func testMeggerBlocksEnergizedTestAndModelsPolarization() {
        var state = InsulationState()
        let spec = InsulationSpec(initialMegohms: 100)
        let blocked = InsulationMeggerModel.advance(spec: spec, state: &state, testVolts: 500, testSeconds: 60, equipmentEnergized: true)
        XCTAssertTrue(blocked.unsafeEnergizedTestBlocked)
        let safe = InsulationMeggerModel.advance(spec: spec, state: &state, testVolts: 500, testSeconds: 60, equipmentEnergized: false)
        XCTAssertFalse(safe.unsafeEnergizedTestBlocked)
        XCTAssertGreaterThan(safe.apparentMegohms, 100)
        XCTAssertGreaterThan(safe.polarizationIndex, 1)
        XCTAssertTrue(safe.dischargeRequired)
    }

    func testShortCircuitModelIncludesAsymmetricalPeak() {
        let f = ShortCircuitTransientModel.sample(spec: .init(rmsVolts: 480, sourceImpedanceOhms: 0.08, xToR: 6), time: 0.005, closingAngle: .pi/2)
        XCTAssertEqual(f.symmetricalRMSAmps, 6000, accuracy: 0.01)
        XCTAssertGreaterThan(f.peakAsymmetricalAmps, sqrt(2) * f.symmetricalRMSAmps)
    }

    func testSelectiveCoordinationPrefersDownstreamDevice() {
        let result = SelectiveCoordinationModel.evaluate(devices: [
            .init(id: "branch", ratedAmps: 10, instantaneousMultiple: 5, i2tCapacity: 500, upstream: false),
            .init(id: "main", ratedAmps: 100, instantaneousMultiple: 10, i2tCapacity: 50_000, upstream: true)
        ], faultRMSAmps: 200)
        XCTAssertEqual(result.firstTripDeviceID, "branch")
        XCTAssertTrue(result.selective)
    }

    func testOscilloscopeCalculatesPeakAndRMS() {
        let samples = (0..<1000).map { i in OscilloscopeSample(time: Double(i)/1000, channels: ["v": 10*sin(2*Double.pi*Double(i)/100)]) }
        let c = OscilloscopeCapture(sampleRateHz: 1000, samples: samples)
        XCTAssertEqual(c.peak("v")!, 10, accuracy: 0.01)
        XCTAssertEqual(c.rms("v")!, 10/sqrt(2), accuracy: 0.05)
    }

    func testIndustrialTransientRuntimeProducesCoupledWaveforms() {
        var runtime = IndustrialTransientRuntime()
        for _ in 0..<3000 { _ = runtime.advance(controlVolts: 24, lineVolts: 480, commandHz: 60, loadTorqueFraction: 0.4, dt: 0.001) }
        XCTAssertGreaterThan(runtime.capture.samples.count, 1000)
        XCTAssertGreaterThan(runtime.capture.peak("coilA") ?? 0, 0.1)
        XCTAssertGreaterThan(runtime.vfdState.dcBusVolts, 400)
        XCTAssertGreaterThan(runtime.motorState.speedRPM, 500)
    }
    func testSuppressionChangesInductiveKickAndReleaseTime() {
        let none = CoilSuppressionModel.release(currentAmps: 0.33, inductanceHenries: 0.2, coilResistanceOhms: 72, suppression: .none)
        let diode = CoilSuppressionModel.release(currentAmps: 0.33, inductanceHenries: 0.2, coilResistanceOhms: 72, suppression: .flybackDiode)
        let mov = CoilSuppressionModel.release(currentAmps: 0.33, inductanceHenries: 0.2, coilResistanceOhms: 72, suppression: .mov, clampVolts: 48)
        XCTAssertGreaterThan(none.peakVolts, mov.peakVolts)
        XCTAssertGreaterThan(diode.releaseTimeSeconds, mov.releaseTimeSeconds)
        XCTAssertGreaterThan(diode.dissipatedJoules, 0)
    }

    func testInsulationDegradesWithMoistureHeatAndStress() {
        var state = InsulationState()
        let spec = InsulationSpec(initialMegohms: 500, moistureFactor: 0.6, temperatureC: 70)
        let first = InsulationMeggerModel.advanceDegradation(spec: spec, state: &state, elapsedHours: 1000, electricalStressPerUnit: 1.3, thermalCycles: 100)
        let second = InsulationMeggerModel.advanceDegradation(spec: spec, state: &state, elapsedHours: 1000, electricalStressPerUnit: 1.3, thermalCycles: 100)
        XCTAssertGreaterThan(second.degradation, first.degradation)
        XCTAssertLessThan(second.estimatedMegohms, first.estimatedMegohms)
        XCTAssertGreaterThan(second.leakageMicroampsAt500V, first.leakageMicroampsAt500V)
    }

    func testGroundFaultPathProducesFaultCurrentAndBondRise() {
        let r = GroundFaultPathModel.solve(.init(lineToGroundVolts: 277, sourceImpedanceOhms: 0.08, equipmentBondOhms: 0.04, faultResistanceOhms: 0.5, parallelLeakageOhms: 100_000))
        XCTAssertGreaterThan(r.faultCurrentAmps, 400)
        XCTAssertGreaterThan(r.bondVoltageRise, 10)
        XCTAssertGreaterThan(r.leakageCurrentAmps, 0)
    }

    func testTopologyTransientBridgeRunsAcrossAll28HeroMachines() throws {
        for machineKind in PlayableMachineKind.allCases {
            let scenario = try TopologyProceduralFaultGenerator.generate(machine: machineKind, seed: 20260902, difficulty: .technician)
            var machine = try FullyClosedLoopMachineRuntime(machine: machineKind)
            var runtime = TopologyTransientElectricalRuntime(scenario: scenario)
            let snapshot = runtime.advance(seconds: 0.01, to: &machine, substepSeconds: 0.002, commandHz: 30, loadTorqueFraction: 0.25)
            XCTAssertFalse(snapshot.scope.samples.isEmpty, machineKind.rawValue)
            XCTAssertTrue(snapshot.dcBusVolts.isFinite, machineKind.rawValue)
            XCTAssertTrue(snapshot.coilCurrentAmps.isFinite, machineKind.rawValue)
            XCTAssertFalse(snapshot.steadyState.circuitSnapshots.isEmpty, machineKind.rawValue)
        }
    }

    func testTransientDriveTripBecomesRealMachineOutputFault() throws {
        let scenario = try TopologyProceduralFaultGenerator.generate(machine: .packagingCell, seed: 31415, difficulty: .technician)
        var machine = try FullyClosedLoopMachineRuntime(machine: .packagingCell)
        var runtime = TopologyTransientElectricalRuntime(scenario: scenario)
        runtime.transient.vfdState.prechargeComplete = true
        runtime.transient.vfdState.dcBusVolts = 100
        _ = runtime.advance(seconds: 0.002, to: &machine, substepSeconds: 0.001, commandHz: 60, loadTorqueFraction: 0.5)
        XCTAssertTrue(runtime.transient.vfdState.tripped)
        XCTAssertTrue(machine.plant.faults.contains { $0.id.contains("TRANSIENT|VFD-TRIP") } || machine.controls.faults.contains { $0.id.contains("TRANSIENT|VFD-TRIP") })
    }

}

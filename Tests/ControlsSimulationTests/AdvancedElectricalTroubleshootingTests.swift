import XCTest
@testable import ControlsSimulation

final class AdvancedElectricalTroubleshootingTests: XCTestCase {
    func testLoadedVoltageDropExposesHighResistanceConnection() {
        let result = AdvancedMeterPhysics.voltageDrop(sourceVolts: 24, loadCurrentAmps: 0.45, connectionResistanceOhms: 8)
        XCTAssertEqual(result.value!, 3.6, accuracy: 0.001)
        XCTAssertTrue(result.interpretation.contains("Excessive"))
    }

    func testLoZCollapsesGhostVoltage() {
        let a = AdvancedElectricalNode(id:"a",label:"floating",dcPotential:0,sourceImpedanceOhms:1_000_000)
        let b = AdvancedElectricalNode(id:"b",label:"common",dcPotential:0)
        let highZ = AdvancedMeterPhysics.voltage(red:a, black:b, configuration:.init(function:.voltsDC), ghostCouplingVolts:18)
        let loZ = AdvancedMeterPhysics.voltage(red:a, black:b, configuration:.init(function:.loZDC), ghostCouplingVolts:18)
        XCTAssertGreaterThan(highZ.value!, 10)
        XCTAssertLessThan(loZ.value!, 1)
    }

    func testThreePhaseDetectsPhaseLoss() {
        let result = AdvancedMeterPhysics.threePhase(lineToLineVolts:[480,478,241], phaseCurrents:[18,17.8,0.3])
        XCTAssertTrue(result.phaseLoss)
        XCTAssertGreaterThan(result.currentImbalancePercent, 50)
    }

    func testDiagnosticReasoningRewardsDiscriminatingEvidence() {
        var s = DiagnosticReasoningSession(symptom:"Motor no start", hypotheses:["PLC","Wiring","Motor"])
        s.record(.init(type:.voltageDrop,testPoint:"TB3-17",result:"4.2 V under load",elapsedSeconds:30,discriminatingPower:5), supports:["Wiring"], eliminates:["PLC"])
        s.prove("Wiring"); s.repairVerified=true; s.regressionVerified=true
        XCTAssertEqual(s.hypotheses.first(where:{$0.title=="PLC"})?.state, .eliminated)
        XCTAssertGreaterThan(s.score, 90)
    }

    func testGeneratorIsDeterministicAndDifficultyAware() {
        let path:[ElectricalPathElement] = [
            .init(id:"s",kind:.source,tag:"24V",nominalVoltage:24),
            .init(id:"f",kind:.protection,tag:"FU1",nominalVoltage:24),
            .init(id:"w",kind:.conductor,tag:"101",nominalVoltage:24),
            .init(id:"o",kind:.ioChannel,tag:"O:1",nominalVoltage:24),
            .init(id:"l",kind:.load,tag:"K1",nominalVoltage:24),
            .init(id:"c",kind:.common,tag:"0V",nominalVoltage:0)
        ]
        let a = ProceduralElectricalFaultGenerator.generate(seed:42,difficulty:.expertNightmare,path:path)
        let b = ProceduralElectricalFaultGenerator.generate(seed:42,difficulty:.expertNightmare,path:path)
        XCTAssertEqual(a,b)
        XCTAssertGreaterThanOrEqual(a.faults.count,2)
        XCTAssertFalse(a.misleadingClues.isEmpty)
    }

    func testPracticumCatalogCoversCoreTroubleshootingDomains() {
        let all = ElectricalTroubleshootingPracticumCatalog.all
        XCTAssertGreaterThanOrEqual(all.count,6)
        XCTAssertTrue(all.contains{$0.faults.contains{$0.kind == .looseHighResistanceTerminal}})
        XCTAssertTrue(all.contains{$0.faults.contains{$0.kind == .shieldGroundFault}})
        XCTAssertTrue(all.contains{$0.faults.contains{$0.kind == .contactorPoleFailure}})
        XCTAssertTrue(all.contains{$0.faults.contains{$0.kind == .edmFeedbackFailure}})
        XCTAssertTrue(all.contains{$0.faults.contains{$0.kind == .swappedWires}})
        XCTAssertTrue(all.contains{$0.difficulty == .expertNightmare})
    }

    func testFaultLibraryIncludesPreviousTechnicianAndIntermittentErrors() {
        let kinds = Set(AdvancedElectricalFaultKind.allCases)
        for required: AdvancedElectricalFaultKind in [.jumperLeftInstalled,.wrongSensorPolarity,.defaultedVFDParameters,.undocumentedTemporaryRepair,.positionDependentCableOpen,.moistureLeakage,.contactFailsUnderLoad,.drawingFieldMismatch] {
            XCTAssertTrue(kinds.contains(required))
        }
    }
}

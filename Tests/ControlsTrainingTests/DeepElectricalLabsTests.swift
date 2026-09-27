import XCTest
@testable import ControlsTraining

final class DeepElectricalLabsTests: XCTestCase {
    func testMeterDCVoltageDifference() {
        let a = ElectricalNode(id:"a",label:"+24",dcVoltage:24,acVoltage:nil,connectedGroup:"a",currentMilliamps:nil,safeToProbe:true)
        let b = ElectricalNode(id:"b",label:"COM",dcVoltage:0,acVoltage:nil,connectedGroup:"b",currentMilliamps:nil,safeToProbe:true)
        XCTAssertEqual(VirtualMeter.measure(mode:.dcVolts,red:a,black:b).numericValue ?? -1,24,accuracy:0.001)
    }
    func testMeterBlocksResistanceOnEnergizedCircuit() {
        let a = ElectricalNode(id:"a",label:"+24",dcVoltage:24,acVoltage:nil,connectedGroup:"a",currentMilliamps:nil,safeToProbe:true)
        let b = ElectricalNode(id:"b",label:"COM",dcVoltage:0,acVoltage:nil,connectedGroup:"b",currentMilliamps:nil,safeToProbe:true)
        XCTAssertNotNil(VirtualMeter.measure(mode:.ohms,red:a,black:b).safetyWarning)
    }
    func testSchematicChallengeValidation() {
        var workbench = SchematicWorkbench()
        let p = SchematicPort(id:"1",label:"1",isSource:true)
        workbench.add(.init(id:"p",kind:.powerSource,tag:"PWR",label:"Power",ports:[p]))
        XCTAssertFalse(workbench.validate(DeepElectricalLabCatalog.schematicChallenges[0]).isEmpty)
    }
    func testRackRejectsDuplicateChannels() {
        var rack = DeepElectricalLabCatalog.defaultRack
        rack.assignments = [
            .init(id:"a",moduleID:"m2",channel:0,signal:.pnp24V,tag:"A",fieldDevice:"PE1",commonGroup:"DC0"),
            .init(id:"b",moduleID:"m2",channel:0,signal:.pnp24V,tag:"B",fieldDevice:"PE2",commonGroup:"DC0")
        ]
        XCTAssertTrue(rack.validate().contains(where: {$0.contains("Multiple field devices")}))
    }
    func testCalibrationIdentifiesZeroShift() {
        let lab = DeepElectricalLabCatalog.calibrationLabs[0]
        let result = CalibrationAnalyzer.analyze(points:lab.points,tolerancePercent:0.5)
        XCTAssertFalse(result?.passed ?? true)
        XCTAssertTrue(result?.recommendation.contains("zero") ?? false)
    }
    func testVFDRequiresProofSteps() {
        var session = VFDCommissioningSession(parameters:DeepElectricalLabCatalog.vfdParameters.map { var p=$0; p.value=p.expected; return p })
        XCTAssertFalse(session.isCommissioned)
        session.rotationVerified=true; session.uncoupledBumpTestComplete=true; session.loadedRunComplete=true; session.faultHistoryReviewed=true
        XCTAssertTrue(session.isCommissioned)
    }
    func testHeroMachinesAreMultiFault() {
        XCTAssertGreaterThanOrEqual(DeepElectricalLabCatalog.heroMachines.count,3)
        for machine in DeepElectricalLabCatalog.heroMachines { XCTAssertGreaterThanOrEqual(machine.faults.count,3) }
    }
    func testEveryElectricalChapterHasCertification() {
        XCTAssertEqual(Set(DeepElectricalLabCatalog.certifications.map(\.chapter)),Set(ElectricalChapter.allCases))
    }
    func testCertificationCriticalFailureFailsAttempt() {
        let cert=DeepElectricalLabCatalog.certifications[0]
        var scores=Dictionary(uniqueKeysWithValues:cert.rubrics.map { ($0.domain,100.0) })
        if cert.rubrics.contains(where: {$0.domain == .meterUse}) { scores[.meterUse]=70 }
        let result=ElectricalCertificationScore(certificationID:cert.id,domainScores:scores,safetyViolation:false).result(for:cert)
        XCTAssertFalse(result.passed)
    }
}

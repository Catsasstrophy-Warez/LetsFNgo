import XCTest
@testable import ControlsTraining
final class OperationalCommissioningTests:XCTestCase {
 func testPermitRequiresPrereqsAndSignatures(){ var p=OperationalCommissioningCatalog.trainingPackage.permit; XCTAssertFalse(p.fullyAuthorized); for k in p.prerequisites.keys{p.prerequisites[k]=true}; for i in p.signatures.indices{p.signatures[i].accepted=true}; XCTAssertTrue(p.fullyAuthorized) }
 func testLOTORequiresAllIsolationEvidence(){ var l=OperationalCommissioningCatalog.trainingPackage.loto; XCTAssertFalse(l.safeForWork); l.affectedPersonsNotified=true; for i in l.points.indices{l.points[i].isolated=true;l.points[i].locked=true;l.points[i].zeroEnergyVerified=true}; XCTAssertTrue(l.safeForWork) }
 func testCalibrationTolerance(){ let c=OperationalCommissioningCatalog.trainingPackage.calibrations[0]; XCTAssertTrue(c.asLeftPasses) }
 func testMotorRunGate(){ var m=OperationalCommissioningCatalog.trainingPackage.motorRuns[0]; XCTAssertFalse(m.passes); m.uncoupledOrSafeToRun=true;m.rotationCorrect=true;m.currentA=[4.1,4.0,4.2];m.runMinutes=5;m.status = .passed; XCTAssertTrue(m.passes) }
 func testCampaignFaultsAreStageTriggered(){ var c=OperationalCommissioningCatalog.trainingPackage.campaign; XCTAssertEqual(c.reveal(trigger:.startOfDay,stage:.installation).count,1); XCTAssertEqual(c.reveal(trigger:.startOfDay,stage:.installation).count,0); XCTAssertEqual(c.reveal(trigger:.afterEnergization,stage:.energized).count,0) }
 func testFinalBookTracksCompleteness(){ let p=OperationalCommissioningCatalog.trainingPackage; let b=p.finalBook(projectNumber:"P",revision:"A"); XCTAssertEqual(b.sections.count,7); XCTAssertLessThan(b.completionPercent,100) }
 func testOperationalPackageRoundTrips() throws { let p=OperationalCommissioningCatalog.trainingPackage; let data=try JSONEncoder().encode(p); XCTAssertEqual(try JSONDecoder().decode(OperationalCommissioningPackage.self,from:data),p) }
}

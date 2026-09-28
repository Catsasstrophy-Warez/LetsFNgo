import XCTest
@testable import ControlsSimulation

final class BranchingScenarioPackTests:XCTestCase {
    func testFiveScenarioPacksHaveTenAuthoredDecisionGates() {
        XCTAssertEqual(BranchingScenarioPackCatalog.all.count,5)
        for pack in BranchingScenarioPackCatalog.all {
            XCTAssertEqual(pack.gates.count,10,pack.title)
            XCTAssertTrue(pack.gates.allSatisfy{$0.choices.count >= 3})
            XCTAssertFalse(pack.branchIncidents.isEmpty)
        }
    }

    func testNightShiftPackHasDistinctAuthoredBranches() {
        let p=BranchingScenarioPackCatalog.pack(.nightShiftFromHell)
        XCTAssertEqual(p.gates.first?.title,"Trust the handoff?")
        XCTAssertTrue(p.branchIncidents.contains(where:{$0.id=="seizure"}))
        XCTAssertTrue(p.gates.flatMap(\.choices).flatMap(\.operations).contains(where:{ if case .scheduleBranchIncident("seizure", _) = $0 { return true };return false }))
    }

    func testEarlyChoiceChangesPersistentBranchState() throws {
        var r=try BranchingScenarioRuntime(pack:BranchingScenarioPackCatalog.pack(.nightShiftFromHell),project:ProductionLineTemplates.packagingToPalletizing)
        let before=r.riskPressure
        _=try r.choose("rush-vfd")
        XCTAssertEqual(r.decisionCount,1)
        XCTAssertGreaterThan(r.riskPressure,before)
        XCTAssertTrue(r.scheduledIncidentIDs.contains("airLeak"))
    }

    func testEvidenceFirstBranchSuppressesRisk() throws {
        var good=try BranchingScenarioRuntime(pack:BranchingScenarioPackCatalog.pack(.nightShiftFromHell),project:ProductionLineTemplates.packagingToPalletizing)
        var bad=good
        _=try good.choose("best-evidence")
        _=try bad.choose("bad-ignore")
        XCTAssertLessThan(good.riskPressure,bad.riskPressure)
        XCTAssertGreaterThan(good.earlyDecisionPoints,bad.earlyDecisionPoints)
    }

    func testTemporaryRepairBranchCreatesRecurrenceDebtAndIncident() throws {
        var r=try BranchingScenarioRuntime(pack:BranchingScenarioPackCatalog.pack(.nightShiftFromHell),project:ProductionLineTemplates.packagingToPalletizing)
        _=try r.choose("best-evidence");_=try r.choose("best-correlate");_=try r.choose("best-stage");_=try r.choose("temp-jumper")
        XCTAssertGreaterThan(r.recurrenceRisk,0)
        XCTAssertTrue(r.scheduledIncidentIDs.contains("recurrence"))
    }

    func testScenarioPacksAreCodable() throws {
        let data=try JSONEncoder().encode(BranchingScenarioPackCatalog.all)
        let decoded=try JSONDecoder().decode([BranchingScenarioPack].self,from:data)
        XCTAssertEqual(decoded.count,5)
        XCTAssertEqual(decoded.first?.gates.count,10)
    }

    func testAllPacksCanCreateRuntimeOnMultipleLineTemplates() throws {
        for pack in BranchingScenarioPackCatalog.all {
            _=try BranchingScenarioRuntime(pack:pack,project:ProductionLineTemplates.packagingToPalletizing)
            _=try BranchingScenarioRuntime(pack:pack,project:ProductionLineTemplates.beverageLine)
        }
    }

    func testFirstTenDecisionsProduceCampaignEnding() throws {
        var r=try BranchingScenarioRuntime(pack:BranchingScenarioPackCatalog.pack(.customerLaunchDay),project:ProductionLineTemplates.beverageLine)
        for _ in 0..<10 { let id=try XCTUnwrap(r.currentGate?.choices.first?.id);_=try r.choose(id) }
        XCTAssertTrue(r.complete)
        XCTAssertEqual(r.records.count,10)
        XCTAssertFalse(r.ending().decisiveMoments.isEmpty)
        XCTAssertGreaterThanOrEqual(r.ending().score.overall,0)
    }

    func testPoorChoicesCreateDifferentEndingScore() throws {
        let pack=BranchingScenarioPackCatalog.pack(.utilityCrisis)
        var good=try BranchingScenarioRuntime(pack:pack,project:ProductionLineTemplates.beverageLine)
        var bad=try BranchingScenarioRuntime(pack:pack,project:ProductionLineTemplates.beverageLine)
        for _ in 0..<10 {
            _=try good.choose(try XCTUnwrap(good.currentGate?.choices.first?.id))
            _=try bad.choose(try XCTUnwrap(bad.currentGate?.choices.last?.id))
        }
        XCTAssertGreaterThan(good.score().overall,bad.score().overall)
        XCTAssertNotEqual(good.ending().summary,bad.ending().summary)
    }
}

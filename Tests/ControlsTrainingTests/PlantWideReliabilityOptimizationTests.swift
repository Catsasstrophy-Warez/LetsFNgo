import XCTest
@testable import ControlsSimulation
@testable import ControlsTraining

final class PlantWideReliabilityOptimizationTests:XCTestCase {
    func plant() throws -> PlantShiftManagementRuntime { var p=try PlantShiftManagementTemplates.twentyFourHourCampaign();p.campaignDurationSeconds=365*86400;return p }
    func testElectricalExperienceTiersCoverEveryLesson(){ XCTAssertEqual(Set(ElectricalAutomationCatalog.lessons.map{$0.level.experienceTier}).count,5); XCTAssertEqual(ElectricalExperienceTier.allCases.count,5); XCTAssertEqual(ElectricalAutomationCatalog.lessons(in:.master).allSatisfy{$0.level == .advancedTroubleshooter},true) }
    func testMonteCarloRULIsDeterministic(){ let a=FleetReliabilityAsset(machine:.pumpStation,index:3);let x=ReliabilityMonteCarlo.forecast(asset:a,trials:1000,seed:77),y=ReliabilityMonteCarlo.forecast(asset:a,trials:1000,seed:77);XCTAssertEqual(x,y);XCTAssertGreaterThan(x.p90Days,x.p10Days) }
    func testBayesianUpdateNarrowsUncertainty(){ var b=BayesianRULBelief(meanDays:100,variance:400);let before=b.variance;b.update(measuredDays:70,measurementVariance:25);XCTAssertLessThan(b.variance,before);XCTAssertLessThan(b.meanDays,100) }
    func testFleetContainsAll28Machines() throws { let r=ReliabilityManagerCampaignRuntime(plant:try plant());XCTAssertEqual(r.assets.count,28);XCTAssertEqual(Set(r.assets.keys),Set(PlayableMachineKind.allCases)) }
    func testPrioritizationUsesCriticalityAndFailureRisk() throws { var r=ReliabilityManagerCampaignRuntime(plant:try plant());var a=r.assets[.pumpStation]!;a.health=0.95;a.fmea = .init(severity:10,occurrence:9,detection:8);r.assets[.pumpStation]=a;XCTAssertEqual(r.priorities().first?.machine,.pumpStation) }
    func testMissingSharedSpareQueuesExpedite() throws { var r=ReliabilityManagerCampaignRuntime(plant:try plant());let m=PlayableMachineKind.batchMixingTank;let ok=r.scheduleMaintenance(m,opportunity:false);XCTAssertFalse(ok);XCTAssertTrue(r.plant.inbound.contains{$0.item==r.assets[m]!.sparePartNumber}) }
    func testTurnaroundBundlesRiskWork() throws { var r=ReliabilityManagerCampaignRuntime(plant:try plant());for m in PlayableMachineKind.allCases.prefix(4){r.assets[m]!.health=0.9};let p=r.planTurnaround(startDay:20,durationHours:12);XCTAssertFalse(p.tasks.isEmpty);XCTAssertLessThanOrEqual(p.laborHours,12);XCTAssertTrue(p.tasks.allSatisfy{$0.bundled}) }
    func testInventoryOptimizationCoversFleet() throws { let r=ReliabilityManagerCampaignRuntime(plant:try plant());let x=r.optimizeSpares();XCTAssertEqual(x.count,28);XCTAssertTrue(x.allSatisfy{$0.recommendedStock >= 1 && $0.reorderPoint >= 1}) }
    func testLifecycleCostCoversFleet() throws { let r=ReliabilityManagerCampaignRuntime(plant:try plant());let x=r.lifecycleCosts(years:5);XCTAssertEqual(x.count,28);XCTAssertTrue(x.allSatisfy{$0.total > 0}) }
    func testIgnoredFleetDegradationEventuallyCreatesFailures() throws { var r=ReliabilityManagerCampaignRuntime(plant:try plant(),policy:.runToFailure,seed:5);for _ in 0..<400 { r.degradeFleet() };let s=r.snapshot();XCTAssertGreaterThan(s.failedAssets,0);XCTAssertGreaterThan(s.downtimeCost,0) }
    func testRedundantSwitchingChangesStates() throws { var r=ReliabilityManagerCampaignRuntime(plant:try plant());XCTAssertTrue(r.switchToRedundantAsset(for:.pumpStation));XCTAssertEqual(r.assets[.pumpStation]?.state,.standby) }
    func testFMEARPN(){ XCTAssertEqual(FMEAProfile(severity:9,occurrence:7,detection:6).rpn,378) }
}

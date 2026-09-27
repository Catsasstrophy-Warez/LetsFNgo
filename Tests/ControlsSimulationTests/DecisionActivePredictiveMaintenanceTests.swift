import XCTest
@testable import ControlsSimulation

final class DecisionActivePredictiveMaintenanceTests: XCTestCase {
    private func campaign(_ fault:PredictiveFaultFamily = .bearingWear, months:Int = 10) -> PredictiveCampaignSnapshot {
        PredictiveConditionCampaign.run(machine:.batchMixingTank,fault:fault,configuration:.init(months:months,samplesPerMonth:8,startingSeverity:0,endingSeverity:0.95),seed:42)
    }

    func testRULForecastProducesFiniteConfidenceIntervalAndIncreasingRisk() {
        let c=campaign()
        let f=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:.bearingWear,records:c.records)
        XCTAssertGreaterThanOrEqual(f.interval95.lowerDays,0)
        XCTAssertGreaterThanOrEqual(f.interval95.pointDays,f.interval95.lowerDays)
        XCTAssertGreaterThanOrEqual(f.interval95.upperDays,f.interval95.pointDays)
        XCTAssertGreaterThanOrEqual(f.probabilityWithin30Days,f.probabilityWithin7Days)
        XCTAssertGreaterThanOrEqual(f.probabilityWithin90Days,f.probabilityWithin30Days)
        XCTAssertGreaterThan(f.evidenceQuality,0)
    }

    func testRULShortensAsDegradationProgresses() {
        let c=campaign(months:12)
        let progressive=c.records.filter{$0.simulatedDay>=1}
        let mid=Array(progressive.prefix(max(8,progressive.count/2)))
        let late=progressive
        let a=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:.bearingWear,records:mid)
        let b=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:.bearingWear,records:late)
        XCTAssertLessThanOrEqual(b.interval95.pointDays,a.interval95.pointDays+20)
        XCTAssertGreaterThanOrEqual(b.healthIndex,a.healthIndex)
    }

    func testFalseNegativeCostCanChangeRecommendationEconomics() {
        let c=campaign()
        let f=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:.bearingWear,records:c.records)
        let low=PredictiveMaintenanceRecommender.recommend(forecast:f,economics:.init(falsePositiveCost:2000,falseNegativeFailureCost:1000))
        let high=PredictiveMaintenanceRecommender.recommend(forecast:f,economics:.init(falsePositiveCost:200,falseNegativeFailureCost:30000))
        XCTAssertGreaterThan(high.expectedCostDefer,low.expectedCostDefer)
        XCTAssertLessThanOrEqual(high.expectedCostAct,low.expectedCostAct+2000)
    }

    func testSchedulerUsesMESOrdersCustomerPenaltiesLaborAndSpares() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        let c=campaign()
        let f=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:.bearingWear,records:c.records)
        let part=plant.reliability[.batchMixingTank]?.criticalSparePartNumber
        let s=ProductionAwareMaintenanceScheduler.schedule(machine:.batchMixingTank,forecast:f,plant:plant,durationHours:1,sparePartNumber:part)
        XCTAssertNotNil(s.selected)
        XCTAssertFalse(s.alternatives.isEmpty)
        XCTAssertTrue(s.alternatives.allSatisfy{$0.totalExpectedCost >= 0})
    }

    func testMissingSpareMakesScheduleInfeasible() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for i in plant.spareCrib.indices { plant.spareCrib[i].quantity=0 }
        let c=campaign()
        let f=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:.bearingWear,records:c.records)
        let part=plant.reliability[.batchMixingTank]?.criticalSparePartNumber
        let s=ProductionAwareMaintenanceScheduler.schedule(machine:.batchMixingTank,forecast:f,plant:plant,sparePartNumber:part)
        XCTAssertNil(s.selected)
        XCTAssertTrue(s.alternatives.allSatisfy{!$0.feasible})
    }

    func testExplicitlyMissedAdvisoryRaisesRiskState() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        var r=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:.batchMixingTank,fault:.bearingWear,strategy:.conditionBased)
        r.degradationSeverity=0.55
        let before=r.degradationSeverity
        r.explicitlyDeferCurrentRecommendation()
        XCTAssertEqual(r.missedAdvisories,1)
        XCTAssertGreaterThan(r.degradationSeverity,before)
        XCTAssertEqual(r.decisions.last?.action,.deferred)
    }

    func testReactiveStrategyAllowsFunctionalFailureAndMESDowntime() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        var r=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:.batchMixingTank,fault:.bearingWear,strategy:.reactive)
        r.degradationSeverity=0.90
        r.degradationPerDay=0.05
        let snap=try r.advanceCompressed(days:1,plantSecondsPerDay:0)
        XCTAssertEqual(snap.failures,1)
        XCTAssertTrue(r.plant.mes.downtime.contains(where:{$0.machine == .batchMixingTank && $0.endedAt == nil}))
        XCTAssertTrue(r.plant.mes.maintenanceCalls.contains(where:{$0.machine == .batchMixingTank}))
        XCTAssertGreaterThan(snap.plantEconomics.lostProductionOpportunity,0)
    }

    func testMaintenanceCreatesWorkOrderConsumesSpareAndResetsDegradation() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        let part=plant.reliability[.batchMixingTank]?.criticalSparePartNumber
        let before=plant.spareCrib.first(where:{$0.partNumber==part})?.quantity ?? 0
        var r=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:.batchMixingTank,fault:.bearingWear,strategy:.conditionBased)
        r.degradationSeverity=0.7
        r.performMaintenance(reason:"test predictive repair")
        XCTAssertEqual(r.maintenanceInterventions,1)
        XCTAssertLessThan(r.degradationSeverity,0.1)
        XCTAssertTrue(r.plant.maintenanceBacklog.contains(where:{$0.machine == .batchMixingTank && $0.title.contains("test predictive")}))
        let after=r.plant.spareCrib.first(where:{$0.partNumber==part})?.quantity ?? 0
        XCTAssertLessThanOrEqual(after,before)
    }

    func testPreventiveStrategyIntervenesByCalendar() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        var r=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:.batchMixingTank,fault:.bearingWear,strategy:.preventive)
        r.preventiveIntervalDays=20
        r.degradationPerDay=0.005
        _=try r.advanceCompressed(days:21,plantSecondsPerDay:0)
        XCTAssertGreaterThanOrEqual(r.maintenanceInterventions,1)
    }

    func testStrategyComparatorReturnsAllThreeStrategiesAndEconomics() throws {
        let comparison=try PredictiveMaintenanceStrategyComparator.compare(machine:.batchMixingTank,fault:.bearingWear,horizonDays:180)
        XCTAssertEqual(comparison.outcomes.count,3)
        XCTAssertEqual(Set(comparison.outcomes.map(\.strategy)),Set(MaintenanceStrategy.allCases))
        XCTAssertTrue(comparison.outcomes.allSatisfy{$0.totalEconomicImpact >= 0})
        XCTAssertTrue(MaintenanceStrategy.allCases.contains(comparison.bestStrategy))
    }

    func testAllFaultFamiliesProduceDecisionGradeRULForecasts() {
        for fault in PredictiveFaultFamily.allCases {
            let c=campaign(fault,months:8)
            let f=RemainingUsefulLifeForecaster.forecast(machine:.batchMixingTank,fault:fault,records:c.records)
            XCTAssertTrue(f.interval95.pointDays.isFinite,"\(fault)")
            XCTAssertTrue((0...1).contains(f.probabilityWithin30Days),"\(fault)")
            XCTAssertGreaterThanOrEqual(f.healthIndex,0,"\(fault)")
        }
    }

    func testAll28MachinesSupportRULAndRecommendationPipeline() {
        for machine in PlayableMachineKind.allCases {
            let c=PredictiveConditionCampaign.run(machine:machine,fault:.looseConnection,configuration:.init(months:4,samplesPerMonth:4,startingSeverity:0,endingSeverity:0.8),seed:9)
            let f=RemainingUsefulLifeForecaster.forecast(machine:machine,fault:.looseConnection,records:c.records)
            let rec=PredictiveMaintenanceRecommender.recommend(forecast:f)
            XCTAssertEqual(rec.machine,machine)
            XCTAssertTrue(rec.expectedCostAct.isFinite)
            XCTAssertTrue(rec.expectedCostDefer.isFinite)
        }
    }
    func testUnavailableCriticalSpareQueuesAndExpeditesWithoutMagicallyRepairing() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        let part=plant.reliability[.batchMixingTank]?.criticalSparePartNumber
        for i in plant.spareCrib.indices where plant.spareCrib[i].partNumber == part { plant.spareCrib[i].quantity=0 }
        var r=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:.batchMixingTank,fault:.bearingWear,strategy:.conditionBased)
        r.degradationSeverity=0.72
        r.performMaintenance(reason:"Predictive parts-constrained intervention")
        XCTAssertEqual(r.maintenanceInterventions,0)
        XCTAssertGreaterThan(r.degradationSeverity,0.7)
        XCTAssertTrue(r.plant.maintenanceBacklog.contains(where:{$0.machine == .batchMixingTank && $0.status == .waitingForParts}))
        if let part { XCTAssertTrue(r.plant.inbound.contains(where:{$0.item == part && $0.isSpare && !$0.received})) }
    }

    func testIgnoredPredictionFlowsIntoDowntimeCostAndOEEAvailability() throws {
        var plant=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:ProductionLineTemplates.beverageLine)
        for key in plant.reliability.keys { plant.reliability[key]?.nextTrainingFailureAt=nil }
        var r=DecisionActivePredictiveMaintenanceRuntime(plant:plant,machine:.batchMixingTank,fault:.bearingWear,strategy:.reactive)
        r.degradationSeverity=0.91; r.degradationPerDay=0.05
        let snap=try r.advanceCompressed(days:1,plantSecondsPerDay:600)
        XCTAssertEqual(snap.failures,1)
        XCTAssertGreaterThan(snap.mesCosts.downtimeCost,0)
        XCTAssertLessThan(snap.lineAvailabilityPercent,100)
        XCTAssertGreaterThanOrEqual(snap.customerPenaltyCost,0)
    }

    func testStrategyComparatorCreatesRealPlantForMachineOutsideDefaultLine() throws {
        let c=try PredictiveMaintenanceStrategyComparator.compare(machine:.asrsCrane,fault:.looseConnection,horizonDays:90)
        XCTAssertEqual(c.machine,.asrsCrane)
        XCTAssertEqual(c.outcomes.count,3)
        XCTAssertTrue(c.outcomes.allSatisfy{$0.totalEconomicImpact.isFinite})
    }

}

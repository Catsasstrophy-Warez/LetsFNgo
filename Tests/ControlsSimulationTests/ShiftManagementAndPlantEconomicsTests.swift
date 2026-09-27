import XCTest
@testable import ControlsSimulation

final class ShiftManagementAndPlantEconomicsTests: XCTestCase {
    func testTwentyFourHourTemplateBuildsCrewsSparesPMsAndAgreements() throws {
        let r = try PlantShiftManagementTemplates.twentyFourHourCampaign(project: ProductionLineTemplates.beverageLine)
        XCTAssertEqual(r.crews.count, 3)
        XCTAssertGreaterThanOrEqual(r.spareCrib.count, 3)
        XCTAssertEqual(r.maintenanceBacklog.filter(\.preventive).count, ProductionLineTemplates.beverageLine.nodes.count)
        XCTAssertFalse(r.agreements.isEmpty)
        XCTAssertEqual(r.campaignDurationSeconds, 86_400, accuracy: 0.001)
    }

    func testSkillLevelChangesTechnicianResponseTime() throws {
        let mes = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        var fast = PlantShiftManagementRuntime(mes: mes)
        let high = CrewMember(id:"HIGH",name:"High",role:.controlsTechnician,skills:[.init(.controls,5)],baseResponseMinutes:10)
        let low = CrewMember(id:"LOW",name:"Low",role:.controlsTechnician,skills:[.init(.controls,1)],baseResponseMinutes:10)
        fast.addCrew(.init(name:"Crew",members:[high,low],shiftStart:0,shiftEnd:10000))
        fast.addSpare(.init(partNumber:"IO-POINT",description:"IO",quantity:2,unitCost:10))
        let a=MaintenanceWorkOrder(id:"A",machine:.packagingCell,title:"A",requiredSkill:.controls,requiredPartNumber:"IO-POINT",priority:.urgent,dueAt:100,estimatedHours:1)
        let b=MaintenanceWorkOrder(id:"B",machine:.packagingCell,title:"B",requiredSkill:.controls,requiredPartNumber:"IO-POINT",priority:.urgent,dueAt:100,estimatedHours:1)
        fast.addPM(a);fast.addPM(b)
        XCTAssertTrue(fast.dispatch(workOrderID:"A",memberID:"HIGH"))
        let highResponse=(try XCTUnwrap(fast.maintenanceBacklog.first(where:{$0.id=="A"})?.arrivalAt)) - fast.mes.elapsedSeconds
        XCTAssertTrue(fast.dispatch(workOrderID:"B",memberID:"LOW"))
        let lowResponse=(try XCTUnwrap(fast.maintenanceBacklog.first(where:{$0.id=="B"})?.arrivalAt)) - fast.mes.elapsedSeconds
        XCTAssertLessThan(highResponse, lowResponse)
        _ = mes
    }

    func testMissingSpareBlocksDispatchAndExpediteReceivesLater() throws {
        var r = PlantShiftManagementRuntime(mes: try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing))
        r.addCrew(.init(name:"Crew",members:[.init(id:"T",name:"Tech",role:.electrician,skills:[.init(.electrical,5)])],shiftStart:0,shiftEnd:10000))
        r.addSpare(.init(partNumber:"CONTACTOR-32A",description:"Contactor",quantity:0,unitCost:100,expediteLeadHours:0.001,expediteFee:50))
        r.addPM(.init(id:"WO",machine:.packagingCell,title:"Replace contactor",requiredSkill:.electrical,requiredPartNumber:"CONTACTOR-32A",priority:.emergency,dueAt:10,estimatedHours:0.1))
        XCTAssertFalse(r.dispatch(workOrderID:"WO",memberID:"T"))
        XCTAssertEqual(r.maintenanceBacklog.first?.status,.waitingForParts)
        XCTAssertNotNil(r.expediteSpare(partNumber:"CONTACTOR-32A"))
        _ = try r.run(seconds:5,stepMilliseconds:1000)
        XCTAssertEqual(r.spareCrib.first?.quantity,1)
        XCTAssertGreaterThan(r.economics.expeditedFreight,0)
    }

    func testRepairClearsClosedLoopFaultAndDowntime() throws {
        var r = PlantShiftManagementRuntime(mes: try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing))
        r.automaticDispatch=false
        r.addCrew(.init(name:"Crew",members:[.init(id:"T",name:"Tech",role:.controlsTechnician,skills:[.init(.controls,5)],baseResponseMinutes:0)],shiftStart:0,shiftEnd:10000))
        r.addSpare(.init(partNumber:"IO-POINT",description:"IO",quantity:1,unitCost:100))
        let node=try XCTUnwrap(r.mes.line.project.nodes.first(where:{$0.machine == .packagingCell}))
        var m=try XCTUnwrap(r.mes.line.machines[node.id]);let target=try XCTUnwrap(m.executable.bindings.first(where:{$0.direction == .input})?.ioTag);m.injectInputFault(.init(target:target,kind:.openWire));r.mes.line.machines[node.id]=m
        _=r.mes.reportDowntime(machine:.packagingCell,reason:.controlsFault,detail:"I/O failed")
        r.addPM(.init(id:"WO",machine:.packagingCell,title:"Replace I/O",requiredSkill:.controls,requiredPartNumber:"IO-POINT",priority:.emergency,dueAt:10,estimatedHours:0.001))
        XCTAssertTrue(r.dispatch(workOrderID:"WO",memberID:"T"))
        _ = try r.run(seconds:240,stepMilliseconds:10_000)
        XCTAssertEqual(r.maintenanceBacklog.first(where:{$0.id=="WO"})?.status,.complete)
        XCTAssertTrue(r.mes.line.machines[node.id]?.controls.faults.isEmpty == true)
        XCTAssertFalse(r.mes.downtime.contains(where:{$0.machine == .packagingCell && $0.endedAt == nil}))
    }

    func testUtilitiesAndLaborAccumulateEconomicCost() throws {
        var r=try PlantShiftManagementTemplates.twentyFourHourCampaign(project: ProductionLineTemplates.packagingToPalletizing)
        _ = try r.run(seconds:60,stepMilliseconds:10_000)
        XCTAssertGreaterThan(r.economics.electricity,0)
        XCTAssertGreaterThan(r.economics.directLabor,0)
        XCTAssertGreaterThan(r.economics.totalCost,0)
    }

    func testCustomerPenaltyAccruesWhenOrderIsLate() throws {
        var mes=try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        mes.addShift(.init(name:"Shift",startAt:0,endAt:1000));mes.addOrder(.init(id:"LATE",sku:"A",quantity:100,dueAt:1,priority:100))
        var r=PlantShiftManagementRuntime(mes:mes);r.setAgreement(.init(orderID:"LATE",latePenaltyPerMinute:60,shortUnitPenalty:5,priorityCustomerMultiplier:2))
        _ = try r.run(seconds:120,stepMilliseconds:10_000)
        XCTAssertGreaterThan(r.economics.customerPenalties,0)
        XCTAssertTrue(r.events.contains(where:{$0.kind == .customerRisk}))
    }

    func testOvertimeExtendsCampaignAndMESShiftSchedule() throws {
        var r=try PlantShiftManagementTemplates.twentyFourHourCampaign(project: ProductionLineTemplates.packagingToPalletizing)
        r.authorizeOvertime(hours:2)
        XCTAssertEqual(r.campaignDurationSeconds,93_600,accuracy:0.001)
        XCTAssertTrue(r.mes.shifts.contains(where:{$0.name == "Overtime" && $0.endAt == 93_600}))
        XCTAssertTrue(r.decisions.contains(where:{$0.kind == .overtime}))
    }

    func testAlternateRoutingCreatesPhysicalBypassConnection() throws {
        var p=LineBuilderProject(name:"3 Station")
        let a=p.addMachine(.packagingCell);let b=p.addMachine(.servoConveyor);let c=p.addMachine(.roboticPalletizer);p.connect(a.id,b.id);p.connect(b.id,c.id)
        var r=PlantShiftManagementRuntime(mes:try ManufacturingExecutionRuntime(project:p))
        let before=r.mes.line.project.connections.count
        let bypass=r.activateAlternateRoute(around:.servoConveyor)
        XCTAssertNotNil(bypass)
        XCTAssertEqual(r.mes.line.project.connections.count,before+1)
        XCTAssertNotNil(bypass.flatMap{r.mes.line.buffers[$0.id]})
    }

    func testShiftHandoffCapturesOpenWorkAndScheduleRisk() throws {
        var r=try PlantShiftManagementTemplates.twentyFourHourCampaign(project: ProductionLineTemplates.packagingToPalletizing)
        r.recordHandoff(toCrew:"B Crew",note:"Conveyor intermittent; spare staged",fidelity:0.95)
        let h=try XCTUnwrap(r.handoffs.last)
        XCTAssertEqual(h.toCrew,"B Crew")
        XCTAssertEqual(h.fidelity,0.95,accuracy:0.001)
        XCTAssertFalse(h.openWorkOrders.isEmpty)
    }

    func testReliabilityMetricsTrackObservedMTBFAndMTTR() {
        let a=ReliabilityAsset(machine:.pumpStation,nominalMTBFHours:100,nominalMTTRHours:2,operatingHours:50,failureCount:2,repairHours:3)
        XCTAssertEqual(a.observedMTBFHours,25,accuracy:0.001)
        XCTAssertEqual(a.observedMTTRHours,1.5,accuracy:0.001)
    }

    func testCampaignScoreRespondsToCommunicationAndMaintenance() throws {
        var r=try PlantShiftManagementTemplates.twentyFourHourCampaign(project: ProductionLineTemplates.packagingToPalletizing)
        let before=r.score().communication
        r.recordHandoff(toCrew:"B Crew",note:"Full evidence handoff",fidelity:1)
        r.recordHandoff(toCrew:"C Crew",note:"Full evidence handoff",fidelity:1)
        XCTAssertGreaterThanOrEqual(r.score().communication,before)
        XCTAssertTrue((0...100).contains(r.score().overall))
    }

    func testEveryHeroMachineCanHostShiftEconomicsRuntime() throws {
        for machine in PlayableMachineKind.allCases {
            var p=LineBuilderProject(name:machine.rawValue);_ = p.addMachine(machine)
            var r=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:p)
            let s=try r.cycle(elapsedMilliseconds:1000)
            XCTAssertEqual(s.currentCrew,"A Crew")
            XCTAssertNotNil(r.reliability[machine])
            XCTAssertNotNil(r.utilityProfiles[machine])
        }
    }
    func testAcceleratedRunCompletesTwentyFourHourCampaignClock() throws {
        var p=LineBuilderProject(name:"24h"); _ = p.addMachine(.packagingCell)
        var r=try PlantShiftManagementTemplates.twentyFourHourCampaign(project:p)
        let s=try r.run24Hours(stepMilliseconds:600_000)
        XCTAssertEqual(s.elapsedSeconds,86_400,accuracy:0.001)
        XCTAssertGreaterThan(s.economics.electricity,0)
        XCTAssertGreaterThanOrEqual(s.meetings.count,7)
        XCTAssertGreaterThanOrEqual(s.handoffs.count,2)
        XCTAssertTrue((0...100).contains(s.score.overall))
    }

}

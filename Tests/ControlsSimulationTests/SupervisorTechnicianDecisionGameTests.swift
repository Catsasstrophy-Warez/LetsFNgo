import XCTest
@testable import ControlsSimulation

final class SupervisorTechnicianDecisionGameTests: XCTestCase {
    private func game(_ project:LineBuilderProject = ProductionLineTemplates.packagingToPalletizing) throws -> SupervisorTechnicianDecisionGameRuntime {
        try SupervisorTechnicianDecisionGameTemplates.twentyFourHourDecisionCampaign(project: project)
    }

    func testHiddenTruthStaysHiddenUntilEvidenceIsStrong() throws {
        var g=try game();_ = try g.run(seconds:1700,stepMilliseconds:10_000)
        let incident=try XCTUnwrap(g.visibleIncidents.first)
        XCTAssertEqual(incident.truth.rootCause,"Hidden until verified")
        for _ in 0..<4 { g.inspectHistorian(incidentID:incident.id) }
        XCTAssertNotEqual(g.visibleIncidents.first?.truth.rootCause,"Hidden until verified")
    }

    func testMisleadingOperatorOrHandoffEvidenceIsRepresented() throws {
        var g=try game();_ = try g.run(seconds:5_300,stepMilliseconds:10_000)
        XCTAssertTrue(g.communications.contains(where:{$0.misleading}))
        XCTAssertTrue(g.communications.contains(where:{$0.channel == .shiftLog || $0.channel == .radio}))
    }

    func testToolLocationCreatesRetrievalTravel() throws {
        var g=try game();let tech=try XCTUnwrap(g.technicianStates.values.first)
        XCTAssertNotEqual(tech.area,.controlRoom)
        XCTAssertTrue(g.reserveTool(toolID:"LAPTOP-01",memberID:tech.memberID))
        let moved=try XCTUnwrap(g.technicianStates[tech.memberID])
        XCTAssertNotNil(moved.travelingUntil);XCTAssertEqual(moved.destination,.controlRoom);XCTAssertFalse(moved.carriedToolIDs.contains("LAPTOP-01"))
        _ = try g.run(seconds:3600,stepMilliseconds:10_000)
        XCTAssertTrue(g.technicianStates[tech.memberID]?.carriedToolIDs.contains("LAPTOP-01") == true)
    }

    func testSimultaneousIncidentsCompeteForSameSpecialist() throws {
        var g=try game();let machine=try XCTUnwrap(g.plant.mes.line.project.nodes.first?.machine);let member=try XCTUnwrap(g.plant.currentCrew()?.members.first(where:{$0.skill(.controls)>0}))
        let truth=HiddenPlantTruth(rootCause:"A",actualMachine:machine,actualArea:.maintenanceShop,requiredSkill:.controls)
        let a=DecisionIncident(title:"A",domain:.controls,severity:.lineStop,scheduledAt:0,truth:truth)
        let b=DecisionIncident(title:"B",domain:.controls,severity:.lineStop,scheduledAt:0,truth:truth)
        g.addIncident(a);g.addIncident(b);_ = try g.cycle(elapsedMilliseconds:1)
        XCTAssertTrue(g.dispatch(memberID:member.id,to:a.id));XCTAssertFalse(g.dispatch(memberID:member.id,to:b.id))
    }

    func testPermitAndLOTOGateRepair() throws {
        var g=try game();let machine=try XCTUnwrap(g.plant.mes.line.project.nodes.first?.machine);let member=try XCTUnwrap(g.plant.currentCrew()?.members.first(where:{$0.skill(.controls)>0}))
        let inc=DecisionIncident(title:"LOTO test",domain:.controls,severity:.lineStop,scheduledAt:0,truth:.init(rootCause:"terminal",actualMachine:machine,actualArea:.maintenanceShop,requiredSkill:.controls,permitKind:.loto,permanentRepairMinutes:10,temporaryRepairMinutes:5))
        g.addIncident(inc);_ = try g.cycle(elapsedMilliseconds:1);XCTAssertTrue(g.dispatch(memberID:member.id,to:inc.id));_ = try g.run(seconds:120,stepMilliseconds:10_000)
        XCTAssertFalse(g.performRepair(incidentID:inc.id,strategy:.permanent));XCTAssertTrue(g.requestPermit(incidentID:inc.id));_ = try g.run(seconds:600,stepMilliseconds:10_000);XCTAssertTrue(g.applyLOTO(incidentID:inc.id));_ = try g.run(seconds:301,stepMilliseconds:10_000)
        XCTAssertTrue(g.performRepair(incidentID:inc.id,strategy:.permanent))
    }

    func testVendorSupportHasRealQueueDelayAndCost() throws {
        var g=try game();_ = try g.run(seconds:1700,stepMilliseconds:10_000);let id=try XCTUnwrap(g.visibleIncidents.first?.id);let before=g.plant.economics.totalCost
        let v=try XCTUnwrap(g.requestVendor(incidentID:id,delayMinutes:10,cost:500));XCTAssertEqual(v.status,.queued);XCTAssertGreaterThan(g.plant.economics.totalCost,before)
        _ = try g.run(seconds:601,stepMilliseconds:10_000);XCTAssertEqual(g.vendorRequests.first(where:{$0.id==v.id})?.status,.connected)
    }

    func testTemporaryRepairCanRecur() throws {
        var g=try game();let machine=try XCTUnwrap(g.plant.mes.line.project.nodes.first?.machine);let member=try XCTUnwrap(g.plant.currentCrew()?.members.first(where:{$0.skill(.controls)>0}))
        let inc=DecisionIncident(title:"Temporary",domain:.controls,severity:.lineStop,scheduledAt:0,truth:.init(rootCause:"loose plug",actualMachine:machine,actualArea:.maintenanceShop,requiredSkill:.controls,permanentRepairMinutes:10,temporaryRepairMinutes:1,temporaryRecurrenceAfterMinutes:2))
        g.addIncident(inc);_ = try g.cycle(elapsedMilliseconds:1);XCTAssertTrue(g.dispatch(memberID:member.id,to:inc.id));_ = try g.run(seconds:61,stepMilliseconds:10_000);XCTAssertTrue(g.performRepair(incidentID:inc.id,strategy:.temporary));_ = try g.run(seconds:60,stepMilliseconds:10_000)
        XCTAssertNotNil(g.incidents.first(where:{$0.id==inc.id})?.resolvedAt)
        _ = try g.run(seconds:150,stepMilliseconds:10_000);XCTAssertGreaterThanOrEqual(g.incidents.first(where:{$0.id==inc.id})?.recurrenceCount ?? 0,1)
    }

    func testCustomerPriorityChangeReordersExecution() throws {
        var g=try game();let change=try XCTUnwrap(g.customerPriorityChanges.first);_ = try g.run(seconds:change.triggerAt+1,stepMilliseconds:300_000)
        XCTAssertTrue(g.customerPriorityChanges.first(where:{$0.id==change.id})?.applied == true);XCTAssertEqual(g.plant.mes.orders.first(where:{$0.id==change.orderID})?.priority,change.newPriority)
    }

    func testWeatherUtilityDisturbanceCreatesAndClearsDowntime() throws {
        var g=try game();let u=try XCTUnwrap(g.utilityDisturbances.first);_ = try g.run(seconds:u.triggerAt+1,stepMilliseconds:300_000)
        XCTAssertTrue(g.utilityDisturbances.first(where:{$0.id==u.id})?.applied == true);XCTAssertTrue(g.plant.mes.downtime.contains(where:{($0.machine.map{u.affectedMachines.contains($0)} ?? false)}))
        _ = try g.run(seconds:(u.endAt-g.plant.mes.elapsedSeconds)+2,stepMilliseconds:300_000);XCTAssertTrue(g.utilityDisturbances.first(where:{$0.id==u.id})?.cleared == true)
    }

    func testManagementEscalationOccursForUnresolvedIncident() throws {
        var g=try game();g.managementEscalationMinutes=5;_ = try g.run(seconds:2200,stepMilliseconds:60_000)
        XCTAssertTrue(g.incidents.contains(where:{$0.managementEscalated}));XCTAssertTrue(g.endOfDayReplay().contains(where:{$0.category=="Escalation"}))
    }

    func testEndOfDayReplayIncludesDecisionAndEconomicAttribution() throws {
        var g=try game();_ = try g.run(seconds:1800,stepMilliseconds:10_000);if let id=g.visibleIncidents.first?.id{g.inspectHistorian(incidentID:id)};_ = try g.run(seconds:60,stepMilliseconds:10_000)
        let replay=g.endOfDayReplay();XCTAssertTrue(replay.contains(where:{$0.category=="Diagnosis"}));XCTAssertTrue(replay.contains(where:{$0.category=="Economic Ledger"}));XCTAssertTrue(replay.allSatisfy{$0.downtimeMinutes>=0 && $0.dollarImpact>=0})
    }

    func testAllHeroMachinesCanHostDecisionCampaign() throws {
        for m in PlayableMachineKind.allCases { let p=LineBuilderProject(name:"\(m.rawValue) Decision Campaign",nodes:[.init(machine:m)],connections:[]);let g=try SupervisorTechnicianDecisionGameTemplates.twentyFourHourDecisionCampaign(project:p);XCTAssertEqual(g.plant.mes.line.project.nodes.first?.machine,m);XCTAssertFalse(g.incidents.isEmpty) }
    }

    func testAccelerated24HourDecisionCampaignCompletes() throws {
        var g=try game();let snap=try g.run24Hours(stepMilliseconds:300_000);XCTAssertGreaterThanOrEqual(snap.plant.elapsedSeconds,86_400);XCTAssertFalse(g.endOfDayReplay().isEmpty);XCTAssertTrue((0...100).contains(g.score().overall))
    }
}

import XCTest
@testable import ControlsSimulation

final class ManufacturingExecutionTests: XCTestCase {
    func testOrderReleaseReservesWarehouseLotsAndCreatesEBR() throws {
        var r = try ManufacturingExecutionTemplates.trainingRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        try r.releaseOrder("PO-1001", by: "Operator A")
        XCTAssertEqual(r.orders.first(where:{$0.id=="PO-1001"})?.status,.released)
        XCTAssertFalse(r.reservations.isEmpty)
        XCTAssertTrue(r.inventory.contains(where:{$0.reserved > 0}))
        XCTAssertEqual(r.batchRecords["PO-1001"]?.releasedBy,"Operator A")
        XCTAssertFalse(r.batchRecords["PO-1001"]?.inputLots.isEmpty ?? true)
    }

    func testInsufficientMaterialBlocksReleaseWithoutPartialReservation() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        r.registerBOM(sku:"X",requirements:[.init("Rare",quantityPerUnit:2)])
        r.addInventory(.init(material:"Rare",lotID:"R-1",onHand:1))
        r.addOrder(.init(id:"SHORT",sku:"X",quantity:2,dueAt:100))
        XCTAssertThrowsError(try r.releaseOrder("SHORT"))
        XCTAssertEqual(r.inventory[0].reserved,0)
        XCTAssertTrue(r.reservations.isEmpty)
    }

    func testEarliestDueDateDispatchesReleasedOrder() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        r.addShift(.init(name:"Shift",startAt:0,endAt:1000))
        r.addOrder(.init(id:"LATE",sku:"A",quantity:2,dueAt:500))
        r.addOrder(.init(id:"EARLY",sku:"A",quantity:2,dueAt:100))
        try r.releaseOrder("LATE");try r.releaseOrder("EARLY")
        _ = try r.cycle(elapsedMilliseconds:100)
        XCTAssertEqual(r.orders.first(where:{$0.status == .running})?.id,"EARLY")
    }

    func testFiniteCapacityScheduleIncludesSetupAndLateness() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.beverageLine)
        r.addOrder(.init(id:"A",sku:"A",quantity:100,dueAt:10))
        r.addOrder(.init(id:"B",sku:"B",quantity:100,dueAt:20))
        r.rebuildSchedule()
        XCTAssertEqual(r.schedule.count,2)
        XCTAssertTrue(r.schedule.contains(where:{$0.setupSeconds == 300}))
        XCTAssertTrue(r.schedule.contains(where:{$0.lateBySeconds > 0}))
    }

    func testTaktTargetUsesNetScheduledShiftTime() throws {
        let r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        let shift=ShiftSchedule(name:"Shift",startAt:0,endAt:3600,plannedBreaks:[1200...1800])
        let demand=SKUDemand(sku:"A",quantity:100,dueAt:3600)
        XCTAssertEqual(r.taktTarget(for:demand,shift:shift),30,accuracy:0.001)
    }

    func testFinishedEntityCreditsOrderConsumesMaterialAndReceivesFG() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        r.addShift(.init(name:"Shift",startAt:0,endAt:1000));r.registerBOM(sku:"A",requirements:[.init("Carton",quantityPerUnit:1)]);r.addInventory(.init(material:"Carton",lotID:"C1",onHand:10,unitCost:2));r.addOrder(.init(id:"O1",sku:"A",quantity:1,dueAt:100));try r.releaseOrder("O1")
        _ = try r.cycle(elapsedMilliseconds:20)
        let terminal=r.line.project.nodes.last!;var m=r.line.machines[terminal.id]!;m.materialFlow.completed=[.init(id:"FG1",serial:"FG1",kind:.caseUnit,zoneID:m.materialFlow.profile.zones.last!.id,createdAt:0)];r.line.machines[terminal.id]=m
        _ = try r.cycle(elapsedMilliseconds:20)
        XCTAssertEqual(r.orders.first(where:{$0.id=="O1"})?.status,.complete)
        XCTAssertEqual(r.costs.goodUnits,1);XCTAssertEqual(r.costs.materialCost,2,accuracy:0.001)
        XCTAssertEqual(r.inventory.first(where:{$0.lotID=="FG-O1"})?.onHand,1)
        XCTAssertTrue(r.batchRecords["O1"]?.complete == true)
    }

    func testDowntimeAndonEscalationAndMaintenanceCall() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        r.downtimeEscalationSeconds=0.05;r.automaticMaintenanceEscalationSeconds=0.08
        _ = r.reportDowntime(machine:.packagingCell,reason:.controlsFault,detail:"Output card fault")
        r.addShift(.init(name:"Shift",startAt:0,endAt:100));r.addOrder(.init(id:"O",sku:"A",quantity:1,dueAt:10));try r.releaseOrder("O")
        _ = try r.cycle(elapsedMilliseconds:100)
        XCTAssertTrue(r.andons.contains(where:{$0.severity == .critical}))
        XCTAssertTrue(r.maintenanceCalls.contains(where:{$0.machine == .packagingCell}))
        XCTAssertGreaterThan(r.costs.downtimeCost,0)
    }

    func testOperatorCanAssignReasonAndAcknowledgeAndon() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        let d=r.reportDowntime(machine:.packagingCell,reason:.unknown,detail:"Stopped")
        let a=try XCTUnwrap(r.andons.first)
        r.assignDowntimeReason(eventID:d.id,reason:.controlsFault,by:"Tech")
        r.acknowledgeAndon(a.id,by:"Tech")
        XCTAssertEqual(r.downtime.first(where:{$0.id==d.id})?.reason,.controlsFault)
        XCTAssertNotNil(r.andons.first(where:{$0.id==a.id})?.acknowledgedAt)
        XCTAssertTrue(r.operatorActions.contains(where:{$0.operatorName=="Tech"}))
    }

    func testSecondSKUCreatesPhysicalLineChangeover() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        r.addShift(.init(name:"Shift",startAt:0,endAt:1000));r.addOrder(.init(id:"A",sku:"A",quantity:1,dueAt:100));r.addOrder(.init(id:"B",sku:"B",quantity:1,dueAt:200));try r.releaseOrder("A");try r.releaseOrder("B")
        _ = try r.cycle(elapsedMilliseconds:20)
        let terminal=r.line.project.nodes.last!;var m=r.line.machines[terminal.id]!;m.materialFlow.completed=[.init(id:"A1",serial:"A1",kind:.caseUnit,zoneID:m.materialFlow.profile.zones.last!.id,createdAt:0)];r.line.machines[terminal.id]=m
        _ = try r.cycle(elapsedMilliseconds:20);_ = try r.cycle(elapsedMilliseconds:20)
        XCTAssertEqual(r.orders.first(where:{$0.id=="B"})?.status,.running)
        XCTAssertFalse(r.line.changeovers.isEmpty)
        XCTAssertTrue(r.line.changeovers.values.allSatisfy{$0.toSKU=="B"})
    }

    func testAllTwentyEightHeroMachinesCanHostMESExecution() throws {
        for machine in PlayableMachineKind.allCases {
            var p=LineBuilderProject(name:machine.rawValue);_ = p.addMachine(machine)
            var r=try ManufacturingExecutionRuntime(project:p);r.addShift(.init(name:"Shift",startAt:0,endAt:10));r.addOrder(.init(id:"O-\(machine.rawValue)",sku:"GEN",quantity:1,dueAt:10));try r.releaseOrder("O-\(machine.rawValue)")
            let s=try r.cycle(elapsedMilliseconds:20);XCTAssertNotNil(s.activeOrder,"MES failed for \(machine.rawValue)")
        }
    }
    func testScheduledShiftDisturbanceInjectsRealClosedLoopFault() throws {
        var r = try ManufacturingExecutionRuntime(project: ProductionLineTemplates.packagingToPalletizing)
        r.addShift(.init(name:"Shift",startAt:0,endAt:100));r.addOrder(.init(id:"O",sku:"A",quantity:2,dueAt:50));try r.releaseOrder("O")
        r.scheduleDisturbance(.init(triggerAt:0.05,machine:.packagingCell,outputFault:.brokenFieldWire,message:"Conveyor field conductor opens"))
        _ = try r.cycle(elapsedMilliseconds:100)
        let node=try XCTUnwrap(r.line.project.nodes.first(where:{$0.machine == .packagingCell}))
        XCTAssertTrue(r.disturbances.first?.applied == true)
        XCTAssertTrue(r.line.machines[node.id]?.plant.faults.contains(where:{$0.kind == .brokenFieldWire}) == true)
        XCTAssertTrue(r.batchRecords["O"]?.events.contains(where:{$0.type == "ProductionException"}) == true)
    }

}

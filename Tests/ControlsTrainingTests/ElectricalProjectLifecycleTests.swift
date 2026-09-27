import XCTest
@testable import ControlsTraining

final class ElectricalProjectLifecycleTests: XCTestCase {
    func testIFCIssueIsBlockedUntilRequiredApprovalsAreComplete() {
        var life = ElectricalProjectLifecycleCatalog.trainingLifecycle
        XCTAssertFalse(life.issue(.ifc, by: "Engineer", purpose: "Construction"))
        XCTAssertFalse(EngineeringApprovalEngine.missingRoles(state: .ifc, revision: life.designProject.revision, approvals: life.approvals).isEmpty)
        for i in life.approvals.indices { life.approvals[i].decision = .approved; life.approvals[i].reviewer = "Reviewer \(i)" }
        XCTAssertFalse(life.issue(.ifc, by: "Project Engineer", purpose: "Cannot skip IFR"))
        XCTAssertTrue(life.issue(.ifr, by: "Project Engineer", purpose: "Issued for review"))
        XCTAssertTrue(life.issue(.ifc, by: "Project Engineer", purpose: "Issued for construction"))
        XCTAssertEqual(life.currentIssueState, .ifc)
    }

    func testApprovedFieldChangeGeneratesAsBuiltButUnapprovedChangeDoesNot() {
        var life = ElectricalProjectLifecycleCatalog.trainingLifecycle
        let original = life.designProject.pages[1].document.conductors.first(where: {$0.id == "WDI0"})!.wireNumber
        life.fieldChanges = [
            .init(id:"FC1",kind:.wireNumber,pageID:"P2",targetID:"WDI0",oldValue:original,newValue:"2999",reason:"Field reroute",approved:true),
            .init(id:"FC2",kind:.noteOnly,targetID:"NOTE",oldValue:"",newValue:"Do not apply",reason:"Pending",approved:false)
        ]
        let result = life.generateAsBuilt(revision:"AB")
        XCTAssertEqual(result.appliedChangeIDs,["FC1"])
        XCTAssertEqual(life.asBuiltProject?.revision,"AB")
        XCTAssertEqual(life.asBuiltProject?.pages[1].document.conductors.first(where:{$0.id=="WDI0"})?.wireNumber,"2999")
    }

    func testNumberingConflictResolverFindsAndFixesDuplicateWireNumbers() {
        var p = ElectricalCADProjectCatalog.trainingProject
        XCTAssertGreaterThanOrEqual(p.pages[0].document.conductors.count, 2)
        p.pages[0].document.conductors[1].wireNumber = p.pages[0].document.conductors[0].wireNumber
        XCTAssertTrue(NumberingConflictResolver.conflicts(in:p).contains(where:{$0.kind == .wireNumber}))
        _ = NumberingConflictResolver.autoResolve(project:&p)
        let numbers=p.pages.flatMap{$0.document.conductors}.map(\.wireNumber).filter{!$0.isEmpty}
        XCTAssertEqual(numbers.count,Set(numbers).count)
    }

    func testCableTrayRoutingAvoidsNearlyFullDirectPath() {
        let life=ElectricalProjectLifecycleCatalog.trainingLifecycle
        let cable=life.designProject.cables[0]
        let route=CableTrayRoutingEngine.route(cable:cable,fromNode:"PANEL",toNode:"FIELD",segments:life.cableTraySegments)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.segmentIDs,["TR1","TR2"])
        XCTAssertTrue(route?.passesFillLimit == true)
    }

    func testDeviceLocationAndDrillLayoutsAreAuthored() {
        let life=ElectricalProjectLifecycleCatalog.trainingLifecycle
        XCTAssertEqual(life.deviceLocationDrawings.first?.drawingNumber,"E-401")
        XCTAssertGreaterThanOrEqual(life.deviceLocationDrawings.first?.devices.count ?? 0,3)
        XCTAssertEqual(life.drillLayouts.first?.drawingNumber,"E-501")
        XCTAssertEqual(life.drillLayouts.first?.openings.count,life.designProject.panelPlacements.count)
    }

    func testFabricationCriticalTasksGateFATRelease() {
        var life=ElectricalProjectLifecycleCatalog.trainingLifecycle
        XCTAssertFalse(life.fabricationOrders[0].canReleaseToFAT)
        for i in life.fabricationOrders[0].tasks.indices { life.fabricationOrders[0].tasks[i].status = .passed }
        XCTAssertTrue(life.fabricationOrders[0].canReleaseToFAT)
        life.fabricationOrders[0].tasks[0].status = .waived
        XCTAssertFalse(life.fabricationOrders[0].canReleaseToFAT)
    }

    func testFailedAcceptanceItemCreatesPunchAndNCR() {
        var fat=ElectricalProjectLifecycleCatalog.trainingLifecycle.fat
        fat.items[1].status = .failed
        let punches=LifecycleQualityEngine.punchItems(from:fat)
        XCTAssertEqual(punches.count,1)
        XCTAssertEqual(punches[0].severity,.a)
        let ncr=LifecycleQualityEngine.ncr(number:"NCR-001",from:fat.items[1],stage:"FAT")
        XCTAssertEqual(ncr.severity,.major)
        XCTAssertEqual(ncr.status,.open)
    }

    func testStartupCannotSkipEngineeringRelease() {
        let life=ElectricalProjectLifecycleCatalog.trainingLifecycle
        let gate=life.startupGate(to:.fabrication)
        XCTAssertFalse(gate.allowed)
        XCTAssertTrue(gate.blockers.contains(where:{$0.contains("IFC")}))
    }

    func testReadyToEnergizeRequiresSafetyProofAndClosedAList() {
        var life=preparedThroughSAT()
        life.startup.stage = .coldCommissioning
        var gate=life.startupGate(to:.readyToEnergize)
        XCTAssertFalse(gate.allowed)
        life.startup.emergencyStopTestPassed=true; life.startup.interlockProofPassed=true
        life.punchItems=[.init(id:"P1",number:"P-001",severity:.a,source:"SAT",description:"Safety channel mismatch",owner:"Controls",status:.open,correctiveAction:"",verification:"")]
        gate=life.startupGate(to:.readyToEnergize)
        XCTAssertFalse(gate.allowed)
        life.punchItems[0].status = .closed
        XCTAssertTrue(life.startupGate(to:.readyToEnergize).allowed)
    }

    func testProductionRequiresStableCyclesAndBaseline() {
        var life=preparedThroughSAT()
        life.startup.stage = .hotCommissioning
        life.startup.emergencyStopTestPassed=true; life.startup.interlockProofPassed=true
        XCTAssertFalse(life.startupGate(to:.production).allowed)
        life.startup.stableProductionCycles=life.startup.scenario.requiredProductionCycles
        life.startup.baselineCaptured=true
        XCTAssertTrue(life.startupGate(to:.production).allowed)
    }

    func testLifecycleRoundTripsCodable() throws {
        let life=ElectricalProjectLifecycleCatalog.trainingLifecycle
        let data=try JSONEncoder().encode(life)
        let decoded=try JSONDecoder().decode(ElectricalProjectLifecycle.self,from:data)
        XCTAssertEqual(decoded,life)
    }

    func testRedlineCanLinkToStructuredFieldChange() {
        let redline=FieldRedlineMarkup(id:"RL1",pageID:"P2",revision:"A",kind:.terminalChange,points:[.init(x:10,y:10)],text:"Move PE203 signal to spare terminal",author:"Field Tech",resolvedByChangeID:"FC1")
        let change=FieldChange(id:"FC1",kind:.terminalNumber,pageID:"P2",targetID:"IN",secondaryID:"DI0",oldValue:"0",newValue:"1",reason:"Damaged terminal",sourceRedlineID:"RL1",approved:true)
        XCTAssertEqual(redline.resolvedByChangeID,change.id)
        XCTAssertEqual(change.sourceRedlineID,redline.id)
    }

    private func preparedThroughSAT() -> ElectricalProjectLifecycle {
        var life=ElectricalProjectLifecycleCatalog.trainingLifecycle
        for i in life.approvals.indices { life.approvals[i].decision = .approved }
        _=life.issue(.ifr,by:"PE",purpose:"Review")
        _=life.issue(.ifc,by:"PE",purpose:"Construction")
        for i in life.fabricationOrders[0].tasks.indices { life.fabricationOrders[0].tasks[i].status = .passed }
        for i in life.fat.items.indices { life.fat.items[i].status = .passed }
        for i in life.sat.items.indices { life.sat.items[i].status = .passed }
        return life
    }
}

import XCTest
@testable import ControlsTraining

final class SpatialElectricalLabsTests: XCTestCase {
    func testSpatialDocumentMovesAndClampsSymbols() {
        var doc = SpatialElectricalLabCatalog.starterDocument
        doc.moveSymbol(id:"PS1",to:.init(x:-50,y:9999))
        let p = doc.symbols.first(where:{$0.id=="PS1"})!.position
        XCTAssertEqual(p.x,0)
        XCTAssertLessThanOrEqual(p.y, doc.canvasSize.height)
    }
    func testPowerFlowStopsAtOpenWire() {
        var doc=SpatialElectricalLabCatalog.starterDocument
        doc.conductors[1].state = .open
        let flow=TrainingPowerFlowSolver.solve(document:doc)
        XCTAssertTrue(flow.energizedWireIDs.contains("W101"))
        XCTAssertTrue(flow.blockedWireIDs.contains("W102"))
        XCTAssertFalse(flow.energizedWireIDs.contains("W103"))
    }
    func testProbeRequiresBothLeads() {
        let node=SpatialElectricalNode(id:"a",label:"A",position:.init(x:0,y:0),node:.init(id:"a",label:"A",dcVoltage:24,acVoltage:nil,connectedGroup:"A",currentMilliamps:nil,safeToProbe:true))
        let r=ProbeMeasurementEngine.reading(mode:.dcVolts,placement:.init(redNodeID:"a",blackNodeID:nil),nodes:[node])
        XCTAssertEqual(r.display,"PLACE")
    }
    func testModuleRejectsIncompatibleChannelMode() {
        var m=SpatialElectricalLabCatalog.ioModules[0]
        m.setMode(.currentInput,channel:0)
        XCTAssertFalse(m.validationIssues().isEmpty)
    }
    func testDocumentationProducesFromToRows() {
        let rows=ElectricalDocumentationGenerator.wireFromTo(document:SpatialElectricalLabCatalog.starterDocument)
        XCTAssertEqual(rows.count,4)
        XCTAssertEqual(rows.first?.wireNumber,"101")
    }
    func testSVGContainsDrawingMetadataAndParts() {
        let p=PanelPart(id:"x",kind:.powerSupply,tag:"PS1",x:1,y:1,width:2,height:2,heatWatts:25)
        let svg=PanelDrawingExporter.svg(.init(title:"Main Panel",drawingNumber:"E-001",revision:"A",panelWidthMM:600,panelHeightMM:800,parts:[p]))
        XCTAssertTrue(svg.contains("Main Panel")); XCTAssertTrue(svg.contains("E-001")); XCTAssertTrue(svg.contains("PS1"))
    }
    func testCommissioningSequenceViolationsCanFailCriticalStep() {
        let wo=SpatialElectricalLabCatalog.commissioningOrders[0]
        var attempt=CommissioningAttempt()
        attempt.complete(stepID:"power",workOrder:wo)
        XCTAssertFalse(attempt.criticalFailures.isEmpty)
        XCTAssertFalse(attempt.score(workOrder:wo).passed)
    }
    func testCommissioningCanPassWhenCompleteInOrder() {
        let wo=SpatialElectricalLabCatalog.commissioningOrders[0]
        var attempt=CommissioningAttempt()
        for step in wo.steps { attempt.complete(stepID:step.id,workOrder:wo) }
        let score=attempt.score(workOrder:wo)
        XCTAssertTrue(score.passed)
        XCTAssertEqual(score.percent,100,accuracy:0.001)
    }
}

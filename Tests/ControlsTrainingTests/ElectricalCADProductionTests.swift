import XCTest
@testable import ControlsTraining

final class ElectricalCADProductionTests: XCTestCase {
    func testZoneCoordinatesUsePageColumnRowFormat() {
        let page = ElectricalCADProjectCatalog.trainingProject.pages[1]
        let symbol = page.document.symbols.first(where: {$0.id == "PE203"})!
        let coord = DrawingZoneGrid().coordinate(for: symbol, page: page)
        XCTAssertTrue(coord.hasPrefix("2/"))
        XCTAssertTrue(coord.contains("B") || coord.contains("A"))
    }

    func testParentChildLinksAndPrintedCrossReferences() {
        let p = ElectricalCADProjectCatalog.trainingProject
        XCTAssertEqual(DrawingProductionEngine.childLinks(project:p).count, 1)
        let refs = CrossReferencePrinter.entries(project:p)
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs.contains(where: {$0.text.contains("PARENT@1/")}))
    }

    func testTitleBlockResolvesProjectAndSheet() {
        let p=ElectricalCADProjectCatalog.trainingProject, page=p.pages[0]
        let fields=TitleBlockTemplate.training.resolved(project:p,page:page)
        XCTAssertEqual(fields.first(where:{$0.id=="project"})?.value,"CTT-1001")
        XCTAssertEqual(fields.first(where:{$0.id=="drawing"})?.value,"E-101")
    }

    func testTerminalBridgeGraphicFollowsEndpoints() {
        var p=ElectricalCADProjectCatalog.trainingProject
        let page=p.pages[1]
        let e1=WireEndpoint(symbolID:"PE203",terminalID:"OUT"), e2=WireEndpoint(symbolID:"DI0",terminalID:"IN")
        p.jumpers=[.init(id:"J1",pageID:page.id,endpoints:[e1,e2])]
        let g=TerminalBridgeRenderer.graphics(project:p)
        XCTAssertEqual(g.count,1); XCTAssertGreaterThanOrEqual(g[0].polyline.count,4)
    }

    func testLibrariesContainProductionParts() {
        XCTAssertGreaterThanOrEqual(PanelFootprintLibrary.standard.count,5)
        XCTAssertTrue(IntelligentSymbolLibrary.standard.contains(where:{$0.kind == .relayCoil}))
        XCTAssertTrue(IntelligentSymbolLibrary.standard.contains(where:{$0.kind == .plcInput}))
    }

    func testDuctRoutingCanPreferHighCapacityDuct() {
        let duct=RoutingDuctGeometry(id:"D",tag:"WD",centerline:[.init(x:0,y:50),.init(x:100,y:50)],capacityWeight:3)
        let r=WireRoutingOptimizer.route(from:.init(x:0,y:0),to:.init(x:100,y:100),ducts:[duct])
        XCTAssertEqual(r.usedDuctIDs,["D"])
        XCTAssertGreaterThan(r.points.count,3)
    }

    func testUndoRedoRestoresSnapshots() {
        var p=ElectricalCADProjectCatalog.trainingProject, h=ElectricalCADHistory()
        h.checkpoint(p); p.revision="B"
        p=h.undo(current:p); XCTAssertEqual(p.revision,"A")
        p=h.redo(current:p); XCTAssertEqual(p.revision,"B")
    }

    func testCopyPasteBetweenSheetsRemapsSymbolIDs() {
        var p=ElectricalCADProjectCatalog.trainingProject
        let clip=SchematicClipboard.copy(project:p,pageID:"P2",symbolIDs:["PE203","DI0"])!
        let before=p.pages.first(where:{$0.id=="P3"})!.document.symbols.count
        clip.paste(into:&p,pageID:"P3")
        let afterPage=p.pages.first(where:{$0.id=="P3"})!
        XCTAssertEqual(afterPage.document.symbols.count,before+2)
        XCTAssertTrue(afterPage.document.symbols.contains(where:{$0.id.hasPrefix("PE203-COPY")}))
        XCTAssertEqual(afterPage.document.conductors.count,1)
    }

    func testRevisionComparisonFindsSymbolAndRevisionChanges() {
        let old=ElectricalCADProjectCatalog.trainingProject
        var new=old; new.revision="B"; new.pages[1].document.moveSymbol(id:"PE203",to:.init(x:200,y:200))
        let changes=ElectricalRevisionComparer.compare(old:old,new:new)
        XCTAssertTrue(changes.contains(where:{$0.category=="Project"}))
        XCTAssertTrue(changes.contains(where:{$0.category=="Symbol" && $0.kind == .modified}))
    }

    func testRandomExamIsDeterministicAndUnique() {
        let a=RandomizedMiswireExamGenerator.generate(seed:42,difficulty:3)
        let b=RandomizedMiswireExamGenerator.generate(seed:42,difficulty:3)
        XCTAssertEqual(a,b)
        XCTAssertEqual(a.faults.count,4)
        XCTAssertEqual(Set(a.faults.map(\.id)).count,a.faults.count)
    }

    func testRandomExamActuallyMutatesProject() {
        var p=ElectricalCADProjectCatalog.trainingProject
        let exam=RandomizedMiswireExamGenerator.generate(seed:9,difficulty:2)
        RandomizedMiswireExamGenerator.apply(exam,to:&p)
        XCTAssertEqual(p.instructorSession.injectedFaults.count,exam.faults.count)
    }

    func testProductionModelsRoundTripCodable() throws {
        let grid=DrawingZoneGrid(), title=TitleBlockTemplate.training
        XCTAssertEqual(try JSONDecoder().decode(DrawingZoneGrid.self,from:JSONEncoder().encode(grid)),grid)
        XCTAssertEqual(try JSONDecoder().decode(TitleBlockTemplate.self,from:JSONEncoder().encode(title)),title)
    }
}

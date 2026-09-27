import XCTest
@testable import ControlsTraining

final class ElectricalCADTrainingTests: XCTestCase {
    func testMultiPageCrossReferenceConnectsCoilToRemoteContact() {
        let p = ElectricalCADProjectCatalog.trainingProject
        let refs = p.crossReferences()
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].deviceTag, "M1")
        XCTAssertEqual(refs[0].sourcePage, "P1")
        XCTAssertEqual(refs[0].targetPage, "P3")
    }

    func testRelayNOContactFollowsCoilState() {
        let p = ElectricalCADProjectCatalog.trainingProject
        XCTAssertEqual(p.relayContactClosed(relayID: "REL-M1", contactID: "M1-13-14", energizedCoilSymbolIDs: []), false)
        XCTAssertEqual(p.relayContactClosed(relayID: "REL-M1", contactID: "M1-13-14", energizedCoilSymbolIDs: ["M1"]), true)
    }

    func testAutomaticWireNumberingNumbersBlankDrawingWire() {
        var p = ElectricalCADProjectCatalog.trainingProject
        guard let pi = p.pages.firstIndex(where: { $0.id == "P2" }) else { return XCTFail("Missing P2") }
        p.pages[pi].document.conductors[0].wireNumber = ""
        p.autoNumberWires(start: 100)
        XCTAssertFalse(p.pages[pi].document.conductors[0].wireNumber.isEmpty)
        XCTAssertTrue(p.pages[pi].document.conductors[0].wireNumber.hasPrefix("2"))
    }

    func testWireNumberPropagationStopsAtDeviceBoundariesButCrossesSharedTerminal() {
        let t1 = SpatialSchematicSymbol(id:"T1",kind:.terminal,tag:"TB1",label:"TB",position:.init(x:0,y:0),terminals:[.init(id:"1",label:"1",relativePosition:.init(x:0.5,y:0.5),role:.passive,nodeID:"T1",terminalNumber:"1")])
        let a = SpatialSchematicSymbol(id:"A",kind:.fuse,tag:"F1",label:"F",position:.init(x:0,y:0),terminals:[.init(id:"1",label:"1",relativePosition:.init(x:0,y:0.5),role:.passive,nodeID:"A1",terminalNumber:"1")])
        let b = SpatialSchematicSymbol(id:"B",kind:.fuse,tag:"F2",label:"F",position:.init(x:0,y:0),terminals:[.init(id:"1",label:"1",relativePosition:.init(x:0,y:0.5),role:.passive,nodeID:"B1",terminalNumber:"1")])
        var d = SpatialSchematicDocument(title:"prop",symbols:[t1,a,b])
        d.conductors=[
            .init(id:"W1",from:.init(symbolID:"A",terminalID:"1"),to:.init(symbolID:"T1",terminalID:"1"),wireNumber:"",color:.blue,gauge:.awg18,function:.dcControl),
            .init(id:"W2",from:.init(symbolID:"T1",terminalID:"1"),to:.init(symbolID:"B",terminalID:"1"),wireNumber:"",color:.blue,gauge:.awg18,function:.dcControl)
        ]
        var p = ElectricalCADProject(projectNumber:"x",title:"x",revision:"A",pages:[.init(id:"P",pageNumber:1,sheetCode:"E1",title:"x",document:d)])
        p.propagateWireNumber(pageID:"P",from:"W1",number:"101")
        XCTAssertEqual(p.pages[0].document.conductors.map(\.wireNumber), ["101","101"])
    }

    func testPLCAddressesAreGeneratedFromDrawingSymbols() {
        var p = ElectricalCADProjectCatalog.trainingProject
        p.plcAssignments = []
        p.assignPLCAddressesFromDrawing()
        XCTAssertTrue(p.plcAssignments.contains(where: { $0.symbolID == "DI0" && $0.address.contains("Local:2:I") }))
    }

    func testDuctFillIncreasesWithConductorsAndCanPass() {
        let p = ElectricalCADProjectCatalog.trainingProject
        let all = p.pages.flatMap { $0.document.conductors }
        let result = WireDuctCalculator.fill(p.wireDucts[0], conductors: all)
        XCTAssertGreaterThan(result.usedAreaMM2, 0)
        XCTAssertGreaterThan(result.fillPercent, 0)
        XCTAssertTrue(result.passes)
    }

    func testDINRailSnapAssignsRail() {
        let part=PanelPlacement(id:"X",part:.init(id:"X",kind:.relay,tag:"K1",x:0,y:0,width:1,height:1,heatWatts:2),position:.init(x:100,y:132))
        let snapped=DINRailSnapEngine.snap(part,to:[.init(id:"R",tag:"R",y:120,xStart:0,xEnd:200,snapTolerance:20)])
        XCTAssertEqual(snapped.railID,"R")
        XCTAssertEqual(snapped.position.y,120)
    }

    func testHeatMapRespondsToHighHeatDevice() {
        let low=EnclosureHeatMapEngine.calculate(placements:[],width:800,height:400)
        let p=ElectricalCADProjectCatalog.trainingProject
        let hot=EnclosureHeatMapEngine.calculate(placements:p.panelPlacements,width:800,height:400)
        XCTAssertGreaterThan(hot.map(\.temperatureRiseC).max() ?? 0, low.map(\.temperatureRiseC).max() ?? 0)
    }

    func testBOMIncludesCableAndPanelHardware() {
        let bom=ElectricalBOMGenerator.generate(project:ElectricalCADProjectCatalog.trainingProject)
        XCTAssertTrue(bom.contains(where:{$0.category=="Cable" && $0.tags.contains("CBL-PE203")}))
        XCTAssertTrue(bom.contains(where:{$0.category=="Panel hardware" && $0.tags.contains("VFD1")}))
    }

    func testInstructorOpenWireChangesActualProjectStateAndScoresEvidence() {
        var p=ElectricalCADProjectCatalog.trainingProject
        let f=ElectricalCADProjectCatalog.instructorFaultBank.first(where:{$0.id=="F-OPEN-PE"})!
        p.inject(f)
        let page=p.pages.first(where:{$0.id=="P2"})!
        XCTAssertEqual(page.document.conductors.first(where:{$0.id=="WDI0"})?.state,.open)
        XCTAssertEqual(p.instructorSession.scorePercent,0)
        p.instructorSession.learnerFindings.insert(f.id)
        XCTAssertEqual(p.instructorSession.scorePercent,50,accuracy:0.001)
        p.instructorSession.learnerRepairs.insert(f.id)
        XCTAssertEqual(p.instructorSession.scorePercent,100,accuracy:0.001)
    }

    func testRevisionCloudAndCableCoreMetadataPersistThroughCodableRoundTrip() throws {
        let p=ElectricalCADProjectCatalog.trainingProject
        let data=try JSONEncoder().encode(p)
        let decoded=try JSONDecoder().decode(ElectricalCADProject.self,from:data)
        XCTAssertEqual(decoded.revisionClouds.first?.revision,"A")
        XCTAssertEqual(decoded.cables.first?.cores.count,3)
    }
}

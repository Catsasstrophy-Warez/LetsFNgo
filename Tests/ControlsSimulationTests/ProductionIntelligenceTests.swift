import XCTest
@testable import ControlsSimulation

final class ProductionIntelligenceTests: XCTestCase {
    func testTrackingIdentitySupportsBarcodeRFIDAndLicensePlate() throws {
        var project = LineBuilderProject(name: "Warehouse")
        let node = project.addMachine(.asrsCrane)
        var runtime = try ProductionIntelligenceRuntime(project: project)
        var machine = runtime.machines[node.id]!
        let entity = MaterialEntity(id: "PAL1", serial: "PAL-0001", kind: .pallet, zoneID: machine.materialFlow.profile.zones.first!.id, createdAt: 0)
        _ = machine.materialFlow.enqueue(entity); runtime.machines[node.id] = machine
        _ = try runtime.cycle(elapsedMilliseconds: 100)
        let identity = try XCTUnwrap(runtime.genealogy["PAL1"]?.identity)
        XCTAssertNotNil(identity.technologies[.barcode]); XCTAssertNotNil(identity.technologies[.rfid]); XCTAssertNotNil(identity.palletLicensePlate)
    }

    func testRecipePropagatesIntoGenealogy() throws {
        var project = LineBuilderProject(name: "Recipe")
        let node = project.addMachine(.batchMixingTank)
        var runtime = try ProductionIntelligenceRuntime(project: project)
        runtime.registerRecipe(.init(id:"R1",sku:"SKU-A",description:"Formula A",parameters:["waterPct":65]))
        runtime.setRecipe("R1", on: node.id)
        var machine = runtime.machines[node.id]!
        _ = machine.materialFlow.enqueue(.init(id:"BATCH-R1",serial:"BATCH-R1",kind:.liquidBatch,zoneID:machine.materialFlow.profile.zones.first!.id,createdAt:0))
        runtime.machines[node.id] = machine
        _ = try runtime.cycle(elapsedMilliseconds: 100)
        XCTAssertEqual(runtime.genealogy["BATCH-R1"]?.recipeID, "R1")
    }

    func testFIFOBufferPreservesOldestEntityFirst() {
        let c = LineBuilderConnection(fromNodeID:"A",toNodeID:"B",capacity:3,discipline:.fifo)
        var buffer = IntelligentLineBuffer(connection:c)
        buffer.enqueue([
            .init(id:"new",serial:"N",kind:.carton,zoneID:"Z",createdAt:2),
            .init(id:"old",serial:"O",kind:.carton,zoneID:"Z",createdAt:1)
        ])
        XCTAssertEqual(buffer.dequeue()?.id,"old")
    }

    func testPriorityBufferUsesEntityPriority() {
        let c = LineBuilderConnection(fromNodeID:"A",toNodeID:"B",capacity:3,discipline:.priority)
        var low = MaterialEntity(id:"low",serial:"L",kind:.parcel,zoneID:"Z",createdAt:1); low.attributes["priority"] = 1
        var high = MaterialEntity(id:"high",serial:"H",kind:.parcel,zoneID:"Z",createdAt:2); high.attributes["priority"] = 10
        var buffer = IntelligentLineBuffer(connection:c); buffer.enqueue([low,high])
        XCTAssertEqual(buffer.dequeue()?.id,"high")
    }

    func testDestinationDivertChoosesNamedDownstream() throws {
        var project=LineBuilderProject(name:"Divert")
        let s=project.addMachine(.parcelSortation,name:"Sorter")
        let a=project.addMachine(.asrsCrane,name:"A")
        let b=project.addMachine(.roboticPalletizer,name:"B")
        let ca=project.connect(s.id,a.id,capacity:2); _=project.connect(s.id,b.id,capacity:2)
        var runtime=try ProductionIntelligenceRuntime(project:project)
        var src=runtime.machines[s.id]!
        var e=MaterialEntity(id:"P",serial:"P",kind:.parcel,zoneID:src.materialFlow.profile.zones.last!.id,createdAt:0);e.labels["destination"]="A"
        src.materialFlow.completed=[e];runtime.machines[s.id]=src
        _=try runtime.cycle(elapsedMilliseconds:20)
        XCTAssertTrue(runtime.buffers[ca.id]?.entities.contains(where:{$0.id=="P"}) == true || runtime.machines[a.id]?.materialFlow.entities.contains(where:{$0.id=="P"}) == true)
    }

    func testBlockedStarvedHandshakeGenerated() throws {
        var runtime=try ProductionIntelligenceRuntime(project:ProductionLineTemplates.packagingToPalletizing)
        let snap=try runtime.cycle(elapsedMilliseconds:100)
        XCTAssertEqual(snap.handshakes.count,1)
        XCTAssertTrue(snap.handshakes.values.allSatisfy{$0.lineSpeedReference >= 0 && $0.lineSpeedReference <= 100})
    }

    func testChangeoverBlocksDownstreamPermissionUntilFirstPiece() throws {
        let p=ProductionLineTemplates.packagingToPalletizing
        let downstream=p.nodes[1]
        var runtime=try ProductionIntelligenceRuntime(project:p)
        runtime.beginChangeover(nodeID:downstream.id,toSKU:"SKU-B",targetSeconds:0.6)
        var snap=try runtime.cycle(elapsedMilliseconds:100)
        XCTAssertTrue(snap.handshakes.values.contains{$0.downstreamState == .changeover && !$0.permissionToReceive})
        for _ in 0..<6 { snap=try runtime.cycle(elapsedMilliseconds:100) }
        runtime.approveFirstPiece(nodeID:downstream.id); snap=try runtime.cycle(elapsedMilliseconds:100)
        XCTAssertEqual(runtime.changeovers[downstream.id]?.phase,.complete)
    }

    func testQualityHoldStopsHeldEntityAtBuffer() throws {
        var runtime=try ProductionIntelligenceRuntime(project:ProductionLineTemplates.packagingToPalletizing)
        let c=runtime.project.connections[0];let up=runtime.project.nodes[0]
        var machine=runtime.machines[up.id]!
        let e=MaterialEntity(id:"HOLDME",serial:"CASE-H",kind:.carton,zoneID:machine.materialFlow.profile.zones.last!.id,createdAt:0)
        machine.materialFlow.completed=[e];runtime.machines[up.id]=machine
        _=try runtime.cycle(elapsedMilliseconds:20)
        _=runtime.placeHold(entityIDs:["HOLDME"],reason:"QC investigation")
        _=try runtime.cycle(elapsedMilliseconds:20)
        XCTAssertTrue(runtime.buffers[c.id]?.entities.contains(where:{$0.id=="HOLDME"}) == true || runtime.genealogy["HOLDME"]?.holdState == .held)
    }

    func testLotRecallFindsAffectedGenealogy() throws {
        var project=LineBuilderProject(name:"Recall");let n=project.addMachine(.bottlingLine)
        var runtime=try ProductionIntelligenceRuntime(project:project);var m=runtime.machines[n.id]!
        var e=MaterialEntity(id:"B1",serial:"B1",kind:.bottle,zoneID:m.materialFlow.profile.zones.first!.id,createdAt:0);e.labels["capLot"]="CAP-77"
        _=m.materialFlow.enqueue(e);runtime.machines[n.id]=m;_=try runtime.cycle(elapsedMilliseconds:20)
        let result=runtime.recall(lotID:"CAP-77",reason:"Supplier notice")
        XCTAssertTrue(result.affectedEntityIDs.contains("B1"));XCTAssertEqual(runtime.genealogy["B1"]?.holdState,.recalled)
    }

    func testOEEProducesAvailabilityPerformanceQualityAndComposite() throws {
        var runtime=try ProductionIntelligenceRuntime(project:ProductionLineTemplates.packagingToPalletizing)
        for _ in 0..<10 { _=try runtime.cycle(elapsedMilliseconds:100) }
        let oee=try XCTUnwrap(runtime.machineOEE[.packagingCell])
        XCTAssertGreaterThanOrEqual(oee.availability,0);XCTAssertLessThanOrEqual(oee.oee,1)
    }

    func testLineBuilderSupportsAllHeroMachinesAndValidation() {
        var p=LineBuilderProject(name:"All Heroes")
        var previous:String?
        for (i,m) in PlayableMachineKind.allCases.enumerated() { let n=p.addMachine(m,x:Double(i)*100,y:100);if let previous{p.connect(previous,n.id)};previous=n.id }
        XCTAssertEqual(p.nodes.count,28);XCTAssertTrue(p.validationIssues().isEmpty)
    }

    func testMergeArbitrationCanPrioritizeIncomingLine() throws {
        var p=LineBuilderProject(name:"Merge")
        let a=p.addMachine(.packagingCell,name:"A"), b=p.addMachine(.bottlingLine,name:"B"), d=p.addMachine(.roboticPalletizer,name:"Merge")
        let c1=p.connect(a.id,d.id,capacity:2,priority:1);let c2=p.connect(b.id,d.id,capacity:2,priority:10)
        var r=try ProductionIntelligenceRuntime(project:p);r.setMergeStrategy(.priority,for:d.id)
        var ba=r.buffers[c1.id]!;ba.enqueue([MaterialEntity(id:"A1",serial:"A1",kind:.carton,zoneID:"Z",createdAt:0)]);r.buffers[c1.id]=ba
        var bb=r.buffers[c2.id]!;bb.enqueue([MaterialEntity(id:"B1",serial:"B1",kind:.bottle,zoneID:"Z",createdAt:0)]);r.buffers[c2.id]=bb
        _=try r.cycle(elapsedMilliseconds:20)
        XCTAssertTrue(r.machines[d.id]!.materialFlow.entities.contains(where:{$0.id=="B1"}))
    }
}

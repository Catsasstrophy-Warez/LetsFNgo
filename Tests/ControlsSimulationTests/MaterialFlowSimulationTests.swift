import XCTest
@testable import ControlsSimulation
import ControlsPLC

final class MaterialFlowSimulationTests: XCTestCase {
    func testAll28MachinesHaveMaterialFlowProfiles() {
        XCTAssertEqual(MachineMaterialFlowLibrary.all.count, 28)
        XCTAssertTrue(MachineMaterialFlowLibrary.all.allSatisfy { $0.zones.count >= 3 && $0.maximumWIP > 0 })
    }
    func testPackagingCellCanHoldMultipleCartons() {
        var flow=MachineMaterialFlowRuntime(machine:.packagingCell)
        let cycle=healthyCycle(.packagingCell)
        let plant=healthyPlant()
        for _ in 0..<80 { _=flow.step(plant:plant,cycle:cycle,deltaTime:0.1) }
        XCTAssertGreaterThan(flow.entities.count,1)
        XCTAssertLessThanOrEqual(flow.entities.count,flow.profile.maximumWIP)
    }
    func testBottlesReceiveRealFillerPocketIdentity() {
        var flow=MachineMaterialFlowRuntime(machine:.bottlingLine)
        let cycle=healthyCycle(.bottlingLine)
        for _ in 0..<20 {_ = flow.step(plant:healthyPlant(),cycle:cycle,deltaTime:0.2)}
        XCTAssertTrue(flow.entities.contains { ($0.attributes["fillerPocket"] ?? 0) >= 1 })
    }
    func testBatchCarriesIngredientComposition() {
        var flow=MachineMaterialFlowRuntime(machine:.batchMixingTank)
        let cycle=healthyCycle(.batchMixingTank)
        for _ in 0..<500 {_ = flow.step(plant:healthyPlant(),cycle:cycle,deltaTime:0.1)}
        let e=flow.entities.first ?? flow.completed.first
        XCTAssertEqual(e?.attributes["waterPct"],65)
        XCTAssertNotNil(e?.labels["recipe"])
    }
    func testParcelCarriesDestination() {
        var flow=MachineMaterialFlowRuntime(machine:.parcelSortation)
        let c=healthyCycle(.parcelSortation)
        for _ in 0..<10 {_=flow.step(plant:healthyPlant(),cycle:c,deltaTime:0.2)}
        XCTAssertNotNil(flow.entities.first?.labels["destination"])
    }
    func testMoldedPartsCarryCavityAndDimensions() {
        var flow=MachineMaterialFlowRuntime(machine:.injectionMoldingCell)
        let c=healthyCycle(.injectionMoldingCell)
        for _ in 0..<200 {_=flow.step(plant:healthyPlant(),cycle:c,deltaTime:0.1)}
        let e=flow.entities.first ?? flow.completed.first
        XCTAssertNotNil(e?.attributes["cavity"]);XCTAssertNotNil(e?.attributes["lengthMM"])
    }
    func testPasteurizationRetainsResidenceHistory() {
        var flow=MachineMaterialFlowRuntime(machine:.htstPasteurizer)
        let c=healthyCycle(.htstPasteurizer)
        for _ in 0..<300 {_=flow.step(plant:healthyPlant(),cycle:c,deltaTime:0.1)}
        let all=flow.entities+flow.completed+flow.rework+flow.scrapped
        XCTAssertTrue(all.contains{$0.residenceHistory.count>1})
    }
    func testBatteryCarriesSerialAndCurveSummary() {
        var flow=MachineMaterialFlowRuntime(machine:.batteryFormationLine)
        let c=healthyCycle(.batteryFormationLine)
        for _ in 0..<250 {_=flow.step(plant:healthyPlant(),cycle:c,deltaTime:0.1)}
        let all=flow.entities+flow.completed+flow.rework+flow.scrapped
        XCTAssertTrue(all.allSatisfy{!$0.serial.isEmpty})
        XCTAssertTrue(all.contains{$0.attributes["voltageV"] != nil})
    }
    func testDownstreamBlockageCreatesAccumulation() {
        var flow=MachineMaterialFlowRuntime(machine:.packagingCell);flow.downstreamCapacityAvailable=false
        let c=healthyCycle(.packagingCell)
        var s:MaterialFlowSnapshot?
        for _ in 0..<300{s=flow.step(plant:healthyPlant(),cycle:c,deltaTime:0.1)}
        XCTAssertEqual(s?.blockage,true);XCTAssertGreaterThan(s?.entities.count ?? 0,1)
    }
    func testLineBufferTransfersIdentityBetweenMachines() {
        var line=ProductionLineRuntime(machines:[.packagingCell,.roboticPalletizer],bufferCapacity:4)
        var up=line.materialFlows[.packagingCell]!
        let e=MaterialEntity(id:"x",serial:"CASE-0001",kind:.caseUnit,zoneID:up.profile.zones.last!.id,createdAt:0)
        up.completed=[e];line.materialFlows[.packagingCell]=up
        line.transferCompleted()
        XCTAssertTrue(line.materialFlows[.roboticPalletizer]!.entities.contains{$0.id=="x"})
    }
    func testClosedLoopCycleAutomaticallyAdvancesMaterialFlow() throws {
        var r=try FullyClosedLoopMachineRuntime(machine:.packagingCell)
        for _ in 0..<20 {_=try r.cycle(elapsedMilliseconds:100)}
        XCTAssertNotNil(r.latestMaterialFlow)
        XCTAssertGreaterThan(r.latestMaterialFlow?.entities.count ?? 0,0)
    }
    func testMaterialFlowPersists() throws {
        let r=MachineMaterialFlowRuntime(machine:.parcelSortation)
        let data=try JSONEncoder().encode(r);let d=try JSONDecoder().decode(MachineMaterialFlowRuntime.self,from:data)
        XCTAssertEqual(r,d)
    }
    func testIntegratedLineOwnsRealClosedLoopHeroMachines() throws {
        var line=try IntegratedProductionLineRuntime(machines:[.packagingCell,.roboticPalletizer],bufferCapacity:4)
        let s=try line.cycle(elapsedMilliseconds:100)
        XCTAssertEqual(s.machineSnapshots.count,2)
        XCTAssertNotNil(s.materialSnapshots[.packagingCell])
        XCTAssertNotNil(s.materialSnapshots[.roboticPalletizer])
    }
    func testIntegratedLinePreservesIdentityAcrossMachineBoundary() throws {
        var line=try IntegratedProductionLineRuntime(machines:[.packagingCell,.roboticPalletizer],bufferCapacity:4)
        var upstream=line.machines[.packagingCell]!
        let e=MaterialEntity(id:"genealogy-1",serial:"CASE-00042",kind:.caseUnit,zoneID:upstream.materialFlow.profile.zones.last!.id,createdAt:0)
        upstream.materialFlow.completed=[e];line.machines[.packagingCell]=upstream
        _=try line.cycle(elapsedMilliseconds:20)
        let down=line.machines[.roboticPalletizer]!.materialFlow.entities
        XCTAssertTrue(down.contains{$0.id=="genealogy-1" && $0.labels["upstreamMachine"]==PlayableMachineKind.packagingCell.rawValue})
    }

    private func healthyPlant()->ClosedLoopPlantSnapshot {
        var p=ClosedLoopPlantSnapshot(electrical:[:],actuators:[
            "M":.init(tag:"M",kind:.motorStarter,energized:true,commandPercent:100,actualPercent:100,speedHz:60,positionPercent:0,currentAmps:5,temperatureC:35,pressurePSI:60,faulted:false),
            "V":.init(tag:"V",kind:.controlValve,energized:true,commandPercent:80,actualPercent:80,speedHz:0,positionPercent:80,currentAmps:0,temperatureC:25,pressurePSI:0,faulted:false),
            "S":.init(tag:"S",kind:.solenoid,energized:true,commandPercent:100,actualPercent:100,speedHz:0,positionPercent:100,currentAmps:0,temperatureC:25,pressurePSI:0,faulted:false),
            "A":.init(tag:"A",kind:.servo,energized:true,commandPercent:70,actualPercent:70,speedHz:40,positionPercent:70,currentAmps:4,temperatureC:35,pressurePSI:0,faulted:false),
            "H":.init(tag:"H",kind:.heater,energized:true,commandPercent:100,actualPercent:100,speedHz:0,positionPercent:0,currentAmps:10,temperatureC:80,pressurePSI:0,faulted:false)
        ],process:.init(),generatedDigitalFeedback:[:],generatedAnalogFeedback:[:],activeFaults:[])
        p.process.pressurePercent=75;p.process.flowPercent=80;p.process.levelPercent=60;p.process.temperaturePercent=80;p.process.positionPercent=75;p.process.speedPercent=85
        return p
    }
    private func healthyCycle(_ machine:PlayableMachineKind)->AuthoredMachineCycleSnapshot {
        var r=AuthoredMachineCycleRuntime(machine:machine);return r.step(plant:healthyPlant(),deltaTime:0.1)
    }
}

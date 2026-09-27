import XCTest
@testable import ControlsSimulation
import ControlsPLC

final class MachineCycleRealismTests: XCTestCase {
    func testAll28MachinesHaveAuthoredDistinctCycleProfiles() {
        XCTAssertEqual(MachineCycleLibrary.all.count, 28)
        XCTAssertEqual(Set(MachineCycleLibrary.all.map{$0.productName}).count, 28)
        XCTAssertTrue(MachineCycleLibrary.all.allSatisfy{$0.phases.count >= 4 && $0.qualitySpecs.count >= 2})
    }
    func testProfilesCoverRequestedPhysicalDomains() {
        let all=MachineCycleLibrary.all
        XCTAssertTrue(all.contains{$0.pneumaticStrokeSeconds>0})
        XCTAssertTrue(all.contains{$0.valveTravelSeconds>0})
        XCTAssertTrue(all.contains{$0.tankCapacityLiters>0})
        XCTAssertTrue(all.contains{$0.thermalMassKJPerC>200})
        XCTAssertTrue(all.contains{$0.pumpRatedFlowLPM>0})
        XCTAssertTrue(all.contains{$0.pidResponseSeconds>0})
        XCTAssertTrue(all.contains{$0.servoMoveSeconds>0})
    }
    func testMotorInertiaPreventsInstantaneousPhysicalResponse() throws {
        var loop=try FullyClosedLoopMachineRuntime(machine:.packagingCell)
        var cycle=AuthoredMachineCycleRuntime(machine:.packagingCell)
        if let path=ClosedLoopPlantRuntime.outputPaths(for:loop.executable).first { try loop.forceControllerValue(path.commandTag,.bool(true)) }
        let (_,s)=try loop.cycleWithAuthoredPhysics(&cycle,elapsedMilliseconds:100)
        XCTAssertLessThan(s.dynamics.motorSpeedPercent,100)
    }
    func testBrokenOutputWireCanStallAuthoredSequence() throws {
        var loop=try FullyClosedLoopMachineRuntime(machine:.packagingCell)
        var cycle=AuthoredMachineCycleRuntime(machine:.packagingCell)
        guard let path=ClosedLoopPlantRuntime.outputPaths(for:loop.executable).first else { return XCTFail("missing output") }
        try loop.forceControllerValue(path.commandTag,.bool(true))
        loop.injectOutputFault(.init(target:path.commandTag,kind:.brokenFieldWire))
        var last:AuthoredMachineCycleSnapshot?
        for _ in 0..<30 { last=try loop.cycleWithAuthoredPhysics(&cycle,elapsedMilliseconds:100).1 }
        XCTAssertEqual(last?.phaseIndex,0)
        XCTAssertEqual(last?.dynamics.motorSpeedPercent,0)
    }
    func testGoodPhysicalOperationCanAdvanceASequence() throws {
        var runtime=AuthoredMachineCycleRuntime(machine:.pressureSkid)
        var plant=ClosedLoopPlantSnapshot(electrical:[:],actuators:[
            "P1":.init(tag:"P1",kind:.pump,energized:true,commandPercent:100,actualPercent:100,speedHz:60,positionPercent:0,currentAmps:8,temperatureC:40,pressurePSI:60,faulted:false),
            "V1":.init(tag:"V1",kind:.controlValve,energized:true,commandPercent:80,actualPercent:80,speedHz:0,positionPercent:80,currentAmps:0,temperatureC:25,pressurePSI:0,faulted:false)
        ],process:.init(),generatedDigitalFeedback:[:],generatedAnalogFeedback:[:],activeFaults:[])
        plant.process.pressurePercent=70;plant.process.flowPercent=80;plant.process.levelPercent=60
        var snap:AuthoredMachineCycleSnapshot?
        for _ in 0..<70 { snap=runtime.step(plant:plant,deltaTime:0.1) }
        XCTAssertGreaterThan(snap?.phaseIndex ?? 0,0)
    }
    func testQualityOutcomeTracksGoodReworkRejectCounts() {
        var runtime=AuthoredMachineCycleRuntime(machine:.packagingCell)
        let plant=ClosedLoopPlantSnapshot(electrical:[:],actuators:[
            "M":.init(tag:"M",kind:.motorStarter,energized:true,commandPercent:100,actualPercent:100,speedHz:60,positionPercent:0,currentAmps:7,temperatureC:35,pressurePSI:0,faulted:false),
            "S":.init(tag:"S",kind:.solenoid,energized:true,commandPercent:100,actualPercent:100,speedHz:0,positionPercent:100,currentAmps:0,temperatureC:25,pressurePSI:0,faulted:false)
        ],process:.init(),generatedDigitalFeedback:[:],generatedAnalogFeedback:[:],activeFaults:[])
        for _ in 0..<400 { _=runtime.step(plant:plant,deltaTime:0.1) }
        XCTAssertGreaterThan(runtime.cycleCount,0)
        XCTAssertEqual(runtime.cycleCount,runtime.goodCount+runtime.reworkCount+runtime.rejectCount)
    }
    func testCycleRuntimePersists() throws {
        let r=AuthoredMachineCycleRuntime(machine:.industrialOven)
        let data=try JSONEncoder().encode(r);let decoded=try JSONDecoder().decode(AuthoredMachineCycleRuntime.self,from:data)
        XCTAssertEqual(decoded.profile.machine,.industrialOven); XCTAssertEqual(decoded,r)
    }
    func testNormalClosedLoopCycleAutomaticallyAdvancesAuthoredMachinePhysics() throws {
        var runtime = try FullyClosedLoopMachineRuntime(machine: .packagingCell)
        XCTAssertNil(runtime.latestCycle)
        _ = try runtime.cycle(elapsedMilliseconds: 100)
        XCTAssertNotNil(runtime.latestCycle)
        XCTAssertEqual(runtime.latestCycle?.profile.machine, .packagingCell)
        XCTAssertGreaterThan(runtime.latestCycle?.phaseElapsed ?? 0, 0)
    }

    func testEveryMachineHasUniquePhaseFingerprint() {
        let fingerprints=MachineCycleLibrary.all.map{$0.phases.map{$0.name}.joined(separator:"|")}
        XCTAssertEqual(Set(fingerprints).count,28)
    }
}

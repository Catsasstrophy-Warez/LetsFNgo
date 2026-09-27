import XCTest
@testable import ControlsTraining
import ControlsPLC
import ControlsSimulation

final class IntegratedPlantCampaignTests: XCTestCase {
    func testFaultProgressionMovesThroughConditionsAndRepair() {
        var f = ProgressivePlantFault(id:"F",kind:.degradingBearing,target:"M1",onsetHour:10,initialSeverity:0.1,growthPerHour:0.1)
        XCTAssertEqual(f.condition(at:5), .latent)
        XCTAssertEqual(f.condition(at:11), .degraded)
        XCTAssertEqual(f.condition(at:17), .critical)
        f.repairedAtHour = 18
        XCTAssertEqual(f.condition(at:19), .repaired)
        f.regressionAtHour = 20
        XCTAssertEqual(f.condition(at:21), .regression)
    }

    func testLooseTerminalCanSeparatePhysicalSensorFromPLCObservation() {
        var engine = PlantFaultPropagationEngine()
        let physical = ScenarioProcessSnapshot(discrete:["PE203":true])
        let fault = ProgressivePlantFault(id:"T",kind:.looseTerminal,target:"TB2",onsetHour:0,initialSeverity:1,growthPerHour:0)
        var mismatch = false
        for n in 0..<80 {
            let result = engine.applySensorPath(physical:physical,faults:[fault],hour:1,time:Double(n)/20)
            if result.0.discrete["PE203"] == false {
                mismatch = true
                XCTAssertLessThan(result.1.plcInputVoltage, 10)
                break
            }
        }
        XCTAssertTrue(mismatch)
    }

    func testDriftingTransmitterBiasesPLCObservedAnalogButNotPhysicalValue() {
        var engine = PlantFaultPropagationEngine()
        let physical = ScenarioProcessSnapshot(analog:["PressurePV":50])
        let fault = ProgressivePlantFault(id:"TX",kind:.driftingTransmitter,target:"PT301",onsetHour:0,initialSeverity:0.8,growthPerHour:0)
        let (observed, _) = engine.applySensorPath(physical:physical,faults:[fault],hour:1,time:1)
        XCTAssertEqual(physical.analog["PressurePV"], 50)
        XCTAssertGreaterThan(observed.analog["PressurePV"] ?? 0, 50)
    }

    func testNetworkFaultProducesStalePLCData() {
        var engine = PlantFaultPropagationEngine()
        let fault = ProgressivePlantFault(id:"NET",kind:.networkIntermittency,target:"RIO",onsetHour:0,initialSeverity:1,growthPerHour:0)
        _ = engine.applySensorPath(physical:.init(analog:["PressurePV":10],discrete:["PE203":true]),faults:[],hour:0,time:0)
        var foundStale = false
        for n in 0..<80 {
            let (observed,electrical) = engine.applySensorPath(physical:.init(analog:["PressurePV":99],discrete:["PE203":false]),faults:[fault],hour:1,time:Double(n)/20)
            if electrical.networkStale {
                foundStale = true
                XCTAssertEqual(observed.analog["PressurePV"],10)
                XCTAssertEqual(observed.discrete["PE203"],true)
                break
            }
        }
        XCTAssertTrue(foundStale)
    }

    func testVFDDegradationDeratesAndEventuallyTripsActualRun() {
        var engine = PlantFaultPropagationEngine()
        let degraded = ProgressivePlantFault(id:"V1",kind:.vfdDegradation,target:"VFD",onsetHour:0,initialSeverity:0.6,growthPerHour:0)
        let (_, state) = engine.effectiveRun(command:true,faults:[degraded],hour:1,time:0)
        XCTAssertTrue(state.actualRun)
        XCTAssertLessThan(state.frequencyHz,60)
        let critical = ProgressivePlantFault(id:"V2",kind:.vfdDegradation,target:"VFD",onsetHour:0,initialSeverity:0.9,growthPerHour:0)
        let (actual, tripState) = engine.effectiveRun(command:true,faults:[critical],hour:1,time:0)
        XCTAssertFalse(actual)
        XCTAssertTrue(tripState.faulted)
    }

    func testBearingFaultChangesPhysicalEnvironmentAndAddsConditionSignals() {
        var engine = PlantFaultPropagationEngine()
        let fault = ProgressivePlantFault(id:"B",kind:.degradingBearing,target:"M1",onsetHour:0,initialSeverity:0.7,growthPerHour:0)
        let env = engine.effectiveEnvironment(.init(load:0.5,speed:0.8,ambient:0.5),faults:[fault],hour:1)
        XCTAssertLessThan(env.speed,0.8)
        var physical = ScenarioProcessSnapshot(analog:["LineSpeed":1])
        var drive = PlantDriveSnapshot(); drive.actualRun=true; drive.currentA=10
        engine.addPhysicalDegradation(to:&physical,faults:[fault],hour:1,drive:drive)
        XCTAssertGreaterThan(physical.analog["BearingVibrationMMs"] ?? 0,4)
        XCTAssertGreaterThan(physical.analog["MotorCurrentA"] ?? 0,10)
    }

    func testIntegratedRuntimeFeedsFaultedObservationIntoRealPLCScanAndEvidence() throws {
        var project = try DemoProjectFactory.packagingCell()
        try project.controllerTags.add(.init(name:"Field_24VDC",value:.real(24),role:.input))
        try project.controllerTags.add(.init(name:"InputVoltage",value:.real(24),role:.input))
        try project.controllerTags.add(.init(name:"Network_OK",value:.bool(true),role:.input))
        try project.controllerTags.add(.init(name:"VFD_Ready",value:.bool(true),role:.input))
        try project.controllerTags.add(.init(name:"VFD_Fault",value:.bool(false),role:.input))
        try project.controllerTags.add(.init(name:"VFD_Hz",value:.real(0),role:.input))
        try project.controllerTags.add(.init(name:"VFD_Current",value:.real(0),role:.input))
        var runtime = try IntegratedPlantRuntime(project:project,process:.packaging(.init()),environment:.init(load:0.5,speed:1,ambient:0.5))
        var campaign = PersistentPlantCampaign(faults:[.init(id:"TERM",kind:.looseTerminal,target:"PE203",onsetHour:0,initialSeverity:1,growthPerHour:0)],demands:[.init(day:1,shift:.day,targetUnits:800,maximumDowntimeMinutes:30)])
        try runtime.startMachine()
        for _ in 0..<250 { _ = try runtime.step(milliseconds:20,campaign:&campaign) }
        XCTAssertFalse(campaign.historian.isEmpty)
        XCTAssertTrue(runtime.controller.project.controllerTags.contains("InputVoltage"))
        XCTAssertTrue(runtime.latest.physicalAnalog.keys.contains("VFD_FrequencyHz"))
        XCTAssertGreaterThanOrEqual(campaign.cumulativeLost,0)
    }

    func testRepairConsumesSpareAndRequiresRetest() {
        var campaign = IntegratedPlantCampaignCatalog.sevenDayPackagingCampaign()
        campaign.elapsedCampaignHours = 20
        let fault = campaign.faults[1]
        let wo = campaign.openWorkOrder(for:fault)
        XCTAssertTrue(campaign.repair(workOrderID:wo,parts:["TB-2.5":1],downtimeMinutes:12,notes:"Replaced damaged loose terminal"))
        XCTAssertEqual(campaign.workOrders.first{$0.id==wo}?.status,.retestRequired)
        XCTAssertEqual(campaign.spares.first{$0.partNumber=="TB-2.5"}?.quantityOnHand,5)
        campaign.recordRetest(workOrderID:wo,passed:true)
        XCTAssertEqual(campaign.workOrders.first{$0.id==wo}?.status,.closed)
    }

    func testShiftHandoffCanLoseInformation() {
        var campaign = IntegratedPlantCampaignCatalog.sevenDayPackagingCampaign()
        campaign.advanceShift(handoffNotes:["PE203 intermittent","VFD temp rising","Spare bearing reserved","Network event at 14:05"],fidelityPercent:50)
        XCTAssertEqual(campaign.currentShift,.evening)
        XCTAssertEqual(campaign.handoffs.last?.receivedNotes.count,2)
        XCTAssertEqual(campaign.handoffs.last?.fidelityPercent,50)
    }

    func testCampaignRoundTripsWithEvidenceAndProgression() throws {
        var campaign = IntegratedPlantCampaignCatalog.sevenDayPackagingCampaign()
        campaign.historian.append(.init(timeSeconds:1,values:["PV":42],states:["Run":true]))
        campaign.flightRecorder.append(.init(timeSeconds:1,trigger:"Alarm",detail:"test"))
        let data = try JSONEncoder().encode(campaign)
        let copy = try JSONDecoder().decode(PersistentPlantCampaign.self,from:data)
        XCTAssertEqual(copy,campaign)
    }
}

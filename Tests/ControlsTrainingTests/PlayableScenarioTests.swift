import Testing
import ControlsPLC
import ControlsSimulation
@testable import ControlsTraining

@Test func packagingRuntimeMovesProductAndFeedsPhysicalPhotoeyeIntoPLC() throws {
    let machine = HeroMachineCatalog.machine(.packagingCell)!
    let fault = machine.faults.first { $0.id == "pe203-sticky" }!
    let session = HeroMachineCatalog.start(machine: .packagingCell, faultID: fault.id, mode: .technician)!
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine()
    try engine.run(seconds: 8)
    #expect((engine.runtime.snapshot.analog["ConveyorPosition"] ?? 0) > 0)
    #expect(engine.runtime.eventHistory.contains { $0.name == "PE203 blocked" })
    #expect(engine.runtime.controller.project.controllerTags.contains("PE203"))
}

@Test func packagingStickyFaultCreatesRealDelayedReleaseEventsAtLateProgression() throws {
    let session = HeroMachineCatalog.start(machine: .packagingCell, faultID: "pe203-sticky", mode: .technician)!
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.advance(days: 42)
    try engine.startMachine()
    try engine.run(seconds: 10)
    #expect(engine.session.currentProgression.severity == 1)
    #expect(engine.runtime.eventHistory.contains { $0.name == "PE203 release delayed" })
}

@Test func pressureSkidHealthyRuntimeBuildsPressureFromLiveControllerRunState() throws {
    let session = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician)!
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine()
    try engine.run(seconds: 8)
    let pv = engine.runtime.snapshot.analog["PressurePV"] ?? 0
    let cmd = engine.runtime.snapshot.analog["ValveCmd"] ?? 0
    #expect(pv > 20)
    #expect(cmd > 0)
    #expect(try engine.runtime.controller.project.controllerTags.real("PressurePV") > 20)
}

@Test func pressureValveStictionProducesObservedStickAndBreakawayEvidence() throws {
    let session = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician)!
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.advance(days: 63)
    try engine.startMachine()
    try engine.run(seconds: 10)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Valve breakaway" })
    #expect((engine.runtime.snapshot.analog["BreakawayCount"] ?? 0) > 0)
}

@Test func guidedToolDisclosureUnlocksAdvancedToolsProgressivelyWhileTechnicianModeExposesAll() throws {
    let guided = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .guided)!
    var guidedEngine = try #require(try PlayableScenarioEngine(session: guided))
    #expect(guidedEngine.toolAccess.isAvailable(.flightRecorder))
    #expect(!guidedEngine.toolAccess.isAvailable(.spectralAnalysis))
    for _ in 0..<4 { guidedEngine.revealNextGuidedStep() }
    #expect(guidedEngine.toolAccess.isAvailable(.spectralAnalysis))

    let tech = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician)!
    let techEngine = try #require(try PlayableScenarioEngine(session: tech))
    #expect(techEngine.toolAccess.isAvailable(.spectralAnalysis))
    #expect(techEngine.toolAccess.isAvailable(.causalTracing))
}

@Test func instructorDebriefRewardsEvidenceBeforeRepairAndVerification() throws {
    let session = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician)!
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.advance(days: 63)
    try engine.startMachine()
    try engine.run(seconds: 5)
    engine.record(.openedTrend, target: "ValveCmd vs ValvePosition", informationGain: 0.8)
    engine.record(.enteredMeasurement, target: "Valve stem", note: "Command changes while stem sticks", informationGain: 0.95)
    engine.proposeDiagnosis(session.fault.rootMechanism)
    engine.repair(.serviceValveOrPositioner)
    try engine.verify(seconds: 5)
    let debrief = engine.debrief()
    #expect(debrief.score.overall >= 80)
    #expect(debrief.score.verification == 100)
    #expect(debrief.strengths.contains { $0.contains("verification") })
}

@Test func wrongEarlyRepairIsPenalizedEvenIfLearnerEventuallyFindsCause() throws {
    let session = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician)!
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.record(.changedControllerSetting, target: "PID Kp", note: "Retuned before proving mechanism", interventionPenalty: 0.9, supportedByEvidence: false)
    engine.repair(.restoreProcessDeadTime)
    engine.record(.enteredMeasurement, target: "Valve stem", note: "Stick-release observed", informationGain: 0.95)
    engine.proposeDiagnosis(session.fault.rootMechanism)
    let score = engine.debrief().score
    #expect(score.observationDiscipline < 80)
    #expect(score.interventionDiscipline < 80)
}


@Test func servoResonanceFaultChangesLiveVibrationAndPositionEvidence() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .servoConveyor, faultID: "bearing-resonance", mode: .technician))
    session.advance(days: 84)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine(); try engine.run(seconds: 5)
    #expect((engine.runtime.snapshot.analog["Vibration"] ?? 0) > 0.1)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Resonance excursion" })
}

@Test func pumpCavitationFaultReducesSuctionAndCreatesBroadbandStyleEvents() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pumpStation, faultID: "cavitation", mode: .technician))
    session.advance(days: 90)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine(); try engine.run(seconds: 5)
    #expect((engine.runtime.snapshot.analog["SuctionPressure"] ?? 100) < 30)
    #expect((engine.runtime.snapshot.analog["Vibration"] ?? 0) > 0)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Cavitation burst" })
}

@Test func ahuInteractionProducesTwoFrequencyBeatEvidenceInLiveSignals() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .airHandlingUnit, faultID: "loop-interaction", mode: .technician))
    session.advance(days: 105)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine(); try engine.run(seconds: 12)
    #expect((engine.runtime.snapshot.analog["FanCmd"] ?? 0) > 0)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Loop beat envelope" })
}

@Test func batchAgitatorDragRaisesCurrentAndStretchesMixingPhysics() throws {
    var healthySession = try #require(HeroMachineCatalog.start(machine: .batchMixingTank, faultID: "agitator-drag", mode: .technician))
    var healthy = try #require(try PlayableScenarioEngine(session: healthySession))
    try healthy.startMachine(); try healthy.run(seconds: 55)
    let healthyCurrent = healthy.runtime.snapshot.analog["AgitatorCurrent"] ?? 0

    healthySession.advance(days: 63)
    var degraded = try #require(try PlayableScenarioEngine(session: healthySession))
    try degraded.startMachine(); try degraded.run(seconds: 55)
    #expect((healthy.runtime.snapshot.analog["BatchState"] ?? 0) == 30)
    #expect((degraded.runtime.snapshot.analog["BatchState"] ?? 0) == 20)
    try degraded.run(seconds: 15)
    #expect((degraded.runtime.snapshot.analog["AgitatorCurrent"] ?? 0) > healthyCurrent)
}

@Test func ovenPeriodicDisturbancePropagatesIntoAirflowAndThermalProcess() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .industrialOven, faultID: "burner-disturbance", mode: .technician))
    session.advance(days: 90)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine(); try engine.run(seconds: 5)
    #expect((engine.runtime.snapshot.analog["ZoneTempPV"] ?? 0) > 80)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Periodic airflow disturbance" })
}


@Test func allTwentyEightHeroMachinesHaveRunnableLivePhysics() throws {
    #expect(HeroMachineCatalog.all.count == 28)
    #expect(Set(HeroMachineCatalog.all.map(\.id)).count == 28)
    for machine in HeroMachineCatalog.all {
        let fault = try #require(machine.faults.first)
        var session = try #require(HeroMachineCatalog.start(machine: machine.id, faultID: fault.id, mode: .technician))
        session.advance(days: 63)
        var engine = try #require(try PlayableScenarioEngine(session: session))
        try engine.startMachine()
        try engine.run(seconds: 1)
        #expect(!engine.runtime.snapshot.analog.isEmpty || !engine.runtime.snapshot.discrete.isEmpty)
        #expect(engine.session.currentProgression.severity > 0)
    }
}

@Test func newFourteenMachinesProduceDistinctProcessEvidence() throws {
    let ids:[HeroMachineID] = [.bottlingLine,.cipSkid,.compressedAirPlant,.reverseOsmosisPlant,.dataCenterCooling,.parcelSortation,.automotivePaintBooth,.injectionMoldingCell,.crusherConveyor,.grainElevator,.htstPasteurizer,.bioreactor,.chilledWaterPlant,.batteryFormationLine]
    var signalSets = Set<String>()
    for id in ids {
        let machine = try #require(HeroMachineCatalog.machine(id)); let fault = try #require(machine.faults.first)
        var session = try #require(HeroMachineCatalog.start(machine:id,faultID:fault.id,mode:.technician)); session.advance(days:63)
        var engine = try #require(try PlayableScenarioEngine(session:session)); try engine.startMachine(); try engine.run(seconds:1)
        signalSets.insert(engine.runtime.snapshot.analog.keys.sorted().joined(separator:"|"))
    }
    #expect(signalSets.count == 14)
}

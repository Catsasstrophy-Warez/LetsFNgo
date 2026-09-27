import Testing
@testable import ControlsTraining
import ControlsSimulation

@Test func sameSeedProducesSameVariationAndDifferentSeedChangesConditions() {
    let template = InstructorScenarioTemplate(
        title: "Unknown pressure disturbance",
        machineID: .pressureSkid,
        faultID: "valve-stiction",
        onsetDayRange: 20...60,
        loadRange: 0.4...0.9,
        speedRange: 0.3...0.8,
        ambientRange: 0.2...0.9,
        noiseRange: 0.005...0.02
    )
    let a = template.instantiate(seed: 42)
    let b = template.instantiate(seed: 42)
    let c = template.instantiate(seed: 43)
    #expect(a == b)
    #expect(a != c)
}

@Test func unknownFaultExamHidesFaultIdentityButKeepsSymptom() throws {
    let template = InstructorScenarioTemplate(title: "Pressure Loop Exam 4", machineID: .pressureSkid, faultID: "valve-stiction", hideFaultIdentity: true)
    let machine = try #require(HeroMachineCatalog.machine(.pressureSkid))
    let fault = try #require(machine.faults.first(where: { $0.id == "valve-stiction" }))
    let envelope = ScenarioExamEnvelope(machine: machine, fault: fault, template: template)
    #expect(envelope.displayTitle == "Pressure Loop Exam 4")
    #expect(!envelope.displayTitle.lowercased().contains("stiction"))
    #expect(envelope.symptom == fault.symptom)
}

@Test func variationRoundTripsInTranscriptAndReplayPreservesEnvironment() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 21)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    let variation = ScenarioVariationProfile(seed: 777, load: 0.83, speed: 0.44, ambient: 0.71, faultOnsetDay: 35, severityScale: 1.12, sensorNoiseFraction: 0.01)
    engine.applyVariation(variation)
    try engine.startMachine()
    try engine.run(seconds: 0.25)
    let replay = try ScenarioReplayEngine.replay(engine.transcript)
    #expect(replay.engine.variation == variation)
    #expect(replay.engine.runtime.environment == engine.runtime.environment)
    #expect(replay.engine.runtime.sensorNoiseFraction == engine.runtime.sensorNoiseFraction)
    #expect(replay.engine.session.simulatedDay == engine.session.simulatedDay)
}

@Test func compoundFaultInjectionCanApplyTwoPhysicalMechanismsAtOnce() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    let variation = ScenarioVariationProfile(
        seed: 9, load: 0.75, speed: 0.5, ambient: 0.5, faultOnsetDay: 63,
        additionalFaults: [.init(kind: .pressureDeadTimeGrowth, severity: 0.8)]
    )
    engine.applyVariation(variation)
    #expect(engine.runtime.fault.severity(for: .pressureValveStiction) > 0)
    #expect(engine.runtime.fault.severity(for: .pressureDeadTimeGrowth) == 0.8)
}

@Test func seededSensorNoiseIsRepeatableAtRuntimeLevel() throws {
    let machine = try #require(HeroMachineCatalog.machine(.pressureSkid))
    let projectA = try machine.projectFactory()
    let projectB = try machine.projectFactory()
    var a = try PlayableScenarioRuntime(project: projectA, process: .pressure(.init()), environment: .init(load: 0.6), fault: .init())
    var b = try PlayableScenarioRuntime(project: projectB, process: .pressure(.init()), environment: .init(load: 0.6), fault: .init())
    a.configureSensorNoise(fraction: 0.015, seed: 1234)
    b.configureSensorNoise(fraction: 0.015, seed: 1234)
    _ = try a.step(milliseconds: 10)
    _ = try b.step(milliseconds: 10)
    #expect(a.snapshot.analog == b.snapshot.analog)
}

@Test func mysteryExamGenerationIsSeededAndHidesGroundTruthFromEnvelope() throws {
    let a = try InstructorExamGenerator.generate(machineID: .pressureSkid, seed: 2026)
    let b = try InstructorExamGenerator.generate(machineID: .pressureSkid, seed: 2026)
    #expect(a.groundTruthFaultID == b.groundTruthFaultID)
    #expect(a.variation == b.variation)
    #expect(a.envelope.displayTitle == "Unknown Pressure Control Skid Fault")
    #expect(!a.envelope.displayTitle.lowercased().contains(a.groundTruthFaultID.lowercased()))
}

@Test func generatedExamCanCreateRunnableEngineAtSeededOperatingCondition() throws {
    let exam = try InstructorExamGenerator.generate(machineID: .servoConveyor, seed: 88)
    var engine = try exam.makeEngine()
    try engine.startMachine()
    try engine.run(seconds: 0.2)
    #expect(engine.runtime.environment.load == exam.variation.load)
    #expect(engine.runtime.environment.speed == exam.variation.speed)
    #expect(engine.runtime.clock.elapsedSeconds > 0)
}

@Test func advancedCampaignExamUsesTechnicianModeAndCanIntroduceControlledVariation() throws {
    let mission = try #require(HeroTrainingCampaign.missions.first(where: { $0.tier == .predictiveDiagnostics }))
    let exam = try mission.exam(seed: 555)
    #expect(exam.template.mode == .technician)
    #expect(exam.variation.sensorNoiseFraction > 0)
    #expect(exam.envelope.faultIdentityHidden)
}

@Test func randomizedFaultOnsetShiftsProgressionInsteadOfJumpingScenarioClock() throws {
    let session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    var engine = try #require(try PlayableScenarioEngine(session: session))
    let variation = ScenarioVariationProfile(seed: 1, load: 0.6, speed: 0.5, ambient: 0.5, faultOnsetDay: 40)
    engine.applyVariation(variation)
    #expect(engine.session.simulatedDay == 0)
    #expect(engine.runtime.fault.severity(for: .pressureValveStiction) == 0)
    engine.advance(days: 39)
    #expect(engine.runtime.fault.severity(for: .pressureValveStiction) == 0)
    engine.advance(days: 1)
    #expect(engine.runtime.fault.severity(for: .pressureValveStiction) > 0)
}

@Test func sensorNoiseDoesNotCorruptSetpointsOrControllerCommandChannels() throws {
    let machine = try #require(HeroMachineCatalog.machine(.pressureSkid))
    let projectA = try machine.projectFactory()
    let projectB = try machine.projectFactory()
    var clean = try PlayableScenarioRuntime(project: projectA, process: .pressure(.init()), environment: .init(load: 0.6), fault: .init())
    var noisy = try PlayableScenarioRuntime(project: projectB, process: .pressure(.init()), environment: .init(load: 0.6), fault: .init())
    noisy.configureSensorNoise(fraction: 0.02, seed: 77)
    _ = try clean.step(milliseconds: 10)
    _ = try noisy.step(milliseconds: 10)
    #expect(clean.snapshot.analog["PressureSP"] == noisy.snapshot.analog["PressureSP"])
    #expect(clean.snapshot.analog["ValveCmd"] == noisy.snapshot.analog["ValveCmd"])
    #expect(clean.snapshot.analog["PIDIntegral"] == noisy.snapshot.analog["PIDIntegral"])
    #expect(clean.snapshot.analog["PressurePV"] != noisy.snapshot.analog["PressurePV"])
}

@Test func everyHeroMachineCanGenerateAndRunASeededMysteryExam() throws {
    for (index, machineID) in HeroMachineID.allCases.enumerated() {
        let exam = try InstructorExamGenerator.generate(machineID: machineID, seed: UInt64(1000 + index), mode: .technician)
        var engine = try exam.makeEngine()
        try engine.startMachine()
        try engine.run(seconds: 0.05)
        #expect(exam.envelope.faultIdentityHidden)
        #expect(engine.runtime.clock.elapsedSeconds > 0)
        #expect(engine.variation?.seed == UInt64(1000 + index))
    }
}

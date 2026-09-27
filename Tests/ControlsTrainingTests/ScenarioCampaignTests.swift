import Foundation
import Testing
@testable import ControlsTraining
@testable import ControlsSimulation

@Test func scenarioTranscriptReplayReproducesLearnerPathAndOutcome() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.startMachine()
    try engine.run(seconds: 2)
    engine.record(.openedFlightRecorder, target: "ValveCmd vs ValvePosition", informationGain: 0.8)
    engine.record(.enteredMeasurement, target: "Stem feedback", informationGain: 0.95)
    engine.proposeDiagnosis("valve stiction")
    engine.repair(.serviceValveOrPositioner)
    try engine.verify(seconds: 2)

    let replay = try ScenarioReplayEngine.replay(engine.transcript)
    #expect(replay.engine.session.simulatedDay == engine.session.simulatedDay)
    #expect(replay.engine.diagnosisCorrect == engine.diagnosisCorrect)
    #expect(replay.engine.repairVerified == engine.repairVerified)
    #expect(replay.engine.actions.records.map(\.kind) == engine.actions.records.map(\.kind))
    #expect(replay.debrief.score == engine.debrief().score)
    #expect(abs(replay.engine.runtime.clock.elapsedSeconds - engine.runtime.clock.elapsedSeconds) < 0.001)
}

@Test func campaignBeginsWithFoundationsOnly() {
    let profile = TechnicianCompetencyProfile()
    let unlocked = HeroTrainingCampaign.unlockedMissions(for: profile)
    #expect(!unlocked.isEmpty)
    #expect(unlocked.allSatisfy { $0.tier == .foundations })
    #expect(HeroTrainingCampaign.nextRecommendedMission(for: profile)?.tier == .foundations)
}

private func passingAttempt(for mission: CampaignMission, overall: Int = 95) -> ScenarioAttemptSummary {
    let score = ScenarioScore(
        observationDiscipline: overall,
        measurementStrategy: overall,
        evidenceQuality: overall,
        causalReasoning: overall,
        safety: overall,
        interventionDiscipline: overall,
        verification: overall
    )
    return ScenarioAttemptSummary(machineID: mission.machineID, faultID: mission.faultID, mode: mission.recommendedMode, score: score, diagnosisCorrect: true, repairVerified: true, actionCount: 8)
}

@Test func passingFoundationMissionsUnlocksProcessControlsTier() {
    var profile = TechnicianCompetencyProfile()
    let foundation = HeroTrainingCampaign.missions.filter { $0.tier == .foundations }
    for mission in foundation { profile.record(passingAttempt(for: mission)) }
    let unlocked = HeroTrainingCampaign.unlockedMissions(for: profile)
    #expect(unlocked.contains { $0.tier == .processControls })
    #expect(!unlocked.contains { $0.tier == .predictiveDiagnostics })
}

@Test func campaignDoesNotUnlockNextTierFromOverallScoreAloneWhenRequiredDimensionIsWeak() {
    var profile = TechnicianCompetencyProfile()
    for mission in HeroTrainingCampaign.missions.filter({ $0.tier == .foundations }) {
        var score = ScenarioScore(observationDiscipline: 95, measurementStrategy: 95, evidenceQuality: 95, causalReasoning: 95, safety: 95, interventionDiscipline: 95, verification: 95)
        if mission.requiredDimensions.contains(where: { $0.dimension == .causal }) { score.causalReasoning = 40 }
        profile.record(.init(machineID: mission.machineID, faultID: mission.faultID, mode: mission.recommendedMode, score: score, diagnosisCorrect: true, repairVerified: true, actionCount: 5))
    }
    #expect(!HeroTrainingCampaign.unlockedMissions(for: profile).contains { $0.tier == .processControls })
}

@Test func campaignRecommendationTargetsWeakestDemonstratedDimension() {
    var profile = TechnicianCompetencyProfile()
    let weakScore = ScenarioScore(observationDiscipline: 90, measurementStrategy: 55, evidenceQuality: 88, causalReasoning: 90, safety: 100, interventionDiscipline: 95, verification: 90)
    profile.record(.init(machineID: .packagingCell, faultID: "pe203-sticky", mode: .guided, score: weakScore, diagnosisCorrect: true, repairVerified: true, actionCount: 9))
    #expect(profile.weakestDimension == .measurement)
    let next = HeroTrainingCampaign.nextRecommendedMission(for: profile)
    #expect(next?.requiredDimensions.contains(where: { $0.dimension == .measurement }) == true)
}

@Test func expertPerformanceBandRequiresStrongReasoningAndVerificationNotJustAverage() {
    let score = ScenarioScore(observationDiscipline: 100, measurementStrategy: 100, evidenceQuality: 95, causalReasoning: 70, safety: 100, interventionDiscipline: 100, verification: 100)
    let attempt = ScenarioAttemptSummary(machineID: .industrialOven, faultID: "burner-disturbance", mode: .technician, score: score, diagnosisCorrect: true, repairVerified: true, actionCount: 7)
    #expect(attempt.score.overall >= 92)
    #expect(attempt.performanceBand != .expert)
}

private func correctRepair(for faultID: String) -> ScenarioRepairAction {
    switch faultID {
    case "pe203-sticky": .cleanOrAlignPhotoeye
    case "short-pulse": .improvePulseCapture
    case "valve-stiction": .serviceValveOrPositioner
    case "dead-time-growth": .restoreProcessDeadTime
    case "bearing-resonance": .serviceBearingOrDriveTrain
    case "cavitation": .restoreSuctionConditions
    case "loop-interaction": .decoupleOrRetuneInteractingLoops
    case "agitator-drag": .serviceAgitatorDrive
    case "burner-disturbance": .repairBurnerOrAirflowSystem
    default: .replaceOrServicePhotoeye
    }
}

@Test func everyCampaignMissionCanRunThroughDiagnosisRepairAndVerification() throws {
    for mission in HeroTrainingCampaign.missions {
        var session = try #require(HeroMachineCatalog.start(machine: mission.machineID, faultID: mission.faultID, mode: mission.recommendedMode))
        let fault = session.fault
        session.advance(days: fault.progression.last?.day ?? 0)
        var engine = try #require(try PlayableScenarioEngine(session: session))
        try engine.startMachine()
        engine.record(.openedFlightRecorder, target: "fault evidence", informationGain: 0.85)
        engine.record(.enteredMeasurement, target: fault.technicianChecks.first ?? "measurement", informationGain: 1.0)
        engine.proposeDiagnosis(fault.rootMechanism)
        engine.repair(correctRepair(for: fault.id))
        try engine.verify(seconds: 0.2)
        let summary = ScenarioAttemptSummary(engine: engine)
        #expect(summary.diagnosisCorrect)
        #expect(summary.repairVerified)
        #expect(summary.score.overall >= mission.minimumOverallScore)
    }
}

@Test func wrongRepairCarriesExplicitDowntimeAndPartsConsequencesIntoDebrief() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.repair(.replaceOrServicePhotoeye)
    let debrief = engine.debrief()
    #expect(debrief.resourceImpact.unnecessaryInterventions == 1)
    #expect(debrief.resourceImpact.downtimeMinutes >= 45)
    #expect(debrief.resourceImpact.partsCostCredits > 0)
    #expect(debrief.missedOpportunities.contains { $0.contains("Unnecessary interventions") })
}

@Test func debriefReportsEarliestDetectableDegradationStage() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.record(.openedFlightRecorder, target: "ValveCmd vs ValvePosition", informationGain: 0.9)
    let debrief = engine.debrief()
    #expect(debrief.earliestDetectableEvidence.contains("Day 21"))
    #expect(debrief.earliestDetectableEvidence.contains("Friction rising"))
}

@Test func transcriptRoundTripsThroughJSONWithoutLosingInitialDayOrCommands() throws {
    var transcript = ScenarioTranscript(machineID: .pressureSkid, faultID: "valve-stiction", mode: .technician, initialSimulatedDay: 63)
    transcript.append(.startMachine)
    transcript.append(.run(seconds: 1.25, stepMilliseconds: 10))
    transcript.append(.learnerAction(kind: .openedFlightRecorder, target: "ValveCmd vs ValvePosition", note: "compare", informationGain: 0.9, safetyPenalty: 0, interventionPenalty: 0, supportedByEvidence: true))
    transcript.append(.repair(.serviceValveOrPositioner))
    let data = try JSONEncoder().encode(transcript)
    let decoded = try JSONDecoder().decode(ScenarioTranscript.self, from: data)
    #expect(decoded == transcript)
    #expect(decoded.initialSimulatedDay == 63)
}

@Test func missionCannotPassWithHighScoresIfDiagnosisOrVerificationIsMissing() {
    let mission = HeroTrainingCampaign.missions[0]
    let score = ScenarioScore(observationDiscipline: 100, measurementStrategy: 100, evidenceQuality: 100, causalReasoning: 100, safety: 100, interventionDiscipline: 100, verification: 100)
    var profile = TechnicianCompetencyProfile()
    profile.record(.init(machineID: mission.machineID, faultID: mission.faultID, mode: mission.recommendedMode, score: score, diagnosisCorrect: false, repairVerified: true, actionCount: 4))
    #expect(!profile.hasPassed(mission))
    profile.record(.init(machineID: mission.machineID, faultID: mission.faultID, mode: mission.recommendedMode, score: score, diagnosisCorrect: true, repairVerified: false, actionCount: 4))
    #expect(!profile.hasPassed(mission))
}

@Test func campaignReadinessDoesNotGrantIndependentTechnicianStatusFromGuidedScoresAlone() {
    var profile = TechnicianCompetencyProfile()
    for mission in HeroTrainingCampaign.missions.filter({ $0.tier.rawValue <= CampaignTier.predictiveDiagnostics.rawValue }) {
        let attempt = passingAttempt(for: mission)
        profile.record(.init(machineID: attempt.machineID, faultID: attempt.faultID, mode: .guided, score: attempt.score, diagnosisCorrect: true, repairVerified: true, actionCount: attempt.actionCount))
    }
    let readiness = HeroTrainingCampaign.readiness(for: profile)
    #expect(readiness.highestUnlockedTier == .integratedExpert)
    #expect(!readiness.independentTechnicianReady)
}

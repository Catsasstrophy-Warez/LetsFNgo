// Extracted from the Controls Tech Trainer's DebuggerPresentationTests: the subset that
// exercises only the headless reasoning types. The remaining trainer tests move
// with the code they cover as more of the UI target is extracted.

import Foundation
import Testing
@testable import ControlsReasoning
import ControlsPLC

@Test func traceExplainerCallsOutTagChange() {
    let change = TagChange(tag: "Motor_Run", oldValue: .bool(false), newValue: .bool(true))
    let trace = RungTrace(
        rungNumber: 0,
        incomingCondition: true,
        outgoingCondition: true,
        instructions: [InstructionTrace(mnemonic: "OTE", reference: "Motor_Run", incomingCondition: true, outgoingCondition: true, changes: [change])]
    )
    let step = ControllerDebugStep(taskName: "MainTask", programName: "Packaging", routineName: "MainRoutine", rungNumber: 0, callDepth: 1, trace: trace, nextRoutineName: nil, nextRungNumber: nil)
    let event = TraceExplainer.explain(step: step, scanNumber: 12)
    #expect(event.headline.contains("Motor_Run"))
    #expect(event.explanation.contains("changed from FALSE to TRUE"))
}

@Test func traceExplainerCallsOutBlockedPower() {
    let trace = RungTrace(
        rungNumber: 100,
        incomingCondition: true,
        outgoingCondition: false,
        instructions: [InstructionTrace(mnemonic: "XIO", reference: "PE203", incomingCondition: true, outgoingCondition: false, changes: [])]
    )
    let step = ControllerDebugStep(taskName: "MainTask", programName: "Packaging", routineName: "StateLogic", rungNumber: 100, callDepth: 2, trace: trace, nextRoutineName: "StateLogic", nextRungNumber: 110)
    let event = TraceExplainer.explain(step: step, scanNumber: 3)
    #expect(event.headline == "Power stopped at XIO PE203")
}

@Test func structuredTimerAndCounterMembersAreReadable() throws {
    let store = try TagStore(tags: [
        PLCTag(name: "T1", value: .timer(TimerValue(PRE: 1000, ACC: 750, EN: true, TT: true, DN: false))),
        PLCTag(name: "C1", value: .counter(CounterValue(PRE: 10, ACC: 7, CU: true, DN: false)))
    ])
    #expect(try store.bool("T1.TT") == true)
    #expect(try store.dint("T1.ACC") == 750)
    #expect(try store.dint("C1.ACC") == 7)
    #expect(try store.bool("C1.CU") == true)
}

@Test func reasonerExplainsXIOFromCapturedOperandEvidence() throws {
    let tags = try TagStore(tags: [PLCTag(name: "PE203", value: .bool(true))])
    var engine = PLCEngine(tags: tags)
    let trace = try engine.scan(LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.xio(tag: "PE203")))]))
    let answer = PowerReasoner.answer(question: .whyFalse, nodePath: "root", trace: trace.rungs[0])
    #expect(answer?.headline.contains("evaluated FALSE") == true)
    #expect(answer?.evidence.first?.detail.contains("TRUE") == true)
}

@Test func reasonerIdentifiesWhichParallelBranchCarriedPower() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "A", value: .bool(false)),
        PLCTag(name: "B", value: .bool(true))
    ])
    var engine = PLCEngine(tags: tags)
    let rung = Rung(number: 0, logic: .parallel([.instruction(.xic(tag: "A")), .instruction(.xic(tag: "B"))]))
    let trace = try engine.scan(LadderRoutine(rungs: [rung])).rungs[0]
    let answer = PowerReasoner.answer(question: .whyTrue, nodePath: "root", trace: trace)
    #expect(answer?.explanation.contains("At least one parallel branch") == true)
    #expect(answer?.evidence.contains(where: { $0.label == "Branch 2" && $0.supportsResult }) == true)
}

@Test func structuredTagExpanderProducesTimerAndCounterMemberRows() {
    let timer = StructuredTagExpander.members(name: "T1", value: .timer(TimerValue(PRE: 1000, ACC: 500, EN: true, TT: true, DN: false)))
    let counter = StructuredTagExpander.members(name: "C1", value: .counter(CounterValue(PRE: 5, ACC: 3, CU: true)))
    #expect(timer.contains(where: { $0.name == "T1.ACC" && $0.value == .dint(500) }))
    #expect(counter.contains(where: { $0.name == "C1.CU" && $0.value == .bool(true) }))
}

@Test func causalTimerDoneExplainsStillTimingWithoutInventingFault() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "Enable", value: .bool(true)),
        PLCTag(name: "T1", value: .timer(TimerValue(PRE: 1000)))
    ])
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(name: "MainRoutine", rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Enable")), .instruction(.ton(timer: "T1"))
    ]))])
    let trace = try engine.scan(routine, elapsedMilliseconds: 100)
    var journal = CausalJournal()
    journal.ingest(CausalExecutionRecord(scanNumber: 1, stepIndex: 1, taskName: "Task", programName: "Program", routineName: "MainRoutine", rungNumber: 0, trace: trace.rungs[0]))

    let trail = journal.explainWhy(target: "T1.DN", shouldBe: .bool(true), observedValue: .bool(false))
    #expect(trail.reachedRootCondition)
    #expect(trail.steps.last?.headline.contains("ACC") == true)
    #expect(trail.steps.last?.detail.contains("still timing") == true)
}

@Test func instructionTraceCarriesReadAndWriteProvenanceEvenWhenWriterIsBlocked() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "Permit", value: .bool(false)),
        PLCTag(name: "State", value: .dint(30))
    ])
    var engine = PLCEngine(tags: tags)
    let trace = try engine.scan(LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Permit")),
        .instruction(.mov(source: .dint(40), destination: "State"))
    ]))])).rungs[0]
    #expect(trace.instructions[0].readTags == ["Permit"])
    #expect(trace.instructions[1].writeTags == ["State"])
    #expect(trace.instructions[1].changes.isEmpty)
}

@Test func multiHypothesisDiagnosisClassifiesAllMotorPermissivesAndFindsUpstreamDoor() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "GuardDoor_Closed", value: .bool(false), role: .input),
        PLCTag(name: "Safety_OK", value: .bool(false)),
        PLCTag(name: "Auto_Mode", value: .bool(false), role: .input),
        PLCTag(name: "VFD_Ready", value: .bool(true), role: .input),
        PLCTag(name: "No_Fault", value: .bool(true), role: .input),
        PLCTag(name: "Motor_Run", value: .bool(false), role: .output)
    ])
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(name: "MotorLogic", rungs: [
        Rung(number: 0, logic: .series([
            .instruction(.xic(tag: "GuardDoor_Closed")),
            .instruction(.ote(tag: "Safety_OK"))
        ])),
        Rung(number: 10, logic: .series([
            .instruction(.xic(tag: "Safety_OK")),
            .instruction(.xic(tag: "Auto_Mode")),
            .instruction(.xic(tag: "VFD_Ready")),
            .instruction(.xic(tag: "No_Fault")),
            .instruction(.ote(tag: "Motor_Run"))
        ]))
    ])
    let scan = try engine.scan(routine)
    var journal = CausalJournal()
    for (index, trace) in scan.rungs.enumerated() {
        journal.ingest(CausalExecutionRecord(scanNumber: 1, stepIndex: index + 1, taskName: "Task", programName: "Program", routineName: "MotorLogic", rungNumber: trace.rungNumber, trace: trace))
    }

    let report = journal.diagnose(target: "Motor_Run", shouldBe: .bool(true), observedValue: .bool(false))
    let byTarget = Dictionary(uniqueKeysWithValues: report.hypotheses.map { ($0.target, $0.status) })
    #expect(byTarget["Safety_OK"] == .confirmedBlocker)
    #expect(byTarget["Auto_Mode"] == .contributingCondition)
    #expect(byTarget["VFD_Ready"] == .healthyEvidence)
    #expect(byTarget["No_Fault"] == .healthyEvidence)
    #expect(report.primaryRootTrail?.steps.last?.target == "GuardDoor_Closed")
    #expect(report.recommendedNextCheck?.contains("GuardDoor_Closed") == true)
}

@Test func falseParallelBranchIsNotMisreportedWhenAlternateBranchCarriesPower() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "Local_Start", value: .bool(false)),
        PLCTag(name: "Remote_Start", value: .bool(true)),
        PLCTag(name: "Safety_OK", value: .bool(false)),
        PLCTag(name: "Motor_Run", value: .bool(false))
    ])
    var engine = PLCEngine(tags: tags)
    let rung = Rung(number: 0, logic: .series([
        .parallel([
            .instruction(.xic(tag: "Local_Start")),
            .instruction(.xic(tag: "Remote_Start"))
        ]),
        .instruction(.xic(tag: "Safety_OK")),
        .instruction(.ote(tag: "Motor_Run"))
    ]))
    let trace = try engine.scan(LadderRoutine(rungs: [rung])).rungs[0]
    var journal = CausalJournal()
    journal.ingest(CausalExecutionRecord(scanNumber: 1, stepIndex: 1, taskName: "Task", programName: "Program", routineName: "MainRoutine", rungNumber: 0, trace: trace))
    let report = journal.diagnose(target: "Motor_Run", shouldBe: .bool(true), observedValue: .bool(false))
    #expect(report.hypotheses.contains(where: { $0.target == "Safety_OK" && $0.status == .confirmedBlocker }))
    #expect(!report.hypotheses.contains(where: { $0.target == "Local_Start" }))
    #expect(report.hypotheses.contains(where: { $0.target == "Remote_Start" && $0.status == .healthyEvidence }))
}

@Test func diagnosticStrategyPrefersSharedUpstreamMeasurementOverIndividualPermissives() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "24V_SafetyPower", value: .bool(false), role: .input),
        PLCTag(name: "GuardDoor_Closed", value: .bool(false)),
        PLCTag(name: "EStop_OK", value: .bool(false)),
        PLCTag(name: "LightCurtain_Clear", value: .bool(false)),
        PLCTag(name: "Motor_Run", value: .bool(false), role: .output)
    ])
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(name: "SafetyAndMotor", rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "24V_SafetyPower")), .instruction(.ote(tag: "GuardDoor_Closed"))])),
        Rung(number: 1, logic: .series([.instruction(.xic(tag: "24V_SafetyPower")), .instruction(.ote(tag: "EStop_OK"))])),
        Rung(number: 2, logic: .series([.instruction(.xic(tag: "24V_SafetyPower")), .instruction(.ote(tag: "LightCurtain_Clear"))])),
        Rung(number: 10, logic: .series([
            .instruction(.xic(tag: "GuardDoor_Closed")),
            .instruction(.xic(tag: "EStop_OK")),
            .instruction(.xic(tag: "LightCurtain_Clear")),
            .instruction(.ote(tag: "Motor_Run"))
        ]))
    ])
    let scan = try engine.scan(routine)
    var journal = CausalJournal()
    for (index, trace) in scan.rungs.enumerated() {
        journal.ingest(CausalExecutionRecord(scanNumber: 1, stepIndex: index + 1, taskName: "Task", programName: "Program", routineName: routine.name, rungNumber: trace.rungNumber, trace: trace))
    }

    let report = journal.diagnose(target: "Motor_Run", shouldBe: .bool(true), observedValue: .bool(false))
    let strategy = journal.selectDiagnosticStrategy(for: report)
    #expect(strategy.recommended?.target == "24V_SafetyPower")
    #expect(strategy.recommended?.coveredHypotheses.count == 3)
    #expect(strategy.summary.contains("24V_SafetyPower"))
}

@Test func diagnosticStrategyCanRejectHazardousHighInformationMeasurement() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "480V_LinePower", value: .bool(false), role: .input),
        PLCTag(name: "DriveA_Ready", value: .bool(false)),
        PLCTag(name: "DriveB_Ready", value: .bool(false)),
        PLCTag(name: "Motor_Run", value: .bool(false))
    ])
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(name: "Power", rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "480V_LinePower")), .instruction(.ote(tag: "DriveA_Ready"))])),
        Rung(number: 1, logic: .series([.instruction(.xic(tag: "480V_LinePower")), .instruction(.ote(tag: "DriveB_Ready"))])),
        Rung(number: 10, logic: .series([.instruction(.xic(tag: "DriveA_Ready")), .instruction(.xic(tag: "DriveB_Ready")), .instruction(.ote(tag: "Motor_Run"))]))
    ])
    let scan = try engine.scan(routine)
    var journal = CausalJournal()
    for (index, trace) in scan.rungs.enumerated() {
        journal.ingest(CausalExecutionRecord(scanNumber: 1, stepIndex: index + 1, taskName: "Task", programName: "Program", routineName: routine.name, rungNumber: trace.rungNumber, trace: trace))
    }
    let report = journal.diagnose(target: "Motor_Run", shouldBe: .bool(true), observedValue: .bool(false))
    let strategy = journal.selectDiagnosticStrategy(
        for: report,
        profiles: [MeasurementProfile(target: "480V_LinePower", effort: 0.5, estimatedSeconds: 5, safety: .hazardous, access: .panel)]
    )
    let line = strategy.candidates.first { $0.target == "480V_LinePower" }
    #expect(line?.eligible == false)
    #expect(strategy.recommended?.target != "480V_LinePower")
}

@Test func diagnosticStrategyMetadataCanPreferSafeLowEffortEquivalentCheck() throws {
    let hypotheses = [
        DiagnosticHypothesis(target: "A", instruction: "XIC A", status: .unknownUnobserved, detail: "unknown"),
        DiagnosticHypothesis(target: "B", instruction: "XIC B", status: .unknownUnobserved, detail: "unknown")
    ]
    let report = MultiHypothesisReport(target: "Motor", desiredValue: .bool(true), observedValue: .bool(false), hypotheses: hypotheses, primaryRootTrail: nil, recommendedNextCheck: nil, summary: "test")
    let journal = CausalJournal()
    let strategy = journal.selectDiagnosticStrategy(
        for: report,
        profiles: [
            MeasurementProfile(target: "A", effort: 0.5, estimatedSeconds: 5, safety: .low, access: .immediate),
            MeasurementProfile(target: "B", effort: 4, estimatedSeconds: 90, safety: .elevated, access: .guarded, invasive: true)
        ]
    )
    #expect(strategy.recommended?.target == "A")
}

private func makeAdaptiveSafetySession() throws -> AdaptiveTroubleshootingSession {
    let tags = try TagStore(tags: [
        PLCTag(name: "24V_SafetyPower", value: .bool(false), role: .input),
        PLCTag(name: "GuardDoor_Closed", value: .bool(false)),
        PLCTag(name: "EStop_OK", value: .bool(false)),
        PLCTag(name: "LightCurtain_Clear", value: .bool(false)),
        PLCTag(name: "Motor_Run", value: .bool(false), role: .output)
    ])
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(name: "SafetyAndMotor", rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "24V_SafetyPower")), .instruction(.ote(tag: "GuardDoor_Closed"))])),
        Rung(number: 1, logic: .series([.instruction(.xic(tag: "24V_SafetyPower")), .instruction(.ote(tag: "EStop_OK"))])),
        Rung(number: 2, logic: .series([.instruction(.xic(tag: "24V_SafetyPower")), .instruction(.ote(tag: "LightCurtain_Clear"))])),
        Rung(number: 10, logic: .series([
            .instruction(.xic(tag: "GuardDoor_Closed")),
            .instruction(.xic(tag: "EStop_OK")),
            .instruction(.xic(tag: "LightCurtain_Clear")),
            .instruction(.ote(tag: "Motor_Run"))
        ]))
    ])
    let scan = try engine.scan(routine)
    var journal = CausalJournal()
    for (index, trace) in scan.rungs.enumerated() {
        journal.ingest(CausalExecutionRecord(scanNumber: 1, stepIndex: index + 1, taskName: "Task", programName: "Program", routineName: routine.name, rungNumber: trace.rungNumber, trace: trace))
    }
    let report = journal.diagnose(target: "Motor_Run", shouldBe: .bool(true), observedValue: .bool(false))
    return AdaptiveTroubleshootingSession(
        report: report,
        journal: journal,
        topology: DiagnosticTopology(dependencies: [
            DiagnosticDependency(upstream: "SafetyRelay_A1", downstream: "24V_SafetyPower", description: "Safety relay output feeds the safety-power bus."),
            DiagnosticDependency(upstream: "Fuse_F1_Output", downstream: "SafetyRelay_A1", description: "Fuse F1 supplies the safety relay."),
            DiagnosticDependency(upstream: "PSU_24V", downstream: "Fuse_F1_Output", description: "24 VDC power supply feeds F1.")
        ])
    )
}

@Test func adaptiveDialogueHealthySharedSourcePrunesItAndRecalculatesNextCheck() throws {
    var session = try makeAdaptiveSafetySession()
    let initial = session.currentState()
    #expect(initial.strategy.recommended?.target == "24V_SafetyPower")

    let updated = session.recordMeasurement(target: "24V_SafetyPower", value: .bool(true))
    #expect(updated.candidates.first(where: { $0.target == "24V_SafetyPower" })?.status == .eliminated)
    #expect(updated.confirmedCause == nil)
    #expect(updated.strategy.recommended?.target != "24V_SafetyPower")
    #expect(["GuardDoor_Closed", "EStop_OK", "LightCurtain_Clear"].contains(updated.strategy.recommended?.target ?? ""))
    #expect(updated.observations.count == 1)
}

@Test func adaptiveDialogueFailedSharedSourceCollapsesDownstreamHuntAndMovesUpstream() throws {
    var session = try makeAdaptiveSafetySession()
    let updated = session.recordMeasurement(target: "24V_SafetyPower", value: .bool(false))
    #expect(updated.confirmedCause?.target == "24V_SafetyPower")
    #expect(updated.strategy.recommended?.target == "SafetyRelay_A1")
    #expect(updated.candidates.first(where: { $0.target == "GuardDoor_Closed" })?.status == .superseded)
    #expect(updated.summary.contains("Move upstream"))
}

@Test func adaptiveDialogueContinuesUpstreamAfterEachAbnormalMeasurement() throws {
    var session = try makeAdaptiveSafetySession()
    _ = session.recordMeasurement(target: "24V_SafetyPower", value: .bool(false))
    let second = session.recordMeasurement(target: "SafetyRelay_A1", value: .bool(false))
    #expect(second.confirmedCause?.target == "SafetyRelay_A1")
    #expect(second.strategy.recommended?.target == "Fuse_F1_Output")
    #expect(second.observations.map(\.target) == ["24V_SafetyPower", "SafetyRelay_A1"])
}

@Test func lowConfidenceMeasurementDoesNotHardPruneDiagnosticBranch() throws {
    var session = try makeAdaptiveSafetySession()
    let state = session.recordMeasurement(target: "24V_SafetyPower", value: .bool(true), confidence: .low, condition: .unloaded)
    let power = state.candidates.first { $0.target == "24V_SafetyPower" }
    #expect(power?.status == .unresolved)
    #expect(state.evidenceSummary.lowConfidenceMeasurements == 1)
    #expect(power?.rationale.contains("verify") == true)
}

@Test func contradictoryHighConfidenceEvidencePrioritizesBoundaryVerification() throws {
    var session = try makeAdaptiveSafetySession()
    session.topology = DiagnosticTopology(dependencies: [
        DiagnosticDependency(
            upstream: "SafetyRelay_A1",
            downstream: "24V_SafetyPower",
            verificationTarget: "Fuse_F1_BothSides_Loaded",
            verificationInstruction: "Measure voltage on both sides of Fuse F1 under load.",
            description: "The safety relay output should feed the safety-power bus through F1."
        )
    ])
    _ = session.recordMeasurement(target: "24V_SafetyPower", value: .bool(false), confidence: .high, condition: .underLoad)
    let state = session.recordMeasurement(target: "SafetyRelay_A1", value: .bool(true), confidence: .verified, condition: .underLoad)
    #expect(state.contradictions.count == 1)
    #expect(state.contradictions.first?.severity == .strong)
    #expect(state.strategy.recommended?.target == "Fuse_F1_BothSides_Loaded")
    #expect(state.strategy.summary.contains("contradictory evidence"))
}

@Test func unloadedContradictionIsTreatedAsMeasurementQualityProblemNotCertainFault() throws {
    var session = try makeAdaptiveSafetySession()
    session.topology = DiagnosticTopology(dependencies: [
        DiagnosticDependency(
            upstream: "SafetyRelay_A1",
            downstream: "24V_SafetyPower",
            verificationTarget: "F1_LoadedVoltage",
            verificationInstruction: "Repeat the voltage check across F1 with the circuit under load."
        )
    ])
    _ = session.recordMeasurement(target: "24V_SafetyPower", value: .bool(false), confidence: .high, condition: .underLoad)
    let state = session.recordMeasurement(target: "SafetyRelay_A1", value: .bool(true), confidence: .high, condition: .unloaded)
    #expect(state.contradictions.first?.severity == .meaningful)
    #expect(state.strategy.recommended?.target == "F1_LoadedVoltage")
    #expect(state.contradictions.first?.resolutionInstruction.contains("under load") == true)
}

@Test func assumptionsAreTrackedSeparatelyFromMeasurements() throws {
    var session = try makeAdaptiveSafetySession()
    let state = session.recordEvidence(target: "GuardDoor_Closed", value: .bool(true), kind: .assumption, confidence: .medium, note: "Operator says the door is closed.")
    #expect(state.evidenceSummary.assumptions == 1)
    #expect(state.evidenceSummary.measurements == 0)
    #expect(state.candidates.first(where: { $0.target == "GuardDoor_Closed" })?.status == .unresolved)
}

@Test func temporalAnalyzerRecognizesPhotoeyeFlickerAndCorrelatesMotorFault() throws {
    let observation = TemporalObservation(target: "PE203", samples: [
        TimedEvidenceSample(milliseconds: 0, value: .bool(true)),
        TimedEvidenceSample(milliseconds: 100, value: .bool(false)),
        TimedEvidenceSample(milliseconds: 180, value: .bool(true))
    ])
    let fault = TemporalEventMarker(name: "Motor fault", milliseconds: 137)
    let pattern = TemporalEvidenceAnalyzer.analyze(observation, relativeTo: [fault])
    #expect(pattern.kind == .transientPulse)
    #expect(pattern.transitionCount == 2)
    #expect(pattern.shortestStateDurationMilliseconds == 80)
    #expect(pattern.eventLagMilliseconds == 37)
    #expect(pattern.eventName == "Motor fault")
}

@Test func temporalAnalyzerRecognizesRapidChatterAndRecommendsDebounceInspection() throws {
    let observation = TemporalObservation(target: "GuardDoor_Switch", samples: [
        TimedEvidenceSample(milliseconds: 0, value: .bool(true)),
        TimedEvidenceSample(milliseconds: 10, value: .bool(false)),
        TimedEvidenceSample(milliseconds: 20, value: .bool(true)),
        TimedEvidenceSample(milliseconds: 28, value: .bool(false)),
        TimedEvidenceSample(milliseconds: 39, value: .bool(true)),
        TimedEvidenceSample(milliseconds: 60, value: .bool(false))
    ])
    let pattern = TemporalEvidenceAnalyzer.analyze(observation)
    let recommendation = TemporalEvidenceAnalyzer.recommendCapture(for: pattern, scanPeriodMilliseconds: 10)
    #expect(pattern.kind == .chatter)
    #expect(recommendation.mode == .debounceInspection)
    #expect(recommendation.samplePeriodMilliseconds == 1)
    #expect(recommendation.rationale.contains("input filtering"))
}

@Test func nearScanTimingCorrelationRecommendsScanTraceInsteadOfBlamingSensor() throws {
    let observation = TemporalObservation(target: "PE203", samples: [
        TimedEvidenceSample(milliseconds: 0, value: .bool(true)),
        TimedEvidenceSample(milliseconds: 100, value: .bool(false)),
        TimedEvidenceSample(milliseconds: 180, value: .bool(true))
    ])
    let fault = TemporalEventMarker(name: "Motor fault", milliseconds: 137)
    let pattern = TemporalEvidenceAnalyzer.analyze(observation, relativeTo: [fault])
    let recommendation = TemporalEvidenceAnalyzer.timingRaceRecommendation(signalPattern: pattern, event: fault, scanPeriodMilliseconds: 20)
    #expect(recommendation?.mode == .scanTrace)
    #expect(recommendation?.rationale.contains("scan order") == true)
    #expect(recommendation?.rationale.contains("37 ms") == true)
}

@Test func adaptiveSessionPromotesTemporalEvidenceIntoNextCaptureStrategy() throws {
    var session = try makeAdaptiveSafetySession()
    session.controllerScanPeriodMilliseconds = 20
    _ = session.recordEventMarker(TemporalEventMarker(name: "Motor fault", milliseconds: 137))
    let state = session.recordTemporalObservation(TemporalObservation(target: "PE203", samples: [
        TimedEvidenceSample(milliseconds: 0, value: .bool(true)),
        TimedEvidenceSample(milliseconds: 100, value: .bool(false)),
        TimedEvidenceSample(milliseconds: 180, value: .bool(true))
    ]))
    #expect(state.temporalPatterns.first?.kind == .transientPulse)
    #expect(state.temporalRecommendation?.target == "PE203")
    #expect(state.temporalRecommendation?.mode == .scanTrace)
    #expect(state.summary.contains("scan trace"))
}

@Test func flightRecorderOrdersMultiSignalTransitionsAndSeparatesCausalityFromTiming() {
    var recorder = ControlsFlightRecorder()
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 120, value: .bool(false)),
        FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: 140, value: .bool(false)),
        FlightSignalSample(target: "TransferCmd", layer: .logic, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "TransferCmd", layer: .logic, milliseconds: 160, value: .bool(false))
    ])
    recorder.addCausalLink(FlightCausalLink(upstream: "PE203", downstream: "TransferDelay.DN"))
    recorder.addCausalLink(FlightCausalLink(upstream: "TransferDelay.DN", downstream: "TransferCmd"))

    let report = recorder.report(targets: ["PE203", "TransferDelay.DN", "TransferCmd"])
    #expect(report.firstChangedTarget == "PE203")
    #expect(report.firstChangeMilliseconds == 120)
    #expect(report.orderedTransitions.map(\.target) == ["PE203", "TransferDelay.DN", "TransferCmd"])
    let relationship = recorder.relationship(from: "PE203", to: "TransferDelay.DN")
    #expect(relationship?.kind == .recordedConsequence)
    #expect(relationship?.lagMilliseconds == 20)
}

@Test func flightRecorderCanProveAnEightyMillisecondFieldPulseWasMissedByPLC() {
    var recorder = ControlsFlightRecorder()
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 110, value: .bool(false)),
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 190, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 100, value: .bool(true), scanNumber: 10),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 200, value: .bool(true), scanNumber: 11)
    ])

    let result = recorder.plcVisibility(ofFieldPulse: "PE203")
    #expect(result.status == .missedBetweenExecutions)
    #expect(result.pulseStartMilliseconds == 110)
    #expect(result.pulseEndMilliseconds == 190)
}

@Test func flightRecorderCanProvePulseWasSeenByPLC() {
    var recorder = ControlsFlightRecorder()
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 110, value: .bool(false)),
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 190, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 100, value: .bool(true), scanNumber: 10),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 150, value: .bool(false), scanNumber: 11),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 200, value: .bool(true), scanNumber: 12)
    ])

    #expect(recorder.plcVisibility(ofFieldPulse: "PE203").status == .observed)
}

@Test func flightRecorderDetectsInputTransitionBetweenTaskExecutions() {
    var recorder = ControlsFlightRecorder()
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 137, value: .bool(false))
    ])
    recorder.record(taskExecution: TaskExecutionStamp(taskName: "MainTask", milliseconds: 120, scanNumber: 6))
    recorder.record(taskExecution: TaskExecutionStamp(taskName: "MainTask", milliseconds: 140, scanNumber: 7))

    let result = recorder.changedBetweenTaskExecutions(target: "PE203", taskName: "MainTask")
    #expect(result.changedBetweenExecutions == true)
    #expect(result.previousExecutionMilliseconds == 120)
    #expect(result.nextExecutionMilliseconds == 140)
    #expect(result.transitionMilliseconds == 137)
}

@Test func flightRecorderRequiresExplicitEvidenceBeforeCallingTimingCoincidental() {
    var recorder = ControlsFlightRecorder()
    recorder.record(samples: [
        FlightSignalSample(target: "CabinetFan", layer: .logic, milliseconds: 100, value: .bool(false)),
        FlightSignalSample(target: "CabinetFan", layer: .logic, milliseconds: 120, value: .bool(true)),
        FlightSignalSample(target: "MotorFault", layer: .logic, milliseconds: 100, value: .bool(false)),
        FlightSignalSample(target: "MotorFault", layer: .logic, milliseconds: 125, value: .bool(true))
    ])
    #expect(recorder.relationship(from: "CabinetFan", to: "MotorFault")?.kind == .precedes)
    recorder.markCoincidental(FlightNonCausalAssertion(first: "CabinetFan", second: "MotorFault", rationale: "Independent circuit verified during the lesson."))
    #expect(recorder.relationship(from: "CabinetFan", to: "MotorFault")?.kind == .coincidental)
}

@Test func flightRecorderBuildsRecordedConsequenceChain() {
    var recorder = ControlsFlightRecorder()
    recorder.addCausalLink(FlightCausalLink(upstream: "PE203", downstream: "TransferDelay.DN"))
    recorder.addCausalLink(FlightCausalLink(upstream: "TransferDelay.DN", downstream: "State"))
    recorder.addCausalLink(FlightCausalLink(upstream: "State", downstream: "TransferCmd"))
    #expect(recorder.consequenceChain(startingAt: "PE203") == ["PE203", "TransferDelay.DN", "State", "TransferCmd"])
}

@Test func flightRecorderSynchronizesSignalTaskAndFaultMarkerOnOneTimeline() {
    var recorder = ControlsFlightRecorder()
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 100, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .field, milliseconds: 120, value: .bool(false))
    ])
    recorder.record(taskExecution: TaskExecutionStamp(taskName: "MainTask", milliseconds: 110, scanNumber: 10))
    recorder.record(event: TemporalEventMarker(name: "Motor fault", milliseconds: 137))
    let timeline = recorder.report().timeline
    #expect(timeline.map(\.kind) == [.taskExecution, .signalTransition, .eventMarker])
    #expect(timeline.map(\.milliseconds) == [110, 120, 137])
}

@Test func circularBufferRetainsOnlyConfiguredPreTriggerHistoryAndFreezesPostFaultTail() {
    var recorder = ControlsFlightRecorder()
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 5_000, postTriggerMilliseconds: 2_000, trigger: .eventNamed("Motor fault")))

    recorder.record(FlightSignalSample(target: "PE203", layer: .field, milliseconds: 1_000, value: .bool(true)))
    recorder.record(FlightSignalSample(target: "PE203", layer: .field, milliseconds: 6_000, value: .bool(false)))
    recorder.record(FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 9_000, value: .bool(true)))
    recorder.record(event: TemporalEventMarker(name: "Motor fault", milliseconds: 10_000))
    #expect(recorder.captureState == .triggered)
    #expect(recorder.signalSamples.contains(where: { $0.milliseconds == 1_000 }) == false)
    #expect(recorder.signalSamples.contains(where: { $0.milliseconds == 6_000 }) == true)

    recorder.record(FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 11_000, value: .bool(false)))
    recorder.record(taskExecution: TaskExecutionStamp(taskName: "MainTask", milliseconds: 12_000, scanNumber: 50))

    #expect(recorder.captureState == .frozen)
    #expect(recorder.frozenCapture?.windowStartMilliseconds == 5_000)
    #expect(recorder.frozenCapture?.triggerMilliseconds == 10_000)
    #expect(recorder.frozenCapture?.windowEndMilliseconds == 12_000)
    #expect(recorder.frozenCapture?.signalSamples.map(\.milliseconds) == [6_000, 9_000, 11_000])

    recorder.record(FlightSignalSample(target: "AfterFreeze", layer: .logic, milliseconds: 13_000, value: .bool(true)))
    #expect(recorder.signalSamples.contains(where: { $0.target == "AfterFreeze" }) == false)
}

@Test func circularBufferCanTriggerOnSignalStateAndPreserveVisibleZeroPoint() {
    var recorder = ControlsFlightRecorder()
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 1_000, postTriggerMilliseconds: 500, trigger: .signalEquals(target: "MotorFault", layer: .logic, value: .bool(true))))
    recorder.record(FlightSignalSample(target: "MotorFault", layer: .logic, milliseconds: 1_000, value: .bool(false)))
    recorder.record(FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 1_500, value: .bool(false)))
    recorder.record(FlightSignalSample(target: "MotorFault", layer: .logic, milliseconds: 2_000, value: .bool(true)))
    #expect(recorder.captureState == .triggered)
    #expect(recorder.triggerMilliseconds == 2_000)
    #expect(recorder.events.contains(where: { $0.milliseconds == 2_000 && $0.note == "Flight-recorder trigger" }))
    recorder.record(FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 2_500, value: .bool(false)))
    #expect(recorder.captureState == .frozen)
}

@Test func circularBufferRearmClearsFrozenEvidenceButKeepsConfiguration() {
    var recorder = ControlsFlightRecorder()
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 100, postTriggerMilliseconds: 0, trigger: .manual(name: "Capture")))
    recorder.record(FlightSignalSample(target: "A", layer: .logic, milliseconds: 100, value: .bool(true)))
    recorder.triggerNow(milliseconds: 150)
    #expect(recorder.captureState == .frozen)
    #expect(recorder.frozenCapture != nil)

    recorder.rearm()
    #expect(recorder.captureState == .armed)
    #expect(recorder.frozenCapture == nil)
    #expect(recorder.signalSamples.isEmpty)
    #expect(recorder.captureConfiguration?.preTriggerMilliseconds == 100)
}

@Test func circularBufferTimelineMakesPreAndPostTriggerOffsetsExplicit() {
    var recorder = ControlsFlightRecorder()
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 5_000, postTriggerMilliseconds: 2_000, trigger: .eventNamed("Fault")))
    recorder.record(FlightSignalSample(target: "Safety_OK", layer: .logic, milliseconds: 9_950, value: .bool(true)))
    recorder.record(FlightSignalSample(target: "Safety_OK", layer: .logic, milliseconds: 9_980, value: .bool(false)))
    recorder.record(event: TemporalEventMarker(name: "Fault", milliseconds: 10_000))
    recorder.record(FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 12_000, value: .bool(false)))

    let capture = recorder.frozenCapture
    #expect(capture?.relativeMilliseconds(for: 9_980) == -20)
    #expect(capture?.relativeMilliseconds(for: 10_000) == 0)
    #expect(capture?.relativeMilliseconds(for: 12_000) == 2_000)
}

@Test func reconstructionFindsEarliestLateDeviationAgainstKnownGoodCycle() {
    var recorder = ControlsFlightRecorder()
    recorder.addCausalLink(FlightCausalLink(upstream: "PE203", downstream: "TransferDelay.DN"))
    recorder.addCausalLink(FlightCausalLink(upstream: "TransferDelay.DN", downstream: "TransferCmd"))
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 2_000, postTriggerMilliseconds: 0, trigger: .eventNamed("Motor fault")))

    // Fault cycle: PE203 clears 96 ms later than the healthy cycle.
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 8_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 9_596, value: .bool(false)),
        FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: 8_000, value: .bool(true)),
        FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: 9_650, value: .bool(false)),
        FlightSignalSample(target: "TransferCmd", layer: .controllerOutput, milliseconds: 8_000, value: .bool(true)),
        FlightSignalSample(target: "TransferCmd", layer: .controllerOutput, milliseconds: 9_700, value: .bool(false))
    ])
    recorder.record(event: TemporalEventMarker(name: "Motor fault", milliseconds: 10_000))

    let good = KnownGoodCycle(name: "Healthy packaging cycle", anchorMilliseconds: 10_000, signalSamples: [
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 8_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: 9_500, value: .bool(false)),
        FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: 8_000, value: .bool(true)),
        FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: 9_550, value: .bool(false)),
        FlightSignalSample(target: "TransferCmd", layer: .controllerOutput, milliseconds: 8_000, value: .bool(true)),
        FlightSignalSample(target: "TransferCmd", layer: .controllerOutput, milliseconds: 9_600, value: .bool(false))
    ])

    let report = recorder.reconstructPreFaultSequence(against: good, toleranceMilliseconds: 25)
    #expect(report?.earliestDeviation?.target == "PE203")
    #expect(report?.earliestDeviation?.timingDeltaMilliseconds == 96)
    #expect(report?.rootDeviation?.phase == .rootDeviation)
    #expect(report?.propagatingConsequences.map(\.target).contains("TransferDelay.DN") == true)
}

@Test func reconstructionSeparatesProtectiveResponseFromPropagatingConsequence() {
    var recorder = ControlsFlightRecorder()
    recorder.addCausalLink(FlightCausalLink(upstream: "PE203", downstream: "Motor_Run"))
    recorder.addCausalLink(FlightCausalLink(upstream: "Motor_Run", downstream: "SafetyShutdown"))
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 1_000, postTriggerMilliseconds: 0, trigger: .eventNamed("Fault")))
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_400, value: .bool(false)),
        FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 9_500, value: .bool(false)),
        FlightSignalSample(target: "SafetyShutdown", layer: .logic, milliseconds: 9_000, value: .bool(false)),
        FlightSignalSample(target: "SafetyShutdown", layer: .logic, milliseconds: 9_600, value: .bool(true))
    ])
    recorder.record(event: TemporalEventMarker(name: "Fault", milliseconds: 10_000))
    let good = KnownGoodCycle(anchorMilliseconds: 10_000, signalSamples: [
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_200, value: .bool(false)),
        FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "Motor_Run", layer: .controllerOutput, milliseconds: 9_300, value: .bool(false)),
        FlightSignalSample(target: "SafetyShutdown", layer: .logic, milliseconds: 9_000, value: .bool(false)),
        FlightSignalSample(target: "SafetyShutdown", layer: .logic, milliseconds: 9_400, value: .bool(true))
    ])
    let report = recorder.reconstructPreFaultSequence(against: good, toleranceMilliseconds: 25, protectiveTargets: ["SafetyShutdown"])
    #expect(report?.rootDeviation?.target == "PE203")
    #expect(report?.propagatingConsequences.contains(where: { $0.target == "Motor_Run" }) == true)
    #expect(report?.protectiveResponses.contains(where: { $0.target == "SafetyShutdown" }) == true)
}

@Test func reconstructionDoesNotInventCausationForUnlinkedTransition() {
    var recorder = ControlsFlightRecorder()
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 1_000, postTriggerMilliseconds: 0, trigger: .eventNamed("Fault")))
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_400, value: .bool(false)),
        FlightSignalSample(target: "CabinetFan", layer: .logic, milliseconds: 9_000, value: .bool(false)),
        FlightSignalSample(target: "CabinetFan", layer: .logic, milliseconds: 9_450, value: .bool(true))
    ])
    recorder.record(event: TemporalEventMarker(name: "Fault", milliseconds: 10_000))
    let good = KnownGoodCycle(anchorMilliseconds: 10_000, signalSamples: [
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_200, value: .bool(false)),
        FlightSignalSample(target: "CabinetFan", layer: .logic, milliseconds: 9_000, value: .bool(false)),
        FlightSignalSample(target: "CabinetFan", layer: .logic, milliseconds: 9_250, value: .bool(true))
    ])
    let report = recorder.reconstructPreFaultSequence(against: good, toleranceMilliseconds: 25)
    #expect(report?.rootDeviation?.target == "PE203")
    #expect(report?.propagatingConsequences.contains(where: { $0.target == "CabinetFan" }) == false)
}

@Test func reconstructionReportsNoDeviationInsideTolerance() {
    var recorder = ControlsFlightRecorder()
    recorder.arm(FlightCaptureConfiguration(preTriggerMilliseconds: 1_000, postTriggerMilliseconds: 0, trigger: .eventNamed("Fault")))
    recorder.record(samples: [
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_510, value: .bool(false))
    ])
    recorder.record(event: TemporalEventMarker(name: "Fault", milliseconds: 10_000))
    let good = KnownGoodCycle(anchorMilliseconds: 10_000, signalSamples: [
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .logic, milliseconds: 9_500, value: .bool(false))
    ])
    let report = recorder.reconstructPreFaultSequence(against: good, toleranceMilliseconds: 25)
    #expect(report?.earliestDeviation == nil)
    #expect(report?.steps.contains(where: { $0.phase == .fault }) == true)
}

private func healthyTimingCycle(index: Int, pe203Relative: Int64, timerRelative: Int64 = -448) -> KnownGoodCycle {
    let anchor = Int64(100_000 + index * 10_000)
    return KnownGoodCycle(
        name: "Healthy \(index + 1)",
        anchorMilliseconds: anchor,
        signalSamples: [
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor - 1_000, value: .bool(true)),
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor + pe203Relative, value: .bool(false)),
            FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: anchor - 1_000, value: .bool(false)),
            FlightSignalSample(target: "TransferDelay.DN", layer: .structuredMember, milliseconds: anchor + timerRelative, value: .bool(true))
        ]
    )
}

private func multivariateCycle(index: Int, peTiming: Int64, timerACC: Int32, motorCurrent: Double) -> KnownGoodCycle {
    let anchor = Int64(200_000 + index * 10_000)
    return KnownGoodCycle(
        name: "Cycle \(index + 1)",
        anchorMilliseconds: anchor,
        signalSamples: [
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor - 1_000, value: .bool(true)),
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor + peTiming, value: .bool(false)),
            FlightSignalSample(target: "TransferDelay.ACC", layer: .structuredMember, milliseconds: anchor - 600, value: .dint(timerACC - 12)),
            FlightSignalSample(target: "TransferDelay.ACC", layer: .structuredMember, milliseconds: anchor - 300, value: .dint(timerACC)),
            FlightSignalSample(target: "MotorCurrent", layer: .logic, milliseconds: anchor - 600, value: .real(motorCurrent - 0.15)),
            FlightSignalSample(target: "MotorCurrent", layer: .logic, milliseconds: anchor - 300, value: .real(motorCurrent + 0.15))
        ]
    )
}

private func operatingModeCycle(index: Int, loaded: Bool, recipe: Int32 = 1, degraded: Bool = false) -> KnownGoodCycle {
    let anchor = Int64(1_000_000 + index * 10_000)
    let jitter = Double((index * 7) % 7) - 3.0
    let degradation = degraded ? 1.0 : 0.0
    let pe = Int64((loaded ? -500.0 : -540.0) + jitter + degradation * 22.0)
    let acc = Int32((loaded ? 450.0 : 395.0) + jitter * 1.5 + degradation * 32.0)
    let current = (loaded ? 8.2 : 4.9) + jitter * 0.04 + degradation * 0.75
    return KnownGoodCycle(
        name: "Mode cycle \(index)",
        anchorMilliseconds: anchor,
        signalSamples: [
            FlightSignalSample(target: "ConveyorLoaded", layer: .logic, milliseconds: anchor - 900, value: .bool(loaded)),
            FlightSignalSample(target: "RecipeSpeed", layer: .logic, milliseconds: anchor - 900, value: .dint(recipe)),
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor - 1_000, value: .bool(true)),
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor + pe, value: .bool(false)),
            FlightSignalSample(target: "TransferDelay.ACC", layer: .structuredMember, milliseconds: anchor - 600, value: .dint(acc - 10)),
            FlightSignalSample(target: "TransferDelay.ACC", layer: .structuredMember, milliseconds: anchor - 300, value: .dint(acc)),
            FlightSignalSample(target: "MotorCurrent", layer: .logic, milliseconds: anchor - 600, value: .real(current - 0.12)),
            FlightSignalSample(target: "MotorCurrent", layer: .logic, milliseconds: anchor - 300, value: .real(current + 0.12))
        ]
    )
}

private func continuousStateCycle(index: Int, highLoad: Bool, degraded: Bool = false, extremeContext: Bool = false) -> KnownGoodCycle {
    let anchor = Int64(2_000_000 + index * 10_000)
    let jitter = Double((index * 11) % 9) - 4.0
    let speed = extremeContext ? 180.0 : (highLoad ? 92.0 : 48.0) + jitter * 0.35
    let payload = extremeContext ? 95.0 : (highLoad ? 42.0 : 8.0) + jitter * 0.18
    let degradation = degraded ? 1.0 : 0.0
    let pe = Int64((highLoad ? -485.0 : -535.0) + jitter + degradation * 30.0)
    let acc = Int32((highLoad ? 475.0 : 390.0) + jitter * 1.3 + degradation * 42.0)
    let current = (highLoad ? 9.1 : 4.7) + jitter * 0.035 + degradation * 0.95
    return KnownGoodCycle(
        name: "Continuous state \(index)",
        anchorMilliseconds: anchor,
        signalSamples: [
            FlightSignalSample(target: "LineSpeed", layer: .logic, milliseconds: anchor - 800, value: .real(speed - 0.4)),
            FlightSignalSample(target: "LineSpeed", layer: .logic, milliseconds: anchor - 200, value: .real(speed + 0.4)),
            FlightSignalSample(target: "PayloadKg", layer: .logic, milliseconds: anchor - 800, value: .real(payload - 0.2)),
            FlightSignalSample(target: "PayloadKg", layer: .logic, milliseconds: anchor - 200, value: .real(payload + 0.2)),
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor - 1_000, value: .bool(true)),
            FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor + pe, value: .bool(false)),
            FlightSignalSample(target: "TransferDelay.ACC", layer: .structuredMember, milliseconds: anchor - 600, value: .dint(acc - 12)),
            FlightSignalSample(target: "TransferDelay.ACC", layer: .structuredMember, milliseconds: anchor - 300, value: .dint(acc)),
            FlightSignalSample(target: "MotorCurrent", layer: .logic, milliseconds: anchor - 600, value: .real(current - 0.10)),
            FlightSignalSample(target: "MotorCurrent", layer: .logic, milliseconds: anchor - 300, value: .real(current + 0.10))
        ]
    )
}

private func trajectoryCycle(
    index: Int,
    loadedStartOffset: Int64 = 0,
    loadedEndOffset: Int64 = 0,
    skipDeceleration: Bool = false
) -> KnownGoodCycle {
    let anchor = Int64(3_000_000 + index * 10_000)
    let jitter = Double((index * 7) % 5) - 2.0
    let start = anchor - 1_000
    let accelerate = anchor - 800
    let loaded = anchor - 600 + loadedStartOffset
    let decelerate = anchor - 300 + loadedEndOffset
    let transfer = anchor - 100 + loadedEndOffset
    let end = anchor

    var states: [(Int64, Double, Double)] = [
        (start, 10 + jitter * 0.10, 1 + jitter * 0.05),
        (accelerate, 42 + jitter * 0.15, 6 + jitter * 0.08),
        (loaded, 82 + jitter * 0.18, 40 + jitter * 0.12)
    ]
    if !skipDeceleration {
        states.append((decelerate, 36 + jitter * 0.12, 39 + jitter * 0.10))
    }
    states.append((transfer, 14 + jitter * 0.10, 7 + jitter * 0.08))
    states.append((end, 14 + jitter * 0.10, 7 + jitter * 0.08))

    let samples = states.flatMap { time, speed, payload in
        [
            FlightSignalSample(target: "LineSpeed", layer: .logic, milliseconds: time, value: .real(speed)),
            FlightSignalSample(target: "PayloadKg", layer: .logic, milliseconds: time, value: .real(payload))
        ]
    }
    return KnownGoodCycle(name: "Trajectory cycle \(index)", anchorMilliseconds: anchor, signalSamples: samples)
}

private func phaseShapeCycle(index: Int, globalScale: Double = 1.0, transferDeviationStart: Double? = nil, loadedExtraMilliseconds: Int64 = 0) -> KnownGoodCycle {
    let anchor = Int64(5_000_000 + index * 20_000)
    func t(_ relative: Int64) -> Int64 { anchor + Int64(round(Double(relative) * globalScale)) }

    let boundaries: [(Int64, Double, Double)] = [
        (-1_000, 10, 1),
        (-800, 42, 6),
        (-600, 82, 40),
        (-300 + loadedExtraMilliseconds, 36, 39),
        (-100 + loadedExtraMilliseconds, 14, 7),
        (0 + loadedExtraMilliseconds, 14, 7)
    ]
    var samples: [FlightSignalSample] = boundaries.flatMap { rel, speed, payload in
        [
            FlightSignalSample(target: "LineSpeed", layer: .logic, milliseconds: t(rel), value: .real(speed)),
            FlightSignalSample(target: "PayloadKg", layer: .logic, milliseconds: t(rel), value: .real(payload))
        ]
    }

    // Dense shape signal. Its waveform is defined by normalized phase inside each authored state,
    // so a uniformly faster/slower cycle has the same shape after phase warping.
    let scaledStart = t(-1_000)
    let scaledEnd = t(0 + loadedExtraMilliseconds)
    var ms = scaledStart
    while ms <= scaledEnd {
        let relativeUnscaled = Double(ms - anchor) / globalScale
        let phase: Double
        let base: Double
        if relativeUnscaled < -800 {
            phase = (relativeUnscaled + 1000) / 200; base = 10 + 4 * phase
        } else if relativeUnscaled < -600 {
            phase = (relativeUnscaled + 800) / 200; base = 20 + 18 * phase
        } else if relativeUnscaled < Double(-300 + loadedExtraMilliseconds) {
            phase = (relativeUnscaled + 600) / Double(300 + loadedExtraMilliseconds); base = 50 + 6 * sin(.pi * phase)
        } else if relativeUnscaled < Double(-100 + loadedExtraMilliseconds) {
            phase = (relativeUnscaled - Double(-300 + loadedExtraMilliseconds)) / 200; base = 42 - 12 * phase
        } else {
            phase = (relativeUnscaled - Double(-100 + loadedExtraMilliseconds)) / 100; base = 28 + 8 * phase
        }
        var value = base + Double((index * 13) % 5 - 2) * 0.03
        if relativeUnscaled >= Double(-100 + loadedExtraMilliseconds), let transferDeviationStart, phase >= transferDeviationStart {
            value += 5.0
        }
        samples.append(FlightSignalSample(target: "ProcessShape", layer: .logic, milliseconds: ms, value: .real(value)))
        ms += 10
    }
    return KnownGoodCycle(name: "Phase cycle \(index)", anchorMilliseconds: anchor, signalSamples: samples)
}


private func dynamicResponseCycle(index: Int, deadTime: Int64 = 42, tau: Double = 90, gain: Double = 10, overshootPulse: Double = 0) -> KnownGoodCycle {
    let anchor: Int64 = 100_000 + Int64(index) * 5_000
    var samples: [FlightSignalSample] = [
        FlightSignalSample(target: "ValveCmd", layer: .logic, milliseconds: anchor - 20, value: .bool(false)),
        FlightSignalSample(target: "Pressure", layer: .logic, milliseconds: anchor - 20, value: .real(0)),
        FlightSignalSample(target: "Pressure", layer: .logic, milliseconds: anchor - 10, value: .real(0)),
        FlightSignalSample(target: "ValveCmd", layer: .logic, milliseconds: anchor, value: .bool(true)),
        FlightSignalSample(target: "Pressure", layer: .logic, milliseconds: anchor, value: .real(0))
    ]
    for t in stride(from: Int64(10), through: Int64(1_200), by: 10) {
        let elapsed = Double(max(Int64(0), t - deadTime))
        var y = t < deadTime ? 0 : gain * (1.0 - exp(-elapsed / tau))
        if overshootPulse > 0 {
            let center = deadTime + Int64(round(tau * 2.2))
            let width = max(20.0, tau * 0.35)
            y += gain * overshootPulse * exp(-pow(Double(t - center) / width, 2))
        }
        samples.append(FlightSignalSample(target: "Pressure", layer: .logic, milliseconds: anchor + t, value: .real(y)))
    }
    return KnownGoodCycle(name: "Dynamic response \(index)", anchorMilliseconds: anchor, signalSamples: samples)
}

private func secondOrderResponseCycle(index: Int, deadTime: Int64 = 50, gain: Double = 5.0, zeta: Double = 0.35, wn: Double = 8.0) -> KnownGoodCycle {
    let anchor: Int64 = 600_000 + Int64(index) * 5_000
    var samples: [FlightSignalSample] = [
        .init(target: "ValveCmd", layer: .logic, milliseconds: anchor - 20, value: .bool(false)),
        .init(target: "Pressure", layer: .logic, milliseconds: anchor - 20, value: .real(0)),
        .init(target: "ValveCmd", layer: .logic, milliseconds: anchor, value: .bool(true)),
        .init(target: "Pressure", layer: .logic, milliseconds: anchor, value: .real(0))
    ]
    let root = sqrt(max(1e-9, 1 - zeta*zeta))
    let wd = wn * root
    let phi = acos(zeta)
    for t in stride(from: Int64(10), through: Int64(2_000), by: 10) {
        let y: Double
        if t <= deadTime { y = 0 }
        else {
            let seconds = Double(t - deadTime) / 1_000.0
            let normalized = 1 - exp(-zeta * wn * seconds) / root * sin(wd * seconds + phi)
            y = gain * normalized
        }
        samples.append(.init(target: "Pressure", layer: .logic, milliseconds: anchor + t, value: .real(y)))
    }
    return .init(name: "Second-order \(index)", anchorMilliseconds: anchor, signalSamples: samples)
}

private func addingOperatingMode(_ cycle: KnownGoodCycle, value: Int32) -> KnownGoodCycle {
    var samples = cycle.signalSamples
    samples.append(.init(target: "LoadMode", layer: .logic, milliseconds: cycle.anchorMilliseconds - 30, value: .dint(value)))
    return .init(name: cycle.name, anchorMilliseconds: cycle.anchorMilliseconds, signalSamples: samples, taskExecutions: cycle.taskExecutions, events: cycle.events)
}

import Foundation
import Testing
@testable import ControlsReasoning
@testable import ControlsTraining
import ControlsSimulation
import ControlsPLC

@Test func demoProjectHasCrossRoutineTeachingPath() throws {
    let project = try DemoProjectFactory.packagingCell()
    #expect(project.tasks.count == 1)
    #expect(project.tasks[0].programs[0].routine(named: "StateLogic") != nil)
    #expect(project.controllerTags.contains("PE203"))
}

@Test func debugSessionOwnsStableScanNumber() throws {
    let project = try DemoProjectFactory.packagingCell()
    var runtime = ControllerRuntime(project: project)
    try runtime.setMode(.run)
    var session = try runtime.beginDebugScan(taskName: "MainTask", programName: "Packaging", elapsedMilliseconds: 10)
    #expect(session.scanNumber == 1)
    _ = try runtime.stepDebug(&session)
    _ = try runtime.stepDebug(&session)
    #expect(session.scanNumber == 1)
    #expect(runtime.controllerScanNumber == 1)
}

@Test func demoTagsDistinguishInputsOutputsAndInternalState() throws {
    let project = try DemoProjectFactory.packagingCell()
    let byName = Dictionary(uniqueKeysWithValues: project.controllerTags.allTags.map { ($0.name, $0.role) })
    #expect(byName["PE203"] == .input)
    #expect(byName["Motor_Run"] == .output)
    #expect(byName["State"] == .internalValue)
}

@Test @MainActor func debuggerExposesRawLogicalForcedAndFieldStatesAndSamplesWatchlist() throws {
    let project = try DemoProjectFactory.packagingCell()
    let model = DebuggerModel(project: project)
    model.setForce(tag: "PE203", value: .bool(false), kind: .input)
    model.setForce(tag: "Motor_Run", value: .bool(false), kind: .output)
    model.setForceMaster(true)

    let byName = Dictionary(uniqueKeysWithValues: model.tagSnapshots().map { ($0.name, $0) })
    #expect(byName["PE203"]?.raw == .bool(false))
    #expect(byName["PE203"]?.logical == .bool(false))
    #expect(byName["Motor_Run"]?.field == .bool(false))

    model.toggleWatch("State")
    model.enterRun()
    model.stepRung()
    #expect(model.trendHistory["State"]?.isEmpty == false)
}

@Test func causalJournalWalksPackagingFaultBackToPhotoeye() throws {
    var project = try DemoProjectFactory.packagingCell()
    try project.controllerTags.setBool("Start_PB", true)
    try project.controllerTags.setBool("PE203", true)

    var runtime = ControllerRuntime(project: project)
    try runtime.setMode(.run)
    var session = try runtime.beginDebugScan(taskName: "MainTask", programName: "Packaging", elapsedMilliseconds: 10)
    var journal = CausalJournal()

    while !session.isComplete {
        if let step = try runtime.stepDebug(&session) {
            journal.ingest(step: step, scanNumber: session.scanNumber, stepIndex: session.stepsExecuted)
        }
    }

    let trail = journal.explainWhy(target: "TransferCmd", shouldBe: .bool(true), observedValue: .bool(false))
    let headlines = trail.steps.map(\.headline).joined(separator: " | ")
    #expect(trail.reachedRootCondition)
    #expect(headlines.contains("TransferCmd"))
    #expect(headlines.contains("State"))
    #expect(headlines.contains("TransferDelay.DN"))
    #expect(headlines.contains("PE203"))
    #expect(trail.steps.last?.target == "PE203")
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

private let degradationFeatures: [MultivariateFeatureDefinition] = [
    MultivariateFeatureDefinition(
        target: "PE203",
        layer: .controllerInput,
        kind: .transitionTiming(resultingValue: .bool(false), occurrence: 0),
        displayName: "PE203 clear timing",
        unit: "ms"
    ),
    MultivariateFeatureDefinition(
        target: "TransferDelay.ACC",
        layer: .structuredMember,
        kind: .numeric(aggregation: .maximum),
        displayName: "TransferDelay peak ACC",
        unit: "ms"
    ),
    MultivariateFeatureDefinition(
        target: "MotorCurrent",
        layer: .logic,
        kind: .numeric(aggregation: .mean),
        displayName: "Motor current",
        unit: "A"
    )
]

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

private let loadedContextKey = OperatingContextKey(
    target: "ConveyorLoaded",
    layer: .logic,
    aggregation: .final,
    displayName: "Load"
)

private let recipeContextKey = OperatingContextKey(
    target: "RecipeSpeed",
    layer: .logic,
    aggregation: .final,
    displayName: "Recipe"
)

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

private let speedContextKey = OperatingContextKey(
    target: "LineSpeed",
    layer: .logic,
    aggregation: .mean,
    displayName: "Speed"
)

private let payloadContextKey = OperatingContextKey(
    target: "PayloadKg",
    layer: .logic,
    aggregation: .mean,
    displayName: "Payload"
)

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

private func learnedTrajectoryModel() -> WithinCycleTrajectoryModel? {
    WithinCycleStateTrajectoryAnalyzer.buildModel(
        cycles: (0..<12).map { trajectoryCycle(index: $0) },
        contextKeys: [speedContextKey, payloadContextKey],
        clusterCount: 5,
        samplingIntervalMilliseconds: 20,
        minimumSamplesPerRegion: 12,
        minimumEnvelopeSamples: 6
    )
}

private let phaseShapeFeature = PhaseShapeFeature(target: "ProcessShape", layer: .logic, displayName: "Process shape", unit: "u")

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

private func paintLearnedPhaseShape(
    onto base: KnownGoodCycle,
    model: PhaseWarpedTrajectoryModel,
    deviationRegionID: String? = nil,
    deviationStartPhase: Double? = nil,
    deviationDelta: Double = 0
) -> KnownGoodCycle {
    let trajectory = WithinCycleStateTrajectoryAnalyzer.trajectory(
        for: base,
        model: model.baseTrajectoryModel.operatingStateModel,
        samplingIntervalMilliseconds: model.baseTrajectoryModel.samplingIntervalMilliseconds
    )
    var samples = base.signalSamples.filter { $0.target != "ProcessShape" }
    for envelope in model.shapeEnvelopes where envelope.feature.target == "ProcessShape" {
        guard let segment = trajectory.segments.first(where: { $0.regionID == envelope.regionID }) else { continue }
        let span = max(Int64(0), segment.endRelativeMilliseconds - segment.startRelativeMilliseconds)
        for point in envelope.points {
            let relative = segment.startRelativeMilliseconds + Int64(round(Double(span) * point.phaseFraction))
            var value = point.mean
            if envelope.regionID == deviationRegionID, let deviationStartPhase, point.phaseFraction >= deviationStartPhase {
                value += deviationDelta
            }
            samples.append(FlightSignalSample(
                target: "ProcessShape",
                layer: .logic,
                milliseconds: base.anchorMilliseconds + relative,
                value: .real(value)
            ))
        }
    }
    return KnownGoodCycle(name: base.name + " phase-painted", anchorMilliseconds: base.anchorMilliseconds, signalSamples: samples)
}
private func learnedPhaseWarpedModel(cycles: [KnownGoodCycle]? = nil) -> PhaseWarpedTrajectoryModel? {
    let training = cycles ?? (0..<12).map { phaseShapeCycle(index: $0) }
    guard let base = WithinCycleStateTrajectoryAnalyzer.buildModel(
        cycles: training,
        contextKeys: [speedContextKey, payloadContextKey],
        clusterCount: 5,
        samplingIntervalMilliseconds: 20,
        minimumSamplesPerRegion: 12,
        minimumEnvelopeSamples: 6
    ) else { return nil }
    return PhaseWarpedTrajectoryAnalyzer.buildModel(
        cycles: training,
        baseTrajectoryModel: base,
        shapeFeatures: [phaseShapeFeature],
        phaseBins: 26,
        minimumCycles: 6
    )
}

private func lagAugmentedCycle(index: Int, baseModel: WithinCycleTrajectoryModel, phaseLag: Double = 0.06, eventDelayMilliseconds: Int64 = 42) -> KnownGoodCycle {
    let base = trajectoryCycle(index: 200 + index)
    let trajectory = WithinCycleStateTrajectoryAnalyzer.trajectory(
        for: base,
        model: baseModel.operatingStateModel,
        samplingIntervalMilliseconds: baseModel.samplingIntervalMilliseconds
    )
    let regionID = baseModel.dominantPath.count >= 3 ? baseModel.dominantPath[2] : baseModel.dominantPath.first!
    guard let segment = trajectory.segments.first(where: { $0.regionID == regionID }) else { return base }
    let span = max(Int64(1), segment.endRelativeMilliseconds - segment.startRelativeMilliseconds)
    var samples = base.signalSamples
    for bin in 0...100 {
        let p = Double(bin) / 100.0
        let relative = segment.startRelativeMilliseconds + Int64(round(Double(span) * p))
        let torque = exp(-pow((p - 0.42) / 0.12, 2)) * 100.0
        let q = p - phaseLag
        let speedResponse = exp(-pow((q - 0.42) / 0.12, 2)) * 100.0
        samples.append(FlightSignalSample(target: "MotorTorque", layer: .logic, milliseconds: base.anchorMilliseconds + relative, value: .real(torque)))
        samples.append(FlightSignalSample(target: "LineResponse", layer: .logic, milliseconds: base.anchorMilliseconds + relative, value: .real(speedResponse)))
    }
    let eventBase = base.anchorMilliseconds - 450
    samples += [
        FlightSignalSample(target: "ValveCmd", layer: .logic, milliseconds: eventBase - 10, value: .bool(false)),
        FlightSignalSample(target: "ValveCmd", layer: .logic, milliseconds: eventBase, value: .bool(true)),
        FlightSignalSample(target: "PressureMade", layer: .logic, milliseconds: eventBase, value: .bool(false)),
        FlightSignalSample(target: "PressureMade", layer: .logic, milliseconds: eventBase + eventDelayMilliseconds, value: .bool(true))
    ]
    return KnownGoodCycle(name: "Lag cycle \(index)", anchorMilliseconds: base.anchorMilliseconds, signalSamples: samples)
}

private func lagDefinitions(for base: WithinCycleTrajectoryModel) -> [CrossSignalLagDefinition] {
    let regionID = base.dominantPath.count >= 3 ? base.dominantPath[2] : base.dominantPath.first
    return [
        CrossSignalLagDefinition(
            name: "Torque → speed response",
            kind: .phaseLeadLag,
            upstream: LagSignalReference(target: "MotorTorque", layer: .logic),
            downstream: LagSignalReference(target: "LineResponse", layer: .logic),
            regionID: regionID,
            maximumPhaseLagFraction: 0.20
        ),
        CrossSignalLagDefinition(
            name: "Valve command → pressure",
            kind: .propagationDelay,
            upstream: LagSignalReference(target: "ValveCmd", layer: .logic),
            downstream: LagSignalReference(target: "PressureMade", layer: .logic),
            upstreamResultingValue: .bool(true),
            downstreamResultingValue: .bool(true),
            relationshipBasis: .authoredCausalPath
        )
    ]
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

private let dynamicResponseDefinition = DynamicResponseDefinition(
    name: "Valve command → pressure response",
    command: LagSignalReference(target: "ValveCmd", layer: .logic),
    response: LagSignalReference(target: "Pressure", layer: .logic),
    commandResultingValue: .bool(true),
    relationshipBasis: .authoredCausalPath,
    responseWindowMilliseconds: 1_200
)

private let systemIdentificationDefinition = SystemIdentificationDefinition(
    name: "Valve → pressure plant",
    response: dynamicResponseDefinition,
    preference: .firstOrderPlusDeadTime
)

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

private func identifiedFOPDT(K: Double = 10, L: Double = 42, tau: Double = 90) -> IdentifiedPlantFit {
    .init(
        modelKind: .firstOrderPlusDeadTime,
        processGain: K,
        deadTimeMilliseconds: L,
        timeConstantMilliseconds: tau,
        dampingRatio: nil,
        naturalFrequencyRadiansPerSecond: nil,
        normalizedRMSE: 0.02,
        sampleCount: 100
    )
}

private func limitCycleDefinition(settings: SampledPIDExecutionSettings) -> SampledPIDDefinition {
    .init(name: "Limit-cycle loop", systemIdentificationSignatureID: "synthetic", settings: settings, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 8_000))
}

private func syntheticLimitCycleSimulation(
    amplitude: Double = 0.2,
    periodMilliseconds: Double = 1_000,
    robustness: ClosedLoopRobustness = .balanced,
    stiction: Bool = false,
    deadband: Bool = false,
    saturation: Bool = false
) -> SampledPIDSimulation {
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 1.0, integralGainPerSecond: 1.0),
        taskPeriodMilliseconds: 20,
        outputMinimum: -2,
        outputMaximum: 2
    )
    let plant = identifiedFOPDT(K: 1, L: 10, tau: 250)
    let scenario = SampledPIDScenario(setpointAfterStep: 1, durationMilliseconds: 8_000)
    var points: [SampledPIDPoint] = []
    for i in 0...400 {
        let t = Double(i) * 20
        let phase = 2 * Double.pi * t / periodMilliseconds
        let pv = 1 + amplitude * sin(phase)
        let error = 1 - pv
        let command = 0.5 + 0.22 * sin(phase + 0.35)
        let stuckNow = stiction && sin(phase) > 0.15 && sin(phase) < 0.75
        let breakawayNow = stiction && abs((phase.truncatingRemainder(dividingBy: 2 * .pi)) - 0.90) < 0.07
        let deadbandNow = deadband && abs(cos(phase)) < 0.35
        let satNow = saturation && sin(phase) > 0.45
        let actuator = stuckNow ? 0.5 : 0.5 + 0.20 * sin(phase)
        let integral = 0.35 * asin(sin(phase - 0.2))
        points.append(.init(
            timeMilliseconds: t,
            setpoint: 1,
            processValue: pv,
            error: error,
            proportionalTerm: error,
            integralTerm: integral,
            derivativeTerm: 0,
            unconstrainedOutput: satNow ? 3 : command,
            controllerOutput: satNow ? 2 : command,
            actuatorOutput: actuator,
            saturated: satNow,
            rateLimited: false,
            actuatorStuck: stuckNow,
            breakaway: breakawayNow,
            backlashLimited: false,
            deadbandLimited: deadbandNow,
            hysteresisActive: false
        ))
    }
    let margins = StabilityMarginEstimate(gainCrossoverRadiansPerSecond: 4, phaseMarginDegrees: robustness == .aggressive ? 37 : 68, phaseCrossoverRadiansPerSecond: nil, gainMarginDecibels: 8, delayPhaseAtGainCrossoverDegrees: -2, robustness: robustness)
    let diagnostics = SampledLoopDiagnostics(
        dominantIssue: stiction ? .stiction : (deadband ? .deadband : (saturation ? .outputSaturation : .noDominantNonlinearity)),
        linearMargins: margins,
        taskPeriodMilliseconds: 20,
        samplesPerDominantTimeConstant: 12.5,
        samplesPerGainCrossoverCycle: 78,
        saturationFraction: Double(points.filter(\.saturated).count) / Double(points.count),
        rateLimitFraction: 0,
        stuckFraction: Double(points.filter(\.actuatorStuck).count) / Double(points.count),
        breakawayCount: points.filter(\.breakaway).count,
        backlashFraction: 0,
        deadbandFraction: Double(points.filter(\.deadbandLimited).count) / Double(points.count),
        hysteresisFraction: 0,
        limitCycleReversals: 12,
        peakIntegralMagnitude: 0.35,
        peakProcessValue: 1 + amplitude,
        finalAbsoluteError: abs(points.last?.error ?? 0),
        interpretations: [],
        summary: "Synthetic periodic behavior"
    )
    return .init(settings: settings, plant: plant, scenario: scenario, points: points, diagnostics: diagnostics)
}

private func sineSamples(frequencies: [(hz: Double, amplitude: Double)], durationSeconds: Double = 10, dtMilliseconds: Double = 20, phase: Double = 0) -> [SpectralSignalSample] {
    let count = Int(durationSeconds * 1000 / dtMilliseconds)
    return (0..<count).map { i in
        let t = Double(i) * dtMilliseconds
        let seconds = t / 1000
        let value = frequencies.reduce(0.0) { partial, component in
            partial + component.amplitude * sin(2 * .pi * component.hz * seconds + phase)
        }
        return SpectralSignalSample(timeMilliseconds: t, value: value)
    }
}

@Test func heroMachineCatalogContainsFourteenDistinctCommercialAndIndustrialApplications() throws {
    let machines = HeroMachineCatalog.all
    #expect(machines.count == 28)
    #expect(Set(machines.map(\.id)).count == 28)
    #expect(machines.allSatisfy { !$0.faults.isEmpty && !$0.guidedPath.isEmpty && $0.healthyPopulation.cycleCount >= 300 })
    for machine in machines {
        let project = try machine.projectFactory()
        #expect(!project.tasks.isEmpty)
        #expect(!machine.processSignals.isEmpty)
    }
}

@Test func everyHeroMachineProvidesGuidedAndTechnicianExperiencesAndProgressiveFaultHistory() {
    for machine in HeroMachineCatalog.all {
        guard let fault = machine.faults.first else { Issue.record("Missing fault for \(machine.title)"); continue }
        let guided = HeroMachineCatalog.start(machine: machine.id, faultID: fault.id, mode: .guided)
        let technician = HeroMachineCatalog.start(machine: machine.id, faultID: fault.id, mode: .technician)
        #expect(guided?.visibleLessonSteps.count == 1)
        #expect(technician?.visibleLessonSteps.isEmpty == true)
        #expect(fault.progression.count >= 3)
        #expect((fault.progression.last?.severity ?? 0) >= 0.9)
    }
}

@Test func scenarioSessionCanAdvanceFromHealthyBaselineIntoLateFaultProgression() {
    var session = HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .guided)!
    #expect(session.currentProgression.label == "Healthy")
    session.advance(days: 70)
    #expect(session.currentProgression.label == "Sustained limit cycle")
    session.revealNextGuidedStep()
    #expect(session.visibleLessonSteps.count == 2)
}

@Test @MainActor func debuggerAutomaticallySelectsFirstProgramForNonPackagingHeroMachine() throws {
    let machine = HeroMachineCatalog.machine(.airHandlingUnit)!
    let model = DebuggerModel(project: try machine.projectFactory())
    #expect(model.currentRoutine == "MainRoutine")
    #expect(model.mode == .program)
    model.enterRun()
    model.stepScan()
    #expect(model.errorMessage == nil)
}

@Test func playablePackagingScenarioPhysicallyDelaysStickyPhotoeyeRelease() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .packagingCell, faultID: "pe203-sticky", mode: .technician))
    session.advance(days: 42)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.run(seconds: 8)
    #expect(engine.runtime.eventHistory.contains { $0.name == "PE203 release delayed" })
}

@Test func playablePressureScenarioProducesBreakawayEventsAtSevereStictionStage() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.run(seconds: 18)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Valve breakaway" })
    #expect((engine.runtime.snapshot.analog["BreakawayCount"] ?? 0) > 0)
}

@Test func guidedToolPolicyUnlocksCapabilitiesProgressively() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .guided))
    var policy = ScenarioToolAccessPolicy(session: session)
    #expect(policy.isAvailable(.flightRecorder))
    #expect(!policy.isAvailable(.systemIdentification))
    session.revealNextGuidedStep()
    session.revealNextGuidedStep()
    session.revealNextGuidedStep()
    session.revealNextGuidedStep()
    policy = ScenarioToolAccessPolicy(session: session)
    #expect(policy.isAvailable(.systemIdentification))
    #expect(policy.isAvailable(.limitCycleFingerprinting))
}

@Test func technicianToolPolicyExposesCompleteEvidenceStack() throws {
    let session = try #require(HeroMachineCatalog.start(machine: .packagingCell, faultID: "pe203-sticky", mode: .technician))
    let policy = ScenarioToolAccessPolicy(session: session)
    for capability in ScenarioDiagnosticCapability.allCases {
        #expect(policy.isAvailable(capability))
    }
}

@Test func learnerScoreRewardsEvidenceBeforeCorrectDiagnosisAndVerification() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.record(.observedMachine, target: "PressurePV")
    engine.record(.openedFlightRecorder, target: "ValveCmd vs ValvePosition")
    engine.record(.enteredMeasurement, target: "Valve stem feedback", informationGain: 0.9)
    engine.proposeDiagnosis("Valve stiction")
    engine.repair(.serviceValveOrPositioner)
    try engine.verify(seconds: 6)
    let debrief = engine.debrief()
    #expect(debrief.score.overall >= 80)
    #expect(debrief.score.verification == 100)
    #expect(engine.repairVerified)
}

@Test func learnerScorePenalizesUnsupportedPrematureControllerChange() throws {
    let session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    var engine = try #require(try PlayableScenarioEngine(session: session))
    engine.record(.changedControllerSetting, target: "PID Kp", interventionPenalty: 1, supportedByEvidence: false)
    engine.proposeDiagnosis("bad PID tuning")
    let debrief = engine.debrief()
    #expect(debrief.score.interventionDiscipline <= 60)
    #expect(debrief.score.causalReasoning < 60)
    #expect(!debrief.missedOpportunities.isEmpty)
}

@Test func correctRepairRemovesInjectedPressureStictionForVerification() throws {
    var session = try #require(HeroMachineCatalog.start(machine: .pressureSkid, faultID: "valve-stiction", mode: .technician))
    session.advance(days: 63)
    var engine = try #require(try PlayableScenarioEngine(session: session))
    try engine.run(seconds: 10)
    #expect(engine.runtime.eventHistory.contains { $0.name == "Valve breakaway" })
    engine.repair(.serviceValveOrPositioner)
    let eventIndex = engine.runtime.eventHistory.count
    try engine.verify(seconds: 7)
    let postRepair = engine.runtime.eventHistory.dropFirst(eventIndex)
    #expect(!postRepair.contains { $0.name == "Valve breakaway" || $0.name == "Valve stuck" })
    #expect(engine.repairVerified)
}

@Test func allHeroMachinesNowProvidePlayablePhysicsRuntime() throws {
    for machine in HeroMachineCatalog.all {
        let fault = try #require(machine.faults.first)
        let session = try #require(HeroMachineCatalog.start(machine: machine.id, faultID: fault.id, mode: .guided))
        let engine = try PlayableScenarioEngine(session: session)
        #expect(engine.map { _ in true } == true)
    }
}

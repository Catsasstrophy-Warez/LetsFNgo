import Foundation
import Testing
@testable import ControlsReasoning
import ControlsPLC

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

@Test func healthyEnvelopeLearnsDistributionAcrossTwentyCycles() {
    let peTimes: [Int64] = [-510, -506, -505, -504, -503, -502, -501, -500, -499, -498, -508, -507, -504, -503, -502, -501, -500, -497, -496, -494]
    let cycles = peTimes.enumerated().map { healthyTimingCycle(index: $0.offset, pe203Relative: $0.element) }
    let model = HealthyCycleAnalyzer.buildModel(name: "Packaging healthy", cycles: cycles)
    let pe = model.envelope(target: "PE203", layer: .controllerInput)

    #expect(model.cycleCount == 20)
    #expect(pe?.sampleCount == 20)
    #expect(abs((pe?.meanRelativeMilliseconds ?? 0) - (-502.0)) < 3.0)
    #expect(pe?.contains(relativeMilliseconds: -502) == true)
    #expect(pe?.lowerNormalMilliseconds ?? 0 < -502)
    #expect(pe?.upperNormalMilliseconds ?? -1000 > -502)
}

@Test func healthyEnvelopeDetectsSlowTimingDriftBeforeFailure() {
    let cycles = (0..<20).map { index in
        healthyTimingCycle(index: index, pe203Relative: -560 + Int64(index * 3))
    }
    let model = HealthyCycleAnalyzer.buildModel(cycles: cycles, driftThresholdMillisecondsPerCycle: 2.0)
    let pe = model.envelope(target: "PE203", layer: .controllerInput)

    #expect(pe?.trend == .driftingLater)
    #expect((pe?.slopeMillisecondsPerCycle ?? 0) > 2.9)
    #expect((pe?.trendRSquared ?? 0) > 0.95)
}

@Test func cycleSegmentationBuildsAlignedCyclesFromRecurringMarkers() {
    let events = [
        TemporalEventMarker(name: "CycleComplete", milliseconds: 10_000),
        TemporalEventMarker(name: "CycleComplete", milliseconds: 20_000),
        TemporalEventMarker(name: "CycleComplete", milliseconds: 30_000)
    ]
    let samples = [10_000, 20_000, 30_000].flatMap { anchor in
        [
            FlightSignalSample(target: "PE203", layer: .logic, milliseconds: Int64(anchor - 700), value: .bool(true)),
            FlightSignalSample(target: "PE203", layer: .logic, milliseconds: Int64(anchor - 500), value: .bool(false))
        ]
    }
    let segments = HealthyCycleAnalyzer.segment(
        signalSamples: samples,
        events: events,
        rule: .event(name: "CycleComplete", preMilliseconds: 1_000, postMilliseconds: 100)
    )

    #expect(segments.count == 3)
    #expect(segments[1].cycle.anchorMilliseconds == 20_000)
    #expect(segments.allSatisfy { $0.cycle.signalSamples.count == 2 })
}

@Test func envelopeComparisonFlagsTrueLateOutlierButIgnoresNormalJitter() {
    let healthy = (0..<20).map { index in
        healthyTimingCycle(index: index, pe203Relative: -505 + Int64(index % 7))
    }
    let model = HealthyCycleAnalyzer.buildModel(cycles: healthy)
    let normal = HealthyCycleAnalyzer.compare(cycle: healthyTimingCycle(index: 30, pe203Relative: -501), against: model)
    let late = HealthyCycleAnalyzer.compare(cycle: healthyTimingCycle(index: 31, pe203Relative: -420), against: model)

    #expect(normal.earliestOutlier == nil)
    #expect(late.earliestOutlier?.target == "PE203")
    #expect(late.earliestOutlier?.status == .lateOutlier)
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

@Test func multivariateModelLearnsHealthyCovarianceAcrossTimingTimerAndCurrent() {
    let healthy = (0..<20).map { i in
        let jitter = Double((i * 7) % 9) - 4.0
        return multivariateCycle(
            index: i,
            peTiming: Int64(-505 + Int(jitter)),
            timerACC: Int32(445 + Int(jitter * 1.8)),
            motorCurrent: 8.0 + jitter * 0.055
        )
    }
    let model = MultivariateDegradationAnalyzer.buildModel(cycles: healthy, featureDefinitions: degradationFeatures)

    #expect(model?.cycleCount == 20)
    #expect(model?.features.count == 3)
    #expect(model?.covarianceMatrix.count == 3)
    #expect(model?.correlations.count == 3)
    #expect((model?.correlations.first?.coefficient ?? 0) > 0.70)
}

@Test func multivariateAssessmentCanFlagJointDegradationBeforeAnyFeatureIsExtremeAlone() {
    let healthy = (0..<24).map { i in
        let a = Double((i * 5) % 11) - 5.0
        let b = Double((i * 3) % 7) - 3.0
        return multivariateCycle(
            index: i,
            peTiming: Int64(-505 + Int(a)),
            timerACC: Int32(445 + Int(b * 2.0)),
            motorCurrent: 8.0 + (a - b) * 0.035
        )
    }
    guard let model = MultivariateDegradationAnalyzer.buildModel(cycles: healthy, featureDefinitions: degradationFeatures) else {
        Issue.record("Expected multivariate model")
        return
    }
    let candidate = multivariateCycle(index: 50, peTiming: -497, timerACC: 455, motorCurrent: 8.30)
    let assessment = MultivariateDegradationAnalyzer.assess(cycle: candidate, against: model)

    #expect(assessment.status == .emergingPattern || assessment.status == .anomalousPattern)
    #expect(assessment.contributions.count == 3)
    #expect(assessment.contributions.allSatisfy { abs($0.standardizedDeviation) < 3.0 })
    #expect((assessment.mahalanobisDistance ?? 0) >= model.warningDistance)
}

@Test func multivariateAssessmentKeepsOrdinaryCoupledVariationHealthy() {
    let healthy = (0..<20).map { i in
        let jitter = Double((i * 7) % 9) - 4.0
        return multivariateCycle(
            index: i,
            peTiming: Int64(-505 + Int(jitter)),
            timerACC: Int32(445 + Int(jitter * 1.8)),
            motorCurrent: 8.0 + jitter * 0.055
        )
    }
    guard let model = MultivariateDegradationAnalyzer.buildModel(cycles: healthy, featureDefinitions: degradationFeatures) else {
        Issue.record("Expected multivariate model")
        return
    }
    let ordinary = multivariateCycle(index: 40, peTiming: -502, timerACC: 450, motorCurrent: 8.16)
    let assessment = MultivariateDegradationAnalyzer.assess(cycle: ordinary, against: model)

    #expect(assessment.status == .normal)
}

@Test func multivariateAssessmentReportsMissingFeatureInsteadOfInventingHealthScore() {
    let healthy: [KnownGoodCycle] = (0..<20).map { i in
        let pe = Int64(-505 + (i % 5))
        let acc = Int32(445 + (i % 5))
        let current = 8.0 + Double(i % 5) * 0.03
        return multivariateCycle(index: i, peTiming: pe, timerACC: acc, motorCurrent: current)
    }
    guard let model = MultivariateDegradationAnalyzer.buildModel(cycles: healthy, featureDefinitions: degradationFeatures) else {
        Issue.record("Expected multivariate model")
        return
    }
    let anchor: Int64 = 900_000
    let incomplete = KnownGoodCycle(anchorMilliseconds: anchor, signalSamples: [
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor - 1_000, value: .bool(true)),
        FlightSignalSample(target: "PE203", layer: .controllerInput, milliseconds: anchor - 500, value: .bool(false))
    ])
    let assessment = MultivariateDegradationAnalyzer.assess(cycle: incomplete, against: model)

    #expect(assessment.status == MultivariateHealthStatus.insufficientData)
    #expect(assessment.mahalanobisDistance == nil)
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

@Test func operatingModeDiscoverySeparatesCategoricalMachineRegimes() {
    let cycles = (0..<10).map { operatingModeCycle(index: $0, loaded: false) }
        + (10..<20).map { operatingModeCycle(index: $0, loaded: true) }
    let modes = OperatingModeHealthAnalyzer.discoverModes(cycles: cycles, keys: [loadedContextKey, recipeContextKey])

    #expect(modes.count == 2)
    #expect(modes.contains { $0.name.contains("Load=FALSE") })
    #expect(modes.contains { $0.name.contains("Load=TRUE") })
}

@Test func modeAwareHealthKeepsHealthyLoadedMachineNormalInsteadOfUsingEmptyBaseline() {
    let empty = (0..<12).map { operatingModeCycle(index: $0, loaded: false) }
    let loaded = (12..<24).map { operatingModeCycle(index: $0, loaded: true) }
    let cycles = empty + loaded
    let modes = OperatingModeHealthAnalyzer.discoverModes(cycles: cycles, keys: [loadedContextKey, recipeContextKey])
    let library = OperatingModeHealthAnalyzer.buildLibrary(cycles: cycles, modeDefinitions: modes, healthFeatureDefinitions: degradationFeatures, minimumCyclesPerMode: 8)
    let candidate = operatingModeCycle(index: 40, loaded: true)
    let assessment = OperatingModeHealthAnalyzer.assess(cycle: candidate, against: library, modeDefinitions: modes)

    #expect(library.models.count == 2)
    #expect(assessment.status == .assessed)
    #expect(assessment.selectedModeName?.contains("Load=TRUE") == true)
    #expect(assessment.healthAssessment?.status == .normal)

    let emptyDefinition = modes.first { $0.name.contains("Load=FALSE") }!
    let emptyModel = library.models.first { $0.definition.id == emptyDefinition.id }!.multivariateModel
    let wrongBaseline = MultivariateDegradationAnalyzer.assess(cycle: candidate, against: emptyModel)
    #expect(wrongBaseline.status == .anomalousPattern || wrongBaseline.status == .emergingPattern)
}

@Test func modeAwareHealthStillFindsDegradationInsideCorrectOperatingRegime() {
    let cycles = (0..<12).map { operatingModeCycle(index: $0, loaded: false) }
        + (12..<24).map { operatingModeCycle(index: $0, loaded: true) }
    let modes = OperatingModeHealthAnalyzer.discoverModes(cycles: cycles, keys: [loadedContextKey, recipeContextKey])
    let library = OperatingModeHealthAnalyzer.buildLibrary(cycles: cycles, modeDefinitions: modes, healthFeatureDefinitions: degradationFeatures, minimumCyclesPerMode: 8)
    let degradedLoaded = operatingModeCycle(index: 50, loaded: true, degraded: true)
    let assessment = OperatingModeHealthAnalyzer.assess(cycle: degradedLoaded, against: library, modeDefinitions: modes)

    #expect(assessment.selectedModeName?.contains("Load=TRUE") == true)
    #expect(assessment.healthAssessment?.status == .emergingPattern || assessment.healthAssessment?.status == .anomalousPattern)
}

@Test func unknownOperatingModeIsNotScoredAgainstNearestHealthyCloud() {
    let cycles = (0..<12).map { operatingModeCycle(index: $0, loaded: false, recipe: 1) }
        + (12..<24).map { operatingModeCycle(index: $0, loaded: true, recipe: 1) }
    let modes = OperatingModeHealthAnalyzer.discoverModes(cycles: cycles, keys: [loadedContextKey, recipeContextKey])
    let library = OperatingModeHealthAnalyzer.buildLibrary(cycles: cycles, modeDefinitions: modes, healthFeatureDefinitions: degradationFeatures, minimumCyclesPerMode: 8)
    let unknownRecipe = operatingModeCycle(index: 60, loaded: true, recipe: 2)
    let assessment = OperatingModeHealthAnalyzer.assess(cycle: unknownRecipe, against: library, modeDefinitions: modes)

    #expect(assessment.status == .unknownMode)
    #expect(assessment.healthAssessment == nil)
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

@Test func continuousContextClusteringLearnsNaturalLowAndHighOperatingRegions() {
    let cycles = (0..<12).map { continuousStateCycle(index: $0, highLoad: false) }
        + (12..<24).map { continuousStateCycle(index: $0, highLoad: true) }
    let model = ContinuousOperatingStateAnalyzer.buildModel(
        cycles: cycles,
        contextKeys: [speedContextKey, payloadContextKey],
        healthFeatureDefinitions: degradationFeatures,
        clusterCount: 2,
        minimumCyclesPerRegion: 8
    )

    #expect(model != nil)
    #expect(model?.regions.count == 2)
    #expect(model?.regions.allSatisfy { $0.healthModel != nil } == true)
    #expect((model?.regions[0].centroid[0] ?? 0) < (model?.regions[1].centroid[0] ?? 0))
}

@Test func regionalHealthFindsFailureOnlyUnderHighLoadHighSpeedContext() {
    let cycles = (0..<12).map { continuousStateCycle(index: $0, highLoad: false) }
        + (12..<24).map { continuousStateCycle(index: $0, highLoad: true) }
    guard let model = ContinuousOperatingStateAnalyzer.buildModel(
        cycles: cycles,
        contextKeys: [speedContextKey, payloadContextKey],
        healthFeatureDefinitions: degradationFeatures,
        clusterCount: 2,
        minimumCyclesPerRegion: 8
    ) else {
        Issue.record("Expected continuous operating-state model")
        return
    }

    let healthyHigh = ContinuousOperatingStateAnalyzer.assess(cycle: continuousStateCycle(index: 40, highLoad: true), against: model)
    let degradedHigh = ContinuousOperatingStateAnalyzer.assess(cycle: continuousStateCycle(index: 41, highLoad: true, degraded: true), against: model)
    let healthyLow = ContinuousOperatingStateAnalyzer.assess(cycle: continuousStateCycle(index: 42, highLoad: false), against: model)

    #expect(healthyHigh.status == .assessed)
    #expect(healthyHigh.healthAssessment?.status == .normal)
    #expect(healthyLow.healthAssessment?.status == .normal)
    #expect(degradedHigh.selectedRegionID == healthyHigh.selectedRegionID)
    #expect(degradedHigh.healthAssessment?.status == .emergingPattern || degradedHigh.healthAssessment?.status == .anomalousPattern)
}

@Test func unseenContinuousOperatingPointIsNotForceFitToNearestRegion() {
    let cycles = (0..<12).map { continuousStateCycle(index: $0, highLoad: false) }
        + (12..<24).map { continuousStateCycle(index: $0, highLoad: true) }
    guard let model = ContinuousOperatingStateAnalyzer.buildModel(
        cycles: cycles,
        contextKeys: [speedContextKey, payloadContextKey],
        healthFeatureDefinitions: degradationFeatures,
        clusterCount: 2,
        minimumCyclesPerRegion: 8
    ) else {
        Issue.record("Expected continuous operating-state model")
        return
    }

    let assessment = ContinuousOperatingStateAnalyzer.assess(
        cycle: continuousStateCycle(index: 50, highLoad: true, extremeContext: true),
        against: model
    )
    #expect(assessment.status == .unknownRegion)
    #expect(assessment.healthAssessment == nil)
}

@Test func healthySequenceLearnsAndExplainsOperatingRegionTransitions() {
    let cycles = (0..<12).map { continuousStateCycle(index: $0, highLoad: false) }
        + (12..<24).map { continuousStateCycle(index: $0, highLoad: true) }
    guard let model = ContinuousOperatingStateAnalyzer.buildModel(
        cycles: cycles,
        contextKeys: [speedContextKey, payloadContextKey],
        healthFeatureDefinitions: degradationFeatures,
        clusterCount: 2,
        minimumCyclesPerRegion: 8
    ) else {
        Issue.record("Expected continuous operating-state model")
        return
    }
    let low = model.regions[0].id
    let high = model.regions[1].id
    let learned = ContinuousOperatingStateAnalyzer.assessTransition(from: low, to: high, in: model)
    let unseen = ContinuousOperatingStateAnalyzer.assessTransition(from: high, to: low, in: model)

    #expect(learned != nil)
    #expect(learned?.probability ?? 0 > 0)
    #expect(model.transitions.contains { $0.fromRegionID == low && $0.toRegionID == high })
    #expect(unseen?.novelty == .unseen)
}

@Test func continuousContextCanAutomaticallySelectTwoNaturalRegions() {
    let cycles = (0..<12).map { continuousStateCycle(index: $0, highLoad: false) }
        + (12..<24).map { continuousStateCycle(index: $0, highLoad: true) }
    let model = ContinuousOperatingStateAnalyzer.buildModel(
        cycles: cycles,
        contextKeys: [speedContextKey, payloadContextKey],
        healthFeatureDefinitions: degradationFeatures,
        maximumClusters: 4,
        minimumCyclesPerRegion: 6
    )

    #expect(model != nil)
    #expect(model?.regions.count == 2)
    #expect((model?.silhouetteScore ?? 0) > 0.8)
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

@Test func withinCycleModelLearnsFiveStateTrajectoryAndDwellEnvelopes() {
    guard let model = learnedTrajectoryModel() else {
        Issue.record("Expected within-cycle trajectory model")
        return
    }
    #expect(model.operatingStateModel.regions.count == 5)
    #expect(model.entryEnvelopes.count >= 5)
    #expect(model.dwellEnvelopes.count >= 5)
    #expect(model.dominantPath.count == 5)

    let assessment = WithinCycleStateTrajectoryAnalyzer.assess(cycle: trajectoryCycle(index: 50), against: model)
    #expect(assessment.status == .normal)
    #expect(assessment.segments.count == 5)
}

@Test func withinCycleTrajectoryDetectsEarlyEntryIntoLoadedRegion() {
    guard let model = learnedTrajectoryModel() else {
        Issue.record("Expected within-cycle trajectory model")
        return
    }
    let assessment = WithinCycleStateTrajectoryAnalyzer.assess(
        cycle: trajectoryCycle(index: 51, loadedStartOffset: -120),
        against: model
    )
    #expect(assessment.status == .anomalous)
    #expect(assessment.anomalies.contains { $0.kind == .earlyEntry })
}

@Test func withinCycleTrajectoryDetectsStateHeldAbout180MillisecondsTooLong() {
    guard let model = learnedTrajectoryModel() else {
        Issue.record("Expected within-cycle trajectory model")
        return
    }
    let assessment = WithinCycleStateTrajectoryAnalyzer.assess(
        cycle: trajectoryCycle(index: 52, loadedEndOffset: 180),
        against: model
    )
    let dwell = assessment.anomalies.first { $0.kind == .excessiveDwell }
    #expect(dwell != nil)
    #expect((dwell?.magnitudeMilliseconds ?? 0) >= 140)
    #expect(dwell?.explanation.contains("Stayed in") == true)
}

@Test func withinCycleTrajectoryDetectsPreviouslyUnseenTransitionPath() {
    guard let model = learnedTrajectoryModel() else {
        Issue.record("Expected within-cycle trajectory model")
        return
    }
    let assessment = WithinCycleStateTrajectoryAnalyzer.assess(
        cycle: trajectoryCycle(index: 53, skipDeceleration: true),
        against: model
    )
    #expect(assessment.anomalies.contains { $0.kind == .unexpectedTransition })
    #expect(assessment.summary.contains("trajectory anomaly"))
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

@Test func phaseWarpedAlignmentTreatsUniformlySlowerHealthyCycleAsSameShape() {
    guard let model = learnedPhaseWarpedModel() else {
        Issue.record("Expected phase-warped model")
        return
    }
    let slower = phaseShapeCycle(index: 80, globalScale: 1.15)
    let aligned = paintLearnedPhaseShape(onto: slower, model: model)
    let assessment = PhaseWarpedTrajectoryAnalyzer.assess(cycle: aligned, against: model)
    #expect(assessment.status == .normal)
    #expect(assessment.durationScale > 1.10)
    #expect(assessment.summary.contains("speed variation"))
}

@Test func phaseWarpedAlignmentLocalizesTransferDeviationNearThirtyTwoPercent() {
    guard let model = learnedPhaseWarpedModel(),
          let transferRegionID = model.baseTrajectoryModel.dominantPath.last else {
        Issue.record("Expected phase-warped model and learned transfer state")
        return
    }
    let base = phaseShapeCycle(index: 81, globalScale: 1.08)
    let candidate = paintLearnedPhaseShape(
        onto: base,
        model: model,
        deviationRegionID: transferRegionID,
        deviationStartPhase: 0.32,
        deviationDelta: 5.0
    )
    let assessment = PhaseWarpedTrajectoryAnalyzer.assess(
        cycle: candidate,
        against: model,
        zThreshold: 3.0,
        consecutiveBins: 2
    )
    let transferDeviation = assessment.deviations.first { $0.regionID == transferRegionID }
    #expect(assessment.status == .localizedDeviation)
    #expect(transferDeviation != nil)
    #expect((transferDeviation?.phaseFraction ?? 0) >= 0.28)
    #expect((transferDeviation?.phaseFraction ?? 1) <= 0.40)
    #expect(assessment.summary.contains("phase progress"))
}

@Test func phaseWarpedModelRetainsProgressiveDwellStretchInsteadOfWarpingItAway() {
    let cycles = (0..<12).map { phaseShapeCycle(index: $0, loadedExtraMilliseconds: Int64($0 * 4)) }
    guard let model = learnedPhaseWarpedModel(cycles: cycles) else {
        Issue.record("Expected phase-warped model")
        return
    }
    let stretching = model.dwellTrends.filter(\.isProgressivelyStretching)
    #expect(!stretching.isEmpty)
    #expect(stretching.contains { $0.slopeMillisecondsPerCycle >= 2.0 && $0.rSquared >= 0.60 })
}

@Test func phaseWarpedShapeModelBuildsPerStatePerFeatureEnvelopes() {
    guard let model = learnedPhaseWarpedModel() else {
        Issue.record("Expected phase-warped model")
        return
    }
    #expect(model.phaseBins == 26)
    #expect(model.shapeEnvelopes.count >= 5)
    #expect(model.shapeEnvelopes.allSatisfy { $0.points.count == 26 })
    #expect(model.shapeEnvelopes.allSatisfy { $0.feature.target == "ProcessShape" })
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

@Test func crossSignalLagLearnsHealthyPhaseLeadAndFortyTwoMillisecondPropagation() {
    guard let base = learnedTrajectoryModel() else {
        Issue.record("Expected trajectory model")
        return
    }
    var cycles: [KnownGoodCycle] = []
    for i in 0..<12 {
        let jitter = (i % 3) - 1
        let phaseLag = 0.06 + Double(jitter) * 0.002
        let eventDelay = Int64(42 + jitter)
        cycles.append(lagAugmentedCycle(index: i, baseModel: base, phaseLag: phaseLag, eventDelayMilliseconds: eventDelay))
    }
    guard let model = CrossSignalLagAnalyzer.buildModel(cycles: cycles, baseTrajectoryModel: base, definitions: lagDefinitions(for: base), minimumCycles: 6) else {
        Issue.record("Expected cross-signal lag model")
        return
    }
    let phase = model.envelopes.first { $0.definition.kind == LagSignatureKind.phaseLeadLag }
    let event = model.envelopes.first { $0.definition.kind == LagSignatureKind.propagationDelay }
    #expect(phase != nil)
    #expect((phase?.meanLagPhaseFraction ?? 0) > 0.03)
    #expect((phase?.meanLagPhaseFraction ?? 1) < 0.10)
    #expect(abs((event?.meanLagMilliseconds ?? 0) - 42.0) < 3.0)
}

@Test func crossSignalLagFlagsLossOfSynchronizationEvenWhenSignalAmplitudesRemainNormal() {
    guard let base = learnedTrajectoryModel() else {
        Issue.record("Expected trajectory model")
        return
    }
    let cycles = (0..<12).map { lagAugmentedCycle(index: $0, baseModel: base, phaseLag: 0.06, eventDelayMilliseconds: 42) }
    guard let model = CrossSignalLagAnalyzer.buildModel(cycles: cycles, baseTrajectoryModel: base, definitions: lagDefinitions(for: base), minimumCycles: 6) else {
        Issue.record("Expected cross-signal lag model")
        return
    }
    let candidate = lagAugmentedCycle(index: 80, baseModel: base, phaseLag: 0.16, eventDelayMilliseconds: 42)
    let assessment = CrossSignalLagAnalyzer.assess(cycle: candidate, against: model)
    #expect(assessment.status == .anomalousLag || assessment.status == .emergingDesynchronization)
    #expect(assessment.abnormalFindings.contains { $0.envelope.definition.kind == .phaseLeadLag })
    #expect(assessment.summary.contains("synchron"))
}

@Test func propagationDelayCanDegradeWhilePhaseShapeRelationshipStaysHealthy() {
    guard let base = learnedTrajectoryModel() else {
        Issue.record("Expected trajectory model")
        return
    }
    let cycles = (0..<12).map { lagAugmentedCycle(index: $0, baseModel: base, phaseLag: 0.06, eventDelayMilliseconds: 42) }
    guard let model = CrossSignalLagAnalyzer.buildModel(cycles: cycles, baseTrajectoryModel: base, definitions: lagDefinitions(for: base), minimumCycles: 6) else {
        Issue.record("Expected cross-signal lag model")
        return
    }
    let candidate = lagAugmentedCycle(index: 81, baseModel: base, phaseLag: 0.06, eventDelayMilliseconds: 95)
    let assessment = CrossSignalLagAnalyzer.assess(cycle: candidate, against: model)
    let propagation = assessment.findings.first { $0.envelope.definition.kind == .propagationDelay }
    let phase = assessment.findings.first { $0.envelope.definition.kind == .phaseLeadLag }
    #expect(propagation?.abnormal == true)
    #expect(phase?.abnormal == false)
    #expect(propagation?.explanation.contains("causal path") == true)
}

@Test func crossSignalModelDetectsProgressivePhaseLagDriftAcrossCycles() {
    guard let base = learnedTrajectoryModel() else {
        Issue.record("Expected trajectory model")
        return
    }
    let cycles = (0..<12).map { lagAugmentedCycle(index: $0, baseModel: base, phaseLag: 0.03 + Double($0) * 0.006, eventDelayMilliseconds: 42) }
    guard let model = CrossSignalLagAnalyzer.buildModel(cycles: cycles, baseTrajectoryModel: base, definitions: [lagDefinitions(for: base)[0]], minimumCycles: 6),
          let phase = model.envelopes.first else {
        Issue.record("Expected phase lag envelope")
        return
    }
    #expect(phase.isProgressivelyDesynchronizing)
    #expect(phase.lagTrendPerCycle > 0.002)
    #expect(phase.lagTrendRSquared >= 0.60)
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

@Test func dynamicResponseLearnsHealthyDeadTimeRiseGainAndSettling() {
    var cycles: [KnownGoodCycle] = []
    for i in 0..<12 {
        let jitter = i % 3
        let dead = Int64(40 + jitter)
        let tau = 90.0 + Double(jitter - 1) * 3.0
        cycles.append(dynamicResponseCycle(index: i, deadTime: dead, tau: tau, gain: 10))
    }
    guard let model = DynamicResponseAnalyzer.buildModel(cycles: cycles, definitions: [dynamicResponseDefinition], minimumCycles: 6),
          let signature = model.signatures.first else {
        Issue.record("Expected dynamic response model")
        return
    }
    #expect(abs((signature.envelope(DynamicResponseMetric.deadTimeMilliseconds)?.mean ?? 0) - 42) < 12)
    #expect((signature.envelope(DynamicResponseMetric.riseTimeMilliseconds)?.mean ?? 0) > 100)
    #expect(abs((signature.envelope(DynamicResponseMetric.gain)?.mean ?? 0) - 10) < 1)
    #expect((signature.envelope(DynamicResponseMetric.settlingTimeMilliseconds)?.mean ?? 0) > 200)
}

@Test func dynamicResponseSeparatesNormalDeadTimeFromSluggishPressureBuild() {
    let cycles = (0..<12).map { dynamicResponseCycle(index: $0, deadTime: 42, tau: 90 + Double(($0 % 3) - 1) * 2, gain: 10) }
    guard let model = DynamicResponseAnalyzer.buildModel(cycles: cycles, definitions: [dynamicResponseDefinition], minimumCycles: 6) else {
        Issue.record("Expected dynamic response model")
        return
    }
    let candidate = dynamicResponseCycle(index: 80, deadTime: 42, tau: 180, gain: 10)
    let assessment = DynamicResponseAnalyzer.assess(cycle: candidate, against: model)
    let dead = assessment.findings.first { $0.metric == .deadTimeMilliseconds }
    let rise = assessment.findings.first { $0.metric == .riseTimeMilliseconds }
    let settle = assessment.findings.first { $0.metric == .settlingTimeMilliseconds }
    #expect(dead?.abnormal == false)
    #expect(rise?.abnormal == true)
    #expect(settle?.abnormal == true)
    #expect(assessment.status == .degradedResponse || assessment.status == .emergingDegradation)
}

@Test func dynamicResponseDetectsWeakGainDespiteOnTimeResponse() {
    let cycles = (0..<12).map { dynamicResponseCycle(index: $0, deadTime: 42, tau: 90, gain: 10 + Double(($0 % 3) - 1) * 0.1) }
    guard let model = DynamicResponseAnalyzer.buildModel(cycles: cycles, definitions: [dynamicResponseDefinition], minimumCycles: 6) else {
        Issue.record("Expected dynamic response model")
        return
    }
    let candidate = dynamicResponseCycle(index: 81, deadTime: 42, tau: 90, gain: 7.2)
    let assessment = DynamicResponseAnalyzer.assess(cycle: candidate, against: model)
    #expect(assessment.findings.first { $0.metric == .gain }?.abnormal == true)
    #expect(assessment.findings.first { $0.metric == .deadTimeMilliseconds }?.abnormal == false)
}

@Test func dynamicResponseDetectsOvershootAndReducedDamping() {
    let cycles = (0..<12).map { dynamicResponseCycle(index: $0, deadTime: 42, tau: 90, gain: 10, overshootPulse: 0.02) }
    guard let model = DynamicResponseAnalyzer.buildModel(cycles: cycles, definitions: [dynamicResponseDefinition], minimumCycles: 6) else {
        Issue.record("Expected dynamic response model")
        return
    }
    let candidate = dynamicResponseCycle(index: 82, deadTime: 42, tau: 90, gain: 10, overshootPulse: 0.45)
    let assessment = DynamicResponseAnalyzer.assess(cycle: candidate, against: model)
    #expect(assessment.findings.first { $0.metric == .overshootFraction }?.abnormal == true)
    #expect(assessment.findings.first { $0.metric == .dampingRatio }?.abnormal == true)
}

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

@Test func systemIdentificationFitsExplicitFOPDTParameters() {
    let cycles = (0..<10).map { dynamicResponseCycle(index: $0, deadTime: 42, tau: 90, gain: 10) }
    guard let model = SystemIdentificationAnalyzer.buildModel(cycles: cycles, definitions: [systemIdentificationDefinition], minimumCycles: 6),
          let signature = model.signatures.first else {
        Issue.record("Expected FOPDT model")
        return
    }
    #expect(signature.modelKind == .firstOrderPlusDeadTime)
    #expect(abs((signature.envelope(.processGain)?.mean ?? 0) - 10) < 1.0)
    #expect(abs((signature.envelope(.deadTimeMilliseconds)?.mean ?? 0) - 42) < 15)
    #expect(abs((signature.envelope(.timeConstantMilliseconds)?.mean ?? 0) - 90) < 30)
    #expect(signature.meanNormalizedRMSE < 0.12)
}

@Test func systemIdentificationDetectsTimeConstantGrowthWithStableGainAndDelay() {
    let cycles = (0..<12).map { dynamicResponseCycle(index: $0, deadTime: 42, tau: 90 + Double(($0 % 3) - 1) * 2, gain: 10) }
    guard let model = SystemIdentificationAnalyzer.buildModel(cycles: cycles, definitions: [systemIdentificationDefinition], minimumCycles: 6) else {
        Issue.record("Expected FOPDT model")
        return
    }
    let assessment = SystemIdentificationAnalyzer.assess(cycle: dynamicResponseCycle(index: 90, deadTime: 42, tau: 190, gain: 10), against: model)
    #expect(assessment.findings.first { $0.parameter == .timeConstantMilliseconds }?.abnormal == true)
    #expect(assessment.findings.first { $0.parameter == .processGain }?.abnormal == false)
    #expect(assessment.findings.first { $0.parameter == .deadTimeMilliseconds }?.abnormal == false)
    #expect(assessment.interpretations.contains { $0.contains("sluggish") })
}

@Test func systemIdentificationFitsUnderdampedSecondOrderZetaAndNaturalFrequency() {
    let definition = SystemIdentificationDefinition(
        name: "Valve → pressure second-order plant",
        response: DynamicResponseDefinition(
            name: "Valve → pressure second-order response",
            command: LagSignalReference(target: "ValveCmd", layer: .logic),
            response: LagSignalReference(target: "Pressure", layer: .logic),
            commandResultingValue: .bool(true),
            relationshipBasis: .authoredCausalPath,
            responseWindowMilliseconds: 2_000
        ),
        preference: .underdampedSecondOrder
    )
    let cycles = (0..<8).map { secondOrderResponseCycle(index: $0, deadTime: 50, gain: 5, zeta: 0.35, wn: 8) }
    guard let model = SystemIdentificationAnalyzer.buildModel(cycles: cycles, definitions: [definition], minimumCycles: 6), let signature = model.signatures.first else {
        Issue.record("Expected second-order model")
        return
    }
    #expect(signature.modelKind == .underdampedSecondOrder)
    #expect(abs((signature.envelope(.processGain)?.mean ?? 0) - 5) < 0.8)
    #expect(abs((signature.envelope(.dampingRatio)?.mean ?? 0) - 0.35) < 0.15)
    #expect(abs((signature.envelope(.naturalFrequencyRadiansPerSecond)?.mean ?? 0) - 8) < 3.0)
    #expect(signature.meanNormalizedRMSE < 0.15)
}

@Test func systemIdentificationLearnsProgressivePlantTimeConstantDrift() {
    let cycles = (0..<12).map { dynamicResponseCycle(index: $0, deadTime: 42, tau: 70 + Double($0) * 5, gain: 10) }
    guard let model = SystemIdentificationAnalyzer.buildModel(cycles: cycles, definitions: [systemIdentificationDefinition], minimumCycles: 6),
          let tau = model.signatures.first?.envelope(.timeConstantMilliseconds) else {
        Issue.record("Expected time-constant trend")
        return
    }
    #expect(tau.trendPerCycle > 2.0)
    #expect(tau.trendRSquared >= 0.60)
}

@Test func regionalSystemIdentificationUsesLoadedPlantBaselineInsteadOfEmptyPlantDynamics() {
    let context = OperatingContextKey(target: "LoadMode", layer: .logic, aggregation: .final, displayName: "Load")
    let empty = OperatingModeDefinition(name: "Empty", conditions: [.equals(key: context, value: .dint(0))])
    let loaded = OperatingModeDefinition(name: "Loaded", conditions: [.equals(key: context, value: .dint(1))])
    var cycles: [KnownGoodCycle] = []
    for i in 0..<8 {
        cycles.append(addingOperatingMode(dynamicResponseCycle(index: i, deadTime: 35, tau: 65, gain: 11), value: 0))
        cycles.append(addingOperatingMode(dynamicResponseCycle(index: 100 + i, deadTime: 55, tau: 135, gain: 8), value: 1))
    }
    let library = SystemIdentificationAnalyzer.buildRegionalLibrary(cycles: cycles, modeDefinitions: [empty, loaded], definitions: [systemIdentificationDefinition], minimumCyclesPerMode: 6)
    #expect(library.models.count == 2)
    let candidate = addingOperatingMode(dynamicResponseCycle(index: 300, deadTime: 55, tau: 135, gain: 8), value: 1)
    let assessment = SystemIdentificationAnalyzer.assessRegional(cycle: candidate, library: library, modeDefinitions: [empty, loaded])
    #expect(assessment.selectedModeName == "Loaded")
    #expect(assessment.assessment?.status == .healthy)
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

@Test func controllerAwareMarginsEstimateComfortableHealthyLoop() {
    let controller = PIDControllerSettings(proportionalGain: 0.1, integralGainPerSecond: 1.0)
    let margins = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT())
    #expect((margins.phaseMarginDegrees ?? 0) > 55)
    #expect((margins.phaseMarginDegrees ?? 0) < 80)
    #expect(margins.robustness == .balanced || margins.robustness == .conservative)
    #expect((margins.gainCrossoverRadiansPerSecond ?? 0) > 5)
}

@Test func controllerAwareMarginsShowDeadTimeConsumingPhaseMargin() {
    let controller = PIDControllerSettings(proportionalGain: 0.2, integralGainPerSecond: 2.0)
    let healthy = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT(L: 42))
    let delayed = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT(L: 60))
    #expect((healthy.phaseMarginDegrees ?? 0) > 30)
    #expect((delayed.phaseMarginDegrees ?? 180) < 30)
    #expect((delayed.phaseMarginDegrees ?? 180) < (healthy.phaseMarginDegrees ?? 0) - 15)
    #expect(delayed.robustness == .oscillationProne)
}

@Test func controllerAwareMarginsCanCrossInstabilityBoundaryWithoutChangingPID() {
    let controller = PIDControllerSettings(proportionalGain: 0.2, integralGainPerSecond: 2.0)
    let healthy = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT(L: 42))
    let degraded = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT(L: 80))
    #expect((healthy.phaseMarginDegrees ?? 0) > 0)
    #expect((degraded.phaseMarginDegrees ?? 1) < 0)
    #expect(degraded.robustness == .unstable)
}

@Test func controllerAwareMarginsShowHigherPlantGainMakingSameControllerMoreAggressive() {
    let controller = PIDControllerSettings(proportionalGain: 0.1, integralGainPerSecond: 1.0)
    let healthy = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT(K: 10))
    let higherGain = ControllerAwareTuningAnalyzer.margins(controller: controller, plant: identifiedFOPDT(K: 20))
    #expect((higherGain.gainCrossoverRadiansPerSecond ?? 0) > (healthy.gainCrossoverRadiansPerSecond ?? 0))
    #expect((higherGain.phaseMarginDegrees ?? 180) < (healthy.phaseMarginDegrees ?? 0) - 20)
    #expect(higherGain.robustness == .aggressive || higherGain.robustness == .oscillationProne)
}

@Test func controllerAwareReportExplainsYesterdayGoodTuningBecomingUnsafeAfterDelayGrowth() {
    let cycles = (0..<10).map { dynamicResponseCycle(index: 500 + $0, deadTime: 42, tau: 90, gain: 10) }
    guard let healthyModel = SystemIdentificationAnalyzer.buildModel(cycles: cycles, definitions: [systemIdentificationDefinition], minimumCycles: 6) else {
        Issue.record("Expected identified healthy plant")
        return
    }
    let current = SystemIdentificationAnalyzer.assess(cycle: dynamicResponseCycle(index: 700, deadTime: 80, tau: 90, gain: 10), against: healthyModel)
    let definition = ControllerAwareTuningDefinition(
        name: "Pressure PID",
        systemIdentificationSignatureID: systemIdentificationDefinition.id,
        controller: PIDControllerSettings(proportionalGain: 0.2, integralGainPerSecond: 2.0)
    )
    let report = ControllerAwareTuningAnalyzer.assess(current: current, healthyModel: healthyModel, definitions: [definition])
    guard let assessment = report.assessments.first else {
        Issue.record("Expected controller-aware assessment")
        return
    }
    #expect(assessment.vulnerability == .crossedInstabilityBoundary || assessment.vulnerability == .nearOscillation)
    #expect((assessment.phaseMarginChangeDegrees ?? 0) < -20)
    #expect(assessment.interpretations.contains { $0.contains("controller did not change") || $0.contains("Controller did not change") })
    #expect(assessment.interpretations.contains { $0.contains("Dead time increased") })
}

@Test func controllerAwareRegionalAnalysisUsesSelectedOperatingRegimePlantModel() {
    let context = OperatingContextKey(target: "LoadMode", layer: .logic, aggregation: .final, displayName: "Load")
    let empty = OperatingModeDefinition(name: "Empty", conditions: [.equals(key: context, value: .dint(0))])
    let loaded = OperatingModeDefinition(name: "Loaded", conditions: [.equals(key: context, value: .dint(1))])
    var cycles: [KnownGoodCycle] = []
    for i in 0..<8 {
        cycles.append(addingOperatingMode(dynamicResponseCycle(index: 800 + i, deadTime: 35, tau: 65, gain: 11), value: 0))
        cycles.append(addingOperatingMode(dynamicResponseCycle(index: 900 + i, deadTime: 55, tau: 135, gain: 8), value: 1))
    }
    let library = SystemIdentificationAnalyzer.buildRegionalLibrary(cycles: cycles, modeDefinitions: [empty, loaded], definitions: [systemIdentificationDefinition], minimumCyclesPerMode: 6)
    let candidate = addingOperatingMode(dynamicResponseCycle(index: 1000, deadTime: 55, tau: 135, gain: 8), value: 1)
    let regional = SystemIdentificationAnalyzer.assessRegional(cycle: candidate, library: library, modeDefinitions: [empty, loaded])
    let tuning = ControllerAwareTuningDefinition(name: "Pressure PI", systemIdentificationSignatureID: systemIdentificationDefinition.id, controller: .init(proportionalGain: 0.1, integralGainPerSecond: 1.0))
    let report = ControllerAwareTuningAnalyzer.assessRegional(current: regional, library: library, definitions: [tuning])
    #expect(report.summary.contains("Loaded"))
    #expect(report.assessments.count == 1)
}

@Test func sampledPIDDistinguishesIntegralWindupFromLinearInstability() {
    let plant = identifiedFOPDT(K: 1, L: 10, tau: 300)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 4, integralGainPerSecond: 8),
        taskPeriodMilliseconds: 10,
        outputMinimum: 0,
        outputMaximum: 1,
        antiWindupMode: .none
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 2_500))
    #expect(simulation.diagnostics.linearMargins.robustness != .unstable)
    #expect(simulation.diagnostics.saturationFraction > 0.08)
    #expect(simulation.diagnostics.dominantIssue == .integralWindup)
    #expect(simulation.diagnostics.interpretations.contains { $0.contains("integral windup") || $0.contains("Integral state") })
}

@Test func sampledPIDAntiWindupPreventsWindupDiagnosisDuringSameSaturation() {
    let plant = identifiedFOPDT(K: 1, L: 10, tau: 300)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 4, integralGainPerSecond: 8),
        taskPeriodMilliseconds: 10,
        outputMinimum: 0,
        outputMaximum: 1,
        antiWindupMode: .conditionalIntegration
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 2_500))
    #expect(simulation.diagnostics.saturationFraction > 0.08)
    #expect(simulation.diagnostics.dominantIssue != .integralWindup)
    #expect(simulation.diagnostics.interpretations.contains { $0.contains("Anti-windup") })
}

@Test func sampledPIDDetectsActuatorRateLimitWithFeasibleControllerOutput() {
    let plant = identifiedFOPDT(K: 1, L: 10, tau: 400)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 1.2, integralGainPerSecond: 1.5),
        taskPeriodMilliseconds: 10,
        outputMinimum: -10,
        outputMaximum: 10,
        antiWindupMode: .conditionalIntegration,
        actuatorRateLimitPerSecond: 0.25
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 2_000))
    #expect(simulation.diagnostics.saturationFraction < 0.05)
    #expect(simulation.diagnostics.rateLimitFraction > 0.12)
    #expect(simulation.diagnostics.dominantIssue == .actuatorRateLimit)
}

@Test func sampledPIDFlagsTaskPeriodThatIsTooSlowForIdentifiedPlant() {
    let plant = identifiedFOPDT(K: 1, L: 2, tau: 50)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 0.5, integralGainPerSecond: 2),
        taskPeriodMilliseconds: 20,
        outputMinimum: -10,
        outputMaximum: 10
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 1_000))
    #expect((simulation.diagnostics.samplesPerDominantTimeConstant ?? 99) < 5)
    #expect(simulation.diagnostics.dominantIssue == .samplingTooSlow)
    #expect(simulation.diagnostics.interpretations.contains { $0.contains("task period") || $0.contains("coarse") })
}

@Test func sampledPIDKeepsFundamentallyUnstableLinearLoopAsPrimaryDiagnosis() {
    let plant = identifiedFOPDT(K: 10, L: 80, tau: 90)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 0.2, integralGainPerSecond: 2),
        taskPeriodMilliseconds: 5,
        outputMinimum: -100,
        outputMaximum: 100
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 1_000))
    #expect(simulation.diagnostics.linearMargins.robustness == .unstable)
    #expect(simulation.diagnostics.dominantIssue == .linearInstability)
}

@Test func sampledPIDDetectsStictionBreakawayLimitCycleWithHealthyLinearMargins() {
    let plant = identifiedFOPDT(K: 1, L: 10, tau: 350)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 1.2, integralGainPerSecond: 1.8),
        taskPeriodMilliseconds: 10,
        outputMinimum: -5,
        outputMaximum: 5,
        antiWindupMode: .conditionalIntegration,
        actuatorNonlinearity: .init(stictionBreakaway: 0.12)
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 6_000))
    #expect(simulation.diagnostics.linearMargins.robustness != .unstable)
    #expect(simulation.diagnostics.saturationFraction < 0.05)
    #expect(simulation.diagnostics.stuckFraction > 0.08)
    #expect(simulation.diagnostics.breakawayCount >= 2)
    #expect(simulation.diagnostics.dominantIssue == .stiction)
}

@Test func sampledPIDDetectsDeadbandWithoutCallingItStiction() {
    let plant = identifiedFOPDT(K: 1, L: 10, tau: 300)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 1.0, integralGainPerSecond: 1.2),
        taskPeriodMilliseconds: 10,
        outputMinimum: -5,
        outputMaximum: 5,
        actuatorNonlinearity: .init(deadband: 0.08)
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 5_000))
    #expect(simulation.diagnostics.deadbandFraction > 0.08)
    #expect(simulation.diagnostics.breakawayCount == 0)
    #expect(simulation.diagnostics.dominantIssue == .deadband)
}

@Test func sampledPIDTracksBacklashAsLostMotionAfterDirectionReversal() {
    let plant = identifiedFOPDT(K: 1, L: 5, tau: 120)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 2.0, integralGainPerSecond: 4.0),
        taskPeriodMilliseconds: 5,
        outputMinimum: -10,
        outputMaximum: 10,
        actuatorNonlinearity: .init(backlash: 0.12)
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 4_000))
    #expect(simulation.diagnostics.backlashFraction > 0.01)
    #expect(simulation.points.contains(where: { $0.backlashLimited }))
}

@Test func sampledPIDHysteresisProducesDirectionDependentActuatorPath() {
    let plant = identifiedFOPDT(K: 1, L: 5, tau: 120)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 2.2, integralGainPerSecond: 4.5),
        taskPeriodMilliseconds: 5,
        outputMinimum: -10,
        outputMaximum: 10,
        actuatorNonlinearity: .init(hysteresisWidth: 0.10)
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 4_000))
    #expect(simulation.diagnostics.hysteresisFraction > 0.20)
    #expect(simulation.points.contains(where: { $0.hysteresisActive }))
}

@Test func sampledPIDLinearInstabilityStillOutranksActuatorStiction() {
    let plant = identifiedFOPDT(K: 10, L: 80, tau: 90)
    let settings = SampledPIDExecutionSettings(
        controller: .init(proportionalGain: 0.2, integralGainPerSecond: 2),
        taskPeriodMilliseconds: 5,
        outputMinimum: -100,
        outputMaximum: 100,
        actuatorNonlinearity: .init(stictionBreakaway: 0.2, deadband: 0.05)
    )
    let simulation = SampledDataPIDAnalyzer.simulate(settings: settings, plant: plant, scenario: .init(setpointAfterStep: 1, durationMilliseconds: 2_000))
    #expect(simulation.diagnostics.linearMargins.robustness == .unstable)
    #expect(simulation.diagnostics.dominantIssue == .linearInstability)
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

@Test func limitCycleFingerprintMeasuresPeriodAmplitudeAndCommandPositionLag() {
    let simulation = syntheticLimitCycleSimulation(amplitude: 0.25, periodMilliseconds: 1_000)
    let fingerprint = LimitCycleFingerprintAnalyzer.fingerprint(simulation: simulation)
    #expect(fingerprint.sustained)
    #expect(fingerprint.cycleCount >= 5)
    #expect(abs((fingerprint.meanPeriodMilliseconds ?? 0) - 1_000) < 60)
    #expect(abs((fingerprint.meanProcessAmplitude ?? 0) - 0.25) < 0.03)
    #expect((fingerprint.commandToPositionLagFraction ?? -1) >= 0)
    #expect(fingerprint.periodicityScore > 0.8)
}

@Test func limitCycleFingerprintClassifiesStictionFromMeasuredStickBuildReleaseEvidence() {
    let simulation = syntheticLimitCycleSimulation(stiction: true)
    let definition = limitCycleDefinition(settings: simulation.settings)
    let sampled = SampledPIDReport(assessments: [.init(definition: definition, simulation: simulation)], summary: "synthetic")
    let report = LimitCycleFingerprintAnalyzer.assess(report: sampled)
    #expect(report.assessments.first?.rootCause == .stictionDriven)
    #expect((report.assessments.first?.fingerprint.breakawayCount ?? 0) >= 2)
    #expect((report.assessments.first?.fingerprint.integralSawtoothScore ?? 0) > 0.20)
    #expect(report.assessments.first?.evidence.contains { $0.contains("stick-build-release") } == true)
}

@Test func limitCycleFingerprintSeparatesDeadbandHuntingFromStiction() {
    let simulation = syntheticLimitCycleSimulation(deadband: true)
    let definition = limitCycleDefinition(settings: simulation.settings)
    let sampled = SampledPIDReport(assessments: [.init(definition: definition, simulation: simulation)], summary: "synthetic")
    let result = LimitCycleFingerprintAnalyzer.assess(report: sampled).assessments.first
    #expect(result?.rootCause == .deadbandHunting)
    #expect(result?.fingerprint.breakawayCount == 0)
    #expect((result?.fingerprint.deadbandFraction ?? 0) > 0.06)
}

@Test func limitCycleFingerprintSeparatesSaturationDrivenCycleFromAggressiveTuning() {
    let saturated = syntheticLimitCycleSimulation(saturation: true)
    let aggressive = syntheticLimitCycleSimulation(robustness: .aggressive)
    let d1 = limitCycleDefinition(settings: saturated.settings)
    let d2 = SampledPIDDefinition(name: "Aggressive loop", systemIdentificationSignatureID: "synthetic2", settings: aggressive.settings, scenario: aggressive.scenario)
    let report = LimitCycleFingerprintAnalyzer.assess(report: .init(assessments: [.init(definition: d1, simulation: saturated), .init(definition: d2, simulation: aggressive)], summary: "synthetic"))
    #expect(report.assessments.first(where: { $0.definition.name == "Limit-cycle loop" })?.rootCause == .saturationDriven)
    #expect(report.assessments.first(where: { $0.definition.name == "Aggressive loop" })?.rootCause == .aggressiveTuning)
}

@Test func limitCycleConditionDependenceDetectsAmplitudeChangingWithLoad() {
    let observations = [
        LimitCycleOperatingObservation(label: "Light", setpoint: 1, load: 1, simulation: syntheticLimitCycleSimulation(amplitude: 0.10)),
        LimitCycleOperatingObservation(label: "Medium", setpoint: 1, load: 2, simulation: syntheticLimitCycleSimulation(amplitude: 0.20)),
        LimitCycleOperatingObservation(label: "Heavy", setpoint: 1, load: 3, simulation: syntheticLimitCycleSimulation(amplitude: 0.30)),
        LimitCycleOperatingObservation(label: "Very heavy", setpoint: 1, load: 4, simulation: syntheticLimitCycleSimulation(amplitude: 0.40))
    ]
    let dependence = LimitCycleFingerprintAnalyzer.conditionDependence(observations)
    #expect((dependence.amplitudeLoadCorrelation ?? 0) > 0.95)
    #expect(dependence.interpretation.lowercased().contains("load"))
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

@Test func spectralAnalyzerFindsCleanTwoHertzOscillation() {
    let samples = sineSamples(frequencies: [(2.0, 1.0)])
    let fingerprint = SpectralOscillationAnalyzer.fingerprint(samples: samples)
    #expect(abs((fingerprint.dominantFrequencyHz ?? 0) - 2.0) < 0.12)
    #expect(fingerprint.dominantPowerFraction > 0.45)
    #expect(fingerprint.spectralEntropy < 0.45)
}

@Test func spectralAnalyzerDistinguishesBeatingFromSingleFrequencyCycle() {
    let samples = sineSamples(frequencies: [(2.0, 1.0), (2.3, 0.9)], durationSeconds: 20)
    let assessment = SpectralOscillationAnalyzer.assess(primary: samples)
    #expect(assessment.kind == .beating)
    #expect((assessment.fingerprint.beatFrequencyHz ?? 0) > 0.20)
    #expect((assessment.fingerprint.beatFrequencyHz ?? 0) < 0.40)
}

@Test func spectralAnalyzerUsesIndependentMechanicalSpeedEvidenceForResonanceCandidate() {
    let samples = sineSamples(frequencies: [(6.0, 1.0)])
    let assessment = SpectralOscillationAnalyzer.assess(primary: samples, mechanicalSpeedHz: 3.0)
    #expect(assessment.kind == .mechanicalResonance)
    #expect(assessment.evidence.contains(where: { $0.contains("harmonic") }))
}

@Test func spectralAnalyzerCanMatchAuthoredPeriodicDisturbance() {
    let samples = sineSamples(frequencies: [(1.25, 1.0), (4.0, 0.15)])
    let assessment = SpectralOscillationAnalyzer.assess(primary: samples, knownPeriodicDisturbanceHz: 1.25)
    #expect(assessment.kind == .periodicDisturbance)
}

@Test func spectralOperatingDependenceDetectsFrequencyShiftWithOperatingState() {
    let observations = [
        SpectralContextObservation(label: "Low", operatingValue: 1, samples: sineSamples(frequencies: [(1.0, 1.0)])),
        SpectralContextObservation(label: "Medium", operatingValue: 2, samples: sineSamples(frequencies: [(1.5, 1.0)])),
        SpectralContextObservation(label: "High", operatingValue: 3, samples: sineSamples(frequencies: [(2.0, 1.0)])),
        SpectralContextObservation(label: "Very high", operatingValue: 4, samples: sineSamples(frequencies: [(2.5, 1.0)]))
    ]
    let dependence = SpectralOscillationAnalyzer.operatingDependence(observations)
    #expect(dependence.shiftsWithOperatingState)
    #expect((dependence.frequencyOperatingCorrelation ?? 0) > 0.95)
}

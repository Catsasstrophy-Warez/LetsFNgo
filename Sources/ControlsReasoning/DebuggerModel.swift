import Foundation
#if canImport(SwiftUI)
import Observation
#endif
import ControlsPLC

#if canImport(SwiftUI)
@Observable
#endif
@MainActor
public final class DebuggerModel {
    public private(set) var runtime: ControllerRuntime
    public private(set) var session: ControllerDebugSession?
    public private(set) var selectedTask = "MainTask"
    public private(set) var selectedProgram = "Packaging"
    public private(set) var selectedRoutine = "MainRoutine"
    public private(set) var lastStep: ControllerDebugStep?
    public private(set) var history: [WhyEvent] = []
    public private(set) var errorMessage: String?
    public private(set) var watchlist: [String] = []
    public private(set) var trendHistory: [String: [TrendSample]] = [:]
    public private(set) var selectedNodePath: String?
    public private(set) var reasoningAnswer: ReasoningAnswer?
    public private(set) var causalJournal = CausalJournal()
    public private(set) var causalTrail: CausalTrail?
    public private(set) var diagnosticReport: MultiHypothesisReport?
    public private(set) var diagnosticStrategy: DiagnosticStrategy?
    public private(set) var adaptiveSession: AdaptiveTroubleshootingSession?
    public private(set) var adaptiveState: AdaptiveTroubleshootingState?
    public private(set) var diagnosticTopology: DiagnosticTopology
    public private(set) var flightRecorder = ControlsFlightRecorder()
    public private(set) var flightRecorderReport: FlightRecorderReport?
    public private(set) var pulseVisibilityResult: PulseVisibilityResult?
    public private(set) var betweenExecutionsResult: BetweenExecutionsResult?
    public private(set) var knownGoodCycle: KnownGoodCycle?
    public private(set) var sequenceReconstruction: SequenceReconstructionReport?
    public private(set) var healthyCycles: [KnownGoodCycle] = []
    public private(set) var healthyEnvelopeModel: HealthyEnvelopeModel?
    public private(set) var healthyEnvelopeComparison: HealthyEnvelopeComparison?
    public private(set) var multivariateFeatureDefinitions: [MultivariateFeatureDefinition] = []
    public private(set) var multivariateHealthModel: MultivariateHealthModel?
    public private(set) var multivariateHealthAssessment: MultivariateHealthAssessment?
    public private(set) var operatingContextKeys: [OperatingContextKey] = []
    public private(set) var operatingModeDefinitions: [OperatingModeDefinition] = []
    public private(set) var operatingModeHealthLibrary: OperatingModeHealthLibrary?
    public private(set) var operatingModeHealthAssessment: OperatingModeHealthAssessment?
    public private(set) var continuousOperatingStateModel: ContinuousOperatingStateModel?
    public private(set) var continuousOperatingStateAssessment: ContinuousOperatingStateAssessment?
    public private(set) var continuousTransitionAssessment: OperatingTransitionAssessment?
    public private(set) var previousContinuousRegionID: String?
    public private(set) var withinCycleTrajectoryModel: WithinCycleTrajectoryModel?
    public private(set) var withinCycleTrajectoryAssessment: WithinCycleTrajectoryAssessment?
    public private(set) var phaseShapeFeatures: [PhaseShapeFeature] = []
    public private(set) var phaseWarpedTrajectoryModel: PhaseWarpedTrajectoryModel?
    public private(set) var phaseWarpedTrajectoryAssessment: PhaseWarpedTrajectoryAssessment?
    public private(set) var crossSignalLagDefinitions: [CrossSignalLagDefinition] = []
    public private(set) var crossSignalLagModel: CrossSignalLagModel?
    public private(set) var crossSignalLagAssessment: CrossSignalLagAssessment?
    public private(set) var dynamicResponseDefinitions: [DynamicResponseDefinition] = []
    public private(set) var dynamicResponseModel: DynamicResponseModel?
    public private(set) var dynamicResponseAssessment: DynamicResponseAssessment?
    public private(set) var systemIdentificationDefinitions: [SystemIdentificationDefinition] = []
    public private(set) var systemIdentificationModel: SystemIdentificationModel?
    public private(set) var systemIdentificationAssessment: SystemIdentificationAssessment?
    public private(set) var regionalSystemIdentificationLibrary: RegionalSystemIdentificationLibrary?
    public private(set) var regionalSystemIdentificationAssessment: RegionalSystemIdentificationAssessment?
    public private(set) var controllerAwareTuningDefinitions: [ControllerAwareTuningDefinition] = []
    public private(set) var controllerAwareTuningReport: ControllerAwareTuningReport?
    public private(set) var sampledPIDDefinitions: [SampledPIDDefinition] = []
    public private(set) var sampledPIDReport: SampledPIDReport?
    public private(set) var limitCycleReport: LimitCycleReport?
    public private(set) var spectralOscillationReport: SpectralOscillationReport?
    public private(set) var measurementProfiles: [MeasurementProfile]
    private var lastFlightRecordedFault: ControllerFault?
    public var diagnosticStrategyPolicy: DiagnosticStrategyPolicy

    public init(
        project: ControllerProject,
        forces: ForceTable = ForceTable(),
        measurementProfiles: [MeasurementProfile] = [],
        diagnosticStrategyPolicy: DiagnosticStrategyPolicy = DiagnosticStrategyPolicy(),
        diagnosticTopology: DiagnosticTopology = DiagnosticTopology()
    ) {
        runtime = ControllerRuntime(project: project, forces: forces)
        self.measurementProfiles = measurementProfiles
        self.diagnosticStrategyPolicy = diagnosticStrategyPolicy
        self.diagnosticTopology = diagnosticTopology
        if let task = project.tasks.first {
            selectedTask = task.name
            if let program = task.programs.first {
                selectedProgram = program.name
                selectedRoutine = program.mainRoutineName
            }
        }
    }

    public var mode: ControllerMode { runtime.mode }
    public var fault: ControllerFault? { runtime.majorFault }
    public var scanNumber: UInt64 { runtime.controllerScanNumber }
    public var currentRoutine: String { session?.currentRoutineName ?? selectedRoutine }
    public var callStack: [DebugRoutineFrame] { session?.callStack ?? [] }
    public var firstScanActive: Bool { session?.isFirstScan ?? runtime.isFirstScanPending(taskName: selectedTask, programName: selectedProgram) }
    public var lifecycleHistory: [ControllerLifecycleEvent] { runtime.lifecycleHistory }

    public func enterRun() { perform { try runtime.setMode(.run) } }

    public func enterProgram() {
        session = nil
        perform { try runtime.setMode(.program) }
    }

    public func clearFault() {
        runtime.clearFault()
        lastFlightRecordedFault = nil
        errorMessage = nil
    }

    public func beginDebugScan(elapsedMilliseconds: Int32 = 10) {
        perform {
            session = try runtime.beginDebugScan(
                taskName: selectedTask,
                programName: selectedProgram,
                elapsedMilliseconds: elapsedMilliseconds
            )
            sampleWatchlist()
        }
    }

    public func stepRung() {
        if session == nil { beginDebugScan() }
        guard var working = session else { return }
        perform {
            if let step = try runtime.stepDebug(&working) {
                lastStep = step
                selectedRoutine = step.routineName
                history.insert(TraceExplainer.explain(step: step, scanNumber: working.scanNumber), at: 0)
                causalJournal.ingest(step: step, scanNumber: working.scanNumber, stepIndex: working.stepsExecuted)
                flightRecorder.record(taskExecution: TaskExecutionStamp(
                    taskName: step.taskName, programName: step.programName, routineName: step.routineName,
                    rungNumber: step.rungNumber, milliseconds: runtime.clockMilliseconds,
                    scanNumber: working.scanNumber, stepIndex: working.stepsExecuted
                ))
            }
            session = working.isComplete ? nil : working
            sampleWatchlist(from: working.workingTags, scan: working.scanNumber, step: working.stepsExecuted)
            refreshReasoning()
        }
        recordControllerFaultIfPresent()
    }

    public func stepScan(elapsedMilliseconds: Int32 = 10) {
        session = nil
        perform {
            let trace = try runtime.scan(elapsedMilliseconds: elapsedMilliseconds)
            for program in trace.programs {
                for routine in program.routineTraces {
                    for rung in routine.rungs.reversed() {
                        let step = ControllerDebugStep(
                            taskName: program.taskName,
                            programName: program.programName,
                            routineName: routine.routineName,
                            rungNumber: rung.rungNumber,
                            callDepth: 1,
                            trace: rung,
                            nextRoutineName: nil,
                            nextRungNumber: nil
                        )
                        history.insert(TraceExplainer.explain(step: step, scanNumber: trace.scanNumber), at: 0)
                        let flightStepIndex = causalJournal.records.count + 1
                        causalJournal.ingest(step: step, scanNumber: trace.scanNumber, stepIndex: flightStepIndex)
                        flightRecorder.record(taskExecution: TaskExecutionStamp(
                            taskName: step.taskName, programName: step.programName, routineName: step.routineName,
                            rungNumber: step.rungNumber, milliseconds: runtime.clockMilliseconds,
                            scanNumber: trace.scanNumber, stepIndex: flightStepIndex
                        ))
                    }
                }
            }
            sampleWatchlist(scan: trace.scanNumber, step: Int.max)
        }
        recordControllerFaultIfPresent()
    }

    public func setInput(_ tag: String, value: Bool) {
        if let previous = try? currentValue(tag) {
            flightRecorder.record(FlightSignalSample(target: tag, layer: .field, milliseconds: runtime.clockMilliseconds, value: previous, scanNumber: scanNumber))
        }
        flightRecorder.record(FlightSignalSample(target: tag, layer: .field, milliseconds: runtime.clockMilliseconds, value: .bool(value), scanNumber: scanNumber))
        perform {
            guard let taskIndex = runtime.project.tasks.firstIndex(where: { $0.name == selectedTask }),
                  let programIndex = runtime.project.tasks[taskIndex].programs.firstIndex(where: { $0.name == selectedProgram }) else { return }
            if runtime.project.tasks[taskIndex].programs[programIndex].tags.contains(tag) {
                throw DebuggerModelError.editProgramScopedTagNotYetExposed(tag)
            }
            try runtime.setControllerTagValue(tag, to: .bool(value))
            if session != nil { try session?.workingTags.setBool(tag, value) }
        }
    }

    public func setForce(tag: String, value: TagValue, kind: ForceKind, enabled: Bool = true) {
        var forces = runtime.forces
        forces.set(ForceEntry(tag: tag, value: value, kind: kind, enabled: enabled))
        runtime.forces = forces
    }

    public func removeForce(tag: String, kind: ForceKind? = nil) { runtime.forces.remove(tag: tag, kind: kind) }
    public func setForceMaster(_ enabled: Bool) { runtime.forces.masterEnabled = enabled }

    public func toggleWatch(_ target: String) {
        if let index = watchlist.firstIndex(of: target) {
            watchlist.remove(at: index)
        } else {
            watchlist.append(target)
            trendHistory[target] = trendHistory[target] ?? []
            sampleWatchlist()
        }
    }

    public func clearTrends() { trendHistory = Dictionary(uniqueKeysWithValues: watchlist.map { ($0, []) }) }

    public func askWhy(_ question: WhyQuestion, nodePath: String) {
        selectedNodePath = nodePath
        guard let trace = lastStep?.trace else { reasoningAnswer = nil; return }
        reasoningAnswer = PowerReasoner.answer(question: question, nodePath: nodePath, trace: trace)
    }

    /// Cross-rung technician question. Unlike askWhy(_:nodePath:), this follows recorded
    /// destination writes and upstream blockers through earlier rungs/routines.
    public func askWhyTag(_ target: String, shouldBe desiredValue: TagValue) {
        let observed = try? currentValue(target)
        causalTrail = causalJournal.explainWhy(target: target, shouldBe: desiredValue, observedValue: observed)
        diagnosticReport = causalJournal.diagnose(target: target, shouldBe: desiredValue, observedValue: observed)
        if let diagnosticReport {
            diagnosticStrategy = causalJournal.selectDiagnosticStrategy(
                for: diagnosticReport,
                profiles: measurementProfiles,
                policy: diagnosticStrategyPolicy
            )
            adaptiveSession = AdaptiveTroubleshootingSession(
                report: diagnosticReport,
                journal: causalJournal,
                topology: diagnosticTopology,
                profiles: measurementProfiles,
                policy: diagnosticStrategyPolicy
            )
            adaptiveState = adaptiveSession?.currentState()
        }
    }

    public func recordTroubleshootingMeasurement(target: String, value: TagValue, confidence: EvidenceConfidence = .high, condition: MeasurementCondition = .unspecified, note: String? = nil) {
        guard var adaptiveSession else { return }
        adaptiveState = adaptiveSession.recordMeasurement(target: target, value: value, confidence: confidence, condition: condition, note: note)
        self.adaptiveSession = adaptiveSession
        diagnosticStrategy = adaptiveState?.strategy
    }

    public func recordTroubleshootingTemporalObservation(_ observation: TemporalObservation) {
        guard var adaptiveSession else { return }
        adaptiveState = adaptiveSession.recordTemporalObservation(observation)
        self.adaptiveSession = adaptiveSession
    }

    public func recordTroubleshootingEvent(_ event: TemporalEventMarker) {
        guard var adaptiveSession else { return }
        adaptiveState = adaptiveSession.recordEventMarker(event)
        self.adaptiveSession = adaptiveSession
    }

    /// Promotes the debugger's existing watch history into time-domain diagnostic evidence.
    /// This reuses controller timestamps rather than inventing a separate clock for the tutor.
    public func analyzeTrendForTroubleshooting(_ target: String, note: String? = nil) {
        guard let history = trendHistory[target], !history.isEmpty else { return }
        let samples = history.map {
            TimedEvidenceSample(milliseconds: $0.controllerMilliseconds, value: $0.value, confidence: .verified, condition: .simulated)
        }
        recordTroubleshootingTemporalObservation(TemporalObservation(target: target, samples: samples, source: .simulator, note: note))
    }


    public func armFlightRecorder(
        preTriggerMilliseconds: Int64 = 5_000,
        postTriggerMilliseconds: Int64 = 2_000,
        trigger: FlightTriggerCondition = .eventNamed("Controller major fault")
    ) {
        flightRecorder.arm(FlightCaptureConfiguration(
            preTriggerMilliseconds: preTriggerMilliseconds,
            postTriggerMilliseconds: postTriggerMilliseconds,
            trigger: trigger
        ))
        flightRecorderReport = nil
        pulseVisibilityResult = nil
        betweenExecutionsResult = nil
        sequenceReconstruction = nil
    }

    public func triggerFlightRecorderNow(name: String = "Manual trigger") {
        flightRecorder.triggerNow(name: name, milliseconds: runtime.clockMilliseconds)
    }

    public func rearmFlightRecorder() {
        flightRecorder.rearm()
        flightRecorderReport = nil
        pulseVisibilityResult = nil
        betweenExecutionsResult = nil
        sequenceReconstruction = nil
    }

    public func recordFlightSignal(target: String, layer: FlightSignalLayer, milliseconds: Int64, value: TagValue, scanNumber: UInt64? = nil, stepIndex: Int? = nil) {
        flightRecorder.record(FlightSignalSample(target: target, layer: layer, milliseconds: milliseconds, value: value, scanNumber: scanNumber, stepIndex: stepIndex))
    }

    public func recordFlightEvent(_ event: TemporalEventMarker) {
        flightRecorder.record(event: event)
    }

    public func addFlightCausalLink(upstream: String, downstream: String, rationale: String = "Recorded logic dependency") {
        flightRecorder.addCausalLink(FlightCausalLink(upstream: upstream, downstream: downstream, rationale: rationale))
    }

    public func analyzeFlightRecorder(targets: [String]? = nil) {
        flightRecorderReport = flightRecorder.report(targets: targets)
    }

    public func inspectPLCVisibility(ofFieldPulse target: String) {
        pulseVisibilityResult = flightRecorder.plcVisibility(ofFieldPulse: target)
    }

    public func inspectBetweenTaskExecutions(target: String, taskName: String, layer: FlightSignalLayer = .field) {
        betweenExecutionsResult = flightRecorder.changedBetweenTaskExecutions(target: target, taskName: taskName, layer: layer)
    }

    public func setKnownGoodCycle(_ cycle: KnownGoodCycle) {
        knownGoodCycle = cycle
        sequenceReconstruction = nil
    }

    public func addHealthyCycle(_ cycle: KnownGoodCycle) {
        healthyCycles.append(cycle)
        healthyEnvelopeComparison = nil
        multivariateHealthModel = nil
        multivariateHealthAssessment = nil
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
        continuousOperatingStateModel = nil
        continuousOperatingStateAssessment = nil
        continuousTransitionAssessment = nil
        previousContinuousRegionID = nil
    }

    public func addCurrentFrozenToHealthyPopulation(name: String? = nil) {
        guard let capture = flightRecorder.frozenCapture else { return }
        let cycleName = name ?? "Healthy cycle \(healthyCycles.count + 1)"
        healthyCycles.append(KnownGoodCycle(name: cycleName, capture: capture))
        healthyEnvelopeComparison = nil
        multivariateHealthModel = nil
        multivariateHealthAssessment = nil
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
        continuousOperatingStateModel = nil
        continuousOperatingStateAssessment = nil
        continuousTransitionAssessment = nil
        previousContinuousRegionID = nil
    }

    public func buildHealthyEnvelope(
        name: String = "Learned healthy timing",
        minimumSamplesPerEnvelope: Int = 5,
        minimumNormalBandMilliseconds: Int64 = 10,
        driftThresholdMillisecondsPerCycle: Double = 2.0
    ) {
        healthyEnvelopeModel = HealthyCycleAnalyzer.buildModel(
            name: name, cycles: healthyCycles, minimumSamplesPerEnvelope: minimumSamplesPerEnvelope,
            minimumNormalBandMilliseconds: minimumNormalBandMilliseconds,
            driftThresholdMillisecondsPerCycle: driftThresholdMillisecondsPerCycle
        )
        healthyEnvelopeComparison = nil
    }

    public func compareCurrentFrozenToHealthyEnvelope() {
        guard let capture = flightRecorder.frozenCapture, let healthyEnvelopeModel else {
            healthyEnvelopeComparison = nil
            return
        }
        let cycle = KnownGoodCycle(name: "Current capture", capture: capture)
        healthyEnvelopeComparison = HealthyCycleAnalyzer.compare(cycle: cycle, against: healthyEnvelopeModel)
    }

    public func setMultivariateFeatureDefinitions(_ definitions: [MultivariateFeatureDefinition]) {
        multivariateFeatureDefinitions = definitions
        multivariateHealthModel = nil
        multivariateHealthAssessment = nil
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
        continuousOperatingStateModel = nil
        continuousOperatingStateAssessment = nil
        continuousTransitionAssessment = nil
        previousContinuousRegionID = nil
    }

    public func buildMultivariateHealthModel(
        name: String = "Healthy multivariate signature",
        minimumCycles: Int = 8,
        covarianceRegularization: Double = 0.08
    ) {
        multivariateHealthModel = MultivariateDegradationAnalyzer.buildModel(
            name: name,
            cycles: healthyCycles,
            featureDefinitions: multivariateFeatureDefinitions,
            minimumCycles: minimumCycles,
            covarianceRegularization: covarianceRegularization
        )
        multivariateHealthAssessment = nil
    }

    public func assessCurrentFrozenMultivariateHealth() {
        guard let capture = flightRecorder.frozenCapture, let multivariateHealthModel else {
            multivariateHealthAssessment = nil
            return
        }
        multivariateHealthAssessment = MultivariateDegradationAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: multivariateHealthModel
        )
    }

    public func setOperatingContextKeys(_ keys: [OperatingContextKey]) {
        operatingContextKeys = keys
        operatingModeDefinitions = []
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
        continuousOperatingStateModel = nil
        continuousOperatingStateAssessment = nil
        continuousTransitionAssessment = nil
        previousContinuousRegionID = nil
    }

    public func setOperatingModeDefinitions(_ definitions: [OperatingModeDefinition]) {
        operatingModeDefinitions = definitions
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
    }

    public func discoverOperatingModesFromHealthyPopulation() {
        operatingModeDefinitions = OperatingModeHealthAnalyzer.discoverModes(cycles: healthyCycles, keys: operatingContextKeys)
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
    }

    public func buildOperatingModeHealthModels(
        name: String = "Operating-mode health models",
        minimumCyclesPerMode: Int = 8,
        covarianceRegularization: Double = 0.08
    ) {
        operatingModeHealthLibrary = OperatingModeHealthAnalyzer.buildLibrary(
            name: name,
            cycles: healthyCycles,
            modeDefinitions: operatingModeDefinitions,
            healthFeatureDefinitions: multivariateFeatureDefinitions,
            minimumCyclesPerMode: minimumCyclesPerMode,
            covarianceRegularization: covarianceRegularization
        )
        operatingModeHealthAssessment = nil
    }

    public func assessCurrentFrozenOperatingModeHealth() {
        guard let capture = flightRecorder.frozenCapture, let library = operatingModeHealthLibrary else {
            operatingModeHealthAssessment = nil
            return
        }
        operatingModeHealthAssessment = OperatingModeHealthAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: library,
            modeDefinitions: operatingModeDefinitions
        )
    }

    public func buildContinuousOperatingStateModel(
        name: String = "Continuous operating-state model",
        clusterCount: Int? = nil,
        maximumClusters: Int = 5,
        minimumCyclesPerRegion: Int = 8,
        covarianceRegularization: Double = 0.08
    ) {
        continuousOperatingStateModel = ContinuousOperatingStateAnalyzer.buildModel(
            name: name,
            cycles: healthyCycles,
            contextKeys: operatingContextKeys,
            healthFeatureDefinitions: multivariateFeatureDefinitions,
            clusterCount: clusterCount,
            maximumClusters: maximumClusters,
            minimumCyclesPerRegion: minimumCyclesPerRegion,
            covarianceRegularization: covarianceRegularization
        )
        continuousOperatingStateAssessment = nil
        continuousTransitionAssessment = nil
        previousContinuousRegionID = nil
        withinCycleTrajectoryModel = nil
        withinCycleTrajectoryAssessment = nil
        phaseWarpedTrajectoryModel = nil
        phaseWarpedTrajectoryAssessment = nil
    }

    public func assessCurrentFrozenContinuousOperatingStateHealth() {
        guard let capture = flightRecorder.frozenCapture, let model = continuousOperatingStateModel else {
            continuousOperatingStateAssessment = nil
            continuousTransitionAssessment = nil
            return
        }
        let assessment = ContinuousOperatingStateAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: model
        )
        continuousOperatingStateAssessment = assessment
        if let currentRegionID = assessment.selectedRegionID {
            if let previousContinuousRegionID, previousContinuousRegionID != currentRegionID {
                continuousTransitionAssessment = ContinuousOperatingStateAnalyzer.assessTransition(
                    from: previousContinuousRegionID,
                    to: currentRegionID,
                    in: model
                )
            } else {
                continuousTransitionAssessment = nil
            }
            previousContinuousRegionID = currentRegionID
        }
    }


    public func buildWithinCycleTrajectoryModel(
        name: String = "Within-cycle state trajectory model",
        clusterCount: Int? = nil,
        maximumClusters: Int = 7,
        samplingIntervalMilliseconds: Int64 = 20,
        minimumSamplesPerRegion: Int = 12,
        minimumEnvelopeSamples: Int = 6
    ) {
        withinCycleTrajectoryModel = WithinCycleStateTrajectoryAnalyzer.buildModel(
            name: name,
            cycles: healthyCycles,
            contextKeys: operatingContextKeys,
            clusterCount: clusterCount,
            maximumClusters: maximumClusters,
            samplingIntervalMilliseconds: samplingIntervalMilliseconds,
            minimumSamplesPerRegion: minimumSamplesPerRegion,
            minimumEnvelopeSamples: minimumEnvelopeSamples
        )
        withinCycleTrajectoryAssessment = nil
        phaseWarpedTrajectoryModel = nil
        phaseWarpedTrajectoryAssessment = nil
        crossSignalLagModel = nil
        crossSignalLagAssessment = nil
    }

    public func assessCurrentFrozenWithinCycleTrajectory() {
        guard let capture = flightRecorder.frozenCapture, let withinCycleTrajectoryModel else {
            withinCycleTrajectoryAssessment = nil
            return
        }
        withinCycleTrajectoryAssessment = WithinCycleStateTrajectoryAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: withinCycleTrajectoryModel
        )
    }

    public func setPhaseShapeFeatures(_ features: [PhaseShapeFeature]) {
        phaseShapeFeatures = features
        phaseWarpedTrajectoryModel = nil
        phaseWarpedTrajectoryAssessment = nil
    }

    public func buildPhaseWarpedTrajectoryModel(
        name: String = "Phase-warped trajectory model",
        phaseBins: Int = 25,
        minimumCycles: Int = 6
    ) {
        guard let withinCycleTrajectoryModel else {
            phaseWarpedTrajectoryModel = nil
            phaseWarpedTrajectoryAssessment = nil
            return
        }
        let features = phaseShapeFeatures.isEmpty
            ? operatingContextKeys.map { PhaseShapeFeature(target: $0.target, layer: $0.layer, displayName: $0.displayName) }
            : phaseShapeFeatures
        phaseWarpedTrajectoryModel = PhaseWarpedTrajectoryAnalyzer.buildModel(
            name: name,
            cycles: healthyCycles,
            baseTrajectoryModel: withinCycleTrajectoryModel,
            shapeFeatures: features,
            phaseBins: phaseBins,
            minimumCycles: minimumCycles
        )
        phaseWarpedTrajectoryAssessment = nil
    }

    public func assessCurrentFrozenPhaseWarpedTrajectory() {
        guard let capture = flightRecorder.frozenCapture, let phaseWarpedTrajectoryModel else {
            phaseWarpedTrajectoryAssessment = nil
            return
        }
        phaseWarpedTrajectoryAssessment = PhaseWarpedTrajectoryAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: phaseWarpedTrajectoryModel
        )
    }

    public func setCrossSignalLagDefinitions(_ definitions: [CrossSignalLagDefinition]) {
        crossSignalLagDefinitions = definitions
        crossSignalLagModel = nil
        crossSignalLagAssessment = nil
    }

    public func buildCrossSignalLagModel(
        name: String = "Cross-signal phase-lag model",
        phaseBins: Int = 51,
        minimumCycles: Int = 6
    ) {
        guard let withinCycleTrajectoryModel, !crossSignalLagDefinitions.isEmpty else {
            crossSignalLagModel = nil
            crossSignalLagAssessment = nil
            return
        }
        crossSignalLagModel = CrossSignalLagAnalyzer.buildModel(
            name: name,
            cycles: healthyCycles,
            baseTrajectoryModel: withinCycleTrajectoryModel,
            definitions: crossSignalLagDefinitions,
            phaseBins: phaseBins,
            minimumCycles: minimumCycles
        )
        crossSignalLagAssessment = nil
    }

    public func assessCurrentFrozenCrossSignalLag() {
        guard let capture = flightRecorder.frozenCapture, let crossSignalLagModel else {
            crossSignalLagAssessment = nil
            return
        }
        crossSignalLagAssessment = CrossSignalLagAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: crossSignalLagModel
        )
    }

    public func setDynamicResponseDefinitions(_ definitions: [DynamicResponseDefinition]) {
        dynamicResponseDefinitions = definitions
        dynamicResponseModel = nil
        dynamicResponseAssessment = nil
    }

    public func buildDynamicResponseModel(
        name: String = "Dynamic response model",
        minimumCycles: Int = 6
    ) {
        guard !dynamicResponseDefinitions.isEmpty else {
            dynamicResponseModel = nil
            dynamicResponseAssessment = nil
            return
        }
        dynamicResponseModel = DynamicResponseAnalyzer.buildModel(
            name: name,
            cycles: healthyCycles,
            definitions: dynamicResponseDefinitions,
            minimumCycles: minimumCycles
        )
        dynamicResponseAssessment = nil
    }

    public func assessCurrentFrozenDynamicResponse() {
        guard let capture = flightRecorder.frozenCapture, let dynamicResponseModel else {
            dynamicResponseAssessment = nil
            return
        }
        dynamicResponseAssessment = DynamicResponseAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: dynamicResponseModel
        )
    }

    public func setSystemIdentificationDefinitions(_ definitions: [SystemIdentificationDefinition]) {
        systemIdentificationDefinitions = definitions
        systemIdentificationModel = nil
        sampledPIDReport = nil
        systemIdentificationAssessment = nil
        regionalSystemIdentificationLibrary = nil
        regionalSystemIdentificationAssessment = nil
    }

    public func buildSystemIdentificationModel(
        name: String = "Identified plant dynamics",
        minimumCycles: Int = 6
    ) {
        systemIdentificationModel = SystemIdentificationAnalyzer.buildModel(
            name: name, cycles: healthyCycles, definitions: systemIdentificationDefinitions, minimumCycles: minimumCycles
        )
        systemIdentificationAssessment = nil
    }

    public func assessCurrentFrozenSystemIdentification() {
        guard let capture = flightRecorder.frozenCapture, let systemIdentificationModel else {
            systemIdentificationAssessment = nil
            return
        }
        systemIdentificationAssessment = SystemIdentificationAnalyzer.assess(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            against: systemIdentificationModel
        )
    }

    public func buildRegionalSystemIdentificationLibrary(minimumCyclesPerMode: Int = 6) {
        regionalSystemIdentificationLibrary = SystemIdentificationAnalyzer.buildRegionalLibrary(
            cycles: healthyCycles,
            modeDefinitions: operatingModeDefinitions,
            definitions: systemIdentificationDefinitions,
            minimumCyclesPerMode: minimumCyclesPerMode
        )
        regionalSystemIdentificationAssessment = nil
    }

    public func assessCurrentFrozenRegionalSystemIdentification() {
        guard let capture = flightRecorder.frozenCapture, let regionalSystemIdentificationLibrary else {
            regionalSystemIdentificationAssessment = nil
            return
        }
        regionalSystemIdentificationAssessment = SystemIdentificationAnalyzer.assessRegional(
            cycle: KnownGoodCycle(name: "Current capture", capture: capture),
            library: regionalSystemIdentificationLibrary,
            modeDefinitions: operatingModeDefinitions
        )
    }

    public func setControllerAwareTuningDefinitions(_ definitions: [ControllerAwareTuningDefinition]) {
        controllerAwareTuningDefinitions = definitions
        controllerAwareTuningReport = nil
        sampledPIDReport = nil
    }

    public func assessCurrentControllerAwareTuning() {
        if let regionalSystemIdentificationLibrary, let regionalSystemIdentificationAssessment {
            controllerAwareTuningReport = ControllerAwareTuningAnalyzer.assessRegional(
                current: regionalSystemIdentificationAssessment,
                library: regionalSystemIdentificationLibrary,
                definitions: controllerAwareTuningDefinitions
            )
            return
        }
        guard let systemIdentificationModel, let systemIdentificationAssessment else {
            controllerAwareTuningReport = nil
            return
        }
        controllerAwareTuningReport = ControllerAwareTuningAnalyzer.assess(
            current: systemIdentificationAssessment,
            healthyModel: systemIdentificationModel,
            definitions: controllerAwareTuningDefinitions
        )
    }

    public func setSampledPIDDefinitions(_ definitions: [SampledPIDDefinition]) {
        sampledPIDDefinitions = definitions
        sampledPIDReport = nil
        limitCycleReport = nil
        spectralOscillationReport = nil
    }

    public func assessCurrentSampledPIDBehavior() {
        limitCycleReport = nil
        spectralOscillationReport = nil
        if let regionalSystemIdentificationAssessment {
            sampledPIDReport = SampledDataPIDAnalyzer.assessRegional(
                current: regionalSystemIdentificationAssessment,
                definitions: sampledPIDDefinitions
            )
            return
        }
        guard let systemIdentificationAssessment else {
            sampledPIDReport = nil
            return
        }
        sampledPIDReport = SampledDataPIDAnalyzer.assess(
            current: systemIdentificationAssessment,
            definitions: sampledPIDDefinitions
        )
    }

    public func assessCurrentLimitCycleFingerprints() {
        if sampledPIDReport == nil { assessCurrentSampledPIDBehavior() }
        guard let sampledPIDReport else {
            limitCycleReport = nil
            return
        }
        limitCycleReport = LimitCycleFingerprintAnalyzer.assess(report: sampledPIDReport)
        spectralOscillationReport = nil
    }

    public func assessCurrentSpectralOscillations() {
        if sampledPIDReport == nil { assessCurrentSampledPIDBehavior() }
        if limitCycleReport == nil { assessCurrentLimitCycleFingerprints() }
        guard let sampledPIDReport else {
            spectralOscillationReport = nil
            return
        }
        spectralOscillationReport = SpectralOscillationAnalyzer.assess(sampledPIDReport: sampledPIDReport, limitCycleReport: limitCycleReport)
    }

    public func resetContinuousOperatingStateTracking() {
        previousContinuousRegionID = nil
        continuousTransitionAssessment = nil
        continuousOperatingStateAssessment = nil
    }

    public func clearHealthyPopulation() {
        healthyCycles.removeAll(keepingCapacity: true)
        healthyEnvelopeModel = nil
        healthyEnvelopeComparison = nil
        multivariateHealthModel = nil
        multivariateHealthAssessment = nil
        operatingModeHealthLibrary = nil
        operatingModeHealthAssessment = nil
        continuousOperatingStateModel = nil
        continuousOperatingStateAssessment = nil
        continuousTransitionAssessment = nil
        previousContinuousRegionID = nil
        withinCycleTrajectoryModel = nil
        withinCycleTrajectoryAssessment = nil
        phaseWarpedTrajectoryModel = nil
        phaseWarpedTrajectoryAssessment = nil
        crossSignalLagModel = nil
        crossSignalLagAssessment = nil
        dynamicResponseModel = nil
        dynamicResponseAssessment = nil
        systemIdentificationModel = nil
        systemIdentificationAssessment = nil
        regionalSystemIdentificationLibrary = nil
        regionalSystemIdentificationAssessment = nil
        controllerAwareTuningReport = nil
    }

    public func captureCurrentFrozenAsKnownGood(name: String = "Known-good cycle") {
        guard let capture = flightRecorder.frozenCapture else { return }
        knownGoodCycle = KnownGoodCycle(name: name, capture: capture)
        sequenceReconstruction = nil
    }

    public func reconstructPreFaultSequence(toleranceMilliseconds: Int64 = 25, protectiveTargets: Set<String> = []) {
        guard let knownGoodCycle else {
            sequenceReconstruction = nil
            return
        }
        sequenceReconstruction = flightRecorder.reconstructPreFaultSequence(
            against: knownGoodCycle,
            toleranceMilliseconds: toleranceMilliseconds,
            protectiveTargets: protectiveTargets
        )
    }

    public func clearFlightRecorder() {
        flightRecorder.clear()
        flightRecorderReport = nil
        pulseVisibilityResult = nil
        betweenExecutionsResult = nil
        sequenceReconstruction = nil
        healthyEnvelopeComparison = nil
    }

    public func setDiagnosticTopology(_ topology: DiagnosticTopology) {
        diagnosticTopology = topology
        guard let report = diagnosticReport else { return }
        adaptiveSession = AdaptiveTroubleshootingSession(
            report: report,
            journal: causalJournal,
            topology: topology,
            profiles: measurementProfiles,
            policy: diagnosticStrategyPolicy
        )
        adaptiveState = adaptiveSession?.currentState()
        diagnosticStrategy = adaptiveState?.strategy
    }

    public func setMeasurementProfiles(_ profiles: [MeasurementProfile]) {
        measurementProfiles = profiles
        if var adaptiveSession {
            adaptiveSession.profiles = profiles
            self.adaptiveSession = adaptiveSession
            adaptiveState = adaptiveSession.currentState()
            diagnosticStrategy = adaptiveState?.strategy
        } else if let report = diagnosticReport {
            diagnosticStrategy = causalJournal.selectDiagnosticStrategy(for: report, profiles: profiles, policy: diagnosticStrategyPolicy)
        }
    }

    public func setDiagnosticStrategyPolicy(_ policy: DiagnosticStrategyPolicy) {
        diagnosticStrategyPolicy = policy
        if var adaptiveSession {
            adaptiveSession.policy = policy
            self.adaptiveSession = adaptiveSession
            adaptiveState = adaptiveSession.currentState()
            diagnosticStrategy = adaptiveState?.strategy
        } else if let report = diagnosticReport {
            diagnosticStrategy = causalJournal.selectDiagnosticStrategy(for: report, profiles: measurementProfiles, policy: policy)
        }
    }

    public func clearCausalHistory() {
        causalJournal.clear()
        causalTrail = nil
        diagnosticReport = nil
        diagnosticStrategy = nil
        adaptiveSession = nil
        adaptiveState = nil
    }

    public func tagSnapshots() -> [TagSnapshot] {
        let changed = Set(lastStep?.trace.instructions.flatMap(\.changes).map(\.tag) ?? [])
        return runtime.project.controllerTags.allTags.map { tag in
            let inputForce = runtime.forces.activeValue(for: tag.name, kind: .input)
            let outputForce = runtime.forces.activeValue(for: tag.name, kind: .output)
            let configuredForce = runtime.forces.entries.last { $0.tag == tag.name && $0.enabled }
            let raw = tag.value
            let logical: TagValue
            let forced: TagValue?
            let field: TagValue

            switch tag.role {
            case .input:
                logical = inputForce ?? raw
                forced = inputForce
                field = raw
            case .output:
                logical = raw
                forced = outputForce
                field = outputForce ?? raw
            case .internalValue:
                logical = raw
                forced = nil
                field = raw
            }

            return TagSnapshot(
                name: tag.name,
                type: tag.dataType,
                role: tag.role,
                raw: raw,
                logical: logical,
                forced: forced,
                field: field,
                force: configuredForce,
                changedOnLastRung: changed.contains(tag.name),
                watched: watchlist.contains(tag.name)
            )
        }
    }

    public func program() -> ControllerProgram? {
        runtime.project.tasks.first(where: { $0.name == selectedTask })?.programs.first(where: { $0.name == selectedProgram })
    }

    public func currentValue(_ target: String) throws -> TagValue {
        if let session { return try session.workingTags.value(for: target) }
        if let program = program(), program.tags.contains(target) { return try program.tags.value(for: target) }
        return try runtime.project.controllerTags.value(for: target)
    }

    private func refreshReasoning() {
        guard let path = selectedNodePath, let trace = lastStep?.trace, let answer = reasoningAnswer else { return }
        reasoningAnswer = PowerReasoner.answer(question: answer.question, nodePath: path, trace: trace)
    }

    private func sampleWatchlist(from store: TagStore? = nil, scan: UInt64? = nil, step: Int = 0) {
        guard !watchlist.isEmpty else { return }
        for target in watchlist {
            let value: TagValue?
            if let store { value = try? store.value(for: target) }
            else { value = try? currentValue(target) }
            guard let value else { continue }
            let layer = flightLayer(for: target)
            flightRecorder.record(FlightSignalSample(
                target: target, layer: layer, milliseconds: runtime.clockMilliseconds, value: value,
                scanNumber: scan ?? scanNumber, stepIndex: step
            ))
            var samples = trendHistory[target] ?? []
            if samples.last?.value == value && samples.last?.scanNumber == (scan ?? scanNumber) { continue }
            samples.append(TrendSample(
                target: target,
                scanNumber: scan ?? scanNumber,
                stepIndex: step,
                controllerMilliseconds: runtime.clockMilliseconds,
                value: value
            ))
            if samples.count > 500 { samples.removeFirst(samples.count - 500) }
            trendHistory[target] = samples
        }
    }

    private func flightLayer(for target: String) -> FlightSignalLayer {
        if target.contains(".") { return .structuredMember }
        let root = target.split(separator: ".").first.map(String.init) ?? target
        if let tag = runtime.project.controllerTags.allTags.first(where: { $0.name == root }) {
            switch tag.role {
            case .input: return .controllerInput
            case .output: return .controllerOutput
            case .internalValue: return .logic
            }
        }
        return .logic
    }

    private func recordControllerFaultIfPresent() {
        guard let fault = runtime.majorFault, fault != lastFlightRecordedFault else { return }
        lastFlightRecordedFault = fault
        flightRecorder.record(event: TemporalEventMarker(
            name: "Controller major fault",
            milliseconds: runtime.clockMilliseconds,
            note: "\(fault.code.rawValue): \(fault.message)"
        ))
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); errorMessage = nil }
        catch { errorMessage = String(describing: error) }
    }
}

public enum DebuggerModelError: Error, Equatable {
    case editProgramScopedTagNotYetExposed(String)
}

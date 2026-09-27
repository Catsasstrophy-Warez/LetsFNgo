import Foundation
import ControlsPLC
import ControlsSimulation

public enum LearnerActionKind: String, Codable, CaseIterable, Sendable {
    case observedMachine
    case inspectedLadder
    case askedWhy
    case openedTrend
    case openedFlightRecorder
    case openedHealthyComparison
    case openedAdvancedDiagnostic
    case selectedMeasurement
    case enteredMeasurement
    case changedControllerSetting
    case forcedSignal
    case recordedHypothesis
    case proposedDiagnosis
    case performedRepair
    case ranVerification
}

public struct LearnerActionRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let simulationTimeSeconds: Double
    public let simulatedDay: Int
    public let kind: LearnerActionKind
    public let target: String
    public let note: String
    public let informationGain: Double
    public let safetyPenalty: Double
    public let interventionPenalty: Double
    public let supportedByEvidence: Bool

    public init(id: UUID = UUID(), sequence: Int, simulationTimeSeconds: Double, simulatedDay: Int, kind: LearnerActionKind, target: String = "", note: String = "", informationGain: Double = 0, safetyPenalty: Double = 0, interventionPenalty: Double = 0, supportedByEvidence: Bool = true) {
        self.id = id
        self.sequence = sequence
        self.simulationTimeSeconds = simulationTimeSeconds
        self.simulatedDay = simulatedDay
        self.kind = kind
        self.target = target
        self.note = note
        self.informationGain = max(0, min(1, informationGain))
        self.safetyPenalty = max(0, min(1, safetyPenalty))
        self.interventionPenalty = max(0, min(1, interventionPenalty))
        self.supportedByEvidence = supportedByEvidence
    }
}

public struct LearnerActionLog: Equatable, Sendable {
    public private(set) var records: [LearnerActionRecord] = []
    public init() {}
    public mutating func append(time: Double, day: Int, kind: LearnerActionKind, target: String = "", note: String = "", informationGain: Double = 0, safetyPenalty: Double = 0, interventionPenalty: Double = 0, supportedByEvidence: Bool = true) {
        records.append(.init(sequence: records.count + 1, simulationTimeSeconds: time, simulatedDay: day, kind: kind, target: target, note: note, informationGain: informationGain, safetyPenalty: safetyPenalty, interventionPenalty: interventionPenalty, supportedByEvidence: supportedByEvidence))
        if records.count > 1_000 { records.removeFirst(records.count - 1_000) }
    }
}

public struct ScenarioToolAccessPolicy: Equatable, Sendable {
    public let mode: ScenarioRunMode
    public let guidedPath: [GuidedLessonStep]
    public let revealedGuidedStepCount: Int
    public init(session: ScenarioSession) { mode = session.mode; guidedPath = session.machine.guidedPath; revealedGuidedStepCount = session.revealedGuidedStepCount }
    public var unlockedCapabilities: Set<ScenarioDiagnosticCapability> {
        if mode == .technician { return Set(ScenarioDiagnosticCapability.allCases) }
        return Set(guidedPath.prefix(revealedGuidedStepCount).flatMap(\.unlockedCapabilities))
    }
    public func isAvailable(_ capability: ScenarioDiagnosticCapability) -> Bool { unlockedCapabilities.contains(capability) }
    public func whyLocked(_ capability: ScenarioDiagnosticCapability) -> String? {
        guard !isAvailable(capability) else { return nil }
        if let step = guidedPath.first(where: { $0.unlockedCapabilities.contains(capability) }) { return "Unlocks during: \(step.title)." }
        return "This tool is not part of the guided path for this machine."
    }
}

public struct ScenarioScore: Equatable, Sendable {
    public var observationDiscipline: Int
    public var measurementStrategy: Int
    public var evidenceQuality: Int
    public var causalReasoning: Int
    public var safety: Int
    public var interventionDiscipline: Int
    public var verification: Int
    public var overall: Int { [observationDiscipline, measurementStrategy, evidenceQuality, causalReasoning, safety, interventionDiscipline, verification].reduce(0,+) / 7 }
}

public enum ScenarioScoreEngine {
    public static func score(actions: [LearnerActionRecord], diagnosisCorrect: Bool, repairVerified: Bool) -> ScenarioScore {
        let firstIntervention = actions.firstIndex { [.changedControllerSetting, .forcedSignal, .performedRepair].contains($0.kind) }
        let observedBeforeIntervention: Bool = {
            let prefix = firstIntervention.map { Array(actions.prefix($0)) } ?? actions
            return prefix.contains { [.observedMachine, .inspectedLadder, .openedTrend, .openedFlightRecorder, .enteredMeasurement].contains($0.kind) }
        }()
        let measurements = actions.filter { [.selectedMeasurement, .enteredMeasurement].contains($0.kind) }
        let avgGain = measurements.isEmpty ? 0.45 : measurements.map(\.informationGain).reduce(0,+) / Double(measurements.count)
        let unsupported = actions.filter { !$0.supportedByEvidence }.count
        let safetyPenalty = actions.map(\.safetyPenalty).reduce(0,+)
        let interventionPenalty = actions.map(\.interventionPenalty).reduce(0,+)
        let diagnosisIndex = actions.firstIndex { $0.kind == .proposedDiagnosis }
        let hasEvidenceBeforeDiagnosis: Bool = {
            guard let diagnosisIndex else { return false }
            return actions.prefix(diagnosisIndex).contains { [.openedTrend, .openedFlightRecorder, .enteredMeasurement, .openedAdvancedDiagnostic, .inspectedLadder].contains($0.kind) }
        }()
        let verificationDone = actions.contains { $0.kind == .ranVerification } && repairVerified
        func clamp(_ value: Double) -> Int { Int(max(0,min(100,value)).rounded()) }
        return .init(
            observationDiscipline: observedBeforeIntervention ? 95 : 45,
            measurementStrategy: clamp(45 + avgGain * 55),
            evidenceQuality: clamp((hasEvidenceBeforeDiagnosis ? 92 : 55) - Double(unsupported * 12)),
            causalReasoning: diagnosisCorrect ? (hasEvidenceBeforeDiagnosis ? 95 : 76) : 42,
            safety: clamp(100 - safetyPenalty * 40),
            interventionDiscipline: clamp(100 - interventionPenalty * 45),
            verification: verificationDone ? 100 : (repairVerified ? 75 : 35)
        )
    }
}

public struct ScenarioResourceImpact: Equatable, Sendable {
    public var downtimeMinutes: Int = 0
    public var partsCostCredits: Int = 0
    public var unnecessaryInterventions: Int = 0
    public init() {}
}

public struct ScenarioDebrief: Equatable, Sendable {
    public let physicalCause: String
    public let controllerView: String
    public let learnerPath: [String]
    public let strengths: [String]
    public let missedOpportunities: [String]
    public let expertAlternative: [String]
    public let earliestDetectableEvidence: String
    public let resourceImpact: ScenarioResourceImpact
    public let score: ScenarioScore
}

public enum ScenarioDebriefEngine {
    public static func build(session: ScenarioSession, actions: [LearnerActionRecord], diagnosisCorrect: Bool, repairVerified: Bool, resourceImpact: ScenarioResourceImpact = .init()) -> ScenarioDebrief {
        let score = ScenarioScoreEngine.score(actions: actions, diagnosisCorrect: diagnosisCorrect, repairVerified: repairVerified)
        let path = actions.map { "\($0.sequence). \($0.kind.rawValue)" + ($0.target.isEmpty ? "" : " → \($0.target)") }
        var strengths: [String] = []
        var missed: [String] = []
        if score.observationDiscipline >= 80 { strengths.append("Observed machine behavior before intervening.") } else { missed.append("Establish the symptom and controller state before changing the process.") }
        if score.measurementStrategy >= 80 { strengths.append("Selected measurements with strong diagnostic information gain.") } else { missed.append("Prefer checks that eliminate several hypotheses at once.") }
        if score.interventionDiscipline >= 80 { strengths.append("Avoided unnecessary control changes while root cause was unresolved.") } else { missed.append("Avoid tuning or forcing around an unresolved physical fault.") }
        if repairVerified { strengths.append("Ran a post-repair verification instead of stopping at the repair action.") } else { missed.append("Prove that the symptom and mechanism disappear after repair.") }
        let earliest = session.fault.progression.first(where: { $0.severity > 0 && !$0.visibleSymptoms.isEmpty }) ?? session.fault.progression.first!
        let firstEvidenceDay = actions.first(where: { [.openedTrend, .openedFlightRecorder, .openedHealthyComparison, .enteredMeasurement, .openedAdvancedDiagnostic, .inspectedLadder].contains($0.kind) })?.simulatedDay
        if let firstEvidenceDay, firstEvidenceDay > earliest.day {
            missed.append("Useful evidence existed by simulated day \(earliest.day), but the first diagnostic evidence was gathered on day \(firstEvidenceDay).")
        }
        if resourceImpact.unnecessaryInterventions > 0 {
            missed.append("Unnecessary interventions added \(resourceImpact.downtimeMinutes) simulated downtime minutes and \(resourceImpact.partsCostCredits) parts-cost credits.")
        }
        let earliestText = "Day \(earliest.day), \(earliest.label): " + earliest.visibleSymptoms.joined(separator: " ")
        return .init(physicalCause: session.fault.rootMechanism, controllerView: session.currentProgression.visibleSymptoms.isEmpty ? "No visible fault symptom at this progression stage." : session.currentProgression.visibleSymptoms.joined(separator: " "), learnerPath: path, strengths: strengths, missedOpportunities: missed, expertAlternative: session.fault.technicianChecks.enumerated().map { "\($0.offset + 1). \($0.element)" }, earliestDetectableEvidence: earliestText, resourceImpact: resourceImpact, score: score)
    }
}

public enum ScenarioRepairAction: String, Codable, CaseIterable, Sendable {
    case cleanOrAlignPhotoeye
    case replaceOrServicePhotoeye
    case serviceValveOrPositioner
    case restoreProcessDeadTime
    case improvePulseCapture
    case serviceBearingOrDriveTrain
    case restoreSuctionConditions
    case decoupleOrRetuneInteractingLoops
    case serviceAgitatorDrive
    case repairBurnerOrAirflowSystem
    case servicePalletizerVacuum
    case repairLiftStationCheckValve
    case cleanRefrigerationCondenser
    case correctBoilerFuelAirRatio
    case replaceCoolantFilter
    case repairCleanroomLeak
    case serviceCraneEncoder
    case serviceIdentifiedMachineFault
}

public struct PlayableScenarioEngine: Sendable {
    public private(set) var session: ScenarioSession
    public private(set) var runtime: PlayableScenarioRuntime
    public private(set) var actions = LearnerActionLog()
    public private(set) var repairVerified = false
    public private(set) var diagnosisCorrect = false
    public private(set) var repairApplied = false
    public private(set) var resourceImpact = ScenarioResourceImpact()
    public private(set) var transcript: ScenarioTranscript
    public private(set) var variation: ScenarioVariationProfile?

    public init?(session: ScenarioSession) throws {
        let process: HeroProcessModel
        switch session.machine.id {
        case .packagingCell: process = .packaging(.init())
        case .pressureSkid: process = .pressure(.init())
        case .servoConveyor: process = .servo(.init())
        case .pumpStation: process = .pump(.init())
        case .airHandlingUnit: process = .ahu(.init())
        case .batchMixingTank: process = .batch(.init())
        case .industrialOven: process = .oven(.init())
        case .roboticPalletizer: process = .palletizer(.init())
        case .wastewaterLiftStation: process = .liftStation(.init())
        case .refrigerationRack: process = .refrigeration(.init())
        case .boilerSteamPlant: process = .boiler(.init())
        case .cncCoolantCell: process = .cnc(.init())
        case .cleanroomPressureSystem: process = .cleanroom(.init())
        case .asrsCrane: process = .asrs(.init())
        case .bottlingLine, .cipSkid, .compressedAirPlant, .reverseOsmosisPlant, .dataCenterCooling, .parcelSortation, .automotivePaintBooth, .injectionMoldingCell, .crusherConveyor, .grainElevator, .htstPasteurizer, .bioreactor, .chilledWaterPlant, .batteryFormationLine:
            process = .extended(.init(kind: session.machine.id.playableMachineKind!))
        }
        var project = try session.machine.projectFactory()
        if session.machine.id == .packagingCell {
            if project.controllerTags.contains("Start_PB") { try project.controllerTags.setBool("Start_PB", true) }
            if project.controllerTags.contains("Stop_OK") { try project.controllerTags.setBool("Stop_OK", true) }
        }
        self.session = session
        self.transcript = .init(machineID: session.machine.id, faultID: session.fault.id, mode: session.mode, initialSimulatedDay: session.simulatedDay)
        self.runtime = try .init(project: project, process: process, environment: Self.defaultEnvironment(for: session.machine.id), fault: Self.faultInjection(for: session))
    }

    public var toolAccess: ScenarioToolAccessPolicy { .init(session: session) }

    public mutating func applyVariation(_ profile: ScenarioVariationProfile, recordTranscript: Bool = true) {
        variation = profile
        runtime.environment = .init(load: profile.load, speed: profile.speed, ambient: profile.ambient)
        runtime.configureSensorNoise(fraction: profile.sensorNoiseFraction, seed: profile.seed)
        runtime.fault = effectiveFaultInjection()
        if recordTranscript { transcript.variation = profile }
    }

    private func effectiveFaultInjection() -> ScenarioFaultInjection {
        let base = Self.faultInjection(for: session, repaired: repairApplied)
        guard !repairApplied, let variation else { return base }
        let firstAuthoredFaultDay = session.fault.progression.first(where: { $0.severity > 0 })?.day ?? 0
        let relativeDay = session.simulatedDay - variation.faultOnsetDay
        let primarySeverity: Double
        if relativeDay < 0 {
            primarySeverity = 0
        } else {
            let authoredDay = firstAuthoredFaultDay + relativeDay
            primarySeverity = session.fault.progression.last(where: { $0.day <= authoredDay })?.severity ?? 0
        }
        let primaryKind = Self.faultKind(for: session.fault.id)
        var components: [ScenarioFaultComponent] = []
        if primaryKind != .none && primarySeverity > 0 {
            components.append(.init(kind: primaryKind, severity: min(1, primarySeverity * variation.severityScale)))
        }
        components.append(contentsOf: variation.additionalFaults.map { ScenarioFaultComponent(kind: $0.kind, severity: $0.severity) })
        return .init(components: components)
    }

    public mutating func startMachine(recordTranscript: Bool = true) throws {
        switch session.machine.id {
        case .packagingCell:
            if runtime.controllerContainsTag("Start_PB") { try runtime.setControllerTagValue("Start_PB", to: .bool(true)) }
            if runtime.controllerContainsTag("Stop_OK") { try runtime.setControllerTagValue("Stop_OK", to: .bool(true)) }
        default:
            if runtime.controllerContainsTag("AutoMode") { try runtime.setControllerTagValue("AutoMode", to: .bool(true)) }
            if runtime.controllerContainsTag("PermissiveOK") { try runtime.setControllerTagValue("PermissiveOK", to: .bool(true)) }
        }
        record(.observedMachine, target: "startup", note: "Started machine and established live process behavior.", informationGain: 0.25, recordTranscript: false)
        if recordTranscript { transcript.append(.startMachine) }
    }

    public mutating func stopMachine(recordTranscript: Bool = true) throws {
        switch session.machine.id {
        case .packagingCell:
            if runtime.controllerContainsTag("Start_PB") { try runtime.setControllerTagValue("Start_PB", to: .bool(false)) }
        default:
            if runtime.controllerContainsTag("AutoMode") { try runtime.setControllerTagValue("AutoMode", to: .bool(false)) }
        }
        _ = try runtime.step(milliseconds: 10)
        record(.observedMachine, target: "shutdown", note: "Stopped machine and observed controlled shutdown state.", informationGain: 0.15, recordTranscript: false)
        if recordTranscript { transcript.append(.stopMachine) }
    }

    public mutating func run(seconds: Double, stepMilliseconds: Int32 = 10, recordTranscript: Bool = true) throws {
        runtime.fault = effectiveFaultInjection()
        try runtime.run(for: seconds, stepMilliseconds: stepMilliseconds)
        if recordTranscript { transcript.append(.run(seconds: seconds, stepMilliseconds: stepMilliseconds)) }
    }
    public mutating func advance(days: Int, recordTranscript: Bool = true) {
        session.advance(days: days); runtime.fault = effectiveFaultInjection()
        if recordTranscript { transcript.append(.advanceDays(days)) }
    }
    public mutating func revealNextGuidedStep(recordTranscript: Bool = true) {
        session.revealNextGuidedStep()
        if recordTranscript { transcript.append(.revealNextGuidedStep) }
    }
    public mutating func record(_ kind: LearnerActionKind, target: String = "", note: String = "", informationGain: Double = 0, safetyPenalty: Double = 0, interventionPenalty: Double = 0, supportedByEvidence: Bool = true, recordTranscript: Bool = true) {
        actions.append(time: runtime.clock.elapsedSeconds, day: session.simulatedDay, kind: kind, target: target, note: note, informationGain: informationGain, safetyPenalty: safetyPenalty, interventionPenalty: interventionPenalty, supportedByEvidence: supportedByEvidence)
        if recordTranscript { transcript.append(.learnerAction(kind: kind, target: target, note: note, informationGain: informationGain, safetyPenalty: safetyPenalty, interventionPenalty: interventionPenalty, supportedByEvidence: supportedByEvidence)) }
    }
    public mutating func proposeDiagnosis(_ mechanism: String, recordTranscript: Bool = true) {
        let expected = session.fault.rootMechanism.lowercased(); let proposed = mechanism.lowercased()
        let faultAliases: [String: [String]] = [
            "pe203-sticky": ["sticky photoeye", "photoeye stuck", "pe203 stuck", "sensor contamination"],
            "short-pulse": ["short pulse", "missed pulse", "scan timing", "pulse capture"],
            "valve-stiction": ["valve stiction", "stiction", "valve friction", "breakaway"],
            "dead-time-growth": ["dead time", "dead-time", "transport delay", "process delay"],
            "bearing-resonance": ["bearing resonance", "mechanical resonance", "resonance"],
            "cavitation": ["cavitation", "low suction", "npsh"],
            "loop-interaction": ["loop interaction", "interacting loops", "beating"],
            "agitator-drag": ["agitator drag", "mechanical drag", "agitator friction"],
            "burner-disturbance": ["burner disturbance", "airflow disturbance", "periodic disturbance"]
        ]
        let aliasMatch = faultAliases[session.fault.id, default: []].contains { proposed.contains($0) || $0.contains(proposed) }
        diagnosisCorrect = aliasMatch || expected.contains(proposed) || proposed.contains(expected) || expected.split(separator: " ").contains(where: { $0.count > 5 && proposed.contains($0) })
        record(.proposedDiagnosis, target: mechanism, informationGain: 0.8, supportedByEvidence: diagnosisCorrect, recordTranscript: false)
        if recordTranscript { transcript.append(.proposeDiagnosis(mechanism)) }
    }
    public mutating func repair(_ action: ScenarioRepairAction, recordTranscript: Bool = true) {
        let correct: Bool
        switch session.fault.id {
        case "pe203-sticky": correct = action == .cleanOrAlignPhotoeye || action == .replaceOrServicePhotoeye
        case "short-pulse": correct = action == .improvePulseCapture
        case "valve-stiction": correct = action == .serviceValveOrPositioner
        case "dead-time-growth": correct = action == .restoreProcessDeadTime
        case "bearing-resonance": correct = action == .serviceBearingOrDriveTrain
        case "cavitation": correct = action == .restoreSuctionConditions
        case "loop-interaction": correct = action == .decoupleOrRetuneInteractingLoops
        case "agitator-drag": correct = action == .serviceAgitatorDrive
        case "burner-disturbance": correct = action == .repairBurnerOrAirflowSystem
        case "vacuum-loss": correct = action == .servicePalletizerVacuum
        case "check-valve-leak": correct = action == .repairLiftStationCheckValve
        case "condenser-fouling": correct = action == .cleanRefrigerationCondenser
        case "fuel-air-drift": correct = action == .correctBoilerFuelAirRatio
        case "coolant-restriction": correct = action == .replaceCoolantFilter
        case "door-leak": correct = action == .repairCleanroomLeak
        case "encoder-slip": correct = action == .serviceCraneEncoder
        case "fill-valve-drift", "conductivity-drift", "air-leak-growth", "membrane-fouling", "cooling-valve-stiction", "diverter-timing", "filter-loading", "heater-failure", "belt-slip", "bearing-drag", "divert-leak", "oxygen-transfer-loss", "dp-bias", "contact-resistance": correct = action == .serviceIdentifiedMachineFault
        default: correct = false
        }
        repairApplied = correct
        if correct {
            resourceImpact.downtimeMinutes += 30
            resourceImpact.partsCostCredits += Self.repairCost(for: action)
        } else {
            resourceImpact.downtimeMinutes += 45
            resourceImpact.partsCostCredits += Self.repairCost(for: action)
            resourceImpact.unnecessaryInterventions += 1
        }
        record(.performedRepair, target: action.rawValue, informationGain: correct ? 0.9 : 0.1, interventionPenalty: correct ? 0 : 0.8, supportedByEvidence: correct, recordTranscript: false)
        runtime.fault = effectiveFaultInjection()
        if recordTranscript { transcript.append(.repair(action)) }
    }
    public mutating func verify(seconds: Double = 5, recordTranscript: Bool = true) throws {
        let beforeEvents = runtime.eventHistory.count
        try run(seconds: seconds, recordTranscript: false)
        let recent = runtime.eventHistory.dropFirst(min(beforeEvents, runtime.eventHistory.count))
        let faultEventSeen: Bool
        switch session.fault.id {
        case "pe203-sticky": faultEventSeen = recent.contains { $0.name == "PE203 release delayed" }
        case "valve-stiction": faultEventSeen = recent.contains { $0.name == "Valve breakaway" || $0.name == "Valve stuck" }
        case "bearing-resonance": faultEventSeen = recent.contains { $0.name == "Resonance excursion" }
        case "cavitation": faultEventSeen = recent.contains { $0.name == "Cavitation burst" }
        case "loop-interaction": faultEventSeen = recent.contains { $0.name == "Loop beat envelope" }
        case "agitator-drag": faultEventSeen = recent.contains { $0.name == "Mix phase stretching" }
        case "burner-disturbance": faultEventSeen = recent.contains { $0.name == "Periodic airflow disturbance" }
        case "vacuum-loss": faultEventSeen = recent.contains { $0.name == "Grip confirmation lost" }
        case "check-valve-leak": faultEventSeen = recent.contains { $0.name == "Backflow after stop" }
        case "condenser-fouling": faultEventSeen = recent.contains { $0.name == "High head pressure" }
        case "fuel-air-drift": faultEventSeen = recent.contains { $0.name == "Combustion quality degraded" }
        case "coolant-restriction": faultEventSeen = recent.contains { $0.name == "Coolant flow low" }
        case "door-leak": faultEventSeen = recent.contains { $0.name == "Pressure cascade lost" }
        case "encoder-slip": faultEventSeen = recent.contains { $0.name == "Position disagreement" }
        default: faultEventSeen = false
        }
        repairVerified = repairApplied && !faultEventSeen
        record(.ranVerification, target: session.fault.title, informationGain: 1, supportedByEvidence: repairVerified, recordTranscript: false)
        if recordTranscript { transcript.append(.verify(seconds: seconds)) }
    }
    public func debrief() -> ScenarioDebrief { ScenarioDebriefEngine.build(session: session, actions: actions.records, diagnosisCorrect: diagnosisCorrect, repairVerified: repairVerified, resourceImpact: resourceImpact) }

    private static func repairCost(for action: ScenarioRepairAction) -> Int {
        switch action {
        case .cleanOrAlignPhotoeye: 15
        case .replaceOrServicePhotoeye: 80
        case .serviceValveOrPositioner: 160
        case .restoreProcessDeadTime: 120
        case .improvePulseCapture: 90
        case .serviceBearingOrDriveTrain: 240
        case .restoreSuctionConditions: 140
        case .decoupleOrRetuneInteractingLoops: 110
        case .serviceAgitatorDrive: 260
        case .repairBurnerOrAirflowSystem: 220
        case .servicePalletizerVacuum: 180
        case .repairLiftStationCheckValve: 300
        case .cleanRefrigerationCondenser: 140
        case .correctBoilerFuelAirRatio: 210
        case .replaceCoolantFilter: 75
        case .repairCleanroomLeak: 160
        case .serviceCraneEncoder: 260
        case .serviceIdentifiedMachineFault: 200
        }
    }

    private static func defaultEnvironment(for machine: HeroMachineID) -> ScenarioEnvironment {
        switch machine {
        case .packagingCell: .init(load: 0.4, speed: 0.55, ambient: 0.5)
        case .pressureSkid: .init(load: 0.55, speed: 0.5, ambient: 0.5)
        case .servoConveyor: .init(load: 0.75, speed: 0.72, ambient: 0.5)
        case .pumpStation: .init(load: 0.82, speed: 0.65, ambient: 0.5)
        case .airHandlingUnit: .init(load: 0.78, speed: 0.5, ambient: 0.85)
        case .batchMixingTank: .init(load: 0.70, speed: 0.5, ambient: 0.5)
        case .industrialOven: .init(load: 0.70, speed: 0.62, ambient: 0.5)
        case .roboticPalletizer: .init(load: 0.72, speed: 0.70, ambient: 0.5)
        case .wastewaterLiftStation: .init(load: 0.68, speed: 0.5, ambient: 0.55)
        case .refrigerationRack: .init(load: 0.75, speed: 0.5, ambient: 0.82)
        case .boilerSteamPlant: .init(load: 0.72, speed: 0.5, ambient: 0.45)
        case .cncCoolantCell: .init(load: 0.78, speed: 0.6, ambient: 0.5)
        case .cleanroomPressureSystem: .init(load: 0.65, speed: 0.5, ambient: 0.5)
        case .asrsCrane: .init(load: 0.74, speed: 0.72, ambient: 0.5)
        case .bottlingLine, .parcelSortation, .injectionMoldingCell, .crusherConveyor, .grainElevator, .batteryFormationLine: .init(load: 0.68, speed: 0.72, ambient: 0.5)
        case .cipSkid, .reverseOsmosisPlant, .htstPasteurizer, .bioreactor: .init(load: 0.60, speed: 0.58, ambient: 0.5)
        case .compressedAirPlant, .dataCenterCooling, .automotivePaintBooth, .chilledWaterPlant: .init(load: 0.70, speed: 0.55, ambient: 0.65)
        }
    }
    private static func faultKind(for faultID: String) -> PlayableFaultKind {
        switch faultID {
        case "pe203-sticky": .packagingStickyPhotoeye
        case "short-pulse": .packagingShortPulse
        case "valve-stiction": .pressureValveStiction
        case "dead-time-growth": .pressureDeadTimeGrowth
        case "bearing-resonance": .servoBearingResonance
        case "cavitation": .pumpCavitation
        case "loop-interaction": .ahuLoopInteraction
        case "agitator-drag": .batchAgitatorDrag
        case "burner-disturbance": .ovenBurnerDisturbance
        case "vacuum-loss": .palletizerVacuumLoss
        case "check-valve-leak": .liftStationCheckValveLeak
        case "condenser-fouling": .refrigerationCondenserFouling
        case "fuel-air-drift": .boilerFuelAirDrift
        case "coolant-restriction": .cncCoolantRestriction
        case "door-leak": .cleanroomDoorLeak
        case "encoder-slip": .asrsEncoderSlip
        case "fill-valve-drift": .bottlingFillValveDrift
        case "conductivity-drift": .cipConductivityDrift
        case "air-leak-growth": .compressedAirLeakGrowth
        case "membrane-fouling": .roMembraneFouling
        case "cooling-valve-stiction": .dataCenterValveStiction
        case "diverter-timing": .parcelDiverterTimingDrift
        case "filter-loading": .paintBoothFilterLoading
        case "heater-failure": .moldingHeaterFailure
        case "belt-slip": .crusherBeltSlip
        case "bearing-drag": .grainBearingDrag
        case "divert-leak": .pasteurizerDivertLeak
        case "oxygen-transfer-loss": .bioreactorOxygenTransferLoss
        case "dp-bias": .chilledWaterDPBias
        case "contact-resistance": .batteryContactResistance
        default: .none
        }
    }

    private static func faultInjection(for session: ScenarioSession, repaired: Bool = false) -> ScenarioFaultInjection {
        guard !repaired else { return .init() }
        return .init(kind: faultKind(for: session.fault.id), severity: session.currentProgression.severity)
    }
}
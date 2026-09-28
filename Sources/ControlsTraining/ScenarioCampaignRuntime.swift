import Foundation
import ControlsPLC
import ControlsSimulation


public struct ScenarioVariationProfile: Codable, Equatable, Sendable {
    public var seed: UInt64
    public var load: Double
    public var speed: Double
    public var ambient: Double
    public var faultOnsetDay: Int
    public var severityScale: Double
    public var sensorNoiseFraction: Double
    public var additionalFaults: [ScenarioFaultComponentDescriptor]

    public init(seed: UInt64, load: Double, speed: Double, ambient: Double, faultOnsetDay: Int, severityScale: Double = 1, sensorNoiseFraction: Double = 0, additionalFaults: [ScenarioFaultComponentDescriptor] = []) {
        self.seed = seed
        self.load = min(1,max(0,load)); self.speed = min(1,max(0,speed)); self.ambient = min(1,max(0,ambient))
        self.faultOnsetDay = max(0,faultOnsetDay); self.severityScale = min(1.5,max(0.25,severityScale)); self.sensorNoiseFraction = min(0.2,max(0,sensorNoiseFraction))
        self.additionalFaults = additionalFaults
    }
}

public struct ScenarioFaultComponentDescriptor: Codable, Equatable, Sendable {
    public var kind: PlayableFaultKind
    public var severity: Double
    public init(kind: PlayableFaultKind, severity: Double) { self.kind = kind; self.severity = min(1,max(0,severity)) }
}

public struct SeededScenarioRandomizer: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func nextUnit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    public mutating func range(_ low: Double, _ high: Double) -> Double { low + (high-low) * nextUnit() }
    public mutating func integer(_ low: Int, _ high: Int) -> Int { low + Int((Double(high-low+1) * nextUnit()).rounded(.down)) }
}

public struct InstructorScenarioTemplate: Codable, Equatable, Sendable {
    public var title: String
    public var machineID: HeroMachineID
    public var faultID: String
    public var mode: ScenarioRunMode
    public var hideFaultIdentity: Bool
    public var allowCompoundFaults: Bool
    public var onsetDayRange: ClosedRange<Int>
    public var loadRange: ClosedRange<Double>
    public var speedRange: ClosedRange<Double>
    public var ambientRange: ClosedRange<Double>
    public var noiseRange: ClosedRange<Double>

    public init(title: String, machineID: HeroMachineID, faultID: String, mode: ScenarioRunMode = .technician, hideFaultIdentity: Bool = true, allowCompoundFaults: Bool = false, onsetDayRange: ClosedRange<Int> = 0...0, loadRange: ClosedRange<Double> = 0.35...0.85, speedRange: ClosedRange<Double> = 0.35...0.85, ambientRange: ClosedRange<Double> = 0.25...0.85, noiseRange: ClosedRange<Double> = 0...0.02) {
        self.title=title; self.machineID=machineID; self.faultID=faultID; self.mode=mode; self.hideFaultIdentity=hideFaultIdentity; self.allowCompoundFaults=allowCompoundFaults; self.onsetDayRange=onsetDayRange; self.loadRange=loadRange; self.speedRange=speedRange; self.ambientRange=ambientRange; self.noiseRange=noiseRange
    }

    public func instantiate(seed: UInt64, additionalFaults: [ScenarioFaultComponentDescriptor] = []) -> ScenarioVariationProfile {
        var rng = SeededScenarioRandomizer(seed: seed)
        return .init(seed: seed, load: rng.range(loadRange.lowerBound, loadRange.upperBound), speed: rng.range(speedRange.lowerBound, speedRange.upperBound), ambient: rng.range(ambientRange.lowerBound, ambientRange.upperBound), faultOnsetDay: rng.integer(onsetDayRange.lowerBound, onsetDayRange.upperBound), severityScale: rng.range(0.82,1.18), sensorNoiseFraction: rng.range(noiseRange.lowerBound, noiseRange.upperBound), additionalFaults: allowCompoundFaults ? additionalFaults : [])
    }
}

public struct ScenarioExamEnvelope: Equatable, Sendable {
    public let displayTitle: String
    public let machineTitle: String
    public let symptom: String
    public let faultIdentityHidden: Bool
    public init(machine: HeroMachineScenario, fault: HeroFaultScenario, template: InstructorScenarioTemplate) {
        self.displayTitle = template.hideFaultIdentity ? template.title : fault.title
        self.machineTitle = machine.title
        self.symptom = fault.symptom
        self.faultIdentityHidden = template.hideFaultIdentity
    }
}

public enum ScenarioCommand: Codable, Equatable, Sendable {
    case startMachine
    case stopMachine
    case run(seconds: Double, stepMilliseconds: Int32)
    case advanceDays(Int)
    case revealNextGuidedStep
    case learnerAction(kind: LearnerActionKind, target: String, note: String, informationGain: Double, safetyPenalty: Double, interventionPenalty: Double, supportedByEvidence: Bool)
    case proposeDiagnosis(String)
    case repair(ScenarioRepairAction)
    case verify(seconds: Double)
}

public struct ScenarioTranscript: Codable, Equatable, Sendable {
    public let machineID: HeroMachineID
    public let faultID: String
    public let mode: ScenarioRunMode
    public let initialSimulatedDay: Int
    public var variation: ScenarioVariationProfile?
    public private(set) var commands: [ScenarioCommand]

    public init(machineID: HeroMachineID, faultID: String, mode: ScenarioRunMode, initialSimulatedDay: Int = 0, variation: ScenarioVariationProfile? = nil, commands: [ScenarioCommand] = []) {
        self.machineID = machineID
        self.faultID = faultID
        self.mode = mode
        self.initialSimulatedDay = max(0, initialSimulatedDay)
        self.variation = variation
        self.commands = commands
    }

    public mutating func append(_ command: ScenarioCommand) { commands.append(command) }
}

public struct ScenarioReplayResult: Sendable {
    public let engine: PlayableScenarioEngine
    public let debrief: ScenarioDebrief
}

public enum ScenarioReplayEngine {
    public static func replay(_ transcript: ScenarioTranscript) throws -> ScenarioReplayResult {
        guard var session = HeroMachineCatalog.start(machine: transcript.machineID, faultID: transcript.faultID, mode: transcript.mode) else {
            throw ScenarioReplayError.scenarioUnavailable
        }
        if transcript.initialSimulatedDay > 0 { session.advance(days: transcript.initialSimulatedDay) }
        guard var engine = try PlayableScenarioEngine(session: session) else { throw ScenarioReplayError.scenarioUnavailable }
        if let variation = transcript.variation { engine.applyVariation(variation, recordTranscript: false) }
        for command in transcript.commands {
            switch command {
            case .startMachine: try engine.startMachine(recordTranscript: false)
            case .stopMachine: try engine.stopMachine(recordTranscript: false)
            case let .run(seconds, stepMilliseconds): try engine.run(seconds: seconds, stepMilliseconds: stepMilliseconds, recordTranscript: false)
            case let .advanceDays(days): engine.advance(days: days, recordTranscript: false)
            case .revealNextGuidedStep: engine.revealNextGuidedStep(recordTranscript: false)
            case let .learnerAction(kind, target, note, informationGain, safetyPenalty, interventionPenalty, supportedByEvidence):
                engine.record(kind, target: target, note: note, informationGain: informationGain, safetyPenalty: safetyPenalty, interventionPenalty: interventionPenalty, supportedByEvidence: supportedByEvidence, recordTranscript: false)
            case let .proposeDiagnosis(mechanism): engine.proposeDiagnosis(mechanism, recordTranscript: false)
            case let .repair(action): engine.repair(action, recordTranscript: false)
            case let .verify(seconds): try engine.verify(seconds: seconds, recordTranscript: false)
            }
        }
        return .init(engine: engine, debrief: engine.debrief())
    }
}

public enum ScenarioReplayError: Error, Equatable { case scenarioUnavailable }

public enum ScenarioPerformanceBand: String, CaseIterable, Sendable {
    case developing
    case competent
    case proficient
    case expert
}

public struct ScenarioAttemptSummary: Equatable, Sendable {
    public let machineID: HeroMachineID
    public let faultID: String
    public let mode: ScenarioRunMode
    public let score: ScenarioScore
    public let diagnosisCorrect: Bool
    public let repairVerified: Bool
    public let actionCount: Int

    public var performanceBand: ScenarioPerformanceBand {
        if score.overall >= 92 && score.causalReasoning >= 90 && score.evidenceQuality >= 90 && score.verification >= 90 { return .expert }
        if score.overall >= 82 && score.causalReasoning >= 80 && score.safety >= 85 { return .proficient }
        if score.overall >= 68 && diagnosisCorrect { return .competent }
        return .developing
    }

    public init(machineID: HeroMachineID, faultID: String, mode: ScenarioRunMode, score: ScenarioScore, diagnosisCorrect: Bool, repairVerified: Bool, actionCount: Int) {
        self.machineID = machineID
        self.faultID = faultID
        self.mode = mode
        self.score = score
        self.diagnosisCorrect = diagnosisCorrect
        self.repairVerified = repairVerified
        self.actionCount = actionCount
    }

    public init(engine: PlayableScenarioEngine) {
        let debrief = engine.debrief()
        self.init(machineID: engine.session.machine.id, faultID: engine.session.fault.id, mode: engine.session.mode, score: debrief.score, diagnosisCorrect: engine.diagnosisCorrect, repairVerified: engine.repairVerified, actionCount: engine.actions.records.count)
    }
}

public enum CampaignTier: Int, CaseIterable, Comparable, Sendable {
    case foundations = 1
    case processControls = 2
    case predictiveDiagnostics = 3
    case integratedExpert = 4
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct CampaignMission: Identifiable, Equatable, Sendable {
    public let id: String
    public let tier: CampaignTier
    public let machineID: HeroMachineID
    public let faultID: String
    public let recommendedMode: ScenarioRunMode
    public let title: String
    public let learningOutcome: String
    public let minimumOverallScore: Int
    public let requiredDimensions: [CampaignScoreRequirement]
}

public struct CampaignScoreRequirement: Equatable, Sendable {
    public let dimension: CampaignScoreDimension
    public let minimum: Int
    public init(_ dimension: CampaignScoreDimension, minimum: Int) { self.dimension = dimension; self.minimum = minimum }
}

public enum CampaignScoreDimension: String, CaseIterable, Sendable {
    case observation, measurement, evidence, causal, safety, intervention, verification
    public func value(in score: ScenarioScore) -> Int {
        switch self {
        case .observation: score.observationDiscipline
        case .measurement: score.measurementStrategy
        case .evidence: score.evidenceQuality
        case .causal: score.causalReasoning
        case .safety: score.safety
        case .intervention: score.interventionDiscipline
        case .verification: score.verification
        }
    }
}

public struct TechnicianCompetencyProfile: Equatable, Sendable {
    public private(set) var attempts: [ScenarioAttemptSummary] = []
    public init() {}
    public mutating func record(_ attempt: ScenarioAttemptSummary) { attempts.append(attempt) }

    public var strongestDimension: CampaignScoreDimension? { rankedDimensions.first?.dimension }
    public var weakestDimension: CampaignScoreDimension? { rankedDimensions.last?.dimension }
    public var averageOverall: Int { attempts.isEmpty ? 0 : attempts.map(\.score.overall).reduce(0,+) / attempts.count }

    public var rankedDimensions: [(dimension: CampaignScoreDimension, average: Int)] {
        CampaignScoreDimension.allCases.map { dimension in
            let values = attempts.map { dimension.value(in: $0.score) }
            let avg = values.isEmpty ? 0 : values.reduce(0,+) / values.count
            return (dimension, avg)
        }.sorted { $0.average > $1.average }
    }

    public func hasPassed(_ mission: CampaignMission) -> Bool {
        attempts.contains { attempt in
            attempt.machineID == mission.machineID &&
            attempt.faultID == mission.faultID &&
            attempt.diagnosisCorrect &&
            attempt.repairVerified &&
            attempt.score.overall >= mission.minimumOverallScore &&
            mission.requiredDimensions.allSatisfy { $0.dimension.value(in: attempt.score) >= $0.minimum }
        }
    }
}


public struct CampaignReadiness: Equatable, Sendable {
    public let highestUnlockedTier: CampaignTier
    public let independentTechnicianReady: Bool
    public let completedMissionCount: Int
    public let totalMissionCount: Int
    public let weakestDimension: CampaignScoreDimension?
    public let recommendation: String
}

public enum HeroTrainingCampaign {
    public static let missions: [CampaignMission] = [
        .init(id: "packaging-sticky", tier: .foundations, machineID: .packagingCell, faultID: "pe203-sticky", recommendedMode: .guided, title: "Blocked Sequence", learningOutcome: "Trace a physical sensing fault through ladder state logic without parts swapping.", minimumOverallScore: 68, requiredDimensions: [.init(.observation, minimum: 70), .init(.causal, minimum: 70)]),
        .init(id: "packaging-pulse", tier: .foundations, machineID: .packagingCell, faultID: "short-pulse", recommendedMode: .technician, title: "The Pulse the PLC Never Saw", learningOutcome: "Separate physical field events from PLC-observed input state and choose a capture strategy.", minimumOverallScore: 72, requiredDimensions: [.init(.evidence, minimum: 75), .init(.measurement, minimum: 70)]),
        .init(id: "pressure-stiction", tier: .processControls, machineID: .pressureSkid, faultID: "valve-stiction", recommendedMode: .guided, title: "Stable PID, Bad Valve", learningOutcome: "Prove actuator stiction without retuning a healthy controller.", minimumOverallScore: 76, requiredDimensions: [.init(.causal, minimum: 80), .init(.intervention, minimum: 80)]),
        .init(id: "pressure-delay", tier: .processControls, machineID: .pressureSkid, faultID: "dead-time-growth", recommendedMode: .technician, title: "Yesterday's Good Tuning", learningOutcome: "Explain how plant dead-time growth consumes robustness with unchanged PID gains.", minimumOverallScore: 78, requiredDimensions: [.init(.evidence, minimum: 80), .init(.causal, minimum: 80)]),
        .init(id: "servo-resonance", tier: .predictiveDiagnostics, machineID: .servoConveyor, faultID: "bearing-resonance", recommendedMode: .technician, title: "Resonance Under Load", learningOutcome: "Use operating-state and spectral evidence to separate mechanical resonance from control-loop oscillation.", minimumOverallScore: 80, requiredDimensions: [.init(.measurement, minimum: 80), .init(.evidence, minimum: 82)]),
        .init(id: "pump-cavitation", tier: .predictiveDiagnostics, machineID: .pumpStation, faultID: "cavitation", recommendedMode: .technician, title: "Broadband Trouble", learningOutcome: "Recognize hydraulic degradation that is not a clean single-frequency control fault.", minimumOverallScore: 80, requiredDimensions: [.init(.causal, minimum: 82), .init(.safety, minimum: 90)]),
        .init(id: "batch-drag", tier: .predictiveDiagnostics, machineID: .batchMixingTank, faultID: "agitator-drag", recommendedMode: .technician, title: "The Batch Is Still Passing", learningOutcome: "Detect multivariate degradation before a discrete trip appears.", minimumOverallScore: 82, requiredDimensions: [.init(.evidence, minimum: 85), .init(.measurement, minimum: 80)]),
        .init(id: "ahu-interaction", tier: .integratedExpert, machineID: .airHandlingUnit, faultID: "loop-interaction", recommendedMode: .technician, title: "Two Loops, One Beat", learningOutcome: "Discriminate interacting control loops from a single nonlinear limit cycle.", minimumOverallScore: 85, requiredDimensions: [.init(.causal, minimum: 88), .init(.evidence, minimum: 88)]),
        .init(id: "oven-disturbance", tier: .integratedExpert, machineID: .industrialOven, faultID: "burner-disturbance", recommendedMode: .technician, title: "Driven From Outside", learningOutcome: "Prove that a periodic process disturbance is forcing an otherwise stable thermal loop.", minimumOverallScore: 85, requiredDimensions: [.init(.evidence, minimum: 88), .init(.intervention, minimum: 90), .init(.verification, minimum: 90)])
    ]

    public static func unlockedMissions(for profile: TechnicianCompetencyProfile) -> [CampaignMission] {
        let highestUnlockedTier: CampaignTier
        if tierPassed(.predictiveDiagnostics, profile: profile) { highestUnlockedTier = .integratedExpert }
        else if tierPassed(.processControls, profile: profile) { highestUnlockedTier = .predictiveDiagnostics }
        else if tierPassed(.foundations, profile: profile) { highestUnlockedTier = .processControls }
        else { highestUnlockedTier = .foundations }
        return missions.filter { $0.tier <= highestUnlockedTier }
    }

    public static func readiness(for profile: TechnicianCompetencyProfile) -> CampaignReadiness {
        let unlocked = unlockedMissions(for: profile)
        let highest = unlocked.map(\.tier).max() ?? .foundations
        let completed = missions.filter { profile.hasPassed($0) }.count
        let technicianAttempts = profile.attempts.filter { $0.mode == .technician }
        let strongIndependentAttempts = technicianAttempts.filter {
            $0.diagnosisCorrect && $0.repairVerified && $0.score.overall >= 82 && $0.score.causalReasoning >= 80 && $0.score.evidenceQuality >= 80 && $0.score.safety >= 85
        }
        let representedMachines = Set(strongIndependentAttempts.map(\.machineID))
        let independentReady = representedMachines.count >= 4 && tierPassed(.predictiveDiagnostics, profile: profile)
        let recommendation: String
        if independentReady {
            recommendation = "Ready for broad technician-mode practice. Continue rotating machines to avoid overfitting to one fault family."
        } else if let weak = profile.weakestDimension {
            recommendation = "Prioritize missions that exercise \(weak.rawValue) reasoning before unlocking broader independent practice."
        } else {
            recommendation = "Begin with the foundations missions and establish a baseline across the seven scoring dimensions."
        }
        return .init(highestUnlockedTier: highest, independentTechnicianReady: independentReady, completedMissionCount: completed, totalMissionCount: missions.count, weakestDimension: profile.weakestDimension, recommendation: recommendation)
    }

    public static func nextRecommendedMission(for profile: TechnicianCompetencyProfile) -> CampaignMission? {
        let unlocked = unlockedMissions(for: profile)
        if let weak = profile.weakestDimension {
            if let targeted = unlocked.first(where: { !profile.hasPassed($0) && $0.requiredDimensions.contains(where: { $0.dimension == weak }) }) { return targeted }
        }
        return unlocked.first { !profile.hasPassed($0) }
    }

    private static func tierPassed(_ tier: CampaignTier, profile: TechnicianCompetencyProfile) -> Bool {
        let tierMissions = missions.filter { $0.tier == tier }
        guard !tierMissions.isEmpty else { return false }
        return tierMissions.allSatisfy { profile.hasPassed($0) }
    }
}

public struct GeneratedInstructorExam: Sendable {
    public let template: InstructorScenarioTemplate
    public let variation: ScenarioVariationProfile
    public let envelope: ScenarioExamEnvelope
    public let groundTruthFaultID: String

    public func makeEngine() throws -> PlayableScenarioEngine {
        guard let session = HeroMachineCatalog.start(machine: template.machineID, faultID: groundTruthFaultID, mode: template.mode) else { throw ScenarioReplayError.scenarioUnavailable }
        var engine = try PlayableScenarioEngine(session: session)!
        engine.applyVariation(variation)
        return engine
    }
}

public enum InstructorExamGenerator {
    public static func generate(machineID: HeroMachineID, seed: UInt64, mode: ScenarioRunMode = .technician, allowCompoundFaults: Bool = true) throws -> GeneratedInstructorExam {
        guard let machine = HeroMachineCatalog.machine(machineID), !machine.faults.isEmpty else { throw ScenarioReplayError.scenarioUnavailable }
        var rng = SeededScenarioRandomizer(seed: seed)
        let faultIndex = min(machine.faults.count - 1, Int((rng.nextUnit() * Double(machine.faults.count)).rounded(.down)))
        let fault = machine.faults[faultIndex]
        let meaningfulDays = fault.progression.filter { $0.severity > 0 }.map(\.day)
        let lower = meaningfulDays.first ?? 0
        let upper = meaningfulDays.last ?? lower
        let template = InstructorScenarioTemplate(
            title: "Unknown \(machine.title) Fault",
            machineID: machineID,
            faultID: fault.id,
            mode: mode,
            hideFaultIdentity: true,
            allowCompoundFaults: allowCompoundFaults,
            onsetDayRange: lower...upper,
            loadRange: 0.35...0.95,
            speedRange: 0.30...0.95,
            ambientRange: 0.15...0.95,
            noiseRange: 0.002...0.025
        )
        let extras = compatibleSecondaryFaults(machineID: machineID, excluding: fault.id, rng: &rng, enabled: allowCompoundFaults)
        let variation = template.instantiate(seed: seed, additionalFaults: extras)
        return .init(template: template, variation: variation, envelope: .init(machine: machine, fault: fault, template: template), groundTruthFaultID: fault.id)
    }

    private static func compatibleSecondaryFaults(machineID: HeroMachineID, excluding faultID: String, rng: inout SeededScenarioRandomizer, enabled: Bool) -> [ScenarioFaultComponentDescriptor] {
        guard enabled, rng.nextUnit() > 0.68 else { return [] }
        switch machineID {
        case .pressureSkid:
            if faultID == "valve-stiction" { return [.init(kind: .pressureDeadTimeGrowth, severity: rng.range(0.2, 0.55))] }
            if faultID == "dead-time-growth" { return [.init(kind: .pressureValveStiction, severity: rng.range(0.15, 0.45))] }
        case .packagingCell:
            if faultID == "pe203-sticky" { return [.init(kind: .packagingShortPulse, severity: rng.range(0.15, 0.4))] }
            if faultID == "short-pulse" { return [.init(kind: .packagingStickyPhotoeye, severity: rng.range(0.15, 0.35))] }
        default: break
        }
        return []
    }
}

public extension CampaignMission {
    func exam(seed: UInt64) throws -> GeneratedInstructorExam {
        try InstructorExamGenerator.generate(machineID: machineID, seed: seed, mode: recommendedMode == .guided ? .technician : recommendedMode, allowCompoundFaults: tier >= .predictiveDiagnostics)
    }
}

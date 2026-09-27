import Foundation

/// Skills that survive course boundaries and are inferred from evidence across the whole apprenticeship.
public enum LongHorizonCompetency: String, Codable, CaseIterable, Sendable, Identifiable {
    case scanTiming
    case tagsAndDataOwnership
    case instructionSelection
    case rungTopology
    case interlocksAndSequence
    case analogSignalReasoning
    case remoteIOTiming
    case controllerCommunications
    case hmiDataContracts
    case historianEvidence
    case evidenceStrategy
    case causalTroubleshooting
    case safetyDiscipline
    case verificationDiscipline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scanTiming: "PLC scan & event timing"
        case .tagsAndDataOwnership: "Tags, types & data ownership"
        case .instructionSelection: "Instruction selection"
        case .rungTopology: "Rung topology"
        case .interlocksAndSequence: "Interlocks & sequence state"
        case .analogSignalReasoning: "Analog signal reasoning"
        case .remoteIOTiming: "Remote-I/O timing"
        case .controllerCommunications: "Controller communications"
        case .hmiDataContracts: "HMI / SCADA data contracts"
        case .historianEvidence: "Historian evidence"
        case .evidenceStrategy: "Evidence strategy"
        case .causalTroubleshooting: "Causal troubleshooting"
        case .safetyDiscipline: "Safety discipline"
        case .verificationDiscipline: "Verification discipline"
        }
    }

    /// Number of substantial learning activities required to halve confidence without fresh evidence.
    public var activityHalfLife: Double {
        switch self {
        case .remoteIOTiming, .scanTiming: 3
        case .controllerCommunications, .historianEvidence, .hmiDataContracts: 4
        case .instructionSelection, .analogSignalReasoning, .interlocksAndSequence: 5
        case .rungTopology, .tagsAndDataOwnership: 6
        case .evidenceStrategy, .causalTroubleshooting, .safetyDiscipline, .verificationDiscipline: 7
        }
    }
}

public enum CompetencyEvidenceSource: String, Codable, Sendable {
    case chapterCertification
    case heroMachineCampaign
    case fieldAssignment
    case apprenticeshipWork
}

public enum CompetencyEvidenceMode: String, Codable, Sendable {
    case guided
    case independent

    var credibility: Double { self == .independent ? 1 : 0.84 }
}

public struct CompetencyEvidence: Codable, Equatable, Sendable {
    public let competency: LongHorizonCompetency
    public let score: Double

    public init(_ competency: LongHorizonCompetency, score: Double) {
        self.competency = competency
        self.score = min(1, max(0, score))
    }
}

public struct CompetencyEvidenceEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let activityIndex: Int
    public let occurredAt: Date
    public let source: CompetencyEvidenceSource
    public let sourceID: String
    public let contextLabel: String
    public let contextMachineID: HeroMachineID?
    public let mode: CompetencyEvidenceMode
    public let evidence: [CompetencyEvidence]

    public init(
        id: String,
        activityIndex: Int,
        occurredAt: Date,
        source: CompetencyEvidenceSource,
        sourceID: String,
        contextLabel: String,
        contextMachineID: HeroMachineID? = nil,
        mode: CompetencyEvidenceMode,
        evidence: [CompetencyEvidence]
    ) {
        self.id = id
        self.activityIndex = max(1, activityIndex)
        self.occurredAt = occurredAt
        self.source = source
        self.sourceID = sourceID
        self.contextLabel = contextLabel
        self.contextMachineID = contextMachineID
        self.mode = mode
        self.evidence = evidence
    }
}

public enum CompetencyFreshness: String, Codable, Sendable {
    case unobserved
    case current
    case aging
    case dueForTransfer
    case decayed
}

public struct CompetencyAssessment: Equatable, Sendable {
    public let competency: LongHorizonCompetency
    public let bestDemonstratedScore: Double
    public let retainedConfidence: Double
    public let activitiesSinceEvidence: Int?
    public let lastContext: String?
    public let freshness: CompetencyFreshness

    public var wasPreviouslyStrong: Bool { bestDemonstratedScore >= 0.75 }
    public var needsEmbeddedRetrieval: Bool {
        wasPreviouslyStrong && (freshness == .dueForTransfer || freshness == .decayed)
    }

    public var narrative: String {
        guard let gap = activitiesSinceEvidence, let lastContext else {
            return "No verified evidence for \(competency.title.lowercased()) yet."
        }
        if needsEmbeddedRetrieval {
            let activityWord = gap == 1 ? "activity" : "activities"
            return "You were strong on \(competency.title.lowercased()) in \(lastContext), but haven’t demonstrated it in \(gap) learning \(activityWord)."
        }
        if freshness == .aging {
            return "\(competency.title) was last demonstrated in \(lastContext) and is beginning to age."
        }
        return "\(competency.title) is supported by recent evidence from \(lastContext)."
    }
}

public struct FieldAssignmentOutcome: Equatable, Sendable {
    public let assignmentID: String
    public let scores: [LongHorizonCompetency: Double]
    public let independentlyCompleted: Bool

    public init(assignmentID: String, scores: [LongHorizonCompetency: Double], independentlyCompleted: Bool = true) {
        self.assignmentID = assignmentID
        self.scores = scores
        self.independentlyCompleted = independentlyCompleted
    }
}

public enum DiagnosticMisconception: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case guessedWithoutEvidence
    case singlePointDiagnosis
    case controllerBlameBeforeBoundaryCheck
    case fieldDeviceAssumption
    case timingBlindSpot
    case interventionBeforeEvidence
    case verificationWithoutFreshEvidence

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .guessedWithoutEvidence: "Diagnosis by recognition instead of proof"
        case .singlePointDiagnosis: "Single-point evidence treated as conclusive"
        case .controllerBlameBeforeBoundaryCheck: "Controller blamed before checking the I/O boundary"
        case .fieldDeviceAssumption: "Field state assumed instead of measured"
        case .timingBlindSpot: "Update and task timing treated as simultaneous"
        case .interventionBeforeEvidence: "Intervention started before the mechanism was isolated"
        case .verificationWithoutFreshEvidence: "Repair accepted without fresh post-repair evidence"
        }
    }
}

public struct DiagnosticProofRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let activityIndex: Int
    public let occurredAt: Date
    public let machineID: HeroMachineID
    public let contextLabel: String
    public let hypothesis: String?
    public let measuredTargets: [String]
    public let qualityScore: Double
    public let diagnosisSupported: Bool
    public let repairVerified: Bool
    public let misconceptions: [DiagnosticMisconception]
    public let supervisorFeedback: String

    public init(id: String, activityIndex: Int = 0, occurredAt: Date = Date(), machineID: HeroMachineID, contextLabel: String, hypothesis: String?, measuredTargets: [String], qualityScore: Double, diagnosisSupported: Bool, repairVerified: Bool, misconceptions: [DiagnosticMisconception], supervisorFeedback: String) {
        self.id = id
        self.activityIndex = max(0, activityIndex)
        self.occurredAt = occurredAt
        self.machineID = machineID
        self.contextLabel = contextLabel
        self.hypothesis = hypothesis
        self.measuredTargets = measuredTargets
        self.qualityScore = min(1, max(0, qualityScore))
        self.diagnosisSupported = diagnosisSupported
        self.repairVerified = repairVerified
        self.misconceptions = Array(Set(misconceptions)).sorted { $0.rawValue < $1.rawValue }
        self.supervisorFeedback = supervisorFeedback
    }

    func assigned(to activityIndex: Int) -> Self {
        .init(id: id, activityIndex: activityIndex, occurredAt: occurredAt, machineID: machineID, contextLabel: contextLabel, hypothesis: hypothesis, measuredTargets: measuredTargets, qualityScore: qualityScore, diagnosisSupported: diagnosisSupported, repairVerified: repairVerified, misconceptions: misconceptions, supervisorFeedback: supervisorFeedback)
    }
}

public struct MisconceptionMemoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let misconception: DiagnosticMisconception
    public private(set) var observations: Int
    public private(set) var successfulDisconfirmations: Int
    public private(set) var lastActivityIndex: Int

    public var id: String { misconception.rawValue }
    public var likelihood: Double { Double(observations + 1) / Double(observations + successfulDisconfirmations + 2) }
    public var isActive: Bool { observations > successfulDisconfirmations && likelihood >= 0.5 }

    public init(misconception: DiagnosticMisconception, observations: Int = 0, successfulDisconfirmations: Int = 0, lastActivityIndex: Int = 0) {
        self.misconception = misconception
        self.observations = max(0, observations)
        self.successfulDisconfirmations = max(0, successfulDisconfirmations)
        self.lastActivityIndex = max(0, lastActivityIndex)
    }

    mutating func observe(at activityIndex: Int) { observations += 1; lastActivityIndex = activityIndex }
    mutating func disconfirm(at activityIndex: Int) { successfulDisconfirmations += 1; lastActivityIndex = activityIndex }
}

public enum DiagnosticProofEvaluator {
    public static func evaluate(
        machineID: HeroMachineID,
        contextLabel: String,
        actions: [LearnerActionRecord],
        diagnosisCorrect: Bool,
        repairVerified: Bool,
        embeddedChallenge: EmbeddedCompetencyChallenge? = nil,
        occurredAt: Date = Date()
    ) -> DiagnosticProofRecord {
        let claimIndex = actions.lastIndex { $0.kind == .recordedHypothesis } ?? actions.lastIndex { $0.kind == .proposedDiagnosis }
        let claim = claimIndex.map { actions[$0] }
        let diagnosticPrefix = claimIndex.map { Array(actions.prefix($0)) } ?? actions
        let measurements = diagnosticPrefix.filter { [.enteredMeasurement, .selectedMeasurement, .openedTrend, .openedFlightRecorder, .inspectedLadder, .openedAdvancedDiagnostic].contains($0.kind) }
        let measuredTargets = Array(Set(measurements.map(\.target).filter { !$0.isEmpty })).sorted()
        let firstIntervention = actions.firstIndex { [.changedControllerSetting, .forcedSignal, .performedRepair].contains($0.kind) }
        let intervenedBeforeClaim = firstIntervention.map { claimIndex == nil || $0 < claimIndex! } ?? false
        let verificationIndex = actions.lastIndex { $0.kind == .ranVerification }
        let freshPostRepairEvidence: Bool = {
            guard let repairIndex = actions.lastIndex(where: { $0.kind == .performedRepair }), let verificationIndex, verificationIndex > repairIndex else { return false }
            return actions[(repairIndex + 1)..<verificationIndex].contains { [.enteredMeasurement, .openedTrend, .openedFlightRecorder, .openedAdvancedDiagnostic].contains($0.kind) }
        }()

        let isRemoteTiming: Bool = {
            guard let embeddedChallenge else { return false }
            if case .remoteIOTiming = embeddedChallenge.kind { return true }
            return false
        }()
        let measuredField = measuredTargets.contains { $0.hasSuffix("_Field") }
        let measuredController = measuredTargets.contains { $0.hasSuffix("_PLC") }
        let measuredTiming = measuredTargets.contains { $0.hasPrefix("RemoteIO_") }
        let claimSupported = claim?.supportedByEvidence ?? diagnosisCorrect

        var misconceptions: [DiagnosticMisconception] = []
        if measurements.count < 1 { misconceptions.append(.guessedWithoutEvidence) }
        if measuredTargets.count < 2 { misconceptions.append(.singlePointDiagnosis) }
        if intervenedBeforeClaim { misconceptions.append(.interventionBeforeEvidence) }
        if !freshPostRepairEvidence { misconceptions.append(.verificationWithoutFreshEvidence) }
        if isRemoteTiming {
            if claim?.target.localizedCaseInsensitiveContains("controller program") == true { misconceptions.append(.controllerBlameBeforeBoundaryCheck) }
            if claim?.target.localizedCaseInsensitiveContains("field device never") == true { misconceptions.append(.fieldDeviceAssumption) }
            if !(measuredField && measuredController && measuredTiming && claimSupported) { misconceptions.append(.timingBlindSpot) }
        }

        let breadth = min(1, Double(measuredTargets.count) / 3)
        let boundaryProof = isRemoteTiming ? ((measuredField && measuredController && measuredTiming) ? 1.0 : 0.0) : (measuredTargets.count >= 2 ? 1.0 : 0.0)
        let score = 0.30 * breadth + 0.25 * (claimSupported ? 1 : 0) + 0.20 * boundaryProof + 0.10 * (intervenedBeforeClaim ? 0 : 1) + 0.15 * (freshPostRepairEvidence && repairVerified ? 1 : 0)
        let feedback: String
        if score >= 0.82 && misconceptions.isEmpty {
            feedback = "The repair is supported by a cross-boundary evidence chain and fresh post-repair proof."
        } else if !claimSupported {
            feedback = "The repair may be correct, but the recorded claim was not supported by the evidence gathered."
        } else if !freshPostRepairEvidence {
            feedback = "Correct repair, but capture fresh process evidence after the intervention before returning the machine to service."
        } else if measuredTargets.count < 2 {
            feedback = "One observation is not a diagnostic chain. Compare evidence across at least two causal boundaries."
        } else {
            feedback = "The result is plausible, but the proof chain has gaps. Isolate the mechanism before treating success as mastery."
        }
        return .init(
            id: "proof-\(machineID.rawValue)-\(Int(occurredAt.timeIntervalSince1970 * 1_000))",
            occurredAt: occurredAt,
            machineID: machineID,
            contextLabel: contextLabel,
            hypothesis: claim?.target,
            measuredTargets: measuredTargets,
            qualityScore: score,
            diagnosisSupported: claimSupported,
            repairVerified: repairVerified,
            misconceptions: misconceptions,
            supervisorFeedback: feedback
        )
    }
}

public struct LongHorizonCompetencyHistory: Codable, Equatable, Sendable {
    public private(set) var events: [CompetencyEvidenceEvent]
    public private(set) var diagnosticProofs: [DiagnosticProofRecord]?
    public private(set) var misconceptionMemory: [MisconceptionMemoryEntry]?

    public init(events: [CompetencyEvidenceEvent] = [], diagnosticProofs: [DiagnosticProofRecord]? = nil, misconceptionMemory: [MisconceptionMemoryEntry]? = nil) {
        self.events = events.sorted { $0.activityIndex < $1.activityIndex }
        self.diagnosticProofs = diagnosticProofs
        self.misconceptionMemory = misconceptionMemory
    }

    public var proofRecords: [DiagnosticProofRecord] { diagnosticProofs ?? [] }
    public var activeMisconceptions: [MisconceptionMemoryEntry] {
        (misconceptionMemory ?? []).filter(\.isActive).sorted {
            if $0.likelihood == $1.likelihood { return $0.misconception.rawValue < $1.misconception.rawValue }
            return $0.likelihood > $1.likelihood
        }
    }

    public var currentActivityIndex: Int { events.map(\.activityIndex).max() ?? 0 }

    public mutating func record(
        source: CompetencyEvidenceSource,
        sourceID: String,
        contextLabel: String,
        contextMachineID: HeroMachineID? = nil,
        mode: CompetencyEvidenceMode,
        evidence: [CompetencyEvidence],
        occurredAt: Date = Date()
    ) {
        let merged = Dictionary(grouping: evidence, by: \.competency).map { competency, values in
            CompetencyEvidence(competency, score: values.map(\.score).max() ?? 0)
        }.sorted { $0.competency.rawValue < $1.competency.rawValue }
        guard !merged.isEmpty else { return }
        let index = currentActivityIndex + 1
        events.append(.init(
            id: "\(source.rawValue)-\(sourceID)-\(index)",
            activityIndex: index,
            occurredAt: occurredAt,
            source: source,
            sourceID: sourceID,
            contextLabel: contextLabel,
            contextMachineID: contextMachineID,
            mode: mode,
            evidence: merged
        ))
    }

    public mutating func recordChapterCertification(_ result: ChapterCertificationResult, occurredAt: Date = Date()) {
        var evidence: [CompetencyEvidence] = []
        for (skill, score) in result.skillScores {
            for competency in Self.competencies(for: skill, chapter: result.chapter) {
                evidence.append(.init(competency, score: score))
            }
        }
        let normalizedOverall = min(1, max(0, result.score / 100))
        if evidence.isEmpty {
            for competency in Self.chapterCompetencies(result.chapter) {
                evidence.append(.init(competency, score: normalizedOverall))
            }
        }
        evidence.append(.init(.verificationDiscipline, score: result.verificationPerformed ? max(0.75, normalizedOverall) : 0.25))
        record(
            source: .chapterCertification,
            sourceID: result.examID,
            contextLabel: "Chapter \(result.chapter.rawValue) · \(result.chapter.title)",
            mode: .independent,
            evidence: evidence,
            occurredAt: occurredAt
        )
    }

    public mutating func recordScenarioAttempt(_ attempt: ScenarioAttemptSummary, occurredAt: Date = Date()) {
        let score = attempt.score
        var evidence: [CompetencyEvidence] = [
            .init(.evidenceStrategy, score: Double(score.evidenceQuality) / 100),
            .init(.causalTroubleshooting, score: Double(score.causalReasoning) / 100),
            .init(.safetyDiscipline, score: Double(score.safety) / 100),
            .init(.verificationDiscipline, score: Double(score.verification) / 100)
        ]
        evidence.append(contentsOf: Self.scenarioSpecificEvidence(attempt))
        let machineTitle = HeroMachineCatalog.machine(attempt.machineID)?.title ?? attempt.machineID.rawValue
        record(
            source: .heroMachineCampaign,
            sourceID: "\(attempt.machineID.rawValue)-\(attempt.faultID)",
            contextLabel: machineTitle,
            contextMachineID: attempt.machineID,
            mode: attempt.mode == .technician ? .independent : .guided,
            evidence: evidence,
            occurredAt: occurredAt
        )
    }

    public mutating func recordFieldAssignment(_ outcome: FieldAssignmentOutcome, occurredAt: Date = Date()) {
        guard let assignment = ScenarioFieldAssignmentCatalog.all.first(where: { $0.id == outcome.assignmentID }) else { return }
        record(
            source: .fieldAssignment,
            sourceID: assignment.id,
            contextLabel: assignment.title,
            contextMachineID: assignment.machineID,
            mode: outcome.independentlyCompleted ? .independent : .guided,
            evidence: outcome.scores.map { .init($0.key, score: $0.value) },
            occurredAt: occurredAt
        )
    }

    /// Records one machine completion as one learning activity while retaining the complete proof trail.
    public mutating func recordScenarioCompletion(
        _ attempt: ScenarioAttemptSummary,
        fieldAssignment: LongHorizonFieldAssignment? = nil,
        proof: DiagnosticProofRecord,
        occurredAt: Date = Date()
    ) {
        let score = attempt.score
        let proofGate = proof.qualityScore
        var evidence: [CompetencyEvidence] = [
            .init(.evidenceStrategy, score: min(Double(score.evidenceQuality) / 100, proofGate)),
            .init(.causalTroubleshooting, score: min(Double(score.causalReasoning) / 100, proofGate)),
            .init(.safetyDiscipline, score: Double(score.safety) / 100),
            .init(.verificationDiscipline, score: min(Double(score.verification) / 100, proof.repairVerified ? max(0.5, proofGate) : 0.25))
        ]
        evidence.append(contentsOf: Self.scenarioSpecificEvidence(attempt).map {
            .init($0.competency, score: min($0.score, max(0.25, proofGate)))
        })

        let source: CompetencyEvidenceSource
        let sourceID: String
        let contextLabel: String
        let contextMachineID: HeroMachineID
        if let fieldAssignment {
            source = .fieldAssignment
            sourceID = fieldAssignment.assignment.id
            contextLabel = fieldAssignment.assignment.title
            contextMachineID = fieldAssignment.assignment.machineID
            let outcome = fieldAssignment.outcome(from: attempt)
            evidence.append(contentsOf: outcome.scores.map { .init($0.key, score: min($0.value, proofGate)) })
        } else {
            source = .heroMachineCampaign
            sourceID = "\(attempt.machineID.rawValue)-\(attempt.faultID)"
            contextLabel = HeroMachineCatalog.machine(attempt.machineID)?.title ?? attempt.machineID.rawValue
            contextMachineID = attempt.machineID
        }
        record(
            source: source,
            sourceID: sourceID,
            contextLabel: contextLabel,
            contextMachineID: contextMachineID,
            mode: attempt.mode == .technician ? .independent : .guided,
            evidence: evidence,
            occurredAt: occurredAt
        )
        recordDiagnosticProof(proof.assigned(to: currentActivityIndex))
    }

    public mutating func recordDiagnosticProof(_ proof: DiagnosticProofRecord) {
        var proofs = diagnosticProofs ?? []
        guard !proofs.contains(where: { $0.id == proof.id }) else { return }
        proofs.append(proof)
        if proofs.count > 500 { proofs.removeFirst(proofs.count - 500) }
        diagnosticProofs = proofs

        var memory = Dictionary(uniqueKeysWithValues: (misconceptionMemory ?? []).map { ($0.misconception, $0) })
        for misconception in DiagnosticMisconception.allCases {
            var entry = memory[misconception] ?? .init(misconception: misconception)
            if proof.misconceptions.contains(misconception) {
                entry.observe(at: proof.activityIndex)
            } else if proof.qualityScore >= 0.75 {
                entry.disconfirm(at: proof.activityIndex)
            }
            memory[misconception] = entry
        }
        misconceptionMemory = memory.values.sorted { $0.misconception.rawValue < $1.misconception.rawValue }
    }

    public mutating func recordApprenticeshipGrade(_ grade: ApprenticeshipGrade, occurredAt: Date = Date()) {
        let grouped = Dictionary(grouping: grade.components, by: \.skill)
        var evidence: [CompetencyEvidence] = []
        for (skill, components) in grouped {
            let awarded = components.reduce(0) { $0 + $1.awardedPoints }
            let possible = components.reduce(0) { $0 + $1.possiblePoints }
            let score = possible > 0 ? awarded / possible : 0
            for competency in Self.competencies(for: skill, chapter: StepByStepCatalog.chapter(for: grade.lessonID)) {
                evidence.append(.init(competency, score: score))
            }
        }
        record(
            source: .apprenticeshipWork,
            sourceID: grade.lessonID,
            contextLabel: StepByStepCatalog.lesson(grade.lessonID)?.title ?? grade.lessonID,
            mode: .independent,
            evidence: evidence,
            occurredAt: occurredAt
        )
    }

    public func assessment(for competency: LongHorizonCompetency, atActivity activity: Int? = nil) -> CompetencyAssessment {
        let current = max(currentActivityIndex, activity ?? currentActivityIndex)
        let samples = events.flatMap { event in
            event.evidence.filter { $0.competency == competency }.map { (event, $0) }
        }
        guard !samples.isEmpty else {
            return .init(competency: competency, bestDemonstratedScore: 0, retainedConfidence: 0, activitiesSinceEvidence: nil, lastContext: nil, freshness: .unobserved)
        }
        let latest = samples.max { $0.0.activityIndex < $1.0.activityIndex }!
        let best = samples.map { $0.1.score }.max() ?? 0
        let retained = samples.map { event, evidence in
            let gap = max(0, current - event.activityIndex)
            let decay = pow(0.5, Double(gap) / competency.activityHalfLife)
            return evidence.score * event.mode.credibility * decay
        }.max() ?? 0
        let gap = max(0, current - latest.0.activityIndex)
        let freshness: CompetencyFreshness
        if retained >= 0.72 && gap <= 1 { freshness = .current }
        else if retained >= 0.62 { freshness = .aging }
        else if best >= 0.75 && retained >= 0.38 { freshness = .dueForTransfer }
        else { freshness = .decayed }
        return .init(
            competency: competency,
            bestDemonstratedScore: best,
            retainedConfidence: retained,
            activitiesSinceEvidence: gap,
            lastContext: latest.0.contextLabel,
            freshness: freshness
        )
    }

    public var assessments: [CompetencyAssessment] {
        LongHorizonCompetency.allCases.map { assessment(for: $0) }
    }

    public var dueForEmbeddedRetrieval: [CompetencyAssessment] {
        assessments.filter(\.needsEmbeddedRetrieval).sorted {
            if $0.retainedConfidence == $1.retainedConfidence { return $0.competency.rawValue < $1.competency.rawValue }
            return $0.retainedConfidence < $1.retainedConfidence
        }
    }

    public var apprenticeshipSkillProfile: ApprenticeshipSkillProfile {
        var scores: [ApprenticeshipSkill: Double] = [:]
        for skill in ApprenticeshipSkill.allCases {
            let competencies = Self.competencies(for: skill, chapter: .commissioningCapstone)
            let assessments = competencies.map { assessment(for: $0) }
            let values = assessments.map { $0.freshness == .unobserved ? 0.5 : $0.retainedConfidence }
            if !values.isEmpty { scores[skill] = values.reduce(0, +) / Double(values.count) }
        }
        return .init(scores: scores)
    }

    private static func chapterCompetencies(_ chapter: StepByStepChapter) -> [LongHorizonCompetency] {
        switch chapter {
        case .foundations: [.scanTiming, .tagsAndDataOwnership, .instructionSelection]
        case .digitalMachineControl: [.rungTopology, .interlocksAndSequence]
        case .sequencing: [.scanTiming, .interlocksAndSequence]
        case .analogProcessControl: [.analogSignalReasoning, .verificationDiscipline]
        case .architectureNetworking: [.remoteIOTiming, .controllerCommunications, .tagsAndDataOwnership]
        case .supervisoryData: [.hmiDataContracts, .historianEvidence]
        case .commissioningCapstone: [.evidenceStrategy, .causalTroubleshooting, .verificationDiscipline]
        }
    }

    private static func competencies(for skill: ApprenticeshipSkill, chapter: StepByStepChapter) -> [LongHorizonCompetency] {
        switch skill {
        case .scanReasoning: return [.scanTiming]
        case .tagsAndTypes: return [.tagsAndDataOwnership]
        case .instructionChoice: return [.instructionSelection]
        case .rungTopology: return [.rungTopology]
        case .interlocksAndState: return [.interlocksAndSequence]
        case .analogMath: return [.analogSignalReasoning]
        case .communications:
            if chapter == .architectureNetworking { return [.remoteIOTiming, .controllerCommunications] }
            if chapter == .supervisoryData { return [.hmiDataContracts, .controllerCommunications] }
            return [.controllerCommunications]
        case .historianReasoning: return [.historianEvidence]
        case .verification: return [.verificationDiscipline]
        }
    }

    private static func scenarioSpecificEvidence(_ attempt: ScenarioAttemptSummary) -> [CompetencyEvidence] {
        let measurement = Double(attempt.score.measurementStrategy) / 100
        let causal = Double(attempt.score.causalReasoning) / 100
        switch attempt.faultID {
        case "short-pulse", "diverter-timing":
            return [.init(.remoteIOTiming, score: min(measurement, causal)), .init(.scanTiming, score: causal)]
        case "pe203-sticky", "vacuum-loss", "divert-leak":
            return [.init(.interlocksAndSequence, score: causal), .init(.tagsAndDataOwnership, score: measurement)]
        case "valve-stiction", "dead-time-growth", "agitator-drag", "cooling-valve-stiction":
            return [.init(.analogSignalReasoning, score: causal)]
        case "condenser-fouling", "fuel-air-drift", "filter-loading", "dp-bias":
            return [.init(.historianEvidence, score: Double(attempt.score.evidenceQuality) / 100)]
        default:
            return [.init(.causalTroubleshooting, score: causal)]
        }
    }
}

public enum CompetencyHistoryPersistence {
    public static let storageKey = "ControlsTechTrainer.LongHorizonCompetencyHistory.v1"

    public static func load(defaults: UserDefaults = .standard) -> LongHorizonCompetencyHistory {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(LongHorizonCompetencyHistory.self, from: data) else {
            return .init()
        }
        return value
    }

    public static func save(_ history: LongHorizonCompetencyHistory, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

public struct RemoteIOTimingChallenge: Codable, Equatable, Sendable {
    public let rpiMilliseconds: Int
    public let taskPeriodMilliseconds: Int
    public let pulseWidthMilliseconds: Int
    public let networkPhaseMilliseconds: Int

    public init(rpiMilliseconds: Int, taskPeriodMilliseconds: Int, pulseWidthMilliseconds: Int, networkPhaseMilliseconds: Int = 0) {
        self.rpiMilliseconds = max(1, rpiMilliseconds)
        self.taskPeriodMilliseconds = max(1, taskPeriodMilliseconds)
        self.pulseWidthMilliseconds = max(1, pulseWidthMilliseconds)
        self.networkPhaseMilliseconds = max(0, networkPhaseMilliseconds) % max(1, rpiMilliseconds)
    }

    /// Simulates a field pulse crossing an RPI-updated controller image and then a periodic task.
    public func controllerObservedPulse(startMilliseconds: Int, horizonMilliseconds: Int = 250) -> Bool {
        let pulseEnd = startMilliseconds + pulseWidthMilliseconds
        var controllerImage = false
        var nextNetwork = networkPhaseMilliseconds
        while nextNetwork < 0 { nextNetwork += rpiMilliseconds }
        var nextTask = 0
        let horizon = max(horizonMilliseconds, pulseEnd + rpiMilliseconds + taskPeriodMilliseconds)
        for time in 0...horizon {
            if time == nextNetwork {
                controllerImage = time >= startMilliseconds && time < pulseEnd
                nextNetwork += rpiMilliseconds
            }
            if time == nextTask {
                if controllerImage { return true }
                nextTask += taskPeriodMilliseconds
            }
        }
        return false
    }

    public var demonstratesPhaseDependence: Bool {
        let outcomes = (0..<rpiMilliseconds).map { controllerObservedPulse(startMilliseconds: $0) }
        return outcomes.contains(true) && outcomes.contains(false)
    }
}

public enum EmbeddedCompetencyChallengeKind: Codable, Equatable, Sendable {
    case remoteIOTiming(RemoteIOTimingChallenge)
    case evidenceCrossCheck
    case verificationUnderChangedConditions
}

public struct EmbeddedCompetencyChallenge: Codable, Equatable, Sendable {
    public let id: String
    public let target: LongHorizonCompetency
    public let internalReason: String
    public let kind: EmbeddedCompetencyChallengeKind
}

public struct LongHorizonFieldAssignment: Equatable, Sendable {
    public let assignment: ScenarioFieldAssignment
    public let embeddedChallenge: EmbeddedCompetencyChallenge

    /// The learner sees the normal field call, not a labeled refresher.
    public var learnerFacingTitle: String { assignment.title }
    public var learnerFacingBriefing: String { assignment.briefing }

    public func outcome(from attempt: ScenarioAttemptSummary) -> FieldAssignmentOutcome {
        let score: Double
        switch embeddedChallenge.target {
        case .remoteIOTiming, .scanTiming:
            score = Double(min(attempt.score.measurementStrategy, min(attempt.score.evidenceQuality, attempt.score.causalReasoning))) / 100
        case .verificationDiscipline:
            score = Double(attempt.score.verification) / 100
        case .safetyDiscipline:
            score = Double(attempt.score.safety) / 100
        case .evidenceStrategy, .historianEvidence:
            score = Double(attempt.score.evidenceQuality) / 100
        case .causalTroubleshooting, .interlocksAndSequence, .rungTopology:
            score = Double(attempt.score.causalReasoning) / 100
        default:
            score = Double(attempt.score.overall) / 100
        }
        return .init(
            assignmentID: assignment.id,
            scores: [embeddedChallenge.target: score],
            independentlyCompleted: attempt.mode == .technician
        )
    }
}

public enum LongHorizonChallengeInjector {
    public static func nextFieldAssignment(history: LongHorizonCompetencyHistory, seed: UInt64) -> LongHorizonFieldAssignment? {
        guard let due = history.dueForEmbeddedRetrieval.first else { return nil }
        let candidates = assignmentIDs(for: due.competency).compactMap { id in
            ScenarioFieldAssignmentCatalog.all.first(where: { $0.id == id })
        }
        guard !candidates.isEmpty else { return nil }
        let assignment = candidates[Int(seed % UInt64(candidates.count))]
        let kind: EmbeddedCompetencyChallengeKind
        switch due.competency {
        case .remoteIOTiming, .scanTiming:
            let rpi = [20, 30, 50][Int(seed % 3)]
            let pulse = max(5, rpi / 2)
            kind = .remoteIOTiming(.init(rpiMilliseconds: rpi, taskPeriodMilliseconds: 10, pulseWidthMilliseconds: pulse, networkPhaseMilliseconds: Int(seed % UInt64(rpi))))
        case .verificationDiscipline, .safetyDiscipline:
            kind = .verificationUnderChangedConditions
        default:
            kind = .evidenceCrossCheck
        }
        return .init(
            assignment: assignment,
            embeddedChallenge: .init(
                id: "embedded-\(due.competency.rawValue)-\(assignment.id)-\(seed)",
                target: due.competency,
                internalReason: due.narrative,
                kind: kind
            )
        )
    }

    private static func assignmentIDs(for competency: LongHorizonCompetency) -> [String] {
        switch competency {
        case .remoteIOTiming, .scanTiming: ["parcel-highspeed", "asrs-docking", "palletizer-grip"]
        case .historianEvidence, .evidenceStrategy: ["batch-drag-trend", "airplant-night-leak", "rack-hotday"]
        case .analogSignalReasoning: ["cnc-filter", "chw-dp-bias", "boiler-rich"]
        case .interlocksAndSequence, .rungTopology: ["palletizer-grip", "pasteurizer-divert", "liftstation-backflow"]
        case .verificationDiscipline, .safetyDiscipline: ["boiler-rich", "pasteurizer-divert", "battery-contact"]
        default: ["cleanroom-dp", "ro-fouling", "crusher-slip"]
        }
    }
}

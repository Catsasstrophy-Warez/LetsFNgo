import Foundation

public struct RemediationProofResult: Codable, Equatable, Sendable {
    public let moduleID: String
    public let skill: ApprenticeshipSkill
    public let evidenceScore: Double
    public let structuralPass: Bool
    public let runtimeVerified: Bool
    public let observations: [String]

    public init(moduleID: String, skill: ApprenticeshipSkill, evidenceScore: Double, structuralPass: Bool, runtimeVerified: Bool, observations: [String] = []) {
        self.moduleID = moduleID
        self.skill = skill
        self.evidenceScore = max(0, min(1, evidenceScore))
        self.structuralPass = structuralPass
        self.runtimeVerified = runtimeVerified
        self.observations = observations
    }

    public var automaticallyVerified: Bool {
        structuralPass && runtimeVerified && evidenceScore >= 0.80
    }
}

public enum AutomaticRemediationProofVerifier {
    public static func evaluate(module: CertificationRemediationModule, grade: ApprenticeshipGrade) -> RemediationProofResult {
        let matching = grade.components.filter { $0.skill == module.skill }
        let awarded = matching.reduce(0.0) { $0 + $1.awardedPoints }
        let possible = matching.reduce(0.0) { $0 + $1.possiblePoints }
        let skillScore = possible > 0 ? awarded / possible : 0
        var observations = matching.map { "\($0.title): \($0.feedback)" }
        observations.append(grade.validation.passed ? "Lesson structural validator passed." : "Lesson structural validator did not pass.")
        observations.append(grade.verificationPerformed ? "Runtime verification evidence recorded." : "Runtime verification evidence missing.")
        return .init(
            moduleID: module.id,
            skill: module.skill,
            evidenceScore: skillScore,
            structuralPass: grade.validation.passed,
            runtimeVerified: grade.verificationPerformed,
            observations: observations
        )
    }

    /// Architecture/supervisory remediation can be proven from a graded certification-style diagnostic result.
    public static func evaluate(module: CertificationRemediationModule, diagnosticResult: ChapterCertificationResult) -> RemediationProofResult {
        let score = diagnosticResult.skillScores[module.skill] ?? 0
        return .init(
            moduleID: module.id,
            skill: module.skill,
            evidenceScore: score,
            structuralPass: score >= 0.80,
            runtimeVerified: diagnosticResult.verificationPerformed,
            observations: diagnosticResult.feedback
        )
    }
}

public extension CertificationRemediationProgress {
    mutating func recordAutomaticallyVerified(_ proof: RemediationProofResult, for module: CertificationRemediationModule) -> Bool {
        guard proof.moduleID == module.id, proof.skill == module.skill, proof.automaticallyVerified else { return false }
        markComplete(module.id)
        return true
    }
}

public struct SpacedMasteryRecord: Codable, Equatable, Sendable {
    public let skill: ApprenticeshipSkill
    public var firstMasteredChapter: StepByStepChapter
    public var lastEvidenceChapter: StepByStepChapter
    public var strength: Double
    public var successfulRetrievals: Int
    public var lapses: Int
    public var nextDueChapter: StepByStepChapter?

    public init(skill: ApprenticeshipSkill, firstMasteredChapter: StepByStepChapter, lastEvidenceChapter: StepByStepChapter, strength: Double = 0.75, successfulRetrievals: Int = 0, lapses: Int = 0, nextDueChapter: StepByStepChapter? = nil) {
        self.skill = skill
        self.firstMasteredChapter = firstMasteredChapter
        self.lastEvidenceChapter = lastEvidenceChapter
        self.strength = max(0, min(1, strength))
        self.successfulRetrievals = successfulRetrievals
        self.lapses = lapses
        self.nextDueChapter = nextDueChapter
    }
}

public struct SpacedMasteryCheck: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let skill: ApprenticeshipSkill
    public let dueChapter: StepByStepChapter
    public let exercise: ApprenticeshipExercise
    public let reason: String
}

public struct SpacedMasteryProfile: Codable, Equatable, Sendable {
    public private(set) var records: [ApprenticeshipSkill: SpacedMasteryRecord]

    public init(records: [ApprenticeshipSkill: SpacedMasteryRecord] = [:]) { self.records = records }

    public func record(for skill: ApprenticeshipSkill) -> SpacedMasteryRecord? { records[skill] }

    public mutating func recordRemediationMastery(skills: [ApprenticeshipSkill], chapter: StepByStepChapter) {
        for skill in Set(skills) {
            let due = Self.chapter(after: chapter, offset: 1)
            records[skill] = .init(skill: skill, firstMasteredChapter: chapter, lastEvidenceChapter: chapter, strength: 0.78, successfulRetrievals: 0, lapses: 0, nextDueChapter: due)
        }
    }

    public mutating func recordRetention(skill: ApprenticeshipSkill, passed: Bool, chapter: StepByStepChapter) {
        var rec = records[skill] ?? .init(skill: skill, firstMasteredChapter: chapter, lastEvidenceChapter: chapter)
        rec.lastEvidenceChapter = chapter
        if passed {
            rec.successfulRetrievals += 1
            rec.strength = min(1, rec.strength + 0.08 + Double(min(rec.successfulRetrievals, 3)) * 0.02)
            let spacing = min(3, 1 + rec.successfulRetrievals)
            rec.nextDueChapter = Self.chapter(after: chapter, offset: spacing)
        } else {
            rec.lapses += 1
            rec.strength = max(0.25, rec.strength - 0.30)
            rec.nextDueChapter = Self.chapter(after: chapter, offset: 1)
        }
        records[skill] = rec
    }

    public func dueSkills(entering chapter: StepByStepChapter) -> [ApprenticeshipSkill] {
        records.values.filter { rec in
            guard let due = rec.nextDueChapter else { return false }
            return due.rawValue <= chapter.rawValue
        }.sorted {
            if $0.strength == $1.strength { return $0.skill.rawValue < $1.skill.rawValue }
            return $0.strength < $1.strength
        }.map(\.skill)
    }

    private static func chapter(after chapter: StepByStepChapter, offset: Int) -> StepByStepChapter? {
        StepByStepChapter(rawValue: min(StepByStepChapter.allCases.count, chapter.rawValue + max(1, offset)))
    }
}

public enum SpacedMasteryScheduler {
    public static func checks(profile: SpacedMasteryProfile, entering chapter: StepByStepChapter, seed: UInt64) -> [SpacedMasteryCheck] {
        profile.dueSkills(entering: chapter).prefix(3).enumerated().map { index, skill in
            let mixed = seed &* 6_364_136_223_846_793_005 &+ UInt64(index + 1) &* 7_919 &+ UInt64(chapter.rawValue)
            let lessonID = lesson(for: skill, chapter: chapter)
            let exercise = ApprenticeshipExercise(
                id: "retention-\(chapter.rawValue)-\(skill.rawValue)-\(mixed)",
                lessonID: lessonID,
                kind: exerciseKind(for: skill),
                title: "Retention check: \(skill.title)",
                prompt: prompt(for: skill, chapter: chapter),
                targetSkills: [skill, .verification],
                seed: mixed,
                hints: ["This concept appeared earlier. Solve it without reopening the original remediation solution."]
            )
            return .init(
                id: exercise.id,
                skill: skill,
                dueChapter: chapter,
                exercise: exercise,
                reason: "This skill was previously remediated and is due for a spaced retrieval check."
            )
        }
    }

    private static func exerciseKind(for skill: ApprenticeshipSkill) -> ApprenticeshipExerciseKind {
        switch skill {
        case .scanReasoning, .communications, .historianReasoning: .predictThenRun
        case .rungTopology, .interlocksAndState, .analogMath: .repairBrokenProgram
        default: .buildFromScratch
        }
    }

    private static func lesson(for skill: ApprenticeshipSkill, chapter: StepByStepChapter) -> String {
        switch skill {
        case .scanReasoning: chapter.rawValue >= 3 ? "sequence-timer-counter" : "foundation-scan"
        case .tagsAndTypes: chapter.rawValue >= 5 ? "foundation-structured-data" : "foundation-tags"
        case .instructionChoice: "digital-xic-xio"
        case .rungTopology: "digital-motor-seal"
        case .interlocksAndState: "digital-interlocks"
        case .analogMath: "analog-input-scaling"
        case .communications: chapter.rawValue >= 6 ? "comm-hmi-scada" : "comm-io-rpi"
        case .historianReasoning: "historian-points-scan"
        case .verification: chapter.rawValue >= 4 ? "analog-alarms" : "foundation-first-rung"
        }
    }

    private static func prompt(for skill: ApprenticeshipSkill, chapter: StepByStepChapter) -> String {
        switch skill {
        case .rungTopology: "Repair a different machine's holding/interlock topology and prove Stop still owns the run path."
        case .analogMath: "Calibrate a different transmitter range at low, mid, and high points and preserve raw evidence."
        case .communications: "Trace freshness through a different source/update/task path and prove which layer can miss the event."
        case .historianReasoning: "Decide whether a new short-duration event can be proven from historian data, then select the correct evidence source."
        case .scanReasoning: "Predict a new multi-scan behavior before running it, then reconcile every mismatch with the trace."
        default: "Demonstrate \(skill.title.lowercased()) in a different Chapter \(chapter.rawValue) context and verify the result."
        }
    }
}

public extension SpacedMasteryCheck {
    var proofModule: CertificationRemediationModule {
        .init(
            id: id,
            skill: skill,
            lessonID: exercise.lessonID,
            title: exercise.title,
            prompt: exercise.prompt,
            proofRequirement: "Demonstrate the skill in this new context and verify it with runtime evidence.",
            seed: exercise.seed
        )
    }
}

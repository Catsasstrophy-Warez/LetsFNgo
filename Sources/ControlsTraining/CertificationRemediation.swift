import Foundation

public struct CertificationRemediationModule: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let skill: ApprenticeshipSkill
    public let lessonID: String
    public let title: String
    public let prompt: String
    public let proofRequirement: String
    public let seed: UInt64

    public func makeExercise() -> ApprenticeshipExercise {
        let kind: ApprenticeshipExerciseKind
        switch skill {
        case .scanReasoning, .communications, .historianReasoning: kind = .predictThenRun
        case .rungTopology, .interlocksAndState, .analogMath: kind = .repairBrokenProgram
        default: kind = .buildFromScratch
        }
        return .init(id: id, lessonID: lessonID, kind: kind, title: title, prompt: prompt, targetSkills: [skill, .verification], seed: seed, hints: [proofRequirement])
    }
}

public struct CertificationRemediationPlan: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let failedExamID: String
    public let chapter: StepByStepChapter
    public let originalSeed: UInt64
    public let weakSkills: [ApprenticeshipSkill]
    public let modules: [CertificationRemediationModule]
    public let retestSeed: UInt64

    public var title: String { "Targeted remediation • Chapter \(chapter.rawValue)" }
}

public struct CertificationRemediationProgress: Codable, Equatable, Sendable {
    public let planID: String
    public private(set) var completedModuleIDs: Set<String>

    public init(planID: String, completedModuleIDs: Set<String> = []) {
        self.planID = planID
        self.completedModuleIDs = completedModuleIDs
    }

    public mutating func markComplete(_ moduleID: String) { completedModuleIDs.insert(moduleID) }
    public func isComplete(_ moduleID: String) -> Bool { completedModuleIDs.contains(moduleID) }
    public func isReadyForRetest(_ plan: CertificationRemediationPlan) -> Bool {
        Set(plan.modules.map(\.id)).isSubset(of: completedModuleIDs)
    }
}

public enum CertificationRemediationEngine {
    public static func plan(after result: ChapterCertificationResult, exam: ChapterCertificationExam) -> CertificationRemediationPlan? {
        guard !result.passed else { return nil }
        let weak = weaknessOrder(result: result, exam: exam)
        let selected = Array(weak.prefix(min(3, max(1, weak.count))))
        let modules = selected.enumerated().map { index, skill in
            makeModule(skill: skill, chapter: exam.chapter, seed: mixedSeed(exam.seed, salt: UInt64(index + 1)))
        }
        return .init(
            id: "remediate-\(exam.id)-\(mixedSeed(exam.seed, salt: 77))",
            failedExamID: exam.id,
            chapter: exam.chapter,
            originalSeed: exam.seed,
            weakSkills: selected,
            modules: modules,
            retestSeed: mixedSeed(exam.seed, salt: 9_973)
        )
    }

    public static func freshRetest(for plan: CertificationRemediationPlan) throws -> ChapterCertificationExam {
        var seed = plan.retestSeed
        if seed == plan.originalSeed { seed &+= 1 }
        let exam = try ChapterCertificationGenerator.generate(chapter: plan.chapter, seed: seed)
        if exam.id == plan.failedExamID {
            return try ChapterCertificationGenerator.generate(chapter: plan.chapter, seed: seed &+ 1)
        }
        return exam
    }

    private static func weaknessOrder(result: ChapterCertificationResult, exam: ChapterCertificationExam) -> [ApprenticeshipSkill] {
        var scores = result.skillScores
        if scores.isEmpty {
            for skill in exam.requiredSkills { scores[skill] = result.score / 100 }
            if !result.verificationPerformed { scores[.verification] = 0 }
        }
        let relevant = Set(exam.requiredSkills + [.verification])
        return relevant.sorted {
            let a = scores[$0] ?? 0.5
            let b = scores[$1] ?? 0.5
            if a == b { return $0.rawValue < $1.rawValue }
            return a < b
        }
    }

    private static func makeModule(skill: ApprenticeshipSkill, chapter: StepByStepChapter, seed: UInt64) -> CertificationRemediationModule {
        let lessonID: String
        let prompt: String
        let proof: String
        switch skill {
        case .scanReasoning:
            lessonID = chapter.rawValue >= StepByStepChapter.sequencing.rawValue ? "sequence-timer-counter" : "foundation-scan"
            prompt = "Predict the next three scans before running. Explain exactly when the observed state can change and why."
            proof = "Your predicted scan sequence must match the runtime trace."
        case .tagsAndTypes:
            lessonID = chapter.rawValue >= StepByStepChapter.architectureNetworking.rawValue ? "foundation-structured-data" : "foundation-tags"
            prompt = "Repair the data organization without changing healthy logic. Explain scope/type choices before compiling."
            proof = "Compile with correct types/scope and explain why each selected scope is appropriate."
        case .instructionChoice:
            lessonID = "digital-xic-xio"
            prompt = "Build a small truth-table rung, predict each condition, then select instructions that implement the stated behavior."
            proof = "All requested TRUE/FALSE cases must match your prediction."
        case .rungTopology:
            lessonID = "digital-motor-seal"
            prompt = "Repair a topology defect without bypassing Stop_OK or adding an unnecessary latch."
            proof = "Start seals correctly, Stop interrupts, and the validator confirms branch topology."
        case .interlocksAndState:
            lessonID = "digital-interlocks"
            prompt = "Repair a permissive/fault path and prove that a real trip cannot be defeated by the run seal."
            proof = "Trip, inhibit, reset, and restart behavior must all be demonstrated."
        case .analogMath:
            lessonID = "analog-input-scaling"
            prompt = "Repair an analog conversion and prove low, mid, and high calibration points rather than checking one value."
            proof = "Three-point calibration must pass while preserving raw input evidence."
        case .communications:
            lessonID = chapter == .supervisoryData ? "comm-hmi-scada" : "comm-io-rpi"
            prompt = "Trace source → transport/update timing → controller-visible value. Identify what a stale observation can and cannot prove."
            proof = "Show source and destination timestamps/update periods and explain the freshness boundary."
        case .historianReasoning:
            lessonID = "historian-points-scan"
            prompt = "Choose a collection interval for a short event, predict whether it is guaranteed to appear, then compare historian evidence with scan-level evidence."
            proof = "Correctly state what the historian can prove and when a flight recorder is required."
        case .verification:
            lessonID = chapter.rawValue >= StepByStepChapter.analogProcessControl.rawValue ? "analog-alarms" : "foundation-first-rung"
            prompt = "Take a plausible solution and create a verification matrix covering normal, boundary, and failure states before declaring success."
            proof = "Run every verification case and record observed evidence, not just expected behavior."
        }
        return .init(id: "rem-\(chapter.rawValue)-\(skill.rawValue)-\(seed)", skill: skill, lessonID: lessonID, title: "Remediate: \(skill.title)", prompt: prompt, proofRequirement: proof, seed: seed)
    }

    private static func mixedSeed(_ seed: UInt64, salt: UInt64) -> UInt64 {
        seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 &+ salt &* 7_919
    }
}

public enum CertificationJourneyEvent: Codable, Equatable, Sendable {
    case attemptSubmitted(examID: String, seed: UInt64, result: ChapterCertificationResult)
    case remediationAssigned(planID: String, weakSkills: [ApprenticeshipSkill])
    case remediationModuleCompleted(moduleID: String)
    case retestIssued(examID: String, seed: UInt64)
    case certified(examID: String, score: Double)
}

public struct CertificationJourneyTranscript: Codable, Equatable, Sendable {
    public let chapter: StepByStepChapter
    public private(set) var events: [CertificationJourneyEvent]

    public init(chapter: StepByStepChapter, events: [CertificationJourneyEvent] = []) {
        self.chapter = chapter
        self.events = events
    }

    public mutating func append(_ event: CertificationJourneyEvent) { events.append(event) }

    public var attemptCount: Int {
        events.reduce(0) { count, event in
            if case .attemptSubmitted = event { return count + 1 }
            return count
        }
    }

    public var remediationCount: Int {
        events.reduce(0) { count, event in
            if case .remediationAssigned = event { return count + 1 }
            return count
        }
    }

    public var isCertified: Bool { events.contains { if case .certified = $0 { true } else { false } } }

    public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> CertificationJourneyTranscript {
        try JSONDecoder().decode(CertificationJourneyTranscript.self, from: data)
    }
}

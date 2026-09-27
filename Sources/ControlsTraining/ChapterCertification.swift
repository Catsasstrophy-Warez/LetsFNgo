import Foundation
import ControlsPLC

public enum ChapterCertificationKind: String, Codable, CaseIterable, Sendable {
    case buildFromScratch
    case repairBrokenProgram
    case diagnoseWholeController
    case commissionWholeController

    public var title: String {
        switch self {
        case .buildFromScratch: "Build from scratch"
        case .repairBrokenProgram: "Repair a broken program"
        case .diagnoseWholeController: "Diagnose a controller architecture"
        case .commissionWholeController: "Commission an inherited controls system"
        }
    }
}

public struct ChapterCertificationExam: Identifiable, Sendable {
    public let id: String
    public let chapter: StepByStepChapter
    public let seed: UInt64
    public let kind: ChapterCertificationKind
    public let title: String
    public let briefing: String
    public let lessonID: String?
    public let architectureSeed: UInt64?
    public let requiredSkills: [ApprenticeshipSkill]
    public let passingPercent: Double

    public var difficultyLabel: String {
        switch chapter {
        case .foundations: "Level 1 • Beginner practical"
        case .digitalMachineControl: "Level 2 • Beginner practical"
        case .sequencing: "Level 3 • Intermediate practical"
        case .analogProcessControl: "Level 4 • Intermediate practical"
        case .architectureNetworking: "Level 5 • Advanced practical"
        case .supervisoryData: "Level 6 • Advanced practical"
        case .commissioningCapstone: "Level 7 • Integrated certification"
        }
    }

    public func makeInitialWorkbench() throws -> LadderConstructionWorkbench? {
        guard let lessonID else { return nil }
        switch kind {
        case .repairBrokenProgram:
            return try ApprenticeshipExerciseGenerator.brokenWorkbench(for: lessonID) ?? WorkbenchLessonFactory.starter(for: lessonID)
        case .buildFromScratch:
            return try WorkbenchLessonFactory.starter(for: lessonID)
        case .diagnoseWholeController, .commissionWholeController:
            return nil
        }
    }

    public func makeArchitecture() throws -> GeneratedControllerArchitecture? {
        guard let architectureSeed else { return nil }
        return try GeneratedControllerArchitectureGenerator.generate(seed: architectureSeed)
    }
}

public struct ChapterCertificationResult: Codable, Equatable, Sendable {
    public var chapter: StepByStepChapter
    public var examID: String
    public var score: Double
    public var passed: Bool
    public var verificationPerformed: Bool
    public var feedback: [String]
    /// 0...1 evidence by skill, used to target remediation after a failed practical.
    public var skillScores: [ApprenticeshipSkill: Double]

    public init(chapter: StepByStepChapter, examID: String, score: Double, passed: Bool, verificationPerformed: Bool, feedback: [String], skillScores: [ApprenticeshipSkill: Double] = [:]) {
        self.chapter = chapter
        self.examID = examID
        self.score = score
        self.passed = passed
        self.verificationPerformed = verificationPerformed
        self.feedback = feedback
        self.skillScores = skillScores
    }

    public var weakestSkills: [ApprenticeshipSkill] {
        skillScores.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key.rawValue < rhs.key.rawValue }
            return lhs.value < rhs.value
        }.map(\.key)
    }
}

public struct ChapterCertificationRecord: Codable, Equatable, Sendable {
    public var attempts: Int
    public var bestScore: Double
    public var passed: Bool

    public init(attempts: Int = 0, bestScore: Double = 0, passed: Bool = false) {
        self.attempts = attempts
        self.bestScore = bestScore
        self.passed = passed
    }
}

public struct ChapterCertificationProfile: Codable, Equatable, Sendable {
    public private(set) var records: [StepByStepChapter: ChapterCertificationRecord]

    public init(records: [StepByStepChapter: ChapterCertificationRecord] = [:]) {
        self.records = records
    }

    public func record(for chapter: StepByStepChapter) -> ChapterCertificationRecord {
        records[chapter] ?? .init()
    }

    public func hasPassed(_ chapter: StepByStepChapter) -> Bool {
        record(for: chapter).passed
    }

    public func isUnlocked(_ chapter: StepByStepChapter, progress: StepByStepProgressProfile) -> Bool {
        let lessonsComplete = StepByStepCatalog.lessons(in: chapter).allSatisfy { progress.isComplete($0.id) }
        guard lessonsComplete else { return false }
        guard chapter.rawValue > 1, let previous = StepByStepChapter(rawValue: chapter.rawValue - 1) else { return true }
        return hasPassed(previous)
    }

    public mutating func record(_ result: ChapterCertificationResult) {
        var current = record(for: result.chapter)
        current.attempts += 1
        current.bestScore = max(current.bestScore, result.score)
        current.passed = current.passed || result.passed
        records[result.chapter] = current
    }

    public var certifiedThroughChapter: Int {
        var highest = 0
        for chapter in StepByStepChapter.allCases {
            if hasPassed(chapter) { highest = chapter.rawValue } else { break }
        }
        return highest
    }
}

public enum ChapterCertificationGenerator {
    public static func generate(chapter: StepByStepChapter, seed: UInt64) throws -> ChapterCertificationExam {
        let normalizedSeed = seed == 0 ? UInt64(chapter.rawValue) : seed
        switch chapter {
        case .foundations:
            return .init(
                id: "cert-1-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .buildFromScratch,
                title: "Build and prove your first machine-control rung",
                briefing: "No construction steps are provided. Create the required tags, build a Start_PB → Motor_Run rung, predict behavior for FALSE/TRUE/FALSE input states, then run it and prove the output follows logic without claiming physical feedback.",
                lessonID: "foundation-first-rung", architectureSeed: nil,
                requiredSkills: [.scanReasoning, .tagsAndTypes, .instructionChoice, .verification], passingPercent: 75
            )
        case .digitalMachineControl:
            let lesson = normalizedSeed.isMultiple(of: 2) ? "digital-motor-seal" : "digital-interlocks"
            return .init(
                id: "cert-2-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .repairBrokenProgram,
                title: lesson == "digital-motor-seal" ? "Repair a motor starter handoff" : "Repair an unsafe permissive/fault handoff",
                briefing: "You inherited a program that compiles but violates an important digital-control behavior. Diagnose the topology, repair only what is causal, and prove Start/Stop, permissive, command, and fault behavior with evidence.",
                lessonID: lesson, architectureSeed: nil,
                requiredSkills: [.instructionChoice, .rungTopology, .interlocksAndState, .verification], passingPercent: 78
            )
        case .sequencing:
            return .init(
                id: "cert-3-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .repairBrokenProgram,
                title: "Recover a broken timed sequence",
                briefing: "A transfer sequence has plausible ladder but fails under repeated scans. Diagnose timer/counter/state behavior, repair the event logic, and prove the sequence over multiple scans rather than one static rung snapshot.",
                lessonID: "sequence-timer-counter", architectureSeed: nil,
                requiredSkills: [.scanReasoning, .instructionChoice, .interlocksAndState, .verification], passingPercent: 80
            )
        case .analogProcessControl:
            let choices = ["analog-input-scaling", "analog-alarms", "analog-level-hysteresis"]
            let lesson = choices[Int(normalizedSeed % UInt64(choices.count))]
            return .init(
                id: "cert-4-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .repairBrokenProgram,
                title: "Commission an analog control fragment",
                briefing: "The digital permissives are healthy, but the analog behavior is wrong. Find the scaling, alarm, or deadband defect selected for this attempt. Prove endpoints/threshold behavior and preserve raw evidence for troubleshooting.",
                lessonID: lesson, architectureSeed: nil,
                requiredSkills: [.analogMath, .instructionChoice, .interlocksAndState, .verification], passingPercent: 82
            )
        case .architectureNetworking:
            let architectureSeed = try findArchitectureSeed(startingAt: normalizedSeed, allowed: [.taskScheduling, .routineCallPath, .tagScope, .remoteIO, .explicitMessaging])
            return .init(
                id: "cert-5-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .diagnoseWholeController,
                title: "Trace a cross-boundary controller fault",
                briefing: "The symptom cannot be solved by staring at one rung. Trace task scheduling, routine call path, scope, remote I/O, and explicit messaging. Identify the primary architectural defect, avoid cosmetic edits, repair required weaknesses, and verify end-to-end behavior.",
                lessonID: nil, architectureSeed: architectureSeed,
                requiredSkills: [.scanReasoning, .tagsAndTypes, .communications, .verification], passingPercent: 84
            )
        case .supervisoryData:
            let architectureSeed = try findArchitectureSeed(startingAt: normalizedSeed, allowed: [.hmiMapping, .historianCollection])
            return .init(
                id: "cert-6-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .diagnoseWholeController,
                title: "Prove what the HMI and historian can actually tell you",
                briefing: "Controller, HMI, and historian evidence disagree about event order. Determine whether the supervisory layer is stale, aliased incorrectly, or too slow to prove the claimed sequence. Do not rewrite healthy ladder to make the trend look nicer.",
                lessonID: nil, architectureSeed: architectureSeed,
                requiredSkills: [.communications, .historianReasoning, .verification], passingPercent: 85
            )
        case .commissioningCapstone:
            let architectureSeed = normalizedSeed &* 6364136223846793005 &+ 1442695040888963407
            return .init(
                id: "cert-7-\(normalizedSeed)", chapter: chapter, seed: normalizedSeed,
                kind: .commissionWholeController,
                title: "Final practical: inherit, diagnose, repair, and commission",
                briefing: "You receive an unfamiliar multi-task controller with remote I/O, explicit communications, HMI mappings, historian collection, real secondary defects, cosmetic inherited code, and stale evidence. No hints. Establish what is healthy, identify the primary cause, make only justified repairs, and perform end-to-end verification before declaring the system production-ready.",
                lessonID: nil, architectureSeed: architectureSeed,
                requiredSkills: ApprenticeshipSkill.allCases, passingPercent: 88
            )
        }
    }

    private static func findArchitectureSeed(startingAt seed: UInt64, allowed: Set<GeneratedArchitectureBoundary>) throws -> UInt64 {
        for offset in 0..<512 {
            let candidate = seed &+ UInt64(offset) &* 7_919
            let architecture = try GeneratedControllerArchitectureGenerator.generate(seed: candidate)
            if let boundary = architecture.primaryIssue?.boundary, allowed.contains(boundary) { return candidate }
        }
        throw NSError(domain: "ChapterCertification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not generate a matching architecture practical."])
    }
}

public enum ChapterCertificationAssessor {
    public static func assessLadder(exam: ChapterCertificationExam, workbench: LadderConstructionWorkbench, verificationPerformed: Bool) -> ChapterCertificationResult {
        guard let lessonID = exam.lessonID, let lesson = StepByStepCatalog.lesson(lessonID) else {
            return .init(chapter: exam.chapter, examID: exam.id, score: 0, passed: false, verificationPerformed: verificationPerformed, feedback: ["Certification exam is missing its lesson rubric."])
        }
        let grade = ApprenticeshipGrader.grade(workbench: workbench, lesson: lesson, verificationPerformed: verificationPerformed)
        let passed = grade.validation.passed && verificationPerformed && grade.percent >= exam.passingPercent
        var feedback = grade.components.map { "\($0.title): \($0.feedback)" }
        if grade.percent < exam.passingPercent { feedback.append("Certification requires \(Int(exam.passingPercent))%; current score is \(Int(grade.percent.rounded()))%.") }
        var totals: [ApprenticeshipSkill: (awarded: Double, possible: Double)] = [:]
        for component in grade.components {
            let prior = totals[component.skill] ?? (0, 0)
            totals[component.skill] = (prior.awarded + component.awardedPoints, prior.possible + component.possiblePoints)
        }
        let skillScores = Dictionary(uniqueKeysWithValues: totals.map { skill, total in
            (skill, total.possible > 0 ? total.awarded / total.possible : 1)
        })
        return .init(chapter: exam.chapter, examID: exam.id, score: grade.percent, passed: passed, verificationPerformed: verificationPerformed, feedback: feedback, skillScores: skillScores)
    }

    public static func assessArchitecture(exam: ChapterCertificationExam, architecture: GeneratedControllerArchitecture, identifiedIssueIDs: Set<String>, repairedIssueIDs: Set<String>, verificationPerformed: Bool) -> ChapterCertificationResult {
        let base = GeneratedControllerArchitectureAssessor.assess(architecture, identifiedIssueIDs: identifiedIssueIDs, repairedIssueIDs: repairedIssueIDs, verificationPerformed: verificationPerformed)
        let rootCorrect = architecture.primaryIssue.map { identifiedIssueIDs.contains($0.id) } ?? false
        let requiredRepairs = Set(architecture.issues.filter(\.shouldRepair).map(\.id))
        let requiredComplete = requiredRepairs.isSubset(of: repairedIssueIDs)
        let passed = base.score >= exam.passingPercent && rootCorrect && requiredComplete && verificationPerformed
        var feedback = base.feedback
        if !rootCorrect { feedback.append("Certification requires identifying the primary cross-boundary root cause.") }
        if !requiredComplete { feedback.append("At least one real defect remains unrepaired.") }
        if base.score < exam.passingPercent { feedback.append("Certification requires \(Int(exam.passingPercent))%; current score is \(Int(base.score.rounded()))%.") }
        var skillScores = Dictionary(uniqueKeysWithValues: exam.requiredSkills.map { ($0, 1.0) })
        skillScores[.verification] = verificationPerformed ? 1 : 0
        if !rootCorrect, let boundary = architecture.primaryIssue?.boundary {
            let skill: ApprenticeshipSkill
            switch boundary {
            case .taskScheduling, .routineCallPath: skill = .scanReasoning
            case .tagScope: skill = .tagsAndTypes
            case .remoteIO, .explicitMessaging, .hmiMapping: skill = .communications
            case .historianCollection: skill = .historianReasoning
            }
            skillScores[skill] = 0
        }
        if !requiredComplete {
            for skill in exam.requiredSkills where skillScores[skill, default: 1] > 0.5 {
                skillScores[skill] = 0.5
            }
        }
        return .init(chapter: exam.chapter, examID: exam.id, score: base.score, passed: passed, verificationPerformed: verificationPerformed, feedback: feedback, skillScores: skillScores)
    }
}

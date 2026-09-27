import Foundation

public enum CertificationTranscriptEvent: Codable, Equatable, Sendable {
    case launched
    case inspectedArchitecture
    case identifiedPrimary(issueID: String)
    case repairSelection(issueID: String, selected: Bool)
    case verificationSet(Bool)
    case submitted(ChapterCertificationResult)
}

public struct CertificationAttemptTranscript: Codable, Equatable, Sendable {
    public let examID: String
    public let chapter: StepByStepChapter
    public let seed: UInt64
    public private(set) var events: [CertificationTranscriptEvent]

    public init(exam: ChapterCertificationExam) {
        self.examID = exam.id
        self.chapter = exam.chapter
        self.seed = exam.seed
        self.events = [.launched]
    }

    public mutating func append(_ event: CertificationTranscriptEvent) {
        events.append(event)
    }

    public var submittedResult: ChapterCertificationResult? {
        for event in events.reversed() {
            if case .submitted(let result) = event { return result }
        }
        return nil
    }

    public var identifiedPrimaryIssueID: String? {
        for event in events.reversed() {
            if case .identifiedPrimary(let issueID) = event { return issueID }
        }
        return nil
    }

    public var finalRepairSelections: Set<String> {
        var selected: Set<String> = []
        for event in events {
            if case .repairSelection(let issueID, let enabled) = event {
                if enabled { selected.insert(issueID) } else { selected.remove(issueID) }
            }
        }
        return selected
    }

    public var verificationPerformed: Bool {
        var state = false
        for event in events {
            if case .verificationSet(let value) = event { state = value }
        }
        return state
    }

    public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> CertificationAttemptTranscript {
        try JSONDecoder().decode(CertificationAttemptTranscript.self, from: data)
    }
}

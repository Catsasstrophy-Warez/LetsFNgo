import Foundation
import Testing

@testable import NexusCore

private struct SelfDescribingError: ClassifiableError {
    var classified: ClassifiedError {
        ClassifiedError(
            category: .evidenceVerification, whatHappened: "The reading contradicts the confirmed cause.",
            whatSurvived: ["The investigation"], nextActions: [NextAction("Re-measure", commandID: "measure")]
        )
    }
}

private struct ForeignError: Error {
    var code: Int
}

private struct UnknownError: Error {}

@Suite struct NexusErrorTests {
    @Test func classifiedErrorsPassThroughUnchanged() {
        let error = ClassifiedError(category: .userInput, whatHappened: "Voltage must be a number.")
        #expect(classify(error) == error)
    }

    @Test func classifiableErrorsDescribeThemselvesAndKeepTheUnderlyingDescription() {
        let classified = ErrorClassifier().classify(SelfDescribingError())
        #expect(classified.category == .evidenceVerification)
        #expect(classified.whatSurvived == ["The investigation"])
        #expect(classified.nextActions == [NextAction("Re-measure", commandID: "measure")])
        #expect(classified.underlyingDescription.contains("SelfDescribingError"))
    }

    @Test func registeredMappersHandleForeignErrorsNewestFirst() {
        let classifier = ErrorClassifier()
        classifier.register(ForeignError.self) { error in
            ClassifiedError(category: .dataSource, whatHappened: "Source failed with \(error.code)")
        }
        let token = classifier.register(ForeignError.self) { error in
            ClassifiedError(category: .agentTool, whatHappened: "Tool failed with \(error.code)")
        }
        #expect(classifier.classify(ForeignError(code: 7)).category == .agentTool)
        #expect(classifier.classify(ForeignError(code: 7)).whatHappened == "Tool failed with 7")

        classifier.unregister(token)
        #expect(classifier.classify(ForeignError(code: 7)).category == .dataSource)
        // Mappers only answer for their own type.
        #expect(classifier.classify(UnknownError()).category == .systemRuntime)
    }

    @Test func builtInRulesCoverCancellationDecodingAndFallback() {
        let classifier = ErrorClassifier()
        let cancelled = classifier.classify(CancellationError())
        #expect(cancelled.category == .systemRuntime)
        #expect(!cancelled.whatSurvived.isEmpty)

        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        #expect(classifier.classify(decoding).category == .dataSource)

        let fallback = classifier.classify(UnknownError())
        #expect(fallback.category == .systemRuntime)
        #expect(!fallback.nextActions.isEmpty, "Every error offers a next action")
        #expect(fallback.underlyingDescription.contains("UnknownError"))
    }

    @Test func preservedStateAndActionsCanBeAddedWhereTheErrorIsCaught() {
        let error = ClassifiedError(category: .systemRuntime, whatHappened: "Save failed.")
            .preserving("Your draft", "Measurements up to 14:02")
            .suggesting(NextAction("Retry save", commandID: "save"))
        #expect(error.whatSurvived == ["Your draft", "Measurements up to 14:02"])
        #expect(error.nextActions.map(\.commandID) == ["save"])
    }

    @Test func classifiedErrorsRoundTripThroughJSON() throws {
        let error = ClassifiedError(
            category: .agentTool, whatHappened: "Permission denied.", whatSurvived: ["The plan"],
            nextActions: [NextAction("Ask for approval", commandID: "approve"), NextAction("Cancel")], underlyingDescription: "denied"
        )
        let decoded = try JSONDecoder().decode(ClassifiedError.self, from: JSONEncoder().encode(error))
        #expect(decoded == error)
        #expect(ErrorCategory.allCases.count == 5)
    }
}

import Testing
@testable import NexusAI

private func pair(_ id: String, result: String) -> [ChatMessage] {
    [
        ChatMessage(role: .assistant, toolCalls: [ToolCall(id: id, name: "get_object")]),
        ChatMessage(role: .tool, toolResults: [ToolResult(callID: id, content: result)]),
    ]
}

private let long = String(repeating: "x", count: 4_000)

@Suite struct ContextBudgetTests {
    let conversation: [ChatMessage] = [.system("You are careful."), .user("Find the fault.")]
        + pair("a", result: long) + pair("b", result: long) + pair("c", result: "short")

    @Test func heuristicIsAboutFourCharactersPerToken() {
        let budget = ContextBudget(contextTokens: 1_000, tokensPerMessage: 0)
        #expect(budget.estimateTokens([.user(String(repeating: "a", count: 400))]) == 100)
        #expect(budget.estimateTokens([.user("abc")]) == 1)
        #expect(ContextBudget(contextTokens: 1_000).estimateTokens([.user("")]) == 4)
    }

    @Test func requestsThatFitAreUntouched() async throws {
        let request = GenerationRequest(messages: conversation, maxOutputTokens: 100)
        let (fitted, trim) = try await ContextBudget(contextTokens: 100_000).fit(request)
        #expect(fitted == request && trim == nil)
    }

    @Test func oldestToolResultsAreShortenedFirst() async throws {
        let budget = ContextBudget(contextTokens: 1_500)
        let request = GenerationRequest(messages: conversation, maxOutputTokens: 200)
        let (fitted, trim) = try await budget.fit(request)
        let trimmed = try #require(trim)
        #expect(trimmed.shortenedResults == 1 && trimmed.droppedMessages == 0 && trimmed.trimmedCharacters == 4_000)
        #expect(fitted.messages.count == conversation.count)
        #expect(fitted.messages[3].toolResults[0].content == ContextBudget.marker(trimming: 4_000))
        #expect(fitted.messages[3].toolResults[0].content.contains("4000 characters"))
        #expect(fitted.messages[5].toolResults[0].content == long, "Newer results are kept while it fits")
        #expect(trimmed.tokensAfter <= 1_500 && trimmed.tokensBefore > 1_500)
    }

    @Test func thenWholeCallAndResultPairsAreDropped() async throws {
        // Tools and output reserve leave room for little more than the protected messages.
        let tools = [ToolSpec(name: "get_object", description: String(repeating: "d", count: 400), permission: .observe)]
        let budget = ContextBudget(contextTokens: 190)
        let (fitted, trim) = try await budget.fit(GenerationRequest(messages: conversation, tools: tools, maxOutputTokens: 50))
        let trimmed = try #require(trim)
        #expect(trimmed.shortenedResults == 2)
        #expect(trimmed.droppedMessages == 4)
        #expect(fitted.messages.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(fitted.messages[0].text == "You are careful." && fitted.messages[1].text == "Find the fault.")
        #expect(fitted.messages[2].toolCalls[0].id == "c" && fitted.messages[3].toolResults[0].callID == "c")
    }

    @Test func markersAreNeverTrimmedAgain() async throws {
        let marker = ContextBudget.marker(trimming: 20_000)
        #expect(ContextBudget.isMarker(marker) && !ContextBudget.isMarker("[Trimmed x characters to fit the context window]"))
        let messages: [ChatMessage] = [.user("goal")] + pair("a", result: marker) + pair("b", result: long)
        let (fitted, trim) = try await ContextBudget(contextTokens: 200).fit(GenerationRequest(messages: messages, maxOutputTokens: 0))
        #expect(trim?.shortenedResults == 1)
        #expect(fitted.messages[2].toolResults[0].content == marker)
    }

    @Test func throwsWhenEvenTheProtectedMessagesDoNotFit() async throws {
        await #expect(throws: AIError.contextTooLarge) {
            try await ContextBudget(contextTokens: 100).fit(GenerationRequest(messages: [.system(long), .user("goal")], maxOutputTokens: 10))
        }
        await #expect(throws: AIError.contextTooLarge) {
            try await ContextBudget(contextTokens: 1_000).fit(GenerationRequest(messages: [.user("goal")], maxOutputTokens: 4_096))
        }
    }

    @Test func providerCountsTakePrecedence() async throws {
        let request = GenerationRequest(messages: conversation, maxOutputTokens: 0)
        // The provider says the conversation is tiny: nothing to trim.
        let (_, none) = try await ContextBudget(contextTokens: 100).fit(request) { _ in 10 }
        #expect(none == nil)
        // The provider says every message costs 50: trimming continues until pairs go.
        let (fitted, trim) = try await ContextBudget(contextTokens: 200).fit(request) { $0.count * 50 }
        #expect(fitted.messages.count == 4 && trim?.droppedMessages == 4)
    }
}

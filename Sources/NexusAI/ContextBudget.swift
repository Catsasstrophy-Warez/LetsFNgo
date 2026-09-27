import Foundation

/// What `ContextBudget.fit` did to a request.
public struct ContextTrim: Sendable, Hashable {
    /// Tool results whose content was replaced by a marker.
    public var shortenedResults: Int
    /// Messages dropped (assistant tool-call turns and their result turns).
    public var droppedMessages: Int
    /// Characters removed from tool results.
    public var trimmedCharacters: Int
    /// Estimated tokens before and after, including tools and output reserve.
    public var tokensBefore: Int
    public var tokensAfter: Int

    public init(shortenedResults: Int = 0, droppedMessages: Int = 0, trimmedCharacters: Int = 0, tokensBefore: Int = 0, tokensAfter: Int = 0) {
        self.shortenedResults = shortenedResults
        self.droppedMessages = droppedMessages
        self.trimmedCharacters = trimmedCharacters
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }

    public var summary: String {
        "Trimmed context from ~\(tokensBefore) to ~\(tokensAfter) tokens: shortened \(shortenedResults) tool result(s) "
            + "(\(trimmedCharacters) characters), dropped \(droppedMessages) message(s)"
    }
}

/// Keeps a request inside a model's context window.
///
/// Budget: messages + tool specs + `maxOutputTokens` ≤ `contextTokens`.
/// Tokens are the provider's own count when it offers one
/// (`LanguageModelProvider.countTokens`), otherwise a heuristic of about
/// `charactersPerToken` characters per token.
///
/// When over budget it trims, in order, and stops as soon as it fits:
/// 1. Shortens the oldest tool results, replacing each one's content with a
///    marker that says how many characters were removed.
/// 2. Drops the oldest complete assistant + tool pairs. A tool call is never
///    separated from its results.
/// 3. Throws `AIError.contextTooLarge`.
///
/// System messages and the first user message (the goal) are never touched.
public struct ContextBudget: Sendable, Hashable {
    public var contextTokens: Int
    public var charactersPerToken: Double
    /// Fixed per-message overhead for role markers and framing.
    public var tokensPerMessage: Int

    public init(contextTokens: Int, charactersPerToken: Double = 4, tokensPerMessage: Int = 4) {
        self.contextTokens = contextTokens
        self.charactersPerToken = charactersPerToken
        self.tokensPerMessage = tokensPerMessage
    }

    public init(for model: ModelDescriptor) {
        self.init(contextTokens: model.contextTokens)
    }

    /// Heuristic token estimate for messages.
    public func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + tokens(characters: characters(in: $1)) + tokensPerMessage }
    }

    /// Heuristic token estimate for tool definitions.
    public func estimateTokens(_ tools: [ToolSpec]) -> Int {
        tools.reduce(0) { total, spec in
            total + tokens(characters: spec.name.count + spec.description.count + JSONValue(spec.parameters).serialized.count) + tokensPerMessage
        }
    }

    /// Returns `request`, trimmed if needed to fit, and what was trimmed
    /// (nil when nothing was). `counter` supplies a provider token count.
    public func fit(
        _ request: GenerationRequest,
        counter: (@Sendable ([ChatMessage]) async throws -> Int?)? = nil
    ) async throws -> (request: GenerationRequest, trim: ContextTrim?) {
        let fixed = estimateTokens(request.tools) + request.maxOutputTokens
        func total(_ messages: [ChatMessage]) async throws -> Int {
            let counted = try await counter?(messages)
            return fixed + (counted ?? estimateTokens(messages))
        }

        var messages = request.messages
        let before = try await total(messages)
        guard before > contextTokens else { return (request, nil) }
        var trim = ContextTrim(tokensBefore: before)
        func done() async throws -> Bool {
            let now = try await total(messages)
            trim.tokensAfter = now
            return now <= contextTokens
        }

        // 1. Shorten tool results, oldest first.
        for index in messages.indices where messages[index].role == .tool {
            for resultIndex in messages[index].toolResults.indices {
                let content = messages[index].toolResults[resultIndex].content
                let marker = ContextBudget.marker(trimming: content.count)
                guard content.count > marker.count, !ContextBudget.isMarker(content) else { continue }
                messages[index].toolResults[resultIndex].content = marker
                trim.shortenedResults += 1
                trim.trimmedCharacters += content.count
                if try await done() {
                    return (request.with(messages: messages), trim)
                }
            }
        }

        // 2. Drop assistant + tool pairs, oldest first.
        let goal = messages.firstIndex { $0.role == .user }
        var index = 0
        while index + 1 < messages.count {
            let isPair = messages[index].role == .assistant && !messages[index].toolCalls.isEmpty
                && messages[index + 1].role == .tool && index != goal
            guard isPair else {
                index += 1
                continue
            }
            // Take every consecutive result turn with the call.
            var end = index + 1
            while end + 1 < messages.count, messages[end + 1].role == .tool { end += 1 }
            messages.removeSubrange(index ... end)
            trim.droppedMessages += end - index + 1
            if try await done() {
                return (request.with(messages: messages), trim)
            }
        }
        throw AIError.contextTooLarge
    }

    /// The text that replaces a trimmed tool result.
    public static func marker(trimming characters: Int) -> String {
        markerPrefix + String(characters) + markerSuffix
    }

    /// Whether `content` is already a trim marker (so it is not trimmed again).
    public static func isMarker(_ content: String) -> Bool {
        content.hasPrefix(markerPrefix) && content.hasSuffix(markerSuffix)
            && Int(content.dropFirst(markerPrefix.count).dropLast(markerSuffix.count)) != nil
    }

    private static let markerPrefix = "[Trimmed "
    private static let markerSuffix = " characters to fit the context window]"

    private func tokens(characters: Int) -> Int {
        Int((Double(characters) / charactersPerToken).rounded(.up))
    }

    private func characters(in message: ChatMessage) -> Int {
        if let raw = message.providerContent { return raw.count }
        return message.text.count
            + message.toolCalls.reduce(0) { $0 + $1.id.count + $1.name.count + JSONValue(.map($1.arguments)).serialized.count }
            + message.toolResults.reduce(0) { $0 + $1.callID.count + $1.content.count }
    }
}

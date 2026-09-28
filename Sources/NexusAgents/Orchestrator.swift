import Foundation
import NexusAI

/// Which specialist an orchestrator picked, and how.
public struct OrchestratorChoice: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        /// The model named a specialist.
        case model
        /// Keyword match on the goal.
        case keywords
        /// Nothing matched; the default specialist.
        case fallback
    }

    public var profile: AgentProfile
    public var method: Method
    public var reason: String
}

/// Picks the specialist for a goal.
///
/// With a model, it asks for a choice constrained to the specialists' IDs
/// (structured output, with the reply text as a second chance). When the
/// model is absent, fails, or names no known specialist, a deterministic
/// keyword match decides: each specialist scores one point per keyword found
/// in the goal (single words match as word prefixes, phrases as substrings);
/// the highest score wins, ties go to the earlier specialist, and no match at
/// all gives `fallback`.
public struct Orchestrator: Sendable {
    public var specialists: [AgentProfile]
    public var fallback: AgentProfile

    public init(specialists: [AgentProfile] = AgentProfile.specialists, fallback: AgentProfile = .diagnostician) {
        self.specialists = specialists
        self.fallback = fallback
    }

    /// The JSON Schema of the model's answer.
    public var schema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "agent": .object(["type": .string("string"), "enum": .array(specialists.map { .string($0.id) })]),
                "reason": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("agent")]),
            "additionalProperties": .bool(false),
        ])
    }

    public func choose(for goal: String, context: String = "", model: (any LanguageModelProvider)?) async -> OrchestratorChoice {
        guard let model else { return keywordChoice(for: goal) }
        let roster = specialists.map { "- \($0.id): \($0.summary)" }.joined(separator: "\n")
        let request = GenerationRequest(
            messages: [
                .system(
                    """
                    Choose the one specialist best suited to the user's goal. Specialists:
                    \(roster)
                    Reply with JSON: {"agent": "<id>", "reason": "<one sentence>"}.
                    """
                ),
                .user(context.isEmpty ? goal : "\(goal)\n\nContext:\n\(context)"),
            ],
            maxOutputTokens: 256, responseSchema: schema
        )
        guard let response = try? await model.respond(to: request), response.stopReason == .endTurn else {
            var choice = keywordChoice(for: goal)
            choice.reason = "Model gave no answer; " + choice.reason
            return choice
        }
        if let (profile, reason) = parse(response) {
            return OrchestratorChoice(profile: profile, method: .model, reason: reason)
        }
        var choice = keywordChoice(for: goal)
        choice.reason = "Model gave no usable choice; " + choice.reason
        return choice
    }

    /// The model's pick: the structured `agent` when it validates, else a
    /// reply that is exactly one specialist ID or mentions exactly one.
    func parse(_ response: ModelResponse) -> (AgentProfile, String)? {
        if let structured = response.structured, JSONSchema.conforms(structured, to: schema),
            let id = structured["agent"]?.stringValue, let profile = specialists.first(where: { $0.id == id })
        {
            return (profile, structured["reason"]?.stringValue ?? "Chosen by the model")
        }
        let text = response.message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let profile = specialists.first(where: { $0.id == text }) { return (profile, "Chosen by the model") }
        let words = Set(Self.words(text))
        let named = specialists.filter { words.contains($0.id) }
        if named.count == 1 { return (named[0], "Chosen by the model") }
        return nil
    }

    public func keywordChoice(for goal: String) -> OrchestratorChoice {
        let lower = goal.lowercased()
        let words = Self.words(lower)
        var best: (profile: AgentProfile, hits: [String])?
        for profile in specialists {
            let hits = profile.keywords.filter { keyword in
                keyword.contains(" ") ? lower.contains(keyword) : words.contains { $0.hasPrefix(keyword) }
            }
            if !hits.isEmpty, hits.count > (best?.hits.count ?? 0) { best = (profile, hits) }
        }
        guard let best else {
            return OrchestratorChoice(profile: fallback, method: .fallback, reason: "No specialist keyword in the goal; using \(fallback.id)")
        }
        return OrchestratorChoice(profile: best.profile, method: .keywords, reason: "Keywords: " + best.hits.joined(separator: ", "))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init)
    }
}

import Foundation
import NexusCore
import NexusModel
import NexusPermissions

/// A tool the model may call. Arguments and results are plain values so any
/// provider (Apple Foundation Models, MLX, a cloud API) can map them.
public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON-Schema-like description of the arguments, as a `Value.map`.
    public var parameters: Value
    public var permission: PermissionLevel

    public init(name: String, description: String, parameters: Value = .map([:]), permission: PermissionLevel) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.permission = permission
    }
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: [String: Value]

    public init(id: String, name: String, arguments: [String: Value] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Sendable, Hashable {
    public var callID: String
    public var content: String
    /// Failed or refused calls are returned as errors, never dropped.
    public var isError: Bool

    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}

public enum Role: String, Sendable, Hashable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatMessage: Sendable, Hashable {
    public var role: Role
    public var text: String
    /// Assistant turns may request several tools at once.
    public var toolCalls: [ToolCall]
    /// A tool turn returns every result for the preceding calls together.
    public var toolResults: [ToolResult]

    public init(role: Role, text: String = "", toolCalls: [ToolCall] = [], toolResults: [ToolResult] = []) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, text: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
}

public enum StopReason: String, Sendable, Hashable {
    case endTurn
    case toolUse
    case maxTokens
    /// The model declined. Callers must check before reading the output.
    case refusal
}

public struct Usage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

public struct GenerationRequest: Sendable, Hashable {
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var maxOutputTokens: Int

    public init(messages: [ChatMessage], tools: [ToolSpec] = [], maxOutputTokens: Int = 4_096) {
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ModelResponse: Sendable, Hashable {
    public var message: ChatMessage
    public var stopReason: StopReason
    public var usage: Usage

    public init(message: ChatMessage, stopReason: StopReason, usage: Usage = Usage()) {
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
    }
}

/// Where a model runs, in the order the router prefers them.
public enum ModelTier: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Apple's system model, optionally with a Nexus adapter.
    case onDevice = 1
    /// A Nexus-tuned open-weights model run locally through MLX.
    case localLarge = 2
    /// Apple Private Cloud Compute.
    case privateCloud = 3
    /// A third-party cloud model. Using it is an external action (P4).
    case thirdPartyCloud = 4

    public static func < (lhs: ModelTier, rhs: ModelTier) -> Bool { lhs.rawValue < rhs.rawValue }

    public var isLocal: Bool { self <= .localLarge }
}

public struct ModelDescriptor: Sendable, Hashable {
    public var ref: ModelRef
    public var tier: ModelTier
    public var contextTokens: Int
    public var supportsTools: Bool
    public var supportsImages: Bool

    public init(ref: ModelRef, tier: ModelTier, contextTokens: Int, supportsTools: Bool = true, supportsImages: Bool = false) {
        self.ref = ref
        self.tier = tier
        self.contextTokens = contextTokens
        self.supportsTools = supportsTools
        self.supportsImages = supportsImages
    }
}

/// Any language model Nexus can talk to. Implementations live in
/// platform targets (Foundation Models, MLX, cloud); tests use `ScriptedModel`.
public protocol LanguageModelProvider: Sendable {
    var descriptor: ModelDescriptor { get }
    func respond(to request: GenerationRequest) async throws -> ModelResponse
}

public enum AIError: Error, Equatable, Sendable {
    case noEligibleModel
    case scriptExhausted
}

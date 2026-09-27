#if canImport(FoundationModels) && canImport(SwiftUI)
import Foundation
import FoundationModels
import NexusAgents
import NexusAI
import NexusCore
import NexusModel
import NexusPermissions
import NexusUI

/// Chooses and installs the language models available on this device.
@MainActor
enum ModelProviders {
    static func install(into env: NexusEnvironment) {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        var providers: [any LanguageModelProvider] = []
        let system = SystemLanguageModel.default
        if system.isAvailable {
            providers.append(FoundationModelsProvider(
                model: system,
                descriptor: ModelDescriptor(
                    ref: ModelRef(provider: "apple.foundation-models", modelID: "system"),
                    tier: .onDevice, contextTokens: system.contextSize, supportsTools: true, supportsImages: true
                )
            ))
        }
        let cloud = PrivateCloudComputeLanguageModel()
        if cloud.isAvailable {
            providers.append(FoundationModelsProvider(
                model: cloud,
                descriptor: ModelDescriptor(
                    ref: ModelRef(provider: "apple.private-cloud-compute", modelID: "pcc"),
                    tier: .privateCloud, contextTokens: cloud.contextSize, supportsTools: true, supportsImages: true
                )
            ))
        }
        // A Nexus-tuned open model exported with Core AI plugs in here as one
        // more FoundationModelsProvider once `coreai-models` builds for the
        // simulator (see docs/APPLE_PLATFORM_NOTES.md).
        guard !providers.isEmpty else { return }
        env.agents = AgentRuntime(
            store: env.store, router: ModelRouter(providers: providers), permissions: env.permissions, tools: WorldTools.all
        )
    }
}

/// Any Foundation Models `LanguageModel` (on-device, Private Cloud Compute, or
/// a custom provider) behind Nexus's provider protocol.
///
/// The framework runs tools itself, so every tool call is routed back through
/// `toolHandler`: the agent runtime's permission checks, per-call rollback and
/// ledger apply to each call the model makes.
@available(iOS 27.0, macOS 27.0, *)
struct FoundationModelsProvider: LanguageModelProvider {
    let model: any FoundationModels.LanguageModel
    let descriptor: ModelDescriptor

    func respond(to request: GenerationRequest) async throws -> ModelResponse {
        try await respond(to: request) { call in
            ToolResult(callID: call.id, content: "Tools are not available in this context.", isError: true)
        }
    }

    func respond(to request: GenerationRequest, toolHandler: @escaping ToolHandler) async throws -> ModelResponse {
        let instructionText = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let tools: [any Tool] = try request.tools.map { try BridgedTool(spec: $0, handler: toolHandler) }
        let session = LanguageModelSession(model: model, tools: tools) {
            instructionText
        }
        let prompt = Self.prompt(from: request.messages)
        let options = GenerationOptions(maximumResponseTokens: request.maxOutputTokens)
        do {
            let response = try await session.respond(to: prompt, options: options)
            return ModelResponse(message: ChatMessage(role: .assistant, text: response.content), stopReason: .endTurn)
        } catch let error as LanguageModelError {
            switch error {
            case .refusal, .guardrailViolation:
                return ModelResponse(message: ChatMessage(role: .assistant), stopReason: .refusal)
            case .contextSizeExceeded:
                return ModelResponse(message: ChatMessage(role: .assistant), stopReason: .maxTokens)
            default:
                throw error
            }
        }
    }

    /// Everything after the system instructions, as one prompt. Earlier tool
    /// results stay visible to the model as text.
    static func prompt(from messages: [ChatMessage]) -> String {
        messages.filter { $0.role != .system }.map { message in
            switch message.role {
            case .user: message.text
            case .assistant: "Assistant: \(message.text)"
            case .tool: message.toolResults.map { "Tool result: \($0.content)" }.joined(separator: "\n")
            case .system: ""
            }
        }
        .joined(separator: "\n\n")
    }
}

/// A Nexus `ToolSpec` presented to Foundation Models, with a schema built at
/// runtime and execution delegated to the agent runtime.
@available(iOS 27.0, macOS 27.0, *)
struct BridgedTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let handler: ToolHandler

    init(spec: ToolSpec, handler: @escaping ToolHandler) throws {
        name = spec.name
        description = spec.description
        self.handler = handler
        var properties: [DynamicGenerationSchema.Property] = []
        var required: Set<String> = []
        if case .map(let schema) = spec.parameters {
            if case .list(let names)? = schema["required"] {
                required = Set(names.compactMap { if case .string(let name) = $0 { name } else { nil } })
            }
            if case .map(let declared)? = schema["properties"] {
                for key in declared.keys.sorted() {
                    var detail: String?
                    var isNumber = false
                    if case .map(let property)? = declared[key] {
                        if case .string(let text)? = property["description"] { detail = text }
                        if case .string(let type)? = property["type"] { isNumber = type == "number" || type == "integer" }
                    }
                    let schema = isNumber ? DynamicGenerationSchema(type: Double.self) : DynamicGenerationSchema(type: String.self)
                    properties.append(.init(name: key, description: detail, schema: schema, isOptional: !required.contains(key)))
                }
            }
        }
        parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: "\(spec.name)_arguments", description: spec.description, properties: properties),
            dependencies: []
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        var values: [String: Value] = [:]
        if let parsed = try? JSONValue(parsing: arguments.jsonString), case .map(let map) = parsed.value {
            values = map
        }
        let result = await handler(ToolCall(id: UUID().uuidString, name: name, arguments: values))
        return result.isError ? "Error: \(result.content)" : result.content
    }
}
#endif

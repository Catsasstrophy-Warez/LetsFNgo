#if canImport(FoundationModels) && canImport(SwiftUI)
import Foundation
import FoundationModels
import NexusAgents
import NexusAI
import NexusCloudProviders
import NexusCore
import NexusModel
import NexusPermissions
import NexusUI

/// Chooses and installs the language models available on this device.
@MainActor
enum ModelProviders {
    static func install(into env: NexusEnvironment) async {
        var providers: [any LanguageModelProvider] = []
        // L1: Apple's on-device model, from iOS 26 (iPhone 15 Pro and later,
        // including iPhone 17 Pro Max).
        let system = SystemLanguageModel.default
        if system.isAvailable {
            providers.append(FoundationModelsProvider(
                descriptor: ModelDescriptor(
                    ref: ModelRef(provider: "apple.foundation-models", modelID: "system"),
                    tier: .onDevice, contextTokens: 4_096, supportsTools: true, supportsImages: false
                ),
                makeSession: { tools, instructions in LanguageModelSession(model: system, tools: tools) { instructions } }
            ))
        }
        // L3: Private Cloud Compute, from iOS 27.
        if #available(iOS 27.0, macOS 27.0, *) {
            providers += await privateCloudProviders()
        }
        // L4: opt-in third-party cloud. The router only reaches it when the
        // person allows third-party cloud, and each run asks before data leaves.
        if let key = CloudCredentials.key(for: "anthropic") {
            providers.append(AnthropicProvider(apiKey: key))
        }
        env.installedModels = providers.map { "\($0.descriptor.ref.provider) · \($0.descriptor.ref.modelID) (\($0.descriptor.tier))" }
        env.agents = providers.isEmpty
            ? nil
            : AgentRuntime(store: env.store, router: ModelRouter(providers: providers), permissions: env.permissions, tools: WorldTools.all)
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func privateCloudProviders() async -> [any LanguageModelProvider] {
        let cloud = PrivateCloudComputeLanguageModel()
        guard cloud.isAvailable else { return [] }
        // Asked of the service, so it can fail; 32K is the documented size.
        let contextSize = (try? await cloud.contextSize) ?? 32_768
        // A Nexus-tuned open model exported with Core AI plugs in beside this
        // once `coreai-models` builds for the simulator (docs/APPLE_PLATFORM_NOTES.md).
        return [
            FoundationModelsProvider(
                descriptor: ModelDescriptor(
                    ref: ModelRef(provider: "apple.private-cloud-compute", modelID: "pcc"),
                    tier: .privateCloud, contextTokens: contextSize, supportsTools: true, supportsImages: true
                ),
                makeSession: { tools, instructions in LanguageModelSession(model: cloud, tools: tools) { instructions } }
            )
        ]
    }
}

/// A Foundation Models session behind Nexus's provider protocol: the
/// on-device system model (iOS 26) or Private Cloud Compute (iOS 27).
///
/// The framework runs tools itself, so every tool call is routed back through
/// `toolHandler`: the agent runtime's permission checks, per-call rollback and
/// ledger apply to each call the model makes. A request's JSON schema becomes
/// guided generation, so structured answers (hypotheses) are well formed.
struct FoundationModelsProvider: LanguageModelProvider {
    let descriptor: ModelDescriptor
    let makeSession: @Sendable ([any Tool], String) -> LanguageModelSession

    func respond(to request: GenerationRequest) async throws -> ModelResponse {
        try await respond(to: request) { call in
            ToolResult(callID: call.id, content: "Tools are not available in this context.", isError: true)
        }
    }

    func respond(to request: GenerationRequest, toolHandler: @escaping ToolHandler) async throws -> ModelResponse {
        let instructionText = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let tools: [any Tool] = try request.tools.map { try BridgedTool(spec: $0, handler: toolHandler) }
        let session = makeSession(tools, instructionText)
        let prompt = Self.prompt(from: request.messages)
        let options = GenerationOptions(maximumResponseTokens: request.maxOutputTokens)
        do {
            if let schema = request.responseSchema {
                let generation = try GenerationSchema(root: SchemaBridge.dynamic(schema, name: "Answer"), dependencies: [])
                let response = try await session.respond(to: prompt, schema: generation, includeSchemaInPrompt: true, options: options)
                let json = response.content.jsonString
                return ModelResponse(
                    message: ChatMessage(role: .assistant, text: json), stopReason: .endTurn, structured: try? JSONValue(parsing: json)
                )
            }
            let response = try await session.respond(to: prompt, options: options)
            return ModelResponse(message: ChatMessage(role: .assistant, text: response.content), stopReason: .endTurn)
        } catch {
            if let stop = Self.stopReason(for: error) {
                return ModelResponse(message: ChatMessage(role: .assistant), stopReason: stop)
            }
            throw error
        }
    }

    /// Refusals and guardrails end the turn as a refusal; an overlong
    /// context as max tokens. iOS 27 names these `LanguageModelError`; on
    /// iOS 26 the session's generation error carries the same cases.
    static func stopReason(for error: any Error) -> StopReason? {
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .refusal, .guardrailViolation: return .refusal
            case .contextSizeExceeded: return .maxTokens
            default: return nil
            }
        }
        let text = String(describing: error).lowercased()
        if text.contains("refusal") || text.contains("guardrail") { return .refusal }
        if text.contains("contextwindow") || text.contains("context window") || text.contains("exceededcontext") { return .maxTokens }
        return nil
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

/// JSON Schema (the subset Nexus uses: object, array, string, number,
/// integer, boolean, enum) as a Foundation Models dynamic schema.
enum SchemaBridge {
    static func dynamic(_ schema: JSONValue, name: String) -> DynamicGenerationSchema {
        let description = schema["description"]?.stringValue
        if let options = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: options)
        }
        switch schema["type"]?.stringValue {
        case "object":
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = (schema["properties"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, value in
                DynamicGenerationSchema.Property(
                    name: key, description: value["description"]?.stringValue, schema: dynamic(value, name: "\(name)_\(key)"),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        case "array":
            let item = schema["items"].map { dynamic($0, name: "\(name)_item") } ?? DynamicGenerationSchema(type: String.self)
            return DynamicGenerationSchema(arrayOf: item)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}

/// A Nexus `ToolSpec` presented to Foundation Models, with a schema built at
/// runtime and execution delegated to the agent runtime.
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

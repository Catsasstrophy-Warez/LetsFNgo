import Foundation
import NexusAI
import NexusCore
import NexusModel

/// Settings for `AnthropicProvider`.
public struct AnthropicConfiguration: Sendable, Hashable {
    public var model: String
    /// `max_tokens` sent with every request. Nil sends the request's own
    /// `maxOutputTokens` instead.
    public var maxTokens: Int?
    public var endpoint: URL
    public var apiVersion: String
    /// Server-side refusal fallbacks: the `fallbacks` body field. Nil turns
    /// them off (and drops the beta header).
    public var fallbacks: String?
    public var fallbackBeta: String
    public var contextTokens: Int
    /// Retries after the first attempt, for 408, 429, 5xx and transport errors.
    public var maxRetries: Int
    public var initialBackoff: Duration
    public var maxBackoff: Duration
    /// A `retry-after` longer than this fails at once instead of waiting.
    public var maxRetryAfter: Duration
    /// Per-token price, for cost accounting. Defaults to the list price of
    /// known models; nil when unknown.
    public var price: ModelPrice?

    public init(
        model: String = "claude-opus-5",
        maxTokens: Int? = 16_000,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        apiVersion: String = "2023-06-01",
        fallbacks: String? = "default",
        fallbackBeta: String = "server-side-fallback-2026-07-01",
        contextTokens: Int = 1_000_000,
        maxRetries: Int = 3,
        initialBackoff: Duration = .milliseconds(500),
        maxBackoff: Duration = .seconds(30),
        maxRetryAfter: Duration = .seconds(60),
        price: ModelPrice? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.endpoint = endpoint
        self.apiVersion = apiVersion
        self.fallbacks = fallbacks
        self.fallbackBeta = fallbackBeta
        self.contextTokens = contextTokens
        self.maxRetries = maxRetries
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.maxRetryAfter = maxRetryAfter
        self.price = price ?? Self.listPrices[model]
    }

    /// First-party list prices in USD per million tokens (input, output).
    public static let listPrices: [String: ModelPrice] = [
        "claude-fable-5-1": ModelPrice(inputPerMillionTokens: 10, outputPerMillionTokens: 50),
        "claude-fable-5": ModelPrice(inputPerMillionTokens: 10, outputPerMillionTokens: 50),
        "claude-opus-5-5": ModelPrice(inputPerMillionTokens: 4, outputPerMillionTokens: 20),
        "claude-opus-5": ModelPrice(inputPerMillionTokens: 5, outputPerMillionTokens: 25),
        "claude-sonnet-5": ModelPrice(inputPerMillionTokens: 2, outputPerMillionTokens: 10),
        "claude-haiku-4-5": ModelPrice(inputPerMillionTokens: 1, outputPerMillionTokens: 5),
    ]
}

/// Failures talking to the Messages API. None of them carries the API key.
public enum AnthropicError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 400: the request was malformed or rejected.
    case badRequest(String)
    /// 401: the API key is missing or invalid.
    case unauthorized(String)
    /// 403: the key may not use this resource.
    case forbidden(String)
    /// 404: unknown endpoint or model.
    case notFound(String)
    /// 429 after all retries.
    case rateLimited(String)
    /// 408 or 5xx after all retries.
    case unavailable(status: Int, message: String)
    /// Any other HTTP status.
    case http(status: Int, message: String)
    /// The connection failed after all retries.
    case transport(String)
    /// The response was not what the API documents.
    case invalidResponse(String)

    /// Whether trying again later may succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .unavailable, .transport: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .badRequest(let message): "Bad request: \(message)"
        case .unauthorized(let message): "Unauthorized: \(message)"
        case .forbidden(let message): "Forbidden: \(message)"
        case .notFound(let message): "Not found: \(message)"
        case .rateLimited(let message): "Rate limited: \(message)"
        case .unavailable(let status, let message): "Unavailable (\(status)): \(message)"
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .transport(let message): "Transport failure: \(message)"
        case .invalidResponse(let message): "Invalid response: \(message)"
        }
    }
}

/// Claude through the Anthropic Messages API (L4, third-party cloud).
///
/// Using it is an external action: the agent runtime asks for P4 approval
/// before any data is sent. The provider speaks raw HTTP through an
/// `HTTPTransport`; the API key is sent only in the `x-api-key` header and
/// never appears in descriptions, errors or logs.
///
/// Assistant turns keep the API's raw `content` array in
/// `ChatMessage.providerContent` and it is sent back verbatim, so thinking
/// blocks and their signatures round-trip unchanged.
public struct AnthropicProvider: LanguageModelProvider, CustomStringConvertible, CustomReflectable {
    public let descriptor: ModelDescriptor
    public let configuration: AnthropicConfiguration
    private let apiKey: String
    private let transport: any HTTPTransport
    private let sleeper: @Sendable (Duration) async throws -> Void

    public init(
        apiKey: String,
        configuration: AnthropicConfiguration = AnthropicConfiguration(),
        transport: any HTTPTransport = URLSessionTransport(),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.transport = transport
        self.sleeper = sleeper
        descriptor = ModelDescriptor(
            ref: ModelRef(provider: "anthropic", modelID: configuration.model), tier: .thirdPartyCloud,
            contextTokens: configuration.contextTokens, supportsTools: true, supportsImages: true, price: configuration.price
        )
    }

    public var description: String { "AnthropicProvider(\(configuration.model))" }

    public var customMirror: Mirror {
        Mirror(self, children: ["descriptor": descriptor, "configuration": configuration])
    }

    public func respond(to request: GenerationRequest) async throws -> ModelResponse {
        let http = HTTPRequest(url: configuration.endpoint, method: "POST", headers: headers(), body: Data(body(for: request).utf8))
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let failure: AnthropicError
            var retryAfter: Duration?
            do {
                let response = try await transport.send(http)
                if (200 ..< 300).contains(response.status) { return try parse(response.body, schema: request.responseSchema) }
                failure = error(for: response)
                retryAfter = response.header("retry-after").flatMap(Double.init).map { .milliseconds(Int64(($0 * 1_000).rounded())) }
            } catch let error as AnthropicError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = .transport(String(describing: error))
            }
            guard failure.isRetryable, attempt < configuration.maxRetries else { throw failure }
            let delay = retryAfter ?? backoff(attempt)
            guard delay <= configuration.maxRetryAfter else { throw failure }
            try await sleeper(delay)
            attempt += 1
        }
    }

    // MARK: Request

    func headers() -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": configuration.apiVersion,
            "content-type": "application/json",
        ]
        if configuration.fallbacks != nil { headers["anthropic-beta"] = configuration.fallbackBeta }
        return headers
    }

    /// The request body. Built from JSON fragments so stored provider
    /// content is spliced in byte for byte.
    func body(for request: GenerationRequest) -> String {
        var fields: [String: String] = [
            "model": JSONValue.quoted(configuration.model),
            "max_tokens": String(configuration.maxTokens ?? request.maxOutputTokens),
            "messages": "[" + messages(request.messages).joined(separator: ",") + "]",
        ]
        let system = request.messages.filter { $0.role == .system }.map(\.text).filter { !$0.isEmpty }
        if !system.isEmpty { fields["system"] = JSONValue.quoted(system.joined(separator: "\n\n")) }
        if !request.tools.isEmpty { fields["tools"] = JSONValue.array(request.tools.map(toolDefinition)).serialized }
        if let fallbacks = configuration.fallbacks { fields["fallbacks"] = JSONValue.quoted(fallbacks) }
        if let schema = request.responseSchema {
            fields["output_config"] = JSONValue.object(["format": .object(["type": .string("json_schema"), "schema": schema])]).serialized
        }
        return "{" + fields.keys.sorted().map { JSONValue.quoted($0) + ":" + fields[$0]! }.joined(separator: ",") + "}"
    }

    private func toolDefinition(_ spec: ToolSpec) -> JSONValue {
        var schema = JSONValue(spec.parameters).objectValue ?? [:]
        if schema["type"] == nil { schema["type"] = .string("object") }
        if schema["type"] == .string("object"), schema["properties"] == nil { schema["properties"] = .object([:]) }
        return .object(["name": .string(spec.name), "description": .string(spec.description), "input_schema": .object(schema)])
    }

    /// API messages. Tool results and user text that follow each other go
    /// into one user message, so all results for a turn travel together.
    private func messages(_ messages: [ChatMessage]) -> [String] {
        enum Turn {
            case user([JSONValue])
            case assistant(content: String)
        }
        var turns: [Turn] = []
        func appendUser(_ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if case .user(let existing)? = turns.last {
                turns[turns.count - 1] = .user(existing + blocks)
            } else {
                turns.append(.user(blocks))
            }
        }
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                appendUser(message.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(message.text)])])
            case .tool:
                appendUser(message.toolResults.map { result in
                    var block: [String: JSONValue] = [
                        "type": .string("tool_result"), "tool_use_id": .string(result.callID), "content": .string(result.content),
                    ]
                    if result.isError { block["is_error"] = .bool(true) }
                    return .object(block)
                })
            case .assistant:
                if let raw = message.providerContent, case .array? = try? JSONValue(parsing: raw) {
                    turns.append(.assistant(content: raw))
                    continue
                }
                var blocks: [JSONValue] = []
                if !message.text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(message.text)])) }
                for call in message.toolCalls {
                    blocks.append(.object([
                        "type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name),
                        "input": JSONValue(.map(call.arguments)),
                    ]))
                }
                if !blocks.isEmpty { turns.append(.assistant(content: JSONValue.array(blocks).serialized)) }
            }
        }
        return turns.map { turn in
            switch turn {
            case .user(let blocks): #"{"content":"# + JSONValue.array(blocks).serialized + #","role":"user"}"#
            case .assistant(let content): #"{"content":"# + content + #","role":"assistant"}"#
            }
        }
    }

    // MARK: Response

    /// With a `schema`, a finished answer's text is parsed as JSON into
    /// `structured` (nil if it isn't JSON).
    func parse(_ data: Data, schema: JSONValue? = nil) throws -> ModelResponse {
        let json: JSONValue
        do { json = try JSONValue(parsing: data) } catch { throw AnthropicError.invalidResponse("body is not JSON") }
        let usage = Usage(
            inputTokens: json["usage"]?["input_tokens"]?.intValue.map(Int.init) ?? 0,
            outputTokens: json["usage"]?["output_tokens"]?.intValue.map(Int.init) ?? 0
        )
        // The stop reason decides whether the content may be read at all.
        let stopReason: StopReason
        switch json["stop_reason"]?.stringValue {
        case "refusal":
            return ModelResponse(message: ChatMessage(role: .assistant), stopReason: .refusal, usage: usage)
        case "end_turn", "stop_sequence": stopReason = .endTurn
        case "tool_use": stopReason = .toolUse
        case "max_tokens", "model_context_window_exceeded": stopReason = .maxTokens
        case let other: throw AnthropicError.invalidResponse("unsupported stop_reason \(other ?? "null")")
        }

        guard let blocks = json["content"]?.arrayValue else { throw AnthropicError.invalidResponse("missing content") }
        var text = ""
        var calls: [ToolCall] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
                    throw AnthropicError.invalidResponse("tool_use without id or name")
                }
                guard let input = block["input"]?.objectValue else { throw AnthropicError.invalidResponse("tool_use input is not an object") }
                calls.append(ToolCall(id: id, name: name, arguments: input.mapValues(\.value)))
            default:
                continue  // Thinking and other blocks live on in providerContent.
            }
        }
        let raw = try? JSONValue.rawMember("content", in: data)
        let structured = schema != nil && stopReason == .endTurn ? try? JSONValue(parsing: text) : nil
        return ModelResponse(
            message: ChatMessage(role: .assistant, text: text, toolCalls: calls, providerContent: raw),
            stopReason: stopReason, usage: usage, structured: structured
        )
    }

    private func error(for response: HTTPResponse) -> AnthropicError {
        let json = try? JSONValue(parsing: response.body)
        let message = json?["error"]?["message"]?.stringValue ?? "HTTP \(response.status)"
        switch response.status {
        case 400: return .badRequest(message)
        case 401: return .unauthorized(message)
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 429: return .rateLimited(message)
        case 408, 500 ... 599: return .unavailable(status: response.status, message: message)
        default: return .http(status: response.status, message: message)
        }
    }

    /// Exponential backoff: initial × 2^attempt, capped.
    private func backoff(_ attempt: Int) -> Duration {
        min(configuration.initialBackoff * (1 << min(attempt, 20)), configuration.maxBackoff)
    }
}

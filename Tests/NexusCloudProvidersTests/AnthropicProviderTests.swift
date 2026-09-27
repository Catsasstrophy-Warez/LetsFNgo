import Foundation
import NexusAI
import NexusCore
import NexusModel
import Testing
@testable import NexusCloudProviders

private let apiKey = "sk-ant-test-SECRET-0123456789"

private struct Unreachable: Error {}

/// Replays canned responses and records every request. Never touches the network.
private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case response(HTTPResponse)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [HTTPRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply: Reply = try lock.withLock {
            requests.append(request)
            guard !replies.isEmpty else { throw Unreachable() }
            return replies.removeFirst()
        }
        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    func body(_ index: Int) throws -> JSONValue { try JSONValue(parsing: requests[index].body) }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sleeps: [Duration] = []
    func record(_ duration: Duration) { lock.withLock { sleeps.append(duration) } }
}

private func ok(_ json: String) -> FakeTransport.Reply {
    .response(HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(json.utf8)))
}

private func status(_ code: Int, _ message: String = "nope", headers: [String: String] = [:]) -> FakeTransport.Reply {
    .response(HTTPResponse(status: code, headers: headers, body: Data(#"{"type":"error","error":{"type":"x","message":"\#(message)"}}"#.utf8)))
}

private func provider(
    _ transport: FakeTransport,
    configuration: AnthropicConfiguration = AnthropicConfiguration(),
    sleeps: SleepRecorder = SleepRecorder()
) -> AnthropicProvider {
    AnthropicProvider(apiKey: apiKey, configuration: configuration, transport: transport, sleeper: { sleeps.record($0) })
}

private let endTurn = #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":3}}"#

@Suite struct AnthropicProviderTests {
    @Test func describesItselfAsAThirdPartyCloudModel() {
        let claude = provider(FakeTransport([]))
        #expect(claude.descriptor.ref == ModelRef(provider: "anthropic", modelID: "claude-opus-5"))
        #expect(claude.descriptor.tier == .thirdPartyCloud)
        #expect(claude.descriptor.contextTokens == 1_000_000)
        #expect(claude.descriptor.supportsTools && claude.descriptor.supportsImages)

        var dumped = ""
        dump(claude, to: &dumped)
        for text in [claude.description, String(describing: claude), String(reflecting: claude), dumped] {
            #expect(!text.contains(apiKey), "The API key never shows up in descriptions")
        }
    }

    @Test func requestBodyMatchesTheMessagesAPI() async throws {
        let transport = FakeTransport([ok(endTurn)])
        let tools = [ToolSpec(
            name: "get_measurements", description: "Readings at a test point.",
            parameters: .map(["type": .string("object"), "properties": .map(["test_point": .map(["type": .string("string")])]),
                "required": .list([.string("test_point")])]),
            permission: .observe
        ), ToolSpec(name: "ping", description: "No arguments.", permission: .observe)]
        let request = GenerationRequest(messages: [
            .system("You diagnose loops."),
            .user("Why does LT-101 clamp?"),
            ChatMessage(role: .assistant, text: "Checking.", toolCalls: [
                ToolCall(id: "toolu_1", name: "get_measurements", arguments: ["test_point": .string("tb-4"), "depth": .int(2)]),
                ToolCall(id: "toolu_2", name: "nope"),
            ]),
            ChatMessage(role: .tool, toolResults: [
                ToolResult(callID: "toolu_1", content: "12.0 V (observed)"),
                ToolResult(callID: "toolu_2", content: "Tool nope is not available.", isError: true),
            ]),
            .system("Be brief."),
        ], tools: tools)

        let response = try await provider(transport).respond(to: request)
        #expect(response.message.text == "Done." && response.stopReason == .endTurn)
        #expect(response.usage == Usage(inputTokens: 10, outputTokens: 3))

        let sent = try #require(transport.requests.first)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages" && sent.method == "POST")
        #expect(sent.header("x-api-key") == apiKey)
        #expect(sent.header("anthropic-version") == "2023-06-01")
        #expect(sent.header("content-type") == "application/json")
        #expect(sent.header("anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(!sent.description.contains(apiKey))

        let golden = try JSONValue(parsing: #"""
            {
              "model": "claude-opus-5",
              "max_tokens": 16000,
              "fallbacks": "default",
              "system": "You diagnose loops.\n\nBe brief.",
              "messages": [
                {"role": "user", "content": [{"type": "text", "text": "Why does LT-101 clamp?"}]},
                {"role": "assistant", "content": [
                  {"type": "text", "text": "Checking."},
                  {"type": "tool_use", "id": "toolu_1", "name": "get_measurements", "input": {"test_point": "tb-4", "depth": 2}},
                  {"type": "tool_use", "id": "toolu_2", "name": "nope", "input": {}}
                ]},
                {"role": "user", "content": [
                  {"type": "tool_result", "tool_use_id": "toolu_1", "content": "12.0 V (observed)"},
                  {"type": "tool_result", "tool_use_id": "toolu_2", "content": "Tool nope is not available.", "is_error": true}
                ]}
              ],
              "tools": [
                {"name": "get_measurements", "description": "Readings at a test point.", "input_schema": {
                  "type": "object", "properties": {"test_point": {"type": "string"}}, "required": ["test_point"]}},
                {"name": "ping", "description": "No arguments.", "input_schema": {"type": "object", "properties": {}}}
              ]
            }
            """#)
        #expect(try transport.body(0) == golden)
    }

    @Test func fallbacksAndMaxTokensAreConfigurable() async throws {
        let transport = FakeTransport([ok(endTurn)])
        let configuration = AnthropicConfiguration(model: "claude-sonnet-5", maxTokens: nil, fallbacks: nil)
        _ = try await provider(transport, configuration: configuration).respond(to: GenerationRequest(messages: [.user("hi")], maxOutputTokens: 512))
        let body = try transport.body(0)
        #expect(body["model"] == .string("claude-sonnet-5"))
        #expect(body["max_tokens"] == .int(512))
        #expect(body["fallbacks"] == nil && body["system"] == nil && body["tools"] == nil)
        #expect(transport.requests[0].header("anthropic-beta") == nil)
    }

    @Test func toolCallsRoundTripAndProviderContentIsReplayedVerbatim() async throws {
        // Irregular spacing, a thinking block and escapes: the replay must be byte-identical.
        let content = #"[ {"type":"thinking","thinking":"Check TB-4 é first.","signature":"EqQBCkYIBxgCKkC+/sig=="},  {"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_9","name":"get_measurements","input":{"test_point":"tb-4","limits":{"low":10.5,"high":12},"tags":["a",true,null]}} ]"#
        let toolUse = #"{"id":"msg_2","content":\#(content),"stop_reason":"tool_use","usage":{"input_tokens":50,"output_tokens":20}}"#
        let transport = FakeTransport([ok(toolUse), ok(endTurn)])
        let claude = provider(transport)

        let first = try await claude.respond(to: GenerationRequest(messages: [.user("Check the loop")]))
        #expect(first.stopReason == .toolUse)
        #expect(first.message.text == "Let me look.")
        #expect(first.message.providerContent == content)
        let call = try #require(first.message.toolCalls.first)
        #expect(call.id == "toolu_9" && call.name == "get_measurements")
        #expect(call.arguments == [
            "test_point": .string("tb-4"),
            "limits": .map(["low": .double(10.5), "high": .int(12)]),
            "tags": .list([.string("a"), .bool(true), .null]),
        ])

        let followUp = GenerationRequest(messages: [
            .user("Check the loop"), first.message, ChatMessage(role: .tool, toolResults: [ToolResult(callID: "toolu_9", content: "12.0 V")]),
        ])
        _ = try await claude.respond(to: followUp)
        let body = String(decoding: transport.requests[1].body, as: UTF8.self)
        #expect(body.contains(#"{"content":\#(content),"role":"assistant"}"#), "Assistant content is sent exactly as received")
        let messages = try #require(try transport.body(1)["messages"]?.arrayValue)
        #expect(messages.count == 3)
        #expect(messages[1]["content"] == (try JSONValue(parsing: content)))
        #expect(messages[2] == (try JSONValue(parsing: #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"12.0 V"}]}"#)))
    }

    @Test func refusalsAreReportedWithoutReadingContent() async throws {
        let refusal = #"{"content":[{"type":"text","text":"partial answer"},{"type":"tool_use","id":"t","name":"x","input":"not an object"}],"stop_reason":"refusal","usage":{"input_tokens":5,"output_tokens":1}}"#
        let response = try await provider(FakeTransport([ok(refusal)])).respond(to: GenerationRequest(messages: [.user("x")]))
        #expect(response.stopReason == .refusal)
        #expect(response.message.text.isEmpty && response.message.toolCalls.isEmpty && response.message.providerContent == nil)
        #expect(response.usage == Usage(inputTokens: 5, outputTokens: 1))
    }

    @Test func stopReasonsMapAndMalformedResponsesAreTyped() async throws {
        let maxTokens = #"{"content":[{"type":"text","text":"cut"}],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":1}}"#
        let cut = try await provider(FakeTransport([ok(maxTokens)])).respond(to: GenerationRequest(messages: [.user("x")]))
        #expect(cut.stopReason == .maxTokens && cut.message.text == "cut")

        let badInput = #"{"content":[{"type":"tool_use","id":"t","name":"x","input":"oops"}],"stop_reason":"tool_use"}"#
        await #expect(throws: AnthropicError.invalidResponse("tool_use input is not an object")) {
            try await provider(FakeTransport([ok(badInput)])).respond(to: GenerationRequest(messages: [.user("x")]))
        }
        await #expect(throws: AnthropicError.invalidResponse("body is not JSON")) {
            try await provider(FakeTransport([ok("<html>")])).respond(to: GenerationRequest(messages: [.user("x")]))
        }
    }

    @Test func retryableErrorsBackOffAndHonorRetryAfter() async throws {
        let sleeps = SleepRecorder()
        let transport = FakeTransport([
            status(429, "slow down", headers: ["Retry-After": "2"]),
            status(529, "overloaded"),
            .failure(Unreachable()),
            ok(endTurn),
        ])
        let response = try await provider(transport, sleeps: sleeps).respond(to: GenerationRequest(messages: [.user("x")]))
        #expect(response.message.text == "Done.")
        #expect(transport.requests.count == 4)
        #expect(sleeps.sleeps == [.seconds(2), .seconds(1), .seconds(2)], "retry-after first, then exponential backoff")
    }

    @Test func retriesAreBounded() async throws {
        let sleeps = SleepRecorder()
        let transport = FakeTransport(Array(repeating: status(500, "boom"), count: 10))
        let configuration = AnthropicConfiguration(maxRetries: 2)
        await #expect(throws: AnthropicError.unavailable(status: 500, message: "boom")) {
            try await provider(transport, configuration: configuration, sleeps: sleeps).respond(to: GenerationRequest(messages: [.user("x")]))
        }
        #expect(transport.requests.count == 3 && sleeps.sleeps.count == 2)

        // A retry-after beyond the limit fails at once rather than hanging.
        let patient = FakeTransport([status(429, "later", headers: ["retry-after": "3600"])])
        let error = await #expect(throws: AnthropicError.self) {
            try await provider(patient).respond(to: GenerationRequest(messages: [.user("x")]))
        }
        #expect(error == .rateLimited("later") && error?.isRetryable == true)
        #expect(patient.requests.count == 1)
    }

    @Test func clientErrorsAreNotRetriedAndNeverLeakTheKey() async throws {
        let cases: [(Int, AnthropicError)] = [
            (400, .badRequest("nope")), (401, .unauthorized("nope")), (403, .forbidden("nope")), (404, .notFound("nope")),
        ]
        for (code, expected) in cases {
            let sleeps = SleepRecorder()
            let transport = FakeTransport([status(code), ok(endTurn)])
            let error = await #expect(throws: AnthropicError.self) {
                try await provider(transport, sleeps: sleeps).respond(to: GenerationRequest(messages: [.user("x")]))
            }
            #expect(error == expected)
            #expect(error?.isRetryable == false)
            #expect(transport.requests.count == 1 && sleeps.sleeps.isEmpty)
            #expect(!String(describing: error).contains(apiKey))
        }
    }

    @Test func streamsThroughTheDefaultSingleEvent() async throws {
        let claude = provider(FakeTransport([ok(endTurn)]))
        var events: [ModelEvent] = []
        for try await event in claude.stream(to: GenerationRequest(messages: [.user("x")]), toolHandler: { ToolResult(callID: $0.id, content: "") }) {
            events.append(event)
        }
        #expect(events.count == 1)
        guard case .completed(let response)? = events.first else { Issue.record("Expected a completed event"); return }
        #expect(response.message.text == "Done.")
    }
}

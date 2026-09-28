import Foundation
import NexusAI
import NexusCore
import NexusModel
import Testing

@testable import NexusCloudProviders

/// Answers every request with one canned body and keeps the requests.
private final class CannedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: String
    private(set) var requests: [HTTPRequest] = []

    init(_ body: String) { self.body = body }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { requests.append(request) }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }
}

@Suite struct AnthropicStructuredOutputTests {
    private let schema: JSONValue = .object([
        "type": .string("object"), "properties": .object(["agent": .object(["type": .string("string")])]),
        "required": .array([.string("agent")]), "additionalProperties": .bool(false),
    ])

    @Test func responseSchemaIsSentAsOutputConfigAndParsedBack() async throws {
        let transport = CannedTransport(
            #"{"content":[{"type":"text","text":"{\"agent\":\"research\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":1000,"output_tokens":200}}"#
        )
        let claude = AnthropicProvider(apiKey: "sk-test", transport: transport)
        let response = try await claude.respond(to: GenerationRequest(messages: [.user("Pick one")], responseSchema: schema))
        #expect(response.structured == .object(["agent": .string("research")]))

        let body = try JSONValue(parsing: try #require(transport.requests.first).body)
        #expect(body["output_config"]?["format"]?["type"] == .string("json_schema"))
        #expect(body["output_config"]?["format"]?["schema"] == schema)

        // Without a schema: no output_config and no structured value.
        let plain = try await claude.respond(to: GenerationRequest(messages: [.user("Pick one")]))
        #expect(plain.structured == nil)
        #expect(try JSONValue(parsing: transport.requests[1].body)["output_config"] == nil)
    }

    @Test func knownModelsCarryTheirListPrice() {
        let opus = AnthropicProvider(apiKey: "sk-test", transport: CannedTransport("{}"))
        let price = opus.descriptor.price
        #expect(price == ModelPrice(inputPerMillionTokens: 5, outputPerMillionTokens: 25))
        #expect(price?.cost(of: Usage(inputTokens: 1_000_000, outputTokens: 100_000)) == 7.5)

        let custom = AnthropicProvider(
            apiKey: "sk-test", configuration: AnthropicConfiguration(model: "claude-custom"), transport: CannedTransport("{}")
        )
        #expect(custom.descriptor.price == nil)
        let priced = AnthropicProvider(
            apiKey: "sk-test",
            configuration: AnthropicConfiguration(model: "claude-custom", price: ModelPrice(inputPerMillionTokens: 1, outputPerMillionTokens: 2)),
            transport: CannedTransport("{}")
        )
        #expect(priced.descriptor.price?.outputPerMillionTokens == 2)
    }
}

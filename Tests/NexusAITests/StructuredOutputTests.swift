import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusAI

@Suite struct StructuredOutputTests {
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "agent": .object(["type": .string("string"), "enum": .array([.string("research"), .string("writing")])]),
            "score": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)]),
            "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "maxItems": .int(2)]),
        ]),
        "required": .array([.string("agent")]),
        "additionalProperties": .bool(false),
    ])

    @Test func schemaValidationReportsEveryViolation() throws {
        #expect(JSONSchema.conforms(try JSONValue(parsing: #"{"agent":"research","score":0.5,"tags":["a"]}"#), to: schema))
        #expect(JSONSchema.conforms(try JSONValue(parsing: #"{"agent":"writing","score":1}"#), to: schema))
        let bad = try JSONValue(parsing: #"{"agent":"cooking","score":2,"tags":["a","b",3],"extra":true}"#)
        let problems = JSONSchema.violations(of: bad, against: schema)
        #expect(problems.contains { $0.hasPrefix("$.agent:") })
        #expect(problems.contains("$.score: above maximum 1.0"))
        #expect(problems.contains("$.tags: more than 2 item(s)"))
        #expect(problems.contains("$.tags[2]: expected string, got integer"))
        #expect(problems.contains("$.extra: not allowed"))
        #expect(JSONSchema.violations(of: .object([:]), against: schema) == ["$.agent: required"])
        #expect(JSONSchema.violations(of: .array([]), against: schema) == ["$: expected object, got array"])
    }

    @Test func scriptedModelParsesStructuredAnswers() async throws {
        let model = ScriptedModel(script: [
            ModelResponse(message: ChatMessage(role: .assistant, text: #" {"agent": "research"} "#), stopReason: .endTurn),
            ModelResponse(message: ChatMessage(role: .assistant, text: "not json"), stopReason: .endTurn),
            ModelResponse(message: ChatMessage(role: .assistant, text: #"{"agent": "writing"}"#), stopReason: .endTurn),
            ModelResponse(
                message: ChatMessage(role: .assistant, text: "ignored"), stopReason: .endTurn, structured: .object(["agent": .string("writing")])
            ),
        ])
        let request = GenerationRequest(messages: [.user("Pick")], responseSchema: schema)
        #expect(try await model.respond(to: request).structured == .object(["agent": .string("research")]))
        #expect(try await model.respond(to: request).structured == nil)
        #expect(try await model.respond(to: GenerationRequest(messages: [.user("Pick")])).structured == nil, "No schema, no parsing")
        #expect(try await model.respond(to: request).structured == .object(["agent": .string("writing")]))
    }

    @Test func contextBudgetKeepsTheSchema() async throws {
        let budget = ContextBudget(contextTokens: 400, charactersPerToken: 4)
        let long = String(repeating: "x", count: 2_000)
        let request = GenerationRequest(
            messages: [
                .system("s"), .user("goal"), ChatMessage(role: .assistant, toolCalls: [ToolCall(id: "1", name: "t")]),
                ChatMessage(role: .tool, toolResults: [ToolResult(callID: "1", content: long)]),
            ],
            maxOutputTokens: 100, responseSchema: schema
        )
        let (fitted, trim) = try await budget.fit(request)
        #expect(trim != nil)
        #expect(fitted.responseSchema == schema)
    }

    @Test func pricesTurnUsageIntoCost() {
        let price = ModelPrice(inputPerMillionTokens: 5, outputPerMillionTokens: 25)
        #expect(price.cost(of: Usage(inputTokens: 2_000, outputTokens: 400)) == 0.02)
        let descriptor = ModelDescriptor(ref: ModelRef(provider: "p", modelID: "m"), tier: .thirdPartyCloud, contextTokens: 1, price: price)
        #expect(descriptor.price?.currency == "USD")
        #expect(ScriptedModel.defaultDescriptor.price == nil)
    }
}

@Suite struct QuantityScannerTests {
    @Test func numbersSkipIdentifiers() {
        let id = ObjectID.make()
        #expect(QuantityScanner.numbers(in: "LT-101 reads 12.0 V at -3 °C, object \(id), tag A7, 86.9 %.") == [12, -3, 86.9])
        #expect(QuantityScanner.numbers(in: "v1.2 costs 3.50") == [3.5])
        #expect(QuantityScanner.numbers(in: "range 4-20 mA") == [4, 20])
    }

    @Test func quantitiesNeedAUnit() {
        let found = QuantityScanner.quantities(in: "TB-4 reads 12.0 V and 86.9% at 25 degC; loop 4-20 mA, 3 checks, step 2 in the list, 250 ohms.")
        #expect(found.map(\.value) == [12, 86.9, 25, 4, 20, 250])
        #expect(found.map(\.unit) == ["V", "%", "°C", "mA", "mA", "Ω"])
        #expect(QuantityScanner.quantities(in: "12 Vdc supply, 5 kPa, 10.5 V.").map(\.unit) == ["V", "kPa", "V"])
        #expect(QuantityScanner.quantities(in: "Version 3 of the manual, 12 Vx").isEmpty)
    }

    @Test func rangesReadBoundsAndPoints() {
        let ranges = QuantityScanner.ranges(in: "Current is 4-20 mA, between 10 and 12 V, at least 10.5 V, up to 30 V, and 24 V nominal.")
        #expect(ranges.map { [$0.low, $0.high] } == [[4, 20], [10, 12], [10.5, .infinity], [-.infinity, 30], [24, 24]])
        #expect(ranges.map(\.unit) == ["mA", "V", "V", "V", "V"])
        #expect(QuantityScanner.ranges(in: "0 to 3 mA")[0].isDisjoint(from: ranges[0]))
        #expect(!ranges[2].isDisjoint(from: ranges[4]))
    }
}

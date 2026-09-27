import Foundation
import NexusAI
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence

public enum HypothesisDraftError: Error, Equatable, Sendable {
    /// The document does not match `HypothesisDraft.schema`.
    case schema([String])
    /// Prediction at this index has low > high or a non-finite bound.
    case invalidInterval(Int)
    case invalidPrior(Double)
    /// A prediction names a test point that is not an ID of a stored object.
    case unknownTestPoint(String)
    /// A prediction names an object that is not a test point.
    case notATestPoint(String)
    /// The model returned no JSON.
    case noStructuredOutput
}

/// A hypothesis as a model generates it with structured output, before it
/// is checked and stored. Plain, Sendable value types so any provider can
/// fill it: JSON Schema here, `@Generable` on Apple platforms.
public struct HypothesisDraft: Sendable, Hashable {
    public struct PredictionDraft: Sendable, Hashable {
        /// Object ID of the test point, as text.
        public var testPoint: String
        public var quantity: String
        public var low: Double
        public var high: Double
        public var unit: String

        public init(testPoint: String, quantity: String, low: Double, high: Double, unit: String) {
            self.testPoint = testPoint
            self.quantity = quantity
            self.low = low
            self.high = high
            self.unit = unit
        }
    }

    public var statement: String
    public var predictions: [PredictionDraft]
    /// Relative prior weight, > 0.
    public var prior: Double
    public var safetyNotes: [String]

    public init(statement: String, predictions: [PredictionDraft], prior: Double = 1, safetyNotes: [String] = []) {
        self.statement = statement
        self.predictions = predictions
        self.prior = prior
        self.safetyNotes = safetyNotes
    }

    /// The JSON Schema a model's output must follow.
    public static let schema: JSONValue = {
        func string(_ minLength: Int = 1, _ maxLength: Int = 500) -> JSONValue {
            .object(["type": .string("string"), "minLength": .int(Int64(minLength)), "maxLength": .int(Int64(maxLength))])
        }
        let prediction: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "testPoint": string(), "quantity": string(1, 100), "low": .object(["type": .string("number")]),
                "high": .object(["type": .string("number")]), "unit": string(1, 20),
            ]),
            "required": .array(["testPoint", "quantity", "low", "high", "unit"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "statement": string(3, 500),
                "predictions": .object(["type": .string("array"), "items": prediction, "maxItems": .int(8)]),
                "prior": .object(["type": .string("number"), "minimum": .int(0)]),
                "safetyNotes": .object(["type": .string("array"), "items": string(1, 500), "maxItems": .int(8)]),
            ]),
            "required": .array(["statement", "predictions", "prior", "safetyNotes"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }()

    /// Decodes and validates a model's JSON: the schema, then finite ordered
    /// intervals and a positive prior. Test point IDs are checked against
    /// the store by `predictions(in:)`.
    public init(json: JSONValue) throws {
        let problems = JSONSchema.violations(of: json, against: Self.schema)
        guard problems.isEmpty else { throw HypothesisDraftError.schema(problems) }
        statement = json["statement"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        prior = json["prior"]?.number ?? 1
        safetyNotes = json["safetyNotes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        predictions = (json["predictions"]?.arrayValue ?? []).map { item in
            PredictionDraft(
                testPoint: item["testPoint"]?.stringValue ?? "", quantity: item["quantity"]?.stringValue ?? "",
                low: item["low"]?.number ?? .nan, high: item["high"]?.number ?? .nan, unit: item["unit"]?.stringValue ?? ""
            )
        }
        guard prior > 0, prior.isFinite else { throw HypothesisDraftError.invalidPrior(prior) }
        for (index, prediction) in predictions.enumerated() where !(prediction.low.isFinite && prediction.high.isFinite && prediction.low <= prediction.high) {
            throw HypothesisDraftError.invalidInterval(index)
        }
    }

    /// Decodes a response: its `structured` value, or its text parsed as JSON.
    public init(response: ModelResponse) throws {
        guard let json = response.structured ?? (try? JSONValue(parsing: response.message.text.trimmingCharacters(in: .whitespacesAndNewlines))) else {
            throw HypothesisDraftError.noStructuredOutput
        }
        try self.init(json: json)
    }

    public var json: JSONValue {
        .object([
            "statement": .string(statement),
            "predictions": .array(
                predictions.map { prediction in
                    .object([
                        "testPoint": .string(prediction.testPoint), "quantity": .string(prediction.quantity), "low": .double(prediction.low),
                        "high": .double(prediction.high), "unit": .string(prediction.unit),
                    ])
                }),
            "prior": .double(prior),
            "safetyNotes": .array(safetyNotes.map(JSONValue.string)),
        ])
    }

    /// The predictions, with every test point resolved to a stored test point.
    public func predictions(in store: NexusStore) throws -> [Prediction] {
        try predictions.map { draft in
            guard let id = ObjectID(draft.testPoint.trimmingCharacters(in: .whitespaces)), let record = try store.object(id) else {
                throw HypothesisDraftError.unknownTestPoint(draft.testPoint)
            }
            guard record.type == .testPoint else { throw HypothesisDraftError.notATestPoint(draft.testPoint) }
            return Prediction(testPoint: id, quantity: draft.quantity, unit: draft.unit, low: draft.low, high: draft.high)
        }
    }

    /// Validates against the store and proposes through the investigation
    /// runtime. An agent's or model's draft becomes an interpretation.
    @discardableResult
    public func propose(
        in investigation: ObjectID,
        using runtime: InvestigationRuntime,
        dependsOn evidence: [ObjectID] = [],
        by author: Origin
    ) throws -> Hypothesis {
        try runtime.propose(
            statement, in: investigation, predictions: try predictions(in: runtime.store), prior: prior, safetyNotes: safetyNotes,
            dependsOn: evidence, by: author
        )
    }

    /// Asks `model` for one hypothesis with structured output and decodes it.
    /// `context` should list the symptom, the readings and the test point IDs.
    public static func generate(context: String, model: any LanguageModelProvider) async throws -> HypothesisDraft {
        let request = GenerationRequest(
            messages: [
                .system(
                    """
                    Propose one cause for the symptom as a testable hypothesis. Each prediction names a test point by its \
                    ID and the interval a reading there would fall in if the hypothesis is true. Add safety notes for any \
                    hazardous test. Reply with JSON.
                    """
                ),
                .user(context),
            ],
            maxOutputTokens: 1_024, responseSchema: schema
        )
        return try HypothesisDraft(response: try await model.respond(to: request))
    }
}

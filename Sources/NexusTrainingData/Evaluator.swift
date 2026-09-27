import Foundation
import NexusAgents
import NexusCore
import NexusModel
import NexusModelRegistry

/// One model output for one example, matched by `id`. Every field is optional:
/// a missing cause or next test counts as wrong, a missing answer is not scored.
public struct ModelPrediction: Codable, Sendable, Hashable {
    public var id: String
    public var predictedCause: String?
    public var predictedNextTest: String?
    public var answer: String?
    public var toolCalls: [ToolCallExample]?

    public init(id: String, predictedCause: String? = nil, predictedNextTest: String? = nil, answer: String? = nil, toolCalls: [ToolCallExample]? = nil) {
        self.id = id
        self.predictedCause = predictedCause
        self.predictedNextTest = predictedNextTest
        self.answer = answer
        self.toolCalls = toolCalls
    }
}

/// The JSON metrics report. Its metric keys match `EvalMetrics`, so the
/// promotion gate can read a report file directly.
public struct EvaluationReport: Codable, Sendable, Hashable {
    public var rootCauseAccuracy: Double?
    public var nextTestAgreement: Double?
    public var hallucinatedValueRate: Double?
    public var truthClassDiscipline: Double?
    public var toolCallValidity: Double?

    public var examples: Int
    public var predictions: Int
    public var missingPredictions: Int
    /// Predictions whose id matches no example; ignored.
    public var unmatchedPredictions: Int
    public var causesScored: Int
    public var nextTestsScored: Int
    public var answersScored: Int
    public var hallucinatedAnswers: Int
    public var numbersChecked: Int
    public var ungroundedNumbers: Int
    public var citedValues: Int
    public var correctlyLabeledValues: Int
    public var toolCallsScored: Int
    /// Root-cause accuracy per example kind.
    public var accuracyByKind: [String: Double]

    public var metrics: EvalMetrics {
        EvalMetrics(
            rootCauseAccuracy: rootCauseAccuracy, nextTestAgreement: nextTestAgreement, hallucinatedValueRate: hallucinatedValueRate,
            truthClassDiscipline: truthClassDiscipline, toolCallValidity: toolCallValidity
        )
    }
}

/// Scores predictions against the dataset's answer keys (docs/TRAINING_DATA.md).
///
/// - Root-cause accuracy: normalized exact match with `answer.cause`.
/// - Next-test agreement: normalized exact match with `answer.nextTest`, the
///   test `TestSelector` ranks first.
/// - Hallucinated-value rate: an answer fails if any number in it is not within
///   tolerance of a number in the example (observations, tool results, tests,
///   predictions, rankings, answer-key readings). Small integers 0…10 are
///   treated as counts and skipped, and digits inside identifiers (LT-101,
///   TB-4, UUIDs) are not numbers.
/// - Truth-class discipline: every number that cites a truth-labeled value
///   (same value within tolerance, followed by that value's unit) must be
///   followed by one of that value's truth classes before the next number.
/// - Tool-call validity: each predicted call names a WorldTools tool, has its
///   required arguments, and object-ID arguments parse as IDs.
public struct Evaluator: Sendable {
    public var absoluteTolerance: Double
    public var relativeTolerance: Double
    /// How far after a number its truth label may appear, in characters.
    public var labelWindow: Int

    public init(absoluteTolerance: Double = 0.05, relativeTolerance: Double = 0.01, labelWindow: Int = 48) {
        self.absoluteTolerance = absoluteTolerance
        self.relativeTolerance = relativeTolerance
        self.labelWindow = labelWindow
    }

    public func evaluate(examples: [TrainingExample], predictions: [ModelPrediction]) -> EvaluationReport {
        let byID = Dictionary(predictions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let exampleIDs = Set(examples.map(\.id))
        var report = EvaluationReport(
            examples: examples.count, predictions: predictions.count, missingPredictions: 0,
            unmatchedPredictions: Set(predictions.map(\.id)).subtracting(exampleIDs).count,
            causesScored: 0, nextTestsScored: 0, answersScored: 0, hallucinatedAnswers: 0, numbersChecked: 0, ungroundedNumbers: 0,
            citedValues: 0, correctlyLabeledValues: 0, toolCallsScored: 0, accuracyByKind: [:]
        )
        var correctCauses = 0
        var agreedTests = 0
        var validCalls = 0
        var byKind: [ExampleKind: (right: Int, total: Int)] = [:]
        let tools = Self.toolRequirements

        for example in examples {
            let prediction = byID[example.id]
            if prediction == nil {
                report.missingPredictions += 1
            }
            report.causesScored += 1
            let right = Self.normalized(prediction?.predictedCause) == Self.normalized(example.answer.cause)
            if right {
                correctCauses += 1
            }
            byKind[example.kind, default: (0, 0)].total += 1
            byKind[example.kind, default: (0, 0)].right += right ? 1 : 0

            if let nextTest = example.answer.nextTest {
                report.nextTestsScored += 1
                if Self.normalized(prediction?.predictedNextTest) == Self.normalized(nextTest) {
                    agreedTests += 1
                }
            }

            if let answer = prediction?.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.answersScored += 1
                let check = checkAnswer(answer, against: example)
                report.numbersChecked += check.numbers
                report.ungroundedNumbers += check.ungrounded
                report.citedValues += check.cited
                report.correctlyLabeledValues += check.labeled
                if check.ungrounded > 0 {
                    report.hallucinatedAnswers += 1
                }
            }

            for call in prediction?.toolCalls ?? [] {
                report.toolCallsScored += 1
                if Self.isValid(call, tools: tools) {
                    validCalls += 1
                }
            }
        }

        func ratio(_ part: Int, _ whole: Int) -> Double? {
            whole == 0 ? nil : Double(part) / Double(whole)
        }
        report.rootCauseAccuracy = ratio(correctCauses, report.causesScored)
        report.nextTestAgreement = ratio(agreedTests, report.nextTestsScored)
        report.hallucinatedValueRate = ratio(report.hallucinatedAnswers, report.answersScored)
        report.truthClassDiscipline = ratio(report.correctlyLabeledValues, report.citedValues)
        report.toolCallValidity = ratio(validCalls, report.toolCallsScored)
        report.accuracyByKind = Dictionary(uniqueKeysWithValues: byKind.map { ($0.key.rawValue, Double($0.value.right) / Double($0.value.total)) })
        return report
    }

    // MARK: Answers

    struct AnswerCheck: Equatable {
        var numbers = 0
        var ungrounded = 0
        var cited = 0
        var labeled = 0
    }

    func checkAnswer(_ answer: String, against example: TrainingExample) -> AnswerCheck {
        let labeledValues = Self.labeledValues(of: example)
        let context = Self.contextNumbers(of: example)
        let tokens = Self.numberTokens(in: answer)
        var check = AnswerCheck()
        for (index, token) in tokens.enumerated() where !Self.isTrivial(token.value) {
            check.numbers += 1
            let cited = labeledValues.filter { matches(token.value, $0.value) && Self.unitFits(token, $0.unit) }
            let grounded = !cited.isEmpty || labeledValues.contains { matches(token.value, $0.value) } || context.contains { matches(token.value, $0) }
            if !grounded {
                check.ungrounded += 1
                continue
            }
            guard !cited.isEmpty else { continue }
            check.cited += 1
            let limit = index + 1 < tokens.count ? tokens[index + 1].start : answer.count
            let window = Self.substring(answer, from: token.end, to: min(limit, token.end + labelWindow))
            if let label = Self.firstTruthLabel(in: window), cited.contains(where: { $0.truth == label }) {
                check.labeled += 1
            }
        }
        return check
    }

    func matches(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(absoluteTolerance, relativeTolerance * abs(b))
    }

    /// Integers 0…10 read as counts ("3 candidates", "t = 0 s"), not values.
    static func isTrivial(_ value: Double) -> Bool {
        value >= 0 && value <= 10 && value == value.rounded()
    }

    struct NumberToken: Equatable {
        var value: Double
        /// Character offsets of the number within the text.
        var start: Int
        var end: Int
        /// The unit glued to the number ("12mA") or the word right after it.
        var unit: String
    }

    private static let separators: Set<Character> = [" ", "\n", "\t", ",", ";", "(", ")", "[", "]", "{", "}", "=", ":", "\"", "'", "→", "–", "—", "/", "…"]
    private static let unitCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "%Ωµ°"))

    /// Numbers in free text. A word counts as a number when it is an optional
    /// sign, digits, an optional decimal part and at most a short glued unit;
    /// anything else ("LT-101", "TB-4", a UUID) is an identifier.
    static func numberTokens(in text: String) -> [NumberToken] {
        let characters = Array(text)
        var words: [(text: String, start: Int, end: Int)] = []
        var current = ""
        var start = 0
        for (offset, character) in characters.enumerated() {
            if separators.contains(character) {
                if !current.isEmpty {
                    words.append((current, start, offset))
                }
                current = ""
            } else {
                if current.isEmpty {
                    start = offset
                }
                current.append(character)
            }
        }
        if !current.isEmpty {
            words.append((current, start, characters.count))
        }

        var tokens: [NumberToken] = []
        for (index, word) in words.enumerated() {
            var body = Substring(word.text)
            while let last = body.last, last == "." || last == "!" || last == "?" {
                body = body.dropLast()
            }
            var digits = ""
            var rest = Substring("")
            var sawDigit = false
            var sawPoint = false
            var cursor = body.startIndex
            if cursor < body.endIndex, body[cursor] == "-" || body[cursor] == "+" {
                digits.append(body[cursor])
                cursor = body.index(after: cursor)
            }
            while cursor < body.endIndex {
                let character = body[cursor]
                if character.isASCII, character.isNumber {
                    sawDigit = true
                } else if character == ".", !sawPoint, sawDigit {
                    sawPoint = true
                } else {
                    break
                }
                digits.append(character)
                cursor = body.index(after: cursor)
            }
            rest = body[cursor...]
            guard sawDigit, !digits.hasSuffix("."), let value = Double(digits) else { continue }
            guard rest.count <= 3, rest.unicodeScalars.allSatisfy({ unitCharacters.contains($0) }) else { continue }
            var unit = String(rest)
            if unit.isEmpty, index + 1 < words.count {
                unit = words[index + 1].text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            }
            tokens.append(NumberToken(value: value, start: word.start, end: word.start + digits.count + rest.count, unit: unit))
        }
        return tokens
    }

    static func unitFits(_ token: NumberToken, _ unit: String) -> Bool {
        unit == "ratio" || unit == "bool" || token.unit == unit
    }

    static func firstTruthLabel(in text: String) -> TruthClass? {
        let lower = text.lowercased()
        var best: (TruthClass, String.Index)?
        for truth in TruthClass.allCases {
            if let range = lower.range(of: truth.rawValue.lowercased()), best == nil || range.lowerBound < best!.1 {
                best = (truth, range.lowerBound)
            }
        }
        return best?.0
    }

    private static func substring(_ text: String, from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        let characters = Array(text)
        return String(characters[min(start, characters.count)..<min(end, characters.count)])
    }

    /// Values in the example that carry a truth class.
    static func labeledValues(of example: TrainingExample) -> [(value: Double, unit: String, truth: TruthClass)] {
        var values = example.observations.map { ($0.value, $0.unit, $0.truth) }
        for step in example.answer.expertPath ?? [] {
            values.append((step.value, step.unit, step.truth))
        }
        if let divergence = example.answer.firstDivergence {
            values.append((divergence.actual, divergence.unit, .observed))
            values.append((divergence.expected, divergence.unit, .modeled))
        }
        return values
    }

    /// Every other number the example makes available, without a truth class.
    static func contextNumbers(of example: TrainingExample) -> [Double] {
        var texts = [example.prompt]
        texts += example.observations.flatMap { [$0.object, $0.source] }
        texts += (example.tests ?? []).flatMap { [$0.title, $0.object] }
        texts += (example.hypotheses ?? []).map(\.statement)
        texts += (example.messages ?? []).filter { $0.role != "assistant" }.map(\.content)
        texts += (example.ladder?.rungs ?? []).map(\.text)
        texts += (example.answer.trail ?? []).map(\.headline)
        var numbers = texts.flatMap { numberTokens(in: $0).map(\.value) }
        numbers += (example.tests ?? []).map(\.cost)
        numbers += (example.hypotheses ?? []).flatMap { $0.predictions.flatMap { [$0.low, $0.high] } }
        numbers += (example.answer.ranking ?? []).flatMap { [$0.informationGain, $0.score] }
        if let divergence = example.answer.firstDivergence {
            numbers += [divergence.seconds, Double(divergence.tick)]
        }
        if let scenario = example.scenario {
            numbers += [scenario.setpoint, scenario.initialLevel]
        }
        return numbers
    }

    // MARK: Tool calls

    /// Required arguments per WorldTools tool name.
    static var toolRequirements: [String: [String]] {
        Dictionary(uniqueKeysWithValues: WorldTools.all.map { tool in
            var required: [String] = []
            if case .map(let schema) = tool.spec.parameters, case .list(let names)? = schema["required"] {
                required = names.compactMap { if case .string(let name) = $0 { name } else { nil } }
            }
            return (tool.spec.name, required)
        })
    }

    static let idArguments: Set<String> = ["id", "test_point", "investigation"]

    static func isValid(_ call: ToolCallExample, tools: [String: [String]]) -> Bool {
        guard let required = tools[call.name] else { return false }
        for name in required {
            guard let value = call.arguments[name], !value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        }
        for (name, value) in call.arguments where idArguments.contains(name) {
            if ObjectID(value) == nil {
                return false
            }
        }
        return true
    }

    static func normalized(_ text: String?) -> String? {
        text.map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }
}

/// The trivial baseline: always the most common cause (and next test) seen
/// in training for the example's kind, and an answer that cites one given
/// observation with its truth class.
public struct BaselinePredictor: Sendable {
    public var causes: [ExampleKind: String]
    public var nextTests: [ExampleKind: String]

    public init(training examples: [TrainingExample]) {
        func mostCommon(_ values: [String]) -> String? {
            let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        var causes: [ExampleKind: String] = [:]
        var nextTests: [ExampleKind: String] = [:]
        for kind in ExampleKind.allCases {
            let ofKind = examples.filter { $0.kind == kind }
            causes[kind] = mostCommon(ofKind.map(\.answer.cause))
            nextTests[kind] = mostCommon(ofKind.compactMap(\.answer.nextTest))
        }
        self.causes = causes
        self.nextTests = nextTests
    }

    public func predict(_ example: TrainingExample) -> ModelPrediction {
        let cause = causes[example.kind]
        var answer = "Most likely cause: \(cause ?? "unknown")."
        if let observation = example.observations.first {
            answer = "\(observation.name) = \(DiagnosisCase.cite(observation.value, observation.unit, observation.truth)). " + answer
        }
        return ModelPrediction(
            id: example.id, predictedCause: cause, predictedNextTest: example.answer.nextTest == nil ? nil : nextTests[example.kind], answer: answer
        )
    }
}

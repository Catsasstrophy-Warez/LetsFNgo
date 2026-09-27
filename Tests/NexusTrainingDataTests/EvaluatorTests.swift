import Foundation
import NexusCore
import NexusModelRegistry
import Testing
@testable import NexusTrainingData

/// A hand-made example: HMI 64.23 % (display), terminal voltage 12.03 V
/// (observed) and a twin expectation of 19.03 V (modeled).
private func example(id: String = "ex-1", cause: String = "contactResistance", nextTest: String? = "Terminal voltage at the transmitter") -> TrainingExample {
    TrainingExample(
        id: id, kind: .diagnosis, split: .eval, seed: 1 << 40,
        prompt: "LT-101 reads 64.23 % on the HMI against a 90 % setpoint.",
        observations: [
            ObservationExample(name: "measuredLevel", object: "AI card slot 3 ch 0", value: 64.23, unit: "%", truth: .display, source: "HMI"),
            ObservationExample(name: "setpoint", object: "LIC-101", value: 90, unit: "%", truth: .recorded, source: "controller"),
            ObservationExample(name: "terminalVoltage", object: "TB-4 terminals 7/8", value: 19.03, unit: "V", truth: .modeled, source: "healthy twin"),
        ],
        tests: [TestExample(title: "Terminal voltage at the transmitter", object: "TB-4 terminals 7/8", quantity: "terminalVoltage", unit: "V", cost: 5, safety: "routine")],
        hypotheses: nil, scenario: nil, messages: nil, ladder: nil,
        answer: AnswerKey(
            cause: cause, nextTest: nextTest, text: "",
            expertPath: [ExpertStepExample(test: "Terminal voltage at the transmitter", value: 12.03, unit: "V", truth: .observed, remaining: [cause])]
        )
    )
}

extension AnswerKey {
    init(cause: String, nextTest: String?, text: String, expertPath: [ExpertStepExample]) {
        self.init(cause: cause, nextTest: nextTest, text: text, ranking: nil, expertPath: expertPath, firstDivergence: nil, trail: nil, blockers: nil)
    }
}

@Suite struct EvaluatorTests {
    @Test func numbersAreFoundAndIdentifiersIgnored() {
        let tokens = Evaluator.numberTokens(in: "LT-101 at TB-4 reads 12.03 V (observed), -25 %, 20mA; id 0199ab3c-4d5e-7f00-8a1b-2c3d4e5f6a7b; 4–20 mA. Done at 3.5.")
        #expect(tokens.map(\.value) == [12.03, -25, 20, 4, 20, 3.5])
        #expect(tokens.map(\.unit) == ["V", "%", "mA", "20", "mA", ""], "A bare number takes the next word as its unit")
    }

    @Test func groundedLabeledAnswerScoresPerfectly() {
        let answer = "The HMI shows 64.23 % (display) but the terminals read 12.03 V (observed) where the twin expects 19.03 V (modeled)."
        let check = Evaluator().checkAnswer(answer, against: example())
        #expect(check == Evaluator.AnswerCheck(numbers: 3, ungrounded: 0, cited: 3, labeled: 3))
    }

    @Test func inventedNumbersAndWrongLabelsAreCaught() {
        let evaluator = Evaluator()
        // 17.5 V appears nowhere in the example.
        let invented = evaluator.checkAnswer("Terminal voltage is 17.5 V (observed).", against: example())
        #expect(invented.ungrounded == 1)
        // The twin's value is modeled, not observed; the HMI value carries no label at all.
        let mislabeled = evaluator.checkAnswer("The twin says 19.03 V (observed). HMI 64.23 % and nothing else.", against: example())
        #expect(mislabeled.ungrounded == 0 && mislabeled.cited == 2 && mislabeled.labeled == 0)
        // Rounding within tolerance is still grounded; counts are not values.
        let rounded = evaluator.checkAnswer("About 64.2 % (display) after 3 tests.", against: example())
        #expect(rounded == Evaluator.AnswerCheck(numbers: 1, ungrounded: 0, cited: 1, labeled: 1))
    }

    @Test func reportAggregatesEveryMetric() throws {
        let examples = [example(id: "a"), example(id: "b", cause: "supplySag"), example(id: "c", nextTest: nil)]
        let predictions = [
            ModelPrediction(
                id: "a", predictedCause: "ContactResistance", predictedNextTest: "terminal voltage at the transmitter",
                answer: "Reads 12.03 V (observed).",
                toolCalls: [
                    ToolCallExample(id: "1", name: "get_measurements", arguments: ["test_point": "0199ab3c-4d5e-7f00-8a1b-2c3d4e5f6a7b"]),
                    ToolCallExample(id: "2", name: "get_measurements", arguments: ["test_point": "TB-4"]),
                    ToolCallExample(id: "3", name: "run_simulation", arguments: [:]),
                    ToolCallExample(id: "4", name: "search_objects", arguments: ["query": "LT-101"]),
                ]
            ),
            ModelPrediction(id: "b", predictedCause: "contactResistance", predictedNextTest: "Read the AI channel range", answer: "It is 99.9 V (observed)."),
            ModelPrediction(id: "zzz", predictedCause: "openWire"),
        ]
        let report = Evaluator().evaluate(examples: examples, predictions: predictions)
        #expect(report.missingPredictions == 1 && report.unmatchedPredictions == 1)
        #expect(abs(try #require(report.rootCauseAccuracy) - 1.0 / 3) < 1e-12)
        #expect(report.nextTestAgreement == 0.5)
        #expect(report.hallucinatedValueRate == 0.5)
        #expect(report.truthClassDiscipline == 1)
        #expect(report.toolCallValidity == 0.5)
        #expect(report.accuracyByKind == ["diagnosis": 1.0 / 3])

        // The report file doubles as a metrics file for the gate.
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(EvalMetrics.self, from: data) == report.metrics)
    }

    @Test func baselinePicksTheMostCommonTrainingAnswer() {
        let training = [example(id: "1"), example(id: "2"), example(id: "3", cause: "openWire", nextTest: "Clamp meter on the loop current")]
        let baseline = BaselinePredictor(training: training)
        let prediction = baseline.predict(example(id: "e", cause: "wrongScaling"))
        #expect(prediction.predictedCause == "contactResistance")
        #expect(prediction.predictedNextTest == "Terminal voltage at the transmitter")
        #expect(prediction.answer == "measuredLevel = 64.23 % (display). Most likely cause: contactResistance.")
    }

    @Test func commandLineRunsEndToEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("datasetgen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        var output: [String] = []
        func run(_ arguments: [String]) -> Int32 {
            DatasetCommand.run(arguments) { output.append($0) }
        }

        #expect(run(["--count", "8", "--seed", "42", "--out", path("train.jsonl")]) == 0)
        #expect(run(["generate", "--count", "8", "--seed", "42", "--out", path("eval.jsonl"), "--split", "eval"]) == 0)
        let train = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: path("train.jsonl")))
        let eval = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: path("eval.jsonl")))
        #expect(train.count == 8 && eval.count == 8)
        #expect(Set(train.map(\.seed)).isDisjoint(with: Set(eval.map(\.seed))))

        #expect(run(["baseline", "--train", path("train.jsonl"), "--examples", path("eval.jsonl"), "--out", path("baseline.jsonl")]) == 0)
        #expect(run(["evaluate", "--examples", path("eval.jsonl"), "--predictions", path("baseline.jsonl"), "--out", path("baseline.json")]) == 0)
        let report = try JSONDecoder().decode(EvaluationReport.self, from: Data(contentsOf: URL(fileURLWithPath: path("baseline.json"))))
        #expect(report.examples == 8 && report.missingPredictions == 0)
        #expect(report.hallucinatedValueRate == 0)
        #expect((0...1).contains(try #require(report.rootCauseAccuracy)))

        // A candidate equal to the baseline does not pass the gate; a better one does.
        #expect(run(["gate", "--candidate", path("baseline.json"), "--current", path("baseline.json")]) == 1)
        let perfect = eval.map { ModelPrediction(id: $0.id, predictedCause: $0.answer.cause, predictedNextTest: $0.answer.nextTest, answer: $0.answer.text) }
        try (try perfect.map { try DatasetGenerator.jsonLine($0) }.joined(separator: "\n")).write(toFile: path("perfect.jsonl"), atomically: true, encoding: .utf8)
        #expect(run(["evaluate", "--examples", path("eval.jsonl"), "--predictions", path("perfect.jsonl"), "--out", path("perfect.json")]) == 0)
        #expect(run(["gate", "--candidate", path("perfect.json"), "--current", path("baseline.json")]) == 0)
        #expect(run(["gate", "--candidate", path("baseline.json"), "--current", path("perfect.json")]) == 1)
        #expect(output.last == "FAIL: candidate must not be promoted")

        #expect(run(["generate", "--count", "0", "--seed", "1", "--out", path("x.jsonl")]) == 2)
        #expect(run(["evaluate", "--examples", path("eval.jsonl")]) == 2)
    }
}

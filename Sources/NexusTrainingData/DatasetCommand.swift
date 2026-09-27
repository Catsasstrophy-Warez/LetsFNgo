import Foundation
import NexusModelRegistry

/// The `NexusDatasetGen` command line, kept in the library so it is testable.
///
///     NexusDatasetGen [generate] --count 1000 --seed 42 --out train.jsonl [--split train|eval]
///     NexusDatasetGen baseline --train train.jsonl --examples eval.jsonl --out predictions.jsonl
///     NexusDatasetGen evaluate --examples eval.jsonl --predictions predictions.jsonl [--out metrics.json]
///     NexusDatasetGen gate --candidate metrics.json --current metrics.json
///
/// Returns the process exit code: 0 on success, 1 when the gate refuses a
/// candidate, 2 on a usage or input error.
public enum DatasetCommand {
    public static let usage = """
        usage:
          NexusDatasetGen [generate] --count N --seed S --out FILE.jsonl [--split train|eval]
          NexusDatasetGen baseline --train TRAIN.jsonl --examples EVAL.jsonl --out PREDICTIONS.jsonl
          NexusDatasetGen evaluate --examples EVAL.jsonl --predictions PREDICTIONS.jsonl [--out METRICS.json]
          NexusDatasetGen gate --candidate METRICS.json --current METRICS.json
        """

    struct UsageError: Error {
        var message: String
    }

    @discardableResult
    public static func run(_ arguments: [String], print: (String) -> Void = { Swift.print($0) }) -> Int32 {
        var arguments = arguments
        let command = arguments.first.map { $0.hasPrefix("--") ? "generate" : arguments.removeFirst() } ?? "help"
        do {
            let options = try parse(arguments)
            switch command {
            case "generate":
                return try generate(options, print: print)
            case "baseline":
                return try baseline(options, print: print)
            case "evaluate":
                return try evaluate(options, print: print)
            case "gate":
                return try gate(options, print: print)
            default:
                print(usage)
                return command == "help" ? 0 : 2
            }
        } catch let error as UsageError {
            print("error: \(error.message)\n\(usage)")
            return 2
        } catch {
            print("error: \(error)")
            return 2
        }
    }

    static func parse(_ arguments: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else { throw UsageError(message: "expected --flag value, got \(flag)") }
            options[String(flag.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return options
    }

    static func required(_ key: String, _ options: [String: String]) throws -> String {
        guard let value = options[key] else { throw UsageError(message: "missing --\(key)") }
        return value
    }

    static func generate(_ options: [String: String], print: (String) -> Void) throws -> Int32 {
        guard let count = Int(try required("count", options)), count > 0, count <= DatasetSplit.maximumCount else {
            throw UsageError(message: "--count must be 1…\(DatasetSplit.maximumCount)")
        }
        guard let seed = UInt64(try required("seed", options)) else { throw UsageError(message: "--seed must be a non-negative integer") }
        guard let split = DatasetSplit(rawValue: options["split"] ?? "train") else { throw UsageError(message: "--split must be train or eval") }
        let url = URL(fileURLWithPath: try required("out", options))

        var output = ""
        var kinds: [ExampleKind: Int] = [:]
        try DatasetGenerator().generate(count: count, seed: seed, split: split) { example in
            output += try DatasetGenerator.jsonLine(example) + "\n"
            kinds[example.kind, default: 0] += 1
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
        let summary = ExampleKind.allCases.map { "\($0.rawValue)=\(kinds[$0] ?? 0)" }.joined(separator: " ")
        print("wrote \(count) \(split.rawValue) examples to \(url.path) (\(summary))")
        return 0
    }

    static func baseline(_ options: [String: String], print: (String) -> Void) throws -> Int32 {
        let training = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: try required("train", options)))
        let examples = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: try required("examples", options)))
        let url = URL(fileURLWithPath: try required("out", options))
        let predictor = BaselinePredictor(training: training)
        let lines = try examples.map { try DatasetGenerator.jsonLine(predictor.predict($0)) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(lines.count) baseline predictions to \(url.path)")
        return 0
    }

    static func evaluate(_ options: [String: String], print: (String) -> Void) throws -> Int32 {
        let examples = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: try required("examples", options)))
        let predictions = try DatasetGenerator.readLines(ModelPrediction.self, from: URL(fileURLWithPath: try required("predictions", options)))
        let report = Evaluator().evaluate(examples: examples, predictions: predictions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        if let out = options["out"] {
            try (json + "\n").write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        }
        print(json)
        return 0
    }

    static func gate(_ options: [String: String], print: (String) -> Void) throws -> Int32 {
        let decoder = JSONDecoder()
        let candidate = try decoder.decode(EvalMetrics.self, from: Data(contentsOf: URL(fileURLWithPath: try required("candidate", options))))
        let current = try decoder.decode(EvalMetrics.self, from: Data(contentsOf: URL(fileURLWithPath: try required("current", options))))
        let decision = ModelRegistry.canPromote(candidate: candidate, over: current)
        for line in decision.details {
            print(line)
        }
        print(decision.passed ? "PASS: candidate may be promoted" : "FAIL: candidate must not be promoted")
        return decision.passed ? 0 : 1
    }
}

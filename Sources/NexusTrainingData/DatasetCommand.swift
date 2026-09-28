import Foundation
import NexusModelRegistry
import NexusPersistence

/// The `NexusDatasetGen` command line, kept in the library so it is testable.
///
///     NexusDatasetGen [generate] --count 1000 --seed 42 --out train.jsonl [--split train|eval] [--domain loop|automotive|mixed]
///     NexusDatasetGen baseline --train train.jsonl --examples eval.jsonl --out predictions.jsonl
///     NexusDatasetGen evaluate --examples eval.jsonl --predictions predictions.jsonl [--out metrics.json]
///     NexusDatasetGen gate --candidate metrics.json --current metrics.json
///     NexusDatasetGen gate-selfcheck --train train.jsonl --examples eval.jsonl
///     NexusDatasetGen register --registry models.json --id ID --kind mlxWeights --base-model ID --base-version V
///                              --artifact PATH --metrics metrics.json [--created ISO8601]
///
/// Returns the process exit code: 0 on success, 1 when the gate refuses a
/// candidate (or the self-check finds the gate misbehaving), 2 on a usage or
/// input error.
public enum DatasetCommand {
    public static let usage = """
        usage:
          NexusDatasetGen [generate] --count N --seed S --out FILE.jsonl [--split train|eval] [--domain loop|automotive|mixed]
          NexusDatasetGen baseline --train TRAIN.jsonl --examples EVAL.jsonl --out PREDICTIONS.jsonl
          NexusDatasetGen evaluate --examples EVAL.jsonl --predictions PREDICTIONS.jsonl [--out METRICS.json]
          NexusDatasetGen gate --candidate METRICS.json --current METRICS.json
          NexusDatasetGen gate-selfcheck --train TRAIN.jsonl --examples EVAL.jsonl
          NexusDatasetGen register --registry MODELS.json --id ID --kind mlxWeights|appleAdapter --base-model ID --base-version V
                                   --artifact PATH --metrics METRICS.json [--created ISO8601]
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
            case "gate-selfcheck":
                return try gateSelfCheck(options, print: print)
            case "register":
                return try register(options, print: print)
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
        guard let domain = DatasetDomain(rawValue: options["domain"] ?? "loop") else {
            throw UsageError(message: "--domain must be loop, automotive or mixed")
        }
        let url = URL(fileURLWithPath: try required("out", options))

        var output = ""
        var kinds: [ExampleKind: Int] = [:]
        try DatasetGenerator().generate(count: count, seed: seed, split: split, domain: domain) { example in
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

    /// Proves the promotion gate works on real evaluator output: the answer
    /// keys must pass over the baseline, and the baseline must not pass over
    /// the answer keys or over itself, nor may a degraded copy of the
    /// baseline that invents a value in every answer replace it.
    static func gateSelfCheck(_ options: [String: String], print: (String) -> Void) throws -> Int32 {
        let training = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: try required("train", options)))
        let examples = try DatasetGenerator.readLines(TrainingExample.self, from: URL(fileURLWithPath: try required("examples", options)))
        guard !examples.isEmpty else { throw UsageError(message: "--examples is empty") }
        let evaluator = Evaluator()
        let baselinePredictions = examples.map(BaselinePredictor(training: training).predict)
        let baseline = evaluator.evaluate(examples: examples, predictions: baselinePredictions).metrics
        let reference = evaluator.evaluate(
            examples: examples,
            predictions: examples.map {
                ModelPrediction(id: $0.id, predictedCause: $0.answer.cause, predictedNextTest: $0.answer.nextTest, answer: $0.answer.text)
            }
        ).metrics
        let degraded = evaluator.evaluate(
            examples: examples,
            predictions: baselinePredictions.map { prediction in
                var worse = prediction
                worse.answer = (prediction.answer ?? "") + " The reading was 987.65 V (observed)."
                return worse
            }
        ).metrics

        let checks: [(String, EvalMetrics, EvalMetrics, Bool)] = [
            ("answer keys over baseline", reference, baseline, true),
            ("baseline over answer keys", baseline, reference, false),
            ("baseline over itself", baseline, baseline, false),
            ("degraded baseline over baseline", degraded, baseline, false),
        ]
        var healthy = true
        for (name, candidate, current, shouldPass) in checks {
            let decision = ModelRegistry.canPromote(candidate: candidate, over: current)
            let ok = decision.passed == shouldPass
            healthy = healthy && ok
            print("\(ok ? "ok" : "WRONG"): \(name) → \(decision.passed ? "promoted" : "refused") (expected \(shouldPass ? "promoted" : "refused"))")
            for line in decision.details {
                print("    \(line)")
            }
        }
        print(healthy ? "PASS: the gate promotes a better model and refuses a worse one" : "FAIL: the promotion gate misbehaves")
        return healthy ? 0 : 1
    }

    /// Adds a trained artifact to a registry manifest if it passes the gate
    /// against the newest entry for the same base model and kind. The
    /// manifest is only written when the candidate is promoted.
    static func register(_ options: [String: String], print: (String) -> Void) throws -> Int32 {
        let registryURL = URL(fileURLWithPath: try required("registry", options))
        guard let kind = ModelArtifactKind(rawValue: try required("kind", options)) else {
            throw UsageError(message: "--kind must be one of \(ModelArtifactKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let base = BaseModel(identifier: try required("base-model", options), version: try required("base-version", options))
        let metrics = try JSONDecoder().decode(EvalMetrics.self, from: Data(contentsOf: URL(fileURLWithPath: try required("metrics", options))))
        let (digest, size) = try fingerprint(URL(fileURLWithPath: try required("artifact", options)))
        var created = Date()
        if let text = options["created"] {
            guard let date = ISO8601DateFormatter().date(from: text) else { throw UsageError(message: "--created must be ISO 8601") }
            created = date
        }
        var registry = FileManager.default.fileExists(atPath: registryURL.path) ? try ModelRegistry.load(from: registryURL) : try ModelRegistry()
        let entry = ModelEntry(
            id: try required("id", options), kind: kind, baseModel: base, sha256: digest, sizeBytes: size, metrics: metrics, createdAt: created
        )
        let decision = registry.canPromote(entry)
        for line in decision.details {
            print(line)
        }
        guard decision.passed else {
            print("FAIL: \(entry.id) not registered; the current model stays")
            return 1
        }
        try registry.register(entry)
        try registry.save(to: registryURL)
        print("PASS: registered \(entry.id) (\(base), sha256 \(digest.prefix(12))…, \(size) bytes)")
        return 0
    }

    /// SHA-256 and size of a file, or of a directory (a fused MLX model):
    /// the digest of its sorted "relative path, file digest" lines.
    static func fingerprint(_ url: URL) throws -> (String, Int64) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UsageError(message: "no artifact at \(url.path)")
        }
        if !isDirectory.boolValue {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            return (ContentHash.sha256(data), Int64(data.count))
        }
        let root = url.standardizedFileURL.path
        var lines: [String] = []
        var total: Int64 = 0
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? []).sorted()
        for relative in files {
            let file = URL(fileURLWithPath: root).appendingPathComponent(relative)
            var nested: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &nested), !nested.boolValue else { continue }
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            total += Int64(data.count)
            lines.append("\(relative)\t\(ContentHash.sha256(data))")
        }
        guard total > 0 else { throw UsageError(message: "artifact directory \(url.path) is empty") }
        return (ContentHash.sha256(lines.joined(separator: "\n")), total)
    }
}

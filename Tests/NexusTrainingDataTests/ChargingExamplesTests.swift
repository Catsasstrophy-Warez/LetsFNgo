import Foundation
import NexusAutomotive
import NexusModelRegistry
import Testing

@testable import NexusTrainingData

@Suite struct ChargingExamplesTests {
    @Test func domainsRotateKindsAndLeaveTheLoopRotationAlone() throws {
        for index in 0..<20 {
            #expect(DatasetGenerator.kind(forIndex: index, domain: .loop) == DatasetGenerator.kind(forIndex: index))
            #expect(DatasetGenerator.kind(forIndex: index, domain: .automotive) == .chargingDiagnosis)
        }
        #expect(
            (0..<10).map { DatasetGenerator.kind(forIndex: $0, domain: .mixed) } == [
                .diagnosis, .diagnosis, .toolTranscript, .ladderWhy, .chargingDiagnosis,
                .diagnosis, .diagnosis, .toolTranscript, .ladderWhy, .chargingDiagnosis,
            ])
        // The loop domain is the default and writes no vehicle section.
        let loop = try DatasetGenerator().example(split: .train, runSeed: 1, index: 3)
        let line = try DatasetGenerator.jsonLine(loop)
        #expect(loop.vehicle == nil && !line.contains("\"vehicle\""))
    }

    @Test func chargingCasesAreDeterministicSolvableAndConsistent() throws {
        let generator = DatasetGenerator()
        var lines: [String] = []
        try generator.generate(count: 12, seed: 5, split: .eval, domain: .automotive) { lines.append(try DatasetGenerator.jsonLine($0)) }
        var again: [String] = []
        try generator.generate(count: 12, seed: 5, split: .eval, domain: .automotive) { again.append(try DatasetGenerator.jsonLine($0)) }
        #expect(lines == again)

        let examples = try lines.map { try JSONDecoder().decode(TrainingExample.self, from: Data($0.utf8)) }
        var resolved = 0
        for example in examples {
            #expect(example.kind == .chargingDiagnosis && example.split == .eval && DatasetSplit.containing(example.seed) == .eval)
            let scenario = try #require(example.vehicle)
            #expect(scenario.fault == example.answer.cause && ChargingFaultKind(rawValue: scenario.fault) != nil)
            #expect(try VIN(scenario.vin, requireCheckDigit: true).isCheckDigitValid)
            #expect(example.hypotheses?.count == ChargingFaultKind.allCases.count)
            #expect(example.answer.nextTest == example.answer.ranking?.first?.title)
            let path = try #require(example.answer.expertPath)
            #expect(path.allSatisfy { $0.remaining.contains(example.answer.cause) }, "\(example.id): the true cause is never rejected")
            if path.last?.remaining == [example.answer.cause] {
                resolved += 1
            }
            #expect(example.answer.firstDivergence != nil)
            #expect(example.observations.contains { $0.truth == .display } && example.observations.contains { $0.truth == .modeled })
        }
        #expect(resolved == examples.count, "Charging cases are always singled out by the expert path")
        #expect(Set(examples.map(\.answer.nextTest)).count > 1, "Access costs change the best first test")
    }

    @Test func referenceAnswersAreGroundedAndLabeled() throws {
        let generator = DatasetGenerator()
        let examples = try (0..<10).map { try generator.example(split: .train, runSeed: 9, index: $0, domain: .mixed) }
        #expect(examples.contains { $0.kind == .chargingDiagnosis })
        let evaluator = Evaluator()
        for example in examples {
            let check = evaluator.checkAnswer(example.answer.text, against: example)
            #expect(check.ungrounded == 0, "\(example.id): \(example.answer.text)")
            #expect(check.labeled == check.cited, "\(example.id): \(example.answer.text)")
        }
        let perfect = examples.map {
            ModelPrediction(id: $0.id, predictedCause: $0.answer.cause, predictedNextTest: $0.answer.nextTest, answer: $0.answer.text)
        }
        let report = evaluator.evaluate(examples: examples, predictions: perfect)
        #expect(report.rootCauseAccuracy == 1 && report.hallucinatedValueRate == 0 && report.truthClassDiscipline == 1)
        #expect(report.accuracyByKind["chargingDiagnosis"] == 1)
    }

    @Test func gateSelfCheckAndRegisterRunFromTheCommandLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        var output: [String] = []
        func run(_ arguments: [String]) -> Int32 {
            DatasetCommand.run(arguments) { output.append($0) }
        }

        #expect(run(["--count", "10", "--seed", "2", "--domain", "mixed", "--out", path("train.jsonl")]) == 0)
        #expect(output.last?.hasSuffix("(diagnosis=4 toolTranscript=2 ladderWhy=2 chargingDiagnosis=2)") == true)
        #expect(run(["--count", "5", "--seed", "2", "--split", "eval", "--domain", "automotive", "--out", path("eval.jsonl")]) == 0)
        #expect(run(["--count", "5", "--seed", "2", "--domain", "trucks", "--out", path("x.jsonl")]) == 2)

        #expect(run(["gate-selfcheck", "--train", path("train.jsonl"), "--examples", path("eval.jsonl")]) == 0)
        #expect(output.last == "PASS: the gate promotes a better model and refuses a worse one")
        #expect(output.contains("ok: degraded baseline over baseline → refused (expected refused)"))

        // Register: the first model passes; a worse one is refused and leaves the manifest alone.
        try Data("weights-v1".utf8).write(to: URL(fileURLWithPath: path("v1.safetensors")))
        try FileManager.default.createDirectory(atPath: path("v2"), withIntermediateDirectories: true)
        try Data("config".utf8).write(to: URL(fileURLWithPath: path("v2/config.json")))
        try Data("weights-v2".utf8).write(to: URL(fileURLWithPath: path("v2/model.safetensors")))
        try Data(#"{"rootCauseAccuracy":0.8,"hallucinatedValueRate":0.05}"#.utf8).write(to: URL(fileURLWithPath: path("good.json")))
        try Data(#"{"rootCauseAccuracy":0.7,"hallucinatedValueRate":0.01}"#.utf8).write(to: URL(fileURLWithPath: path("mixed.json")))
        try Data(#"{"rootCauseAccuracy":0.9,"hallucinatedValueRate":0.01}"#.utf8).write(to: URL(fileURLWithPath: path("better.json")))
        let common = ["--registry", path("models.json"), "--kind", "mlxWeights", "--base-model", "qwen3-1.7b", "--base-version", "2025.04"]
        #expect(
            run(
                ["register", "--id", "nexus-mlx-1"] + common + [
                    "--artifact", path("v1.safetensors"), "--metrics", path("good.json"), "--created", "2026-09-01T00:00:00Z",
                ]) == 0)
        #expect(
            run(
                ["register", "--id", "nexus-mlx-2"] + common + ["--artifact", path("v2"), "--metrics", path("mixed.json"), "--created", "2026-09-02T00:00:00Z"])
                == 1)
        #expect(try ModelRegistry.load(from: URL(fileURLWithPath: path("models.json"))).entries.map(\.id) == ["nexus-mlx-1"])
        #expect(
            run(
                ["register", "--id", "nexus-mlx-2"] + common + [
                    "--artifact", path("v2"), "--metrics", path("better.json"), "--created", "2026-09-02T00:00:00Z",
                ]) == 0)
        let registry = try ModelRegistry.load(from: URL(fileURLWithPath: path("models.json")))
        #expect(registry.entries.map(\.id) == ["nexus-mlx-1", "nexus-mlx-2"])
        #expect(registry.entries[1].sizeBytes == 16 && registry.entries[1].sha256.count == 64)
        #expect(registry.compatibleEntry(for: BaseModel(identifier: "qwen3-1.7b", version: "2025.04"))?.id == "nexus-mlx-2")
        #expect(run(["register", "--id", "x"] + common + ["--artifact", path("missing"), "--metrics", path("good.json")]) == 2)
    }
}

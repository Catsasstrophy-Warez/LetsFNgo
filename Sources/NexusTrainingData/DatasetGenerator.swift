import Foundation
import NexusSimulation

/// Headless training-data factory (docs/BUILD_PLAN.md §F3, docs/TRAINING_DATA.md).
///
/// Example `index` of a run uses scenario seed `split.scenarioSeed(runSeed:index:)`,
/// so a run replays exactly and the train and eval splits never share a
/// scenario. Kinds rotate with the index: two diagnosis examples, then a tool
/// transcript, then a ladder "why" question.
public final class DatasetGenerator {
    private let factory = LoopScenarioFactory()

    public init() {}

    public static func kind(forIndex index: Int) -> ExampleKind {
        switch index % 4 {
        case 0, 1: .diagnosis
        case 2: .toolTranscript
        default: .ladderWhy
        }
    }

    /// The kind of example `index` for a domain. `mixed` rotates over five:
    /// two loop diagnoses, a transcript, a ladder question, a charging case.
    public static func kind(forIndex index: Int, domain: DatasetDomain) -> ExampleKind {
        switch domain {
        case .loop: kind(forIndex: index)
        case .automotive: .chargingDiagnosis
        case .mixed: index % 5 == 4 ? .chargingDiagnosis : kind(forIndex: index % 5)
        }
    }

    public func example(split: DatasetSplit, runSeed: UInt64, index: Int, domain: DatasetDomain = .loop) throws -> TrainingExample {
        let seed = split.scenarioSeed(runSeed: runSeed, index: index)
        let kind = Self.kind(forIndex: index, domain: domain)
        let id = "\(split.rawValue)-\(seed)-\(kind.rawValue)"
        switch kind {
        case .diagnosis:
            return try factory.makeCase(seed: seed).diagnosisExample(id: id, split: split)
        case .toolTranscript:
            return try factory.makeCase(seed: seed).transcriptExample(id: id, split: split)
        case .ladderWhy:
            return try LadderExamples.example(seed: seed, id: id, split: split)
        case .chargingDiagnosis:
            return try ChargingExamples.example(seed: seed, id: id, split: split)
        }
    }

    /// Generates `count` examples in order, handing each to `emit`.
    public func generate(
        count: Int, seed: UInt64, split: DatasetSplit, domain: DatasetDomain = .loop, emit: (TrainingExample) throws -> Void
    ) throws {
        precondition(count <= DatasetSplit.maximumCount, "count exceeds the per-seed range")
        for index in 0..<count {
            try emit(try example(split: split, runSeed: seed, index: index, domain: domain))
        }
    }

    // MARK: JSONL

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// One example as a single JSON line, keys sorted so output is byte-stable.
    public static func jsonLine<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Decodes every non-empty line of a JSONL file.
    public static func readLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            try decoder.decode(T.self, from: Data(line.utf8))
        }
    }
}

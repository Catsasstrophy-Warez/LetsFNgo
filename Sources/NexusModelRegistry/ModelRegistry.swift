import Foundation
import NexusAI
import NexusCore

/// What a registered model artifact is.
public enum ModelArtifactKind: String, Codable, Sendable, CaseIterable {
    /// A LoRA adapter for Apple's on-device Foundation Model (`.fmadapter`).
    case appleAdapter
    /// Fine-tuned open weights served through MLX Swift.
    case mlxWeights

    /// The routing tier the artifact runs on.
    public var tier: ModelTier {
        switch self {
        case .appleAdapter: .onDevice
        case .mlxWeights: .localLarge
        }
    }
}

/// The base model an artifact was trained against. Adapters only load on the
/// exact base version they were trained for, so compatibility is an exact
/// match of identifier and version.
public struct BaseModel: Codable, Sendable, Hashable, CustomStringConvertible {
    public var identifier: String
    public var version: String

    public init(identifier: String, version: String) {
        self.identifier = identifier
        self.version = version
    }

    public var description: String { "\(identifier)@\(version)" }
}

/// One trained model version: an adapter or a set of weights, with the
/// evaluation scores it shipped with.
public struct ModelEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ModelArtifactKind
    public var baseModel: BaseModel
    /// Lowercase hex SHA-256 of the artifact file.
    public var sha256: String
    public var sizeBytes: Int64
    public var metrics: EvalMetrics
    public var createdAt: Date

    public init(id: String, kind: ModelArtifactKind, baseModel: BaseModel, sha256: String, sizeBytes: Int64, metrics: EvalMetrics, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.baseModel = baseModel
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.metrics = metrics
        self.createdAt = createdAt
    }

    /// The reference recorded in provenance when this entry answers.
    public var modelRef: ModelRef {
        ModelRef(provider: kind == .appleAdapter ? "apple.foundation-models" : "nexus.mlx", modelID: baseModel.description, adapterID: id, adapterVersion: sha256)
    }
}

public enum ModelRegistryError: Error, Equatable, Sendable {
    case duplicateID(String)
    case invalidSHA256(String)
    case invalidSize(Int64)
    case unsupportedFormat(Int)
}

/// The versioned list of trained models, persisted as a JSON manifest.
///
/// The registry only describes artifacts; the files themselves ship as
/// background assets. When no entry fits the installed base model, callers
/// use the base model with tools (`compatibleEntry(for:)` returns nil).
public struct ModelRegistry: Codable, Sendable, Hashable {
    /// Manifest format version. Bumped only with a migration in `load`.
    public static let currentFormat = 1

    public var format: Int
    public private(set) var entries: [ModelEntry]

    public init(entries: [ModelEntry] = []) throws {
        format = Self.currentFormat
        self.entries = []
        for entry in entries {
            try register(entry)
        }
    }

    public mutating func register(_ entry: ModelEntry) throws {
        guard !entries.contains(where: { $0.id == entry.id }) else { throw ModelRegistryError.duplicateID(entry.id) }
        guard entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ModelRegistryError.invalidSHA256(entry.sha256)
        }
        guard entry.sizeBytes > 0 else { throw ModelRegistryError.invalidSize(entry.sizeBytes) }
        entries.append(entry)
    }

    public func entry(_ id: String) -> ModelEntry? {
        entries.first { $0.id == id }
    }

    /// The newest entry trained for exactly this base model, optionally of one
    /// kind. Nil means: use the base model and tools, no adapter.
    public func compatibleEntry(for baseModel: BaseModel, kind: ModelArtifactKind? = nil) -> ModelEntry? {
        entries
            .filter { $0.baseModel == baseModel && (kind == nil || $0.kind == kind) }
            .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    // MARK: Promotion gate

    /// Result of comparing a candidate's metrics with the current model's.
    public struct PromotionDecision: Sendable, Hashable, Codable {
        public var passed: Bool
        /// One line per metric: better, tied, worse, missing or new.
        public var details: [String]
    }

    /// The CI gate from §F3: a candidate ships only if it beats or ties the
    /// current model on every metric the current model has, and strictly
    /// beats it on at least one. A metric the candidate lacks but the current
    /// model has fails the gate; a metric only the candidate has is reported
    /// but not compared. With no current model, any candidate passes.
    public static func canPromote(candidate: EvalMetrics, over current: EvalMetrics?, tolerance: Double = 1e-9) -> PromotionDecision {
        guard let current else {
            return PromotionDecision(passed: true, details: ["no current model: first candidate is promoted"])
        }
        var details: [String] = []
        var worse = false
        var better = false
        for (new, old) in zip(candidate.all, current.all) {
            switch (new.value, old.value) {
            case (nil, nil):
                continue
            case (nil, let old?):
                worse = true
                details.append("\(new.name): missing (current \(format(old)))")
            case (let value?, nil):
                details.append("\(new.name): new metric \(format(value)), not compared")
            case (let value?, let old?):
                let gain = new.higherIsBetter ? value - old : old - value
                if gain > tolerance {
                    better = true
                    details.append("\(new.name): better \(format(old)) → \(format(value))")
                } else if gain < -tolerance {
                    worse = true
                    details.append("\(new.name): worse \(format(old)) → \(format(value))")
                } else {
                    details.append("\(new.name): tied \(format(value))")
                }
            }
        }
        if !worse && !better {
            details.append("no metric strictly improved")
        }
        return PromotionDecision(passed: !worse && better, details: details)
    }

    /// Whether `candidate` may replace the newest entry for its base model.
    public func canPromote(_ candidate: ModelEntry) -> PromotionDecision {
        Self.canPromote(candidate: candidate.metrics, over: compatibleEntry(for: candidate.baseModel, kind: candidate.kind)?.metrics)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    // MARK: Persistence

    public static func load(from url: URL) throws -> ModelRegistry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let registry = try decoder.decode(ModelRegistry.self, from: Data(contentsOf: url))
        guard registry.format == currentFormat else { throw ModelRegistryError.unsupportedFormat(registry.format) }
        return try ModelRegistry(entries: registry.entries)
    }

    /// Writes the manifest atomically, with sorted keys so diffs stay readable.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

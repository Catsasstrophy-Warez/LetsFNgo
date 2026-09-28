import Foundation
import NexusAI
import Testing
@testable import NexusModelRegistry

private let base27 = BaseModel(identifier: "apple.system", version: "27.0")
private let base28 = BaseModel(identifier: "apple.system", version: "28.0")
private let qwen = BaseModel(identifier: "qwen3-8b", version: "2026.05")

private func sha(_ digit: Character) -> String {
    String(repeating: digit, count: 64)
}

private func entry(
    _ id: String, _ kind: ModelArtifactKind = .appleAdapter, base: BaseModel = base27, day: Double, metrics: EvalMetrics = EvalMetrics()
) -> ModelEntry {
    ModelEntry(
        id: id, kind: kind, baseModel: base, sha256: sha("a"), sizeBytes: 12_000_000, metrics: metrics,
        createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + day * 86_400)
    )
}

private let reference = EvalMetrics(
    rootCauseAccuracy: 0.8, nextTestAgreement: 0.6, hallucinatedValueRate: 0.1, truthClassDiscipline: 0.9, toolCallValidity: 0.95
)

@Suite struct ModelRegistryTests {
    @Test func picksTheNewestEntryForTheExactBaseModel() throws {
        let registry = try ModelRegistry(entries: [
            entry("adapter-1", day: 1), entry("adapter-2", day: 5), entry("adapter-3", base: base28, day: 9),
            entry("mlx-1", .mlxWeights, base: qwen, day: 7),
        ])
        #expect(registry.compatibleEntry(for: base27)?.id == "adapter-2")
        #expect(registry.compatibleEntry(for: base28)?.id == "adapter-3")
        #expect(registry.compatibleEntry(for: qwen)?.id == "mlx-1")
        #expect(registry.compatibleEntry(for: qwen, kind: .appleAdapter) == nil)
        // An unknown base version gets no adapter: use the base model with tools.
        #expect(registry.compatibleEntry(for: BaseModel(identifier: "apple.system", version: "27.1")) == nil)
        #expect(try ModelRegistry().compatibleEntry(for: base27) == nil)
    }

    @Test func rejectsDuplicatesAndMalformedEntries() throws {
        var registry = try ModelRegistry(entries: [entry("adapter-1", day: 1)])
        #expect(throws: ModelRegistryError.duplicateID("adapter-1")) { try registry.register(entry("adapter-1", day: 2)) }
        var bad = entry("adapter-2", day: 2)
        bad.sha256 = "ABC"
        #expect(throws: ModelRegistryError.invalidSHA256("ABC")) { try registry.register(bad) }
        bad.sha256 = String(repeating: "A", count: 64)
        #expect(throws: ModelRegistryError.invalidSHA256(bad.sha256)) { try registry.register(bad) }
        bad.sha256 = sha("0")
        bad.sizeBytes = 0
        #expect(throws: ModelRegistryError.invalidSize(0)) { try registry.register(bad) }
    }

    @Test func manifestRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = try ModelRegistry(entries: [
            entry("adapter-1", day: 1, metrics: reference), entry("mlx-1", .mlxWeights, base: qwen, day: 3),
        ])
        try registry.save(to: url)
        let loaded = try ModelRegistry.load(from: url)
        #expect(loaded == registry)
        #expect(loaded.format == ModelRegistry.currentFormat)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"kind\" : \"mlxWeights\""))
        #expect(!text.contains("toolCallValidity\" : null"), "Unmeasured metrics are omitted, not null")
    }

    @Test func entriesMapToRoutingTiersAndProvenance() {
        let adapter = entry("adapter-1", day: 1)
        #expect(adapter.kind.tier == .onDevice)
        #expect(ModelArtifactKind.mlxWeights.tier == .localLarge)
        #expect(adapter.modelRef.adapterID == "adapter-1")
        #expect(adapter.modelRef.modelID == "apple.system@27.0")
    }

    @Test func gatePromotesOnlyAStrictImprovementWithNoRegression() {
        func candidate(_ change: (inout EvalMetrics) -> Void) -> EvalMetrics {
            var metrics = reference
            change(&metrics)
            return metrics
        }
        // Better on one, tied on the rest.
        #expect(ModelRegistry.canPromote(candidate: candidate { $0.rootCauseAccuracy = 0.85 }, over: reference).passed)
        // Lower hallucination is better.
        #expect(ModelRegistry.canPromote(candidate: candidate { $0.hallucinatedValueRate = 0.05 }, over: reference).passed)
        // Ties everywhere is not enough.
        let tie = ModelRegistry.canPromote(candidate: reference, over: reference)
        #expect(!tie.passed && tie.details.last == "no metric strictly improved")
        // Better on one, worse on another fails.
        let mixed = ModelRegistry.canPromote(
            candidate: candidate {
                $0.rootCauseAccuracy = 0.95
                $0.hallucinatedValueRate = 0.2
            },
            over: reference
        )
        #expect(!mixed.passed)
        #expect(mixed.details.contains { $0.hasPrefix("hallucinatedValueRate: worse") })
        // Dropping a measured metric fails; adding a new one is not compared.
        let dropped = candidate {
            $0.rootCauseAccuracy = 0.9
            $0.toolCallValidity = nil
        }
        #expect(!ModelRegistry.canPromote(candidate: dropped, over: reference).passed)
        var old = reference
        old.toolCallValidity = nil
        let extended = candidate {
            $0.nextTestAgreement = 0.7
            $0.toolCallValidity = 0.1
        }
        let added = ModelRegistry.canPromote(candidate: extended, over: old)
        #expect(added.passed && added.details.contains { $0.hasPrefix("toolCallValidity: new metric") })
        // First model ever.
        #expect(ModelRegistry.canPromote(candidate: reference, over: nil).passed)
    }

    @Test func gateComparesAgainstTheNewestCompatibleEntry() throws {
        var worse = reference
        worse.rootCauseAccuracy = 0.5
        let registry = try ModelRegistry(entries: [entry("adapter-1", day: 1, metrics: worse), entry("adapter-2", day: 2, metrics: reference)])
        var next = reference
        next.truthClassDiscipline = 0.95
        #expect(registry.canPromote(entry("adapter-3", day: 3, metrics: next)).passed)
        #expect(!registry.canPromote(entry("adapter-3", day: 3, metrics: worse)).passed)
        // Nothing yet for the new base model: the first adapter for it passes.
        #expect(registry.canPromote(entry("adapter-4", base: base28, day: 3, metrics: worse)).passed)
    }
}

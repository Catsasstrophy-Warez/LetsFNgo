#if canImport(NaturalLanguage)
    import Foundation
    import NaturalLanguage

    /// Apple's on-device English sentence embedding (`NLEmbedding.sentenceEmbedding`).
    ///
    /// The sentence model returns one vector per string, so no pooling is
    /// needed. It knows general English, not field abbreviations, so plant
    /// jargon ("xmtr", "TB") matches better with `HashingEmbedder`. Returns nil
    /// from `init` when the asset isn't on the device.
    public final class NLEmbeddingEmbedder: Embedder, @unchecked Sendable {
        public let modelID: String
        public let dimension: Int
        /// Unrelated sentences still score well above zero under this model.
        public var minimumSimilarity: Float { 0.3 }

        private let embedding: NLEmbedding
        /// `NLEmbedding` isn't documented as thread-safe, so calls are serialized.
        private let lock = NSLock()
        /// Longer text is cut here; the model is meant for sentences and short passages.
        private let maxCharacters: Int

        public init?(language: NLLanguage = .english, maxCharacters: Int = 2_000) {
            guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
            self.embedding = embedding
            self.dimension = embedding.dimension
            self.modelID = "apple.nl.sentence.\(language.rawValue).r\(embedding.revision).\(embedding.dimension)"
            self.maxCharacters = maxCharacters
        }

        public func embed(_ text: String) -> [Float] {
            let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
            guard !trimmed.isEmpty else { return [Float](repeating: 0, count: dimension) }
            let values = lock.withLock { embedding.vector(for: trimmed) }
            guard let values, values.count == dimension else { return [Float](repeating: 0, count: dimension) }
            var vector = values.map(Float.init)
            EmbeddingMath.normalize(&vector)
            return vector
        }
    }
#endif

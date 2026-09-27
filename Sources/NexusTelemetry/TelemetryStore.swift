import Dispatch
import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusVisualization

/// Time-series storage on the canonical store.
///
/// Every call is async and runs on the telemetry store's own serial queue,
/// never on the caller's actor, so SQLite work stays off the main actor and
/// out of Swift's cooperative pool. Channels and samples live in
/// `NexusStore` (migration 5); this type owns the sample format, chunking,
/// range queries, downsampling and retention.
public final class TelemetryStore: Sendable {
    public let store: NexusStore
    /// Samples per stored chunk.
    public let chunkSize: Int
    private let queue = DispatchQueue(label: "nexus.telemetry", qos: .utility)

    public init(store: NexusStore, chunkSize: Int = 4_096) {
        self.store = store
        self.chunkSize = max(1, chunkSize)
        _ = Self.classifierRegistration
    }

    /// Runs `body` with the store on the telemetry queue.
    public func perform<T: Sendable>(_ body: @escaping @Sendable (NexusStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                continuation.resume(with: Result { try body(store) })
            }
        }
    }

    // MARK: Channels

    @discardableResult
    public func createChannel(
        object: ObjectID, quantity: String, unit: String, sampleRate: Double? = nil, provenance: Provenance
    ) async throws -> TelemetryChannel {
        let channel = TelemetryChannel(object: object, quantity: quantity, unit: unit, sampleRate: sampleRate, provenance: provenance)
        try await perform { try $0.createTelemetryChannel(channel) }
        return channel
    }

    public func channel(_ id: ObjectID) async throws -> TelemetryChannel? {
        try await perform { try $0.telemetryChannel(id) }
    }

    public func channels(on object: ObjectID? = nil) async throws -> [TelemetryChannel] {
        try await perform { try $0.telemetryChannels(object: object) }
    }

    /// Deletes a channel and its samples. Recorded or observed channels may
    /// only be deleted by a user or the system.
    public func deleteChannel(_ id: ObjectID, by author: Origin) async throws {
        try await perform { try $0.deleteTelemetryChannel(id, by: author) }
    }

    // MARK: Samples

    /// Appends a batch atomically, in chunks of `chunkSize`. `truth` must be
    /// the channel's truth class; the store refuses anything else, so modeled
    /// samples can never enter an observed channel. The batch is sorted by
    /// time first. Times must be finite; values may be NaN (a dropout).
    public func append(_ samples: [TelemetrySample], to channel: ObjectID, truth: TruthClass) async throws {
        guard !samples.isEmpty else { return }
        let chunkSize = chunkSize
        try await perform { store in
            var sorted = samples
            if !zip(samples, samples.dropFirst()).allSatisfy({ $0.time <= $1.time }) {
                sorted.sort { $0.time < $1.time }
            }
            if let bad = sorted.firstIndex(where: { !$0.time.isFinite || $0.value.isInfinite }) {
                throw TelemetryError.invalidSample(index: bad)
            }
            var chunks: [TelemetryChunk] = []
            chunks.reserveCapacity(sorted.count / chunkSize + 1)
            var start = 0
            while start < sorted.count {
                let end = min(start + chunkSize, sorted.count)
                let slice = sorted[start..<end]
                chunks.append(
                    TelemetryChunk(
                        channel: channel, start: slice.first!.time, end: slice.last!.time, count: slice.count, encoding: SampleCodec.encoding,
                        payload: SampleCodec.encode(slice)
                    )
                )
                start = end
            }
            try store.appendTelemetryChunks(chunks, truth: truth)
        }
    }

    /// Samples in `[from, to]` (seconds since the reference date; nil for
    /// unbounded), in time order, LTTB-downsampled to `maxPoints` if given.
    public func samples(_ channel: ObjectID, from: Double? = nil, to: Double? = nil, maxPoints: Int? = nil) async throws -> [TelemetrySample] {
        try await perform { store in
            guard try store.telemetryChannel(channel) != nil else { throw TelemetryError.channelNotFound(channel) }
            let chunks = try store.telemetryChunks(channel: channel, from: from, to: to)
            var samples = try Self.decode(chunks, from: from, to: to)
            if let maxPoints { samples = samples.downsampled(to: maxPoints) }
            return samples
        }
    }

    /// A visualization-ready series carrying the channel's unit and truth class.
    public func series(_ channel: ObjectID, name: String? = nil, from: Double? = nil, to: Double? = nil, maxPoints: Int? = nil) async throws -> SeriesSpec {
        guard let record = try await self.channel(channel) else { throw TelemetryError.channelNotFound(channel) }
        let samples = try await samples(channel, from: from, to: to, maxPoints: maxPoints)
        return SeriesSpec(
            id: record.id.description, name: name ?? record.quantity, unit: record.unit, truth: record.truth,
            points: samples.map { DataPoint($0.time, $0.value) }
        )
    }

    /// Number of samples stored on a channel.
    public func sampleCount(_ channel: ObjectID) async throws -> Int {
        try await perform { try $0.telemetryChunks(channel: channel).reduce(0) { $0 + $1.count } }
    }

    // MARK: Retention

    /// Removes samples older than `cutoff` from one channel, keeping the rest
    /// of any chunk that straddles it. Returns the number of samples removed.
    /// Recorded or observed samples may only be removed by a user or the system.
    @discardableResult
    public func removeSamples(from channel: ObjectID, before cutoff: Double, by author: Origin) async throws -> Int {
        try await perform { store in
            let old = try store.telemetryChunks(channel: channel, to: cutoff).filter { $0.start < cutoff }
            var removed = 0
            var replacements: [TelemetryChunk] = []
            for chunk in old {
                var samples: [TelemetrySample] = []
                try Self.decodeChunk(chunk, into: &samples)
                let kept = samples.filter { $0.time >= cutoff }
                removed += samples.count - kept.count
                if let first = kept.first, let last = kept.last {
                    replacements.append(
                        TelemetryChunk(
                            channel: channel, start: first.time, end: last.time, count: kept.count, encoding: SampleCodec.encoding,
                            payload: SampleCodec.encode(kept[...])
                        )
                    )
                }
            }
            try store.pruneTelemetry(channel: channel, before: cutoff, replacements: replacements, by: author)
            return removed
        }
    }

    /// Applies `maxAge` to every channel, measured back from `now`. Returns
    /// samples removed per channel (channels with none removed are omitted).
    public func applyRetention(maxAge: TimeInterval, now: Date, by author: Origin = .system) async throws -> [ObjectID: Int] {
        let cutoff = now.timeIntervalSinceReferenceDate - maxAge
        var removed: [ObjectID: Int] = [:]
        for channel in try await channels() {
            let count = try await removeSamples(from: channel.id, before: cutoff, by: author)
            if count > 0 { removed[channel.id] = count }
        }
        return removed
    }

    // MARK: Decoding

    static func decode(_ chunks: [TelemetryChunk], from: Double?, to: Double?) throws -> [TelemetrySample] {
        var samples: [TelemetrySample] = []
        samples.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        var ordered = true
        var lastEnd = -Double.infinity
        for chunk in chunks {
            if chunk.start < lastEnd { ordered = false }
            lastEnd = max(lastEnd, chunk.end)
            try decodeChunk(chunk, into: &samples)
        }
        // Batches appended out of order overlap; merge them by time.
        if !ordered { samples.sort { $0.time < $1.time } }
        let low = from ?? -Double.infinity
        let high = to ?? Double.infinity
        guard let first = samples.first, let last = samples.last, first.time < low || last.time > high else { return samples }
        let lower = samples.partitionPoint { $0.time >= low }
        let upper = samples.partitionPoint { $0.time > high }
        return Array(samples[lower..<upper])
    }

    static func decodeChunk(_ chunk: TelemetryChunk, into samples: inout [TelemetrySample]) throws {
        guard chunk.encoding == SampleCodec.encoding else { throw TelemetryError.unsupportedEncoding(chunk.encoding) }
        try SampleCodec.decode(chunk.payload, count: chunk.count, into: &samples)
    }

    /// Classifies the store errors telemetry surfaces, registered once.
    private static let classifierRegistration: Void = {
        ErrorClassifier.shared.register { error in
            guard let error = error as? StoreError else { return nil }
            switch error {
            case .truthConflict(_, let attribute, let existing, let incoming):
                return ClassifiedError(
                    category: .evidenceVerification,
                    whatHappened: "\(incoming.rawValue.capitalized) values can't be written into \(existing.rawValue) \(attribute ?? "data").",
                    whatSurvived: ["The \(existing.rawValue) values are unchanged."],
                    nextActions: [NextAction("Store them in a separate \(incoming.rawValue) channel")]
                )
            case .protectedRemoval(_, let attribute, _):
                return ClassifiedError(
                    category: .agentTool, whatHappened: "Only a person or the system can remove protected \(attribute) values.",
                    whatSurvived: ["All values were kept."], nextActions: [NextAction("Ask a person to approve the removal")]
                )
            default:
                return nil
            }
        }
    }()
}

extension Array {
    /// First index whose element satisfies `predicate`, for a predicate that
    /// is false then true along the array (binary search).
    fileprivate func partitionPoint(_ predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

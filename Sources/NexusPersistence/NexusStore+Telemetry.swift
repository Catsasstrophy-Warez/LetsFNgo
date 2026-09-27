import Foundation
import NexusCore
import NexusModel

/// A telemetry channel: one quantity at one object (usually a test point),
/// sampled over time, in exactly one truth class. Observed samples from an
/// instrument and modeled samples from a simulation never share a channel.
public struct TelemetryChannel: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    /// The object measured or simulated: a test point, sensor or component.
    public var object: ObjectID
    public var quantity: String
    public var unit: String
    /// Nominal rate in Hz; nil for irregular sampling.
    public var sampleRate: Double?
    /// Who produces the samples. `provenance.truth` is the channel's truth class.
    public var provenance: Provenance
    public var createdAt: Date

    public init(
        id: ObjectID = .make(), object: ObjectID, quantity: String, unit: String, sampleRate: Double? = nil, provenance: Provenance,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.object = object
        self.quantity = quantity
        self.unit = unit
        self.sampleRate = sampleRate
        self.provenance = provenance
        self.createdAt = createdAt ?? provenance.timestamp
    }

    public var truth: TruthClass { provenance.truth }
}

/// A run of samples stored as one row. The store treats `payload` as opaque
/// bytes described by `encoding`; NexusTelemetry owns the format.
public struct TelemetryChunk: Sendable, Hashable {
    public var channel: ObjectID
    /// First and last sample times, seconds since the reference date.
    public var start: Double
    public var end: Double
    public var count: Int
    public var encoding: String
    public var payload: Data

    public init(channel: ObjectID, start: Double, end: Double, count: Int, encoding: String, payload: Data) {
        self.channel = channel
        self.start = start
        self.end = end
        self.count = count
        self.encoding = encoding
        self.payload = payload
    }
}

/// Telemetry storage (migration 5).
///
/// Samples are stored in chunks rather than one row per sample. At 1M+
/// samples a row per sample costs ~40–60 bytes each with its index, a B-tree
/// insert per sample, and a row decode per sample on read. A chunk of a few
/// thousand samples is one insert and one index entry, reads fetch a handful
/// of rows for any range, and retention deletes whole rows. The trade-off is
/// that SQL can't filter inside a chunk; the caller trims the edge chunks.
///
/// Payloads are base64 text for now, like in-memory blobs, because the
/// connection binds text but not blobs; `encoding` lets a later format store
/// raw bytes without a migration.
///
/// Truth is enforced here, so no caller can bypass it: samples may only be
/// appended to a channel of the same truth class, and samples of a recorded
/// or observed channel may only be removed by a user or the system.
extension NexusStore {
    public func createTelemetryChannel(_ channel: TelemetryChannel) throws {
        try locked {
            try transaction {
                guard channel.provenance.isConfidenceValid else {
                    throw ModelError.confidenceOutOfRange(channel.provenance.confidence ?? .nan)
                }
                if try fetchTelemetryChannel(channel.id) != nil { throw StoreError.duplicate(channel.id) }
                try db.run(
                    """
                    INSERT INTO telemetry_channels (id, object_id, quantity, unit, truth, sample_rate, created_at, record)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(channel.id.description), .text(channel.object.description), .text(channel.quantity), .text(channel.unit),
                        .text(channel.truth.rawValue), channel.sampleRate.sql, .real(channel.createdAt.timeIntervalSinceReferenceDate),
                        .text(try telemetryJSON(channel)),
                    ]
                )
            }
        }
    }

    public func telemetryChannel(_ id: ObjectID) throws -> TelemetryChannel? {
        try locked { try fetchTelemetryChannel(id) }
    }

    /// Channels, optionally only those on `object`, oldest first.
    public func telemetryChannels(object: ObjectID? = nil) throws -> [TelemetryChannel] {
        try locked {
            let rows: [String]
            if let object {
                rows = try db.query(
                    "SELECT record FROM telemetry_channels WHERE object_id = ? ORDER BY created_at, id", [.text(object.description)]
                ) { $0.text(0) ?? "" }
            } else {
                rows = try db.query("SELECT record FROM telemetry_channels ORDER BY created_at, id") { $0.text(0) ?? "" }
            }
            return try rows.map(decodeTelemetryChannel)
        }
    }

    /// Appends chunks atomically. Every chunk's channel must exist and be of
    /// the `truth` class given; a modeled chunk can never land in an observed channel.
    public func appendTelemetryChunks(_ chunks: [TelemetryChunk], truth: TruthClass) throws {
        try locked {
            try transaction {
                var checked: Set<ObjectID> = []
                for chunk in chunks {
                    if checked.insert(chunk.channel).inserted {
                        guard let channel = try fetchTelemetryChannel(chunk.channel) else { throw StoreError.notFound(chunk.channel) }
                        guard channel.truth == truth else {
                            throw StoreError.truthConflict(object: channel.id, attribute: channel.quantity, existing: channel.truth, incoming: truth)
                        }
                    }
                    try insertTelemetryChunk(chunk)
                }
            }
        }
    }

    /// Chunks of `channel` overlapping `[from, to]` (seconds since the
    /// reference date; nil for unbounded), in time order.
    public func telemetryChunks(channel: ObjectID, from: Double? = nil, to: Double? = nil) throws -> [TelemetryChunk] {
        try locked {
            try db.query(
                """
                SELECT start_at, end_at, sample_count, encoding, payload FROM telemetry_chunks
                WHERE channel_id = ? AND end_at >= ? AND start_at <= ? ORDER BY start_at, row_id
                """,
                [.text(channel.description), .real(from ?? -Double.greatestFiniteMagnitude), .real(to ?? Double.greatestFiniteMagnitude)]
            ) { row in
                guard let encoding = row.text(3), let text = row.text(4), let payload = Data(base64Encoded: text) else {
                    throw StoreError.corruptRecord(table: "telemetry_chunks", id: channel.description)
                }
                return TelemetryChunk(channel: channel, start: row.real(0), end: row.real(1), count: Int(row.int(2)), encoding: encoding, payload: payload)
            }
        }
    }

    /// Removes every chunk of `channel` starting before `cutoff` and inserts
    /// `replacements` (the kept tails of chunks that straddled it), atomically.
    /// Returns the number of chunks removed.
    @discardableResult
    public func pruneTelemetry(channel: ObjectID, before cutoff: Double, replacements: [TelemetryChunk] = [], by author: Origin) throws -> Int {
        try locked {
            try transaction {
                guard let record = try fetchTelemetryChannel(channel) else { throw StoreError.notFound(channel) }
                try requireRemovable(record, by: author)
                let removed =
                    try db.query(
                        "SELECT COUNT(*) FROM telemetry_chunks WHERE channel_id = ? AND start_at < ?", [.text(channel.description), .real(cutoff)]
                    ) { Int($0.int(0)) }.first ?? 0
                try db.run("DELETE FROM telemetry_chunks WHERE channel_id = ? AND start_at < ?", [.text(channel.description), .real(cutoff)])
                for chunk in replacements {
                    guard chunk.channel == channel else { throw StoreError.notFound(chunk.channel) }
                    try insertTelemetryChunk(chunk)
                }
                return removed
            }
        }
    }

    /// Deletes a channel and all its samples.
    public func deleteTelemetryChannel(_ id: ObjectID, by author: Origin) throws {
        try locked {
            try transaction {
                guard let record = try fetchTelemetryChannel(id) else { throw StoreError.notFound(id) }
                try requireRemovable(record, by: author)
                try db.run("DELETE FROM telemetry_chunks WHERE channel_id = ?", [.text(id.description)])
                try db.run("DELETE FROM telemetry_channels WHERE id = ?", [.text(id.description)])
            }
        }
    }

    // MARK: Private

    private func requireRemovable(_ channel: TelemetryChannel, by author: Origin) throws {
        guard TruthPolicy.protected.contains(channel.truth) else { return }
        switch author {
        case .user, .system: return
        default: throw StoreError.protectedRemoval(object: channel.id, attribute: channel.quantity, by: author)
        }
    }

    private func insertTelemetryChunk(_ chunk: TelemetryChunk) throws {
        guard chunk.start.isFinite, chunk.end.isFinite, chunk.end >= chunk.start, chunk.count >= 0 else {
            throw StoreError.corruptRecord(table: "telemetry_chunks", id: chunk.channel.description)
        }
        try db.run(
            "INSERT INTO telemetry_chunks (channel_id, start_at, end_at, sample_count, encoding, payload) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(chunk.channel.description), .real(chunk.start), .real(chunk.end), .int(Int64(chunk.count)), .text(chunk.encoding),
                .text(chunk.payload.base64EncodedString()),
            ]
        )
    }

    private func fetchTelemetryChannel(_ id: ObjectID) throws -> TelemetryChannel? {
        try db.query("SELECT record FROM telemetry_channels WHERE id = ?", [.text(id.description)]) { $0.text(0) ?? "" }
            .first.map(decodeTelemetryChannel)
    }

    private func decodeTelemetryChannel(_ text: String) throws -> TelemetryChannel {
        do {
            return try JSONDecoder().decode(TelemetryChannel.self, from: Data(text.utf8))
        } catch {
            throw StoreError.corruptRecord(table: "telemetry_channels", id: "?")
        }
    }

    private func telemetryJSON(_ channel: TelemetryChannel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(channel), as: UTF8.self)
    }
}

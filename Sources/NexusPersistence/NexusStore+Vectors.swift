import Foundation
import NexusCore
import NexusModel

/// One object's embedding under one model (migration 6).
///
/// Vectors are derived data: they can always be rebuilt from the object, so
/// they carry no truth class of their own. The object keeps its `TruthClass`
/// and `Provenance`; a vector is only another way to find it.
public struct StoredVector: Sendable, Hashable {
    public var object: ObjectID
    /// Embedding model identifier, e.g. "nexus.hashing.v1.256".
    public var model: String
    public var vector: [Float]
    /// Hash of the exact text that was embedded; see `staleVectorObjects`.
    public var contentHash: String
    public var updatedAt: Date
    /// The object's type, filled in on reads when the object exists. Ignored on writes.
    public var objectType: ObjectType?

    public var dimension: Int { vector.count }

    public init(object: ObjectID, model: String, vector: [Float], contentHash: String, updatedAt: Date, objectType: ObjectType? = nil) {
        self.object = object
        self.model = model
        self.vector = vector
        self.contentHash = contentHash
        self.updatedAt = updatedAt
        self.objectType = objectType
    }

    /// Base64 of the vector as little-endian Float32, the stored format.
    public static func encode(_ vector: [Float]) -> String {
        #if _endian(little)
            return vector.withUnsafeBytes { Data($0) }.base64EncodedString()
        #else
            var data = Data(capacity: vector.count * 4)
            for value in vector {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            return data.base64EncodedString()
        #endif
    }

    /// Inverse of `encode`; nil when the text isn't `dimension` Float32 values.
    public static func decode(_ text: String, dimension: Int) -> [Float]? {
        guard dimension >= 0, let data = Data(base64Encoded: text), data.count == dimension * 4 else { return nil }
        return data.withUnsafeBytes { raw in
            [Float](unsafeUninitializedCapacity: dimension) { buffer, initialized in
                for index in 0..<dimension {
                    let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                    buffer[index] = Float(bitPattern: bits)
                }
                initialized = dimension
            }
        }
    }
}

/// Vector storage (migration 6).
///
/// The canonical store keeps the vectors so an index survives a reload
/// without re-embedding; the search itself runs in memory (`NexusSearch`).
/// Writing a vector is not a change to the object, so it never appears in
/// the change feed, which is what keeps an index that follows the feed from
/// re-triggering itself.
extension NexusStore {
    /// Inserts or replaces vectors, keyed by (object, model), in one transaction.
    public func upsertVectors(_ vectors: [StoredVector]) throws {
        guard !vectors.isEmpty else { return }
        try locked {
            try transaction {
                for vector in vectors {
                    guard !vector.model.isEmpty, vector.vector.allSatisfy(\.isFinite) else {
                        throw StoreError.corruptRecord(table: "vectors", id: vector.object.description)
                    }
                    try db.run(
                        """
                        INSERT INTO vectors (object_id, model, dimension, vector, content_hash, updated_at) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (object_id, model) DO UPDATE SET
                            dimension = excluded.dimension, vector = excluded.vector,
                            content_hash = excluded.content_hash, updated_at = excluded.updated_at
                        """,
                        [
                            .text(vector.object.description), .text(vector.model), .int(Int64(vector.dimension)),
                            .text(StoredVector.encode(vector.vector)), .text(vector.contentHash),
                            .real(vector.updatedAt.timeIntervalSinceReferenceDate),
                        ]
                    )
                }
            }
        }
    }

    public func upsertVector(_ vector: StoredVector) throws {
        try upsertVectors([vector])
    }

    /// Removes an object's vectors: under one model, or under every model when `model` is nil.
    public func deleteVectors(object: ObjectID, model: String? = nil) throws {
        try deleteVectors(objects: [object], model: model)
    }

    public func deleteVectors(objects: [ObjectID], model: String? = nil) throws {
        guard !objects.isEmpty else { return }
        try locked {
            try transaction {
                for id in objects {
                    if let model {
                        try db.run("DELETE FROM vectors WHERE object_id = ? AND model = ?", [.text(id.description), .text(model)])
                    } else {
                        try db.run("DELETE FROM vectors WHERE object_id = ?", [.text(id.description)])
                    }
                }
            }
        }
    }

    /// Removes every vector of `model`, e.g. when a model is retired.
    public func deleteVectors(model: String) throws {
        try locked {
            try transaction { try db.run("DELETE FROM vectors WHERE model = ?", [.text(model)]) }
        }
    }

    public func vector(object: ObjectID, model: String) throws -> StoredVector? {
        try locked {
            try db.query(
                """
                SELECT v.object_id, v.dimension, v.vector, v.content_hash, v.updated_at, o.type
                FROM vectors v LEFT JOIN objects o ON o.id = v.object_id
                WHERE v.object_id = ? AND v.model = ?
                """,
                [.text(object.description), .text(model)]
            ) { try decodeVectorRow($0, model: model) }.first
        }
    }

    public func vectorCount(model: String) throws -> Int {
        try locked {
            try db.query("SELECT COUNT(*) FROM vectors WHERE model = ?", [.text(model)]) { Int($0.int(0)) }.first ?? 0
        }
    }

    /// One page of `model`'s vectors in object-ID order, starting after
    /// `after`. Vectors of deleted objects are skipped unless `includeDeleted`.
    public func vectors(model: String, after: ObjectID? = nil, limit: Int = 1_000, includeDeleted: Bool = false) throws -> [StoredVector] {
        guard limit > 0 else { return [] }
        return try locked {
            try db.query(
                """
                SELECT v.object_id, v.dimension, v.vector, v.content_hash, v.updated_at, o.type
                FROM vectors v LEFT JOIN objects o ON o.id = v.object_id
                WHERE v.model = ? AND v.object_id > ? AND (? OR o.lifecycle IS NULL OR o.lifecycle != 'deleted')
                ORDER BY v.object_id LIMIT ?
                """,
                [.text(model), .text(after?.description ?? ""), .int(includeDeleted ? 1 : 0), .int(Int64(limit))]
            ) { try decodeVectorRow($0, model: model) }
        }
    }

    /// Streams every vector of `model` in chunks of `chunkSize`. Each chunk is
    /// read under its own lock, so writers aren't held off for a whole scan.
    public func forEachVectorChunk(
        model: String, chunkSize: Int = 1_000, includeDeleted: Bool = false, _ body: ([StoredVector]) throws -> Void
    ) throws {
        var cursor: ObjectID?
        while true {
            let chunk = try vectors(model: model, after: cursor, limit: max(chunkSize, 1), includeDeleted: includeDeleted)
            guard let last = chunk.last else { return }
            try body(chunk)
            cursor = last.object
        }
    }

    /// Stored content hash of every vector of `model`.
    public func vectorContentHashes(model: String) throws -> [ObjectID: String] {
        try locked {
            let rows = try db.query("SELECT object_id, content_hash FROM vectors WHERE model = ?", [.text(model)]) {
                (($0.text(0)).flatMap(ObjectID.init), $0.text(1) ?? "")
            }
            var hashes: [ObjectID: String] = [:]
            for (id, hash) in rows {
                if let id { hashes[id] = hash }
            }
            return hashes
        }
    }

    /// The objects in `current` (object → hash of its text now) whose stored
    /// vector under `model` is missing or was embedded from different text.
    public func staleVectorObjects(model: String, current: [ObjectID: String]) throws -> [ObjectID] {
        guard !current.isEmpty else { return [] }
        let ids = current.keys.sorted()
        return try locked {
            var stored: [ObjectID: String] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = ids[start..<min(start + 500, ids.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try db.query(
                    "SELECT object_id, content_hash FROM vectors WHERE model = ? AND object_id IN (\(placeholders))",
                    [.text(model)] + chunk.map { .text($0.description) }
                ) { (($0.text(0)).flatMap(ObjectID.init), $0.text(1) ?? "") }
                for (id, hash) in rows {
                    if let id { stored[id] = hash }
                }
            }
            return ids.filter { stored[$0] != current[$0] }
        }
    }

    /// One page of objects in ID order, starting after `after`, including
    /// deleted ones. For walking the whole store in bounded memory.
    public func objectPage(after: ObjectID? = nil, limit: Int = 500) throws -> [ObjectRecord] {
        guard limit > 0 else { return [] }
        return try locked {
            try db.query(
                "SELECT record FROM objects WHERE id > ? ORDER BY id LIMIT ?", [.text(after?.description ?? ""), .int(Int64(limit))]
            ) { try decode(ObjectRecord.self, $0, table: "objects") }
        }
    }

    // MARK: Private

    private func decodeVectorRow(_ row: SQLiteConnection.Statement, model: String) throws -> StoredVector {
        let idText = row.text(0) ?? "?"
        guard let id = ObjectID(idText), let text = row.text(2), let vector = StoredVector.decode(text, dimension: Int(row.int(1))) else {
            throw StoreError.corruptRecord(table: "vectors", id: idText)
        }
        return StoredVector(
            object: id, model: model, vector: vector, contentHash: row.text(3) ?? "",
            updatedAt: Date(timeIntervalSinceReferenceDate: row.real(4)), objectType: row.text(5).map(ObjectType.init(rawValue:))
        )
    }
}

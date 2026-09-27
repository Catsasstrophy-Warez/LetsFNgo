import Foundation
import NexusCore

/// Metadata for one stored blob. The bytes are addressed by their SHA-256.
///
/// A blob is raw content with no meaning of its own, so it carries no truth
/// class: the object that references it (a document, an image) holds the
/// provenance saying who brought those bytes in, when, and how far to trust
/// them. Two objects holding identical bytes share one blob.
public struct BlobRef: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    /// Lowercase hex SHA-256 of the bytes.
    public var sha256: String
    public var byteCount: Int
    /// IANA media type given when the bytes were first stored, e.g. "text/markdown".
    public var mediaType: String
    public var createdAt: Date
}

public enum BlobError: Error, Equatable, Sendable {
    case invalidDigest(String)
    /// Metadata exists but the bytes are gone from the blob directory.
    case missingBytes(sha256: String)
    /// The stored bytes no longer hash to their address.
    case corruptBytes(sha256: String)
}

/// Content-addressed blob storage.
///
/// Metadata lives in the `blobs` table (migration 4). For a file store the
/// bytes live beside the database in `<database>.blobs/<first two hex
/// digits>/<sha256>`, so large payloads stay out of SQLite pages and the WAL.
/// An in-memory store keeps them in a temporary table of the same connection,
/// so they vanish with it.
extension NexusStore {
    /// Stores `data` and returns its metadata. Storing bytes that are already
    /// present returns the existing blob unchanged, whatever `mediaType` says.
    @discardableResult
    public func putBlob(_ data: Data, mediaType: String) throws -> BlobRef {
        let digest = ContentHash.sha256(data)
        return try locked {
            try transaction {
                let location = try blobLocation()
                if let existing = try fetchBlob(digest) {
                    // Repair a blob directory that lost the file.
                    if try !hasBytes(digest, in: location) {
                        try writeBytes(data, digest: digest, in: location)
                    }
                    return existing
                }
                try writeBytes(data, digest: digest, in: location)
                let blob = BlobRef(
                    id: .make(), sha256: digest, byteCount: data.count, mediaType: mediaType, createdAt: clock.now()
                )
                try db.run(
                    "INSERT INTO blobs (id, sha256, byte_count, media_type, created_at) VALUES (?, ?, ?, ?, ?)",
                    [
                        .text(blob.id.description), .text(blob.sha256), .int(Int64(blob.byteCount)),
                        .text(blob.mediaType), .real(blob.createdAt.timeIntervalSinceReferenceDate),
                    ]
                )
                return blob
            }
        }
    }

    /// Metadata for the blob with this digest, or nil.
    public func blob(sha256 digest: String) throws -> BlobRef? {
        try locked { try fetchBlob(digest) }
    }

    /// The bytes of a stored blob, verified against their digest. Nil when no
    /// blob with this digest was stored.
    public func blobData(sha256 digest: String) throws -> Data? {
        guard ContentHash.isDigest(digest) else { throw BlobError.invalidDigest(digest) }
        return try locked {
            guard try fetchBlob(digest) != nil else { return nil }
            let data: Data
            switch try blobLocation() {
            case .directory(let directory):
                let url = Self.blobURL(digest, in: directory)
                guard FileManager.default.fileExists(atPath: url.path) else { throw BlobError.missingBytes(sha256: digest) }
                data = try Data(contentsOf: url)
            case .memory:
                guard let encoded = try db.query(
                    "SELECT bytes FROM temp.blob_bytes WHERE sha256 = ?", [.text(digest)], row: { $0.text(0) }
                ).first, let text = encoded, let decoded = Data(base64Encoded: text) else {
                    throw BlobError.missingBytes(sha256: digest)
                }
                data = decoded
            }
            guard ContentHash.sha256(data) == digest else { throw BlobError.corruptBytes(sha256: digest) }
            return data
        }
    }

    /// Directory holding a file store's blob bytes; nil for an in-memory store.
    public var blobDirectory: URL? {
        guard case .directory(let url)? = try? locked({ try blobLocation() }) else { return nil }
        return url
    }

    /// Copies a file store's blob directory next to another database file, so
    /// a backup carries the bytes its `blobs` rows point at.
    func copyBlobs(toDatabaseAt url: URL) throws {
        guard case .directory(let directory) = try blobLocation(),
            FileManager.default.fileExists(atPath: directory.path)
        else { return }
        try FileManager.default.copyItem(at: directory, to: URL(fileURLWithPath: url.path + ".blobs", isDirectory: true))
    }

    // MARK: Private

    private enum BlobLocation {
        case directory(URL)
        case memory
    }

    private func fetchBlob(_ digest: String) throws -> BlobRef? {
        guard ContentHash.isDigest(digest) else { throw BlobError.invalidDigest(digest) }
        return try db.query(
            "SELECT id, sha256, byte_count, media_type, created_at FROM blobs WHERE sha256 = ?", [.text(digest)]
        ) { row in
            guard let idText = row.text(0), let id = ObjectID(idText), let sha = row.text(1), let media = row.text(3) else {
                throw StoreError.corruptRecord(table: "blobs", id: row.text(0) ?? "?")
            }
            return BlobRef(
                id: id, sha256: sha, byteCount: Int(row.int(2)), mediaType: media,
                createdAt: Date(timeIntervalSinceReferenceDate: row.real(4))
            )
        }.first
    }

    /// The main database's file, from SQLite itself, so the store needs no
    /// extra state to find its blob directory. SQLite reports an empty file
    /// name for in-memory databases.
    private func blobLocation() throws -> BlobLocation {
        let file = try db.query("PRAGMA database_list") { row in (row.text(1), row.text(2)) }
            .first { $0.0 == "main" }?.1 ?? ""
        guard !file.isEmpty else {
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS blob_bytes (sha256 TEXT PRIMARY KEY, bytes TEXT NOT NULL);")
            return .memory
        }
        return .directory(URL(fileURLWithPath: file + ".blobs", isDirectory: true))
    }

    private static func blobURL(_ digest: String, in directory: URL) -> URL {
        directory.appendingPathComponent(String(digest.prefix(2)), isDirectory: true).appendingPathComponent(digest)
    }

    private func hasBytes(_ digest: String, in location: BlobLocation) throws -> Bool {
        switch location {
        case .directory(let directory):
            return FileManager.default.fileExists(atPath: Self.blobURL(digest, in: directory).path)
        case .memory:
            return try !db.query("SELECT 1 FROM temp.blob_bytes WHERE sha256 = ?", [.text(digest)]) { _ in true }.isEmpty
        }
    }

    /// Writes the bytes before the metadata row, atomically, so a crash can
    /// leave at worst an unreferenced file, never a row without its bytes.
    private func writeBytes(_ data: Data, digest: String, in location: BlobLocation) throws {
        switch location {
        case .directory(let directory):
            let url = Self.blobURL(digest, in: directory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        case .memory:
            try db.run(
                "INSERT OR REPLACE INTO temp.blob_bytes (sha256, bytes) VALUES (?, ?)",
                [.text(digest), .text(data.base64EncodedString())]
            )
        }
    }
}

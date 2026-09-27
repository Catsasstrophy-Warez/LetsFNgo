import Foundation
import NexusCore
import NexusModel
import NexusPersistence

extension ObjectType {
    /// A citable span of a document. Child of its document through `contains`.
    public static let passage: ObjectType = "passage"
}

/// How a document's bytes are read.
public enum DocumentFormat: String, Sendable, Hashable, Codable {
    case plainText
    case markdown
    case pdf

    public init?(mediaType: String) {
        switch mediaType.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
        case "text/plain": self = .plainText
        case "text/markdown", "text/x-markdown": self = .markdown
        case "application/pdf": self = .pdf
        default: return nil
        }
    }
}

public enum ExtractionState: String, Sendable, Hashable, Codable {
    /// Passages were segmented from the blob.
    case extracted
    /// The blob is stored but its text is not yet extracted (PDF on Linux).
    case needsExtraction
}

public enum DocumentError: Error, Equatable, Sendable {
    case unsupportedMediaType(String)
    case notADocument(ObjectID)
    case notAPassage(ObjectID)
    case corrupt(ObjectID, field: String)
}

/// A passage object read through a typed view.
public struct Passage: Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var document: ObjectID
    public var index: Int
    /// UTF-8 byte range of the passage in the document's blob.
    public var start: Int
    public var end: Int
    /// Verbatim text of that byte range.
    public var text: String
    public var section: String?
    public var provenance: Provenance

    public init(record: ObjectRecord) throws {
        guard record.type == .passage else { throw DocumentError.notAPassage(record.id) }
        func int(_ key: String) throws -> Int {
            guard case .int(let value)? = record.attributes[key]?.value else { throw DocumentError.corrupt(record.id, field: key) }
            return Int(value)
        }
        guard case .reference(let document)? = record.attributes[Keys.document]?.value else {
            throw DocumentError.corrupt(record.id, field: Keys.document)
        }
        guard case .string(let text)? = record.attributes[Keys.text]?.value else {
            throw DocumentError.corrupt(record.id, field: Keys.text)
        }
        id = record.id
        self.document = document
        index = try int(Keys.index)
        start = try int(Keys.start)
        end = try int(Keys.end)
        self.text = text
        if case .string(let section)? = record.attributes[Keys.section]?.value { self.section = section }
        provenance = record.provenance
    }

    /// Stable address of the passage: the same bytes always give the same
    /// key, whichever document object holds them.
    public func key(blob: String) -> String { "\(blob)#\(start)-\(end)" }

    enum Keys {
        static let document = "document"
        static let text = "text"
        static let index = "index"
        static let start = "start"
        static let end = "end"
        static let section = "section"
    }
}

public struct IngestResult: Sendable, Hashable {
    public var document: ObjectRecord
    public var blob: BlobRef
    public var passages: [Passage]
    /// True when these bytes were already a document and that one was returned.
    public var deduplicated: Bool
}

/// A search hit resolved to the document it belongs to.
public struct DocumentHit: Sendable, Hashable {
    public var document: ObjectID
    /// The matching passage, or nil when the document itself matched (its title, say).
    public var passage: Passage?
    public var title: String
    /// BM25; lower is more relevant.
    public var score: Double
}

/// Document ingestion over the canonical store.
///
/// The bytes go to the store's content-addressed blob storage. The document
/// is a `.document` object whose `blob` attribute is the SHA-256, and each
/// passage is a `.passage` object the document `contains`.
///
/// Passages are child objects rather than one big attribute on the document
/// because the object search index is per object: a passage object makes a
/// full-text hit point at the exact passage (and through it the document),
/// ranks a short relevant paragraph above a long document that mentions the
/// word once, and gives claims a precise object to cite. A dedicated
/// `passage` type, rather than `source`, keeps "a citable source" meaning
/// what it says and lets search filter to passages.
///
/// PDF: the blob is stored and the document marked `needsExtraction`. Linux
/// has no PDF parser; extraction with PDFKit belongs in an Apple-only target
/// and will add passages to the existing document without touching its blob.
public struct DocumentLibrary: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Ingesting

    /// Stores `data` and, for text formats, segments it into passages.
    ///
    /// Identical bytes are one document: ingesting them again returns the
    /// existing (non-deleted) document with `deduplicated` set, adding it to
    /// `project` if given.
    @discardableResult
    public func ingest(
        _ data: Data,
        title: String,
        mediaType: String,
        in project: ObjectID? = nil,
        by author: Origin
    ) throws -> IngestResult {
        guard let format = DocumentFormat(mediaType: mediaType) else { throw DocumentError.unsupportedMediaType(mediaType) }
        let segmentation: Segmentation? = switch format {
        case .plainText: try Segmenter.segment(data, as: .plainText)
        case .markdown: try Segmenter.segment(data, as: .markdown)
        case .pdf: nil
        }

        return try store.batch { store in
            let now = clock.now()
            let blob = try store.putBlob(data, mediaType: mediaType)
            if let existing = try document(withBlob: blob.sha256) {
                if let project, try !store.relationships(from: project, kind: .contains).contains(where: { $0.to == existing.id && $0.validTo == nil }) {
                    try store.relate(Relationship(
                        kind: .contains, from: project, to: existing.id, validFrom: now,
                        provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
                    ))
                }
                return IngestResult(document: existing, blob: blob, passages: try passages(of: existing.id), deduplicated: true)
            }

            let method = segmentation == nil ? "blob stored; text extraction pending" : "segmenter v\(Segmenter.version) (\(format.rawValue))"
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: method)
            var attributes: [String: Attribute] = [
                "blob": Attribute(.string(blob.sha256)),
                "mediaType": Attribute(.string(mediaType)),
                "format": Attribute(.string(format.rawValue)),
                "byteCount": Attribute(.int(Int64(data.count))),
                "extraction": Attribute(.string((segmentation == nil ? ExtractionState.needsExtraction : .extracted).rawValue)),
            ]
            if let segmentation {
                attributes["passageCount"] = Attribute(.int(Int64(segmentation.passages.count)))
                if !segmentation.sections.isEmpty {
                    attributes["sections"] = Attribute(.list(segmentation.sections.map { section in
                        .map([
                            "title": .string(section.title), "level": .int(Int64(section.level)),
                            "start": .int(Int64(section.start)),
                        ])
                    }))
                }
            }
            let document = try store.create(ObjectRecord(type: .document, title: title, attributes: attributes, provenance: provenance))
            if let project {
                try store.relate(Relationship(kind: .contains, from: project, to: document.id, validFrom: now, provenance: provenance))
            }

            var passages: [Passage] = []
            for span in segmentation?.passages ?? [] {
                let derived = Provenance(
                    origin: author, truth: .derived, timestamp: now, method: method,
                    dependencies: [document.id], transformation: "utf8[\(span.start)..<\(span.end)]"
                )
                var passageAttributes: [String: Attribute] = [
                    Passage.Keys.document: Attribute(.reference(document.id)),
                    Passage.Keys.text: Attribute(.string(span.text)),
                    Passage.Keys.index: Attribute(.int(Int64(span.index))),
                    Passage.Keys.start: Attribute(.int(Int64(span.start))),
                    Passage.Keys.end: Attribute(.int(Int64(span.end))),
                ]
                if let section = span.section.map({ segmentation!.sections[$0].title }), !section.isEmpty {
                    passageAttributes[Passage.Keys.section] = Attribute(.string(section))
                }
                let record = try store.create(ObjectRecord(
                    type: .passage, title: Self.snippet(span.text, fallback: "\(title) ¶\(span.index + 1)"),
                    attributes: passageAttributes, provenance: derived
                ))
                try store.relate(Relationship(kind: .contains, from: document.id, to: record.id, provenance: derived))
                passages.append(try Passage(record: record))
            }
            return IngestResult(document: document, blob: blob, passages: passages, deduplicated: false)
        }
    }

    // MARK: Reading

    /// The document's passages in reading order.
    public func passages(of document: ObjectID) throws -> [Passage] {
        let ids = try store.relationships(from: document, kind: .contains).map(\.to)
        return try store.objects(ids)
            .filter { $0.type == .passage && $0.lifecycle != .deleted }
            .map(Passage.init(record:))
            .sorted { $0.index < $1.index }
    }

    public func passage(_ id: ObjectID) throws -> Passage {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        return try Passage(record: record)
    }

    /// The document's original bytes, verified against their digest.
    public func contents(of document: ObjectID) throws -> Data {
        let digest = try blobDigest(of: document)
        guard let data = try store.blobData(sha256: digest) else { throw BlobError.missingBytes(sha256: digest) }
        return data
    }

    /// Re-reads a passage from the blob. Equal to `passage.text` unless
    /// something has gone badly wrong; used to prove citation lineage.
    public func sourceText(of passage: Passage) throws -> String {
        let data = try contents(of: passage.document)
        guard passage.start >= 0, passage.end <= data.count, passage.start <= passage.end else {
            throw DocumentError.corrupt(passage.id, field: "range")
        }
        return String(decoding: data[data.startIndex + passage.start..<data.startIndex + passage.end], as: UTF8.self)
    }

    public func extractionState(of document: ObjectID) throws -> ExtractionState {
        let record = try requireDocument(document)
        guard case .string(let raw)? = record.attributes["extraction"]?.value, let state = ExtractionState(rawValue: raw) else {
            throw DocumentError.corrupt(document, field: "extraction")
        }
        return state
    }

    /// Full-text search over documents and their passages. Passage hits
    /// carry the passage; every hit names its document.
    public func search(_ text: String, limit: Int = 20) throws -> [DocumentHit] {
        try store.search(text, types: [.document, .passage], limit: limit).map { hit in
            if hit.type == .passage {
                let passage = try passage(hit.id)
                return DocumentHit(document: passage.document, passage: passage, title: hit.title, score: hit.score)
            }
            return DocumentHit(document: hit.id, passage: nil, title: hit.title, score: hit.score)
        }
    }

    // MARK: Claims

    /// A claim citing the passage's document, quoting the passage verbatim.
    ///
    /// The claim's sources are the document; its provenance depends on the
    /// passage and document; and a `cites` relationship points at the passage,
    /// so the exact bytes behind any claim can be found again.
    @discardableResult
    public func extractClaim(
        from passageID: ObjectID,
        statement: String,
        sourceClass: SourceClass,
        applicability: String? = nil,
        confidence: Double? = nil,
        by author: Origin
    ) throws -> Claim {
        let passage = try passage(passageID)
        let digest = try blobDigest(of: passage.document)
        let now = clock.now()
        let claim = Claim(
            statement: statement, sources: [passage.document], passages: [passage.text], sourceClass: sourceClass,
            applicability: applicability,
            provenance: Provenance(
                origin: author, truth: .claimed, timestamp: now, method: "extracted from passage", confidence: confidence,
                dependencies: [passage.id, passage.document], transformation: "verbatim \(passage.key(blob: digest))"
            )
        )
        try store.batch { store in
            try store.add(claim)
            try store.relate(Relationship(
                kind: .cites, from: claim.id, to: passage.id,
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
            ))
        }
        return claim
    }

    /// Claims citing a specific passage.
    public func claims(citing passageID: ObjectID) throws -> [Claim] {
        try store.relationships(to: passageID, kind: .cites).compactMap { try store.claim($0.from) }
    }

    // MARK: Private

    /// The live document holding these bytes, if any.
    ///
    /// The digest is part of the document's indexed text, so FTS finds
    /// candidates without scanning every document; the attribute check then
    /// rules out anything that merely mentions the digest.
    private func document(withBlob digest: String) throws -> ObjectRecord? {
        let hits = try store.search(digest, types: [.document], limit: 100)
        return try store.objects(hits.map(\.id).sorted())
            .first { $0.attributes["blob"]?.value == .string(digest) && $0.lifecycle != .deleted }
    }

    private func requireDocument(_ id: ObjectID) throws -> ObjectRecord {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .document else { throw DocumentError.notADocument(id) }
        return record
    }

    private func blobDigest(of document: ObjectID) throws -> String {
        guard case .string(let digest)? = try requireDocument(document).attributes["blob"]?.value else {
            throw DocumentError.corrupt(document, field: "blob")
        }
        return digest
    }

    /// First line of a passage, shortened, as its title.
    static func snippet(_ text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return fallback }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}

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
    /// The blob is stored but its text is not yet extracted (a PDF with no
    /// extractor, or one without a text layer).
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
    /// One-based PDF page the passage starts on; nil for text documents.
    public var page: Int?
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
        if case .int(let page)? = record.attributes[Keys.page]?.value { self.page = Int(page) }
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
        static let page = "page"
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
/// PDF: with a `PDFTextExtractor` the extracted text is stored as a second
/// blob (the document's `textBlob`) and segmented like plain text, so passage
/// byte ranges address that text and claims still quote exact bytes. Without
/// one, or when the PDF has no text layer, the PDF is stored and the document
/// marked `needsExtraction`; `extractText(of:)` adds the passages later
/// without touching the original blob.
public struct DocumentLibrary: Sendable {
    public let store: NexusStore
    let clock: NexusClock
    /// Reads PDF text. `DocumentLibrary.platformPDFExtractor` is PDFKit on Apple platforms.
    public let pdfExtractor: (any PDFTextExtractor)?

    public init(store: NexusStore, clock: NexusClock = SystemClock(), pdfExtractor: (any PDFTextExtractor)? = nil) {
        self.store = store
        self.clock = clock
        self.pdfExtractor = pdfExtractor
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
        let text: ExtractedText? = switch format {
        case .plainText: ExtractedText(segmentation: try Segmenter.segment(data, as: .plainText), method: "segmenter v\(Segmenter.version) (plainText)")
        case .markdown: ExtractedText(segmentation: try Segmenter.segment(data, as: .markdown), method: "segmenter v\(Segmenter.version) (markdown)")
        case .pdf: try extractPDF(data)
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

            let method = text?.method ?? "blob stored; text extraction pending"
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: method)
            var attributes: [String: Attribute] = [
                "blob": Attribute(.string(blob.sha256)),
                "mediaType": Attribute(.string(mediaType)),
                "format": Attribute(.string(format.rawValue)),
                "byteCount": Attribute(.int(Int64(data.count))),
                "extraction": Attribute(.string((text == nil ? ExtractionState.needsExtraction : .extracted).rawValue)),
            ]
            if let text {
                attributes.merge(try Self.textAttributes(text, in: store)) { _, new in new }
            }
            let document = try store.create(ObjectRecord(type: .document, title: title, attributes: attributes, provenance: provenance))
            if let project {
                try store.relate(Relationship(kind: .contains, from: project, to: document.id, validFrom: now, provenance: provenance))
            }
            let passages = try text.map { try addPassages($0, to: document.id, title: title, by: author, at: now) } ?? []
            return IngestResult(document: document, blob: blob, passages: passages, deduplicated: false)
        }
    }

    /// Extracts the text of a document stored as `needsExtraction`, using
    /// `pdfExtractor`, and adds its passages. The original blob is untouched.
    ///
    /// Returns the passages, or nil when there is still no text to extract
    /// (no extractor, or no text layer). Already extracted documents return
    /// their existing passages.
    @discardableResult
    public func extractText(of documentID: ObjectID, by author: Origin) throws -> [Passage]? {
        let record = try requireDocument(documentID)
        if try extractionState(of: documentID) == .extracted { return try passages(of: documentID) }
        guard case .string(let format)? = record.attributes["format"]?.value, format == DocumentFormat.pdf.rawValue,
              let text = try extractPDF(try contents(of: documentID))
        else { return nil }
        return try store.batch { store in
            let now = clock.now()
            let extracted = try Self.textAttributes(text, in: store)
            let stamp = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: text.method)
            try store.update(documentID, by: author, instruction: "Extracted text (\(text.method))") {
                for (key, attribute) in extracted {
                    $0.attributes[key] = Attribute(attribute.value, provenance: stamp)
                }
                $0.attributes["extraction"] = Attribute(.string(ExtractionState.extracted.rawValue), provenance: stamp)
            }
            return try addPassages(text, to: documentID, title: record.title, by: author, at: now)
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
        let digest = try textDigest(of: passage.document)
        guard let data = try store.blobData(sha256: digest) else { throw BlobError.missingBytes(sha256: digest) }
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
        let digest = try textDigest(of: passage.document)
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

    /// The blob passages index into: the extracted text for a PDF, the
    /// document's own bytes otherwise.
    private func textDigest(of document: ObjectID) throws -> String {
        if case .string(let digest)? = try requireDocument(document).attributes["textBlob"]?.value { return digest }
        return try blobDigest(of: document)
    }

    /// Text from a PDF, or nil when there is no extractor or no text.
    /// An unreadable PDF is still stored: extraction just waits.
    private func extractPDF(_ data: Data) throws -> ExtractedText? {
        guard let pdfExtractor, let pages = try? pdfExtractor.pages(of: data) else { return nil }
        guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        var joined = Data()
        var pageStarts: [Int] = []
        for (index, page) in pages.enumerated() {
            if index > 0 { joined.append(contentsOf: Array("\n\n".utf8)) }
            pageStarts.append(joined.count)
            joined.append(contentsOf: Array(page.utf8))
        }
        return ExtractedText(
            segmentation: try Segmenter.segment(joined, as: .plainText),
            method: "\(pdfExtractor.identifier) text, segmenter v\(Segmenter.version) (plainText)",
            text: joined, pageStarts: pageStarts
        )
    }

    /// Document attributes describing extracted text; stores a PDF's text blob.
    private static func textAttributes(_ text: ExtractedText, in store: NexusStore) throws -> [String: Attribute] {
        var attributes: [String: Attribute] = ["passageCount": Attribute(.int(Int64(text.segmentation.passages.count)))]
        if !text.segmentation.sections.isEmpty {
            attributes["sections"] = Attribute(.list(text.segmentation.sections.map { section in
                .map([
                    "title": .string(section.title), "level": .int(Int64(section.level)),
                    "start": .int(Int64(section.start)),
                ])
            }))
        }
        if let data = text.text {
            attributes["textBlob"] = Attribute(.string(try store.putBlob(data, mediaType: "text/plain; charset=utf-8").sha256))
            attributes["pageCount"] = Attribute(.int(Int64(text.pageStarts.count)))
        }
        return attributes
    }

    private func addPassages(_ text: ExtractedText, to document: ObjectID, title: String, by author: Origin, at now: Date) throws -> [Passage] {
        let segmentation = text.segmentation
        var passages: [Passage] = []
        for span in segmentation.passages {
            let derived = Provenance(
                origin: author, truth: .derived, timestamp: now, method: text.method,
                dependencies: [document], transformation: "utf8[\(span.start)..<\(span.end)]"
            )
            var passageAttributes: [String: Attribute] = [
                Passage.Keys.document: Attribute(.reference(document)),
                Passage.Keys.text: Attribute(.string(span.text)),
                Passage.Keys.index: Attribute(.int(Int64(span.index))),
                Passage.Keys.start: Attribute(.int(Int64(span.start))),
                Passage.Keys.end: Attribute(.int(Int64(span.end))),
            ]
            if let section = span.section.map({ segmentation.sections[$0].title }), !section.isEmpty {
                passageAttributes[Passage.Keys.section] = Attribute(.string(section))
            }
            if let page = text.pageStarts.lastIndex(where: { $0 <= span.start }) {
                passageAttributes[Passage.Keys.page] = Attribute(.int(Int64(page + 1)))
            }
            let record = try store.create(ObjectRecord(
                type: .passage, title: Self.snippet(span.text, fallback: "\(title) ¶\(span.index + 1)"),
                attributes: passageAttributes, provenance: derived
            ))
            try store.relate(Relationship(kind: .contains, from: document, to: record.id, provenance: derived))
            passages.append(try Passage(record: record))
        }
        return passages
    }

    /// First line of a passage, shortened, as its title.
    static func snippet(_ text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return fallback }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}

/// Text ready to become passages: the segmentation, how it was made and, for
/// PDFs, the extracted text (which passages index into) and page offsets.
struct ExtractedText {
    var segmentation: Segmentation
    var method: String
    var text: Data? = nil
    var pageStarts: [Int] = []
}

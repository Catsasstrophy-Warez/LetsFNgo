import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import Testing
@testable import NexusDocuments

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let agent = Origin.agent(id: "research", run: nil)

private let manual = """
    # LT-101 Installation

    Mount the transmitter vertically.
    Keep cable runs short.

    ## Power

    Minimum lift-off voltage is 12 V at the terminals.

    ```
    Vsupply - Iloop x Rloop >= 12 V

    (worst case at 20 mA)
    ```

    ## Wiring C#

    Use twisted pair.
    """

private func library() throws -> (NexusStore, DocumentLibrary) {
    let clock = ManualClock(t0)
    let store = try NexusStore(.inMemory, clock: clock)
    return (store, DocumentLibrary(store: store, clock: clock))
}

@Suite struct SegmenterTests {
    @Test func plainTextSplitsOnBlankLinesWithByteOffsets() throws {
        let text = "First line\nsecond line\n\n  \nThird ✓ para\r\n\r\nLast"
        let segmentation = try Segmenter.segment(Data(text.utf8), as: .plainText)
        #expect(segmentation.passages.map(\.text) == ["First line\nsecond line", "Third ✓ para", "Last"])
        #expect(segmentation.sections.isEmpty)
        let bytes = Array(text.utf8)
        for passage in segmentation.passages {
            #expect(String(decoding: bytes[passage.start..<passage.end], as: UTF8.self) == passage.text)
        }
        // "✓" is three UTF-8 bytes, so offsets are bytes, not characters.
        #expect(segmentation.passages[1].end - segmentation.passages[1].start == 14)
    }

    @Test func markdownHeadingsMakeSectionsAndFencesStayWhole() throws {
        let segmentation = try Segmenter.segment(Data(manual.utf8), as: .markdown)
        #expect(segmentation.sections.map(\.title) == ["LT-101 Installation", "Power", "Wiring C#"])
        #expect(segmentation.sections.map(\.level) == [1, 2, 2])
        #expect(segmentation.passages.count == 4)
        #expect(segmentation.passages[0].text == "Mount the transmitter vertically.\nKeep cable runs short.")
        #expect(segmentation.passages[2].text.hasPrefix("```") && segmentation.passages[2].text.hasSuffix("```"))
        #expect(segmentation.passages[2].text.contains("\n\n(worst case"))
        #expect(segmentation.passages.map(\.section) == [0, 1, 1, 2])
    }

    @Test func segmentationIsDeterministic() throws {
        let data = Data(manual.utf8)
        #expect(try Segmenter.segment(data, as: .markdown) == Segmenter.segment(data, as: .markdown))
    }

    @Test func invalidUTF8IsRefused() {
        #expect(throws: SegmentationError.notUTF8) {
            try Segmenter.segment(Data([0x66, 0xFF, 0xFE]), as: .plainText)
        }
    }
}

@Suite struct DocumentLibraryTests {
    @Test func ingestStoresBlobDocumentAndPassages() throws {
        let (store, library) = try library()
        let result = try library.ingest(Data(manual.utf8), title: "LT-101 manual", mediaType: "text/markdown", by: tech)

        #expect(!result.deduplicated)
        #expect(result.blob.sha256 == ContentHash.sha256(manual))
        #expect(result.document.type == .document)
        #expect(result.document.attributes["blob"]?.value == .string(result.blob.sha256))
        #expect(result.document.attributes["extraction"]?.value == .string("extracted"))
        #expect(result.passages.count == 4)
        #expect(result.passages[1].section == "Power")
        #expect(try library.passages(of: result.document.id) == result.passages)
        #expect(try library.contents(of: result.document.id) == Data(manual.utf8))

        let passage = try #require(try store.object(result.passages[1].id))
        #expect(passage.type == .passage)
        #expect(passage.provenance.truth == .derived)
        #expect(passage.provenance.dependencies == [result.document.id])
    }

    @Test func identicalBytesAreOneDocumentAndOneBlob() throws {
        let (store, library) = try library()
        let project = try store.create(ObjectRecord(
            type: .project, title: "Loop", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        ))
        let first = try library.ingest(Data(manual.utf8), title: "Manual", mediaType: "text/markdown", by: tech)
        let second = try library.ingest(Data(manual.utf8), title: "Manual (copy)", mediaType: "text/markdown", in: project.id, by: tech)

        #expect(second.deduplicated)
        #expect(second.document.id == first.document.id)
        #expect(second.blob == first.blob)
        #expect(second.passages == first.passages)
        #expect(try store.objects(ofType: .document).count == 1)
        #expect(try store.objects(ofType: .passage).count == 4)
        #expect(try store.relationships(from: project.id, kind: .contains).map(\.to) == [first.document.id])

        let other = try library.ingest(Data("Different".utf8), title: "Note", mediaType: "text/plain", by: tech)
        #expect(!other.deduplicated)
        #expect(other.blob.sha256 != first.blob.sha256)
    }

    @Test func ingestionIsDeterministicAcrossStores() throws {
        let (_, one) = try library()
        let (_, two) = try library()
        let a = try one.ingest(Data(manual.utf8), title: "Manual", mediaType: "text/markdown", by: tech)
        let b = try two.ingest(Data(manual.utf8), title: "Manual", mediaType: "text/markdown", by: tech)
        let digest = a.blob.sha256
        #expect(a.passages.map { $0.key(blob: digest) } == b.passages.map { $0.key(blob: b.blob.sha256) })
        #expect(a.passages.map(\.text) == b.passages.map(\.text))
        #expect(a.passages.map(\.section) == b.passages.map(\.section))
        #expect(a.document.attributes["sections"] == b.document.attributes["sections"])
    }

    @Test func pdfIsStoredForLaterExtraction() throws {
        let (store, library) = try library()
        let pdf = Data("%PDF-1.7\n%âãÏÓ\n1 0 obj\n<<>>\nendobj\n".utf8)
        let result = try library.ingest(pdf, title: "Datasheet", mediaType: "application/pdf", by: tech)
        #expect(result.passages.isEmpty)
        #expect(try library.extractionState(of: result.document.id) == .needsExtraction)
        #expect(try store.blobData(sha256: result.blob.sha256) == pdf)
        #expect(throws: DocumentError.unsupportedMediaType("image/png")) {
            try library.ingest(Data([1, 2, 3]), title: "Photo", mediaType: "image/png", by: tech)
        }
    }

    @Test func searchPointsAtDocumentAndPassage() throws {
        let (_, library) = try library()
        let result = try library.ingest(Data(manual.utf8), title: "LT-101 manual", mediaType: "text/markdown", by: tech)
        let hits = try library.search("lift-off voltage")
        let hit = try #require(hits.first)
        #expect(hit.document == result.document.id)
        #expect(hit.passage?.id == result.passages[1].id)
        #expect(hit.passage?.text == "Minimum lift-off voltage is 12 V at the terminals.")

        let titleHit = try #require(try library.search("LT-101 manual").first { $0.passage == nil })
        #expect(titleHit.document == result.document.id)
    }

    @Test func extractedClaimCitesDocumentWithVerbatimPassage() throws {
        let (store, library) = try library()
        let result = try library.ingest(Data(manual.utf8), title: "LT-101 manual", mediaType: "text/markdown", by: tech)
        let passage = result.passages[1]
        let claim = try library.extractClaim(
            from: passage.id, statement: "The transmitter needs at least 12 V at its terminals",
            sourceClass: .primary, applicability: "LT-101", confidence: 0.9, by: agent
        )

        let stored = try #require(try store.claim(claim.id))
        #expect(stored.sources == [result.document.id])
        #expect(stored.passages == [passage.text])
        #expect(stored.provenance.truth == .claimed)
        #expect(stored.provenance.origin == agent)
        #expect(stored.provenance.dependencies == [passage.id, result.document.id])
        #expect(stored.provenance.transformation == "verbatim \(passage.key(blob: result.blob.sha256))")

        // Lineage: claim → passage → document → blob bytes, and back.
        #expect(try store.claims(citing: result.document.id).map(\.id) == [claim.id])
        #expect(try library.claims(citing: passage.id).map(\.id) == [claim.id])
        #expect(try library.sourceText(of: passage) == stored.passages[0])
    }

    @Test func documentsAndBlobsSurviveReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".blobs"))
        }
        let clock = ManualClock(t0)
        let original: IngestResult
        do {
            let library = DocumentLibrary(store: try NexusStore(.file(url), clock: clock), clock: clock)
            original = try library.ingest(Data(manual.utf8), title: "Manual", mediaType: "text/markdown", by: tech)
        }
        let library = DocumentLibrary(store: try NexusStore(.file(url), clock: clock), clock: clock)
        #expect(try library.passages(of: original.document.id) == original.passages)
        #expect(try library.contents(of: original.document.id) == Data(manual.utf8))
        let again = try library.ingest(Data(manual.utf8), title: "Manual", mediaType: "text/markdown", by: tech)
        #expect(again.deduplicated && again.document.id == original.document.id)
    }
}

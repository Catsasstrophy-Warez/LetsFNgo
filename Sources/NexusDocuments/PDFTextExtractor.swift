import Foundation

#if canImport(PDFKit)
    import PDFKit
#endif

/// Turns PDF bytes into plain text, one string per page in reading order.
///
/// `DocumentLibrary` uses one when it is given one: the text is stored as a
/// second blob next to the PDF and segmented into passages, so claims can
/// still quote exact bytes. Without an extractor (Linux, tests, or a PDF the
/// extractor cannot read) the document is stored as `needsExtraction`.
public protocol PDFTextExtractor: Sendable {
    /// Names the extractor and its version in provenance, e.g. "PDFKit".
    var identifier: String { get }

    func pages(of data: Data) throws -> [String]
}

public enum PDFExtractionError: Error, Equatable, Sendable {
    /// The bytes are not a PDF the extractor can open (damaged or encrypted).
    case unreadable
}

extension DocumentLibrary {
    /// The platform's PDF extractor: PDFKit on Apple platforms, none on Linux.
    public static var platformPDFExtractor: (any PDFTextExtractor)? {
        #if canImport(PDFKit)
            PDFKitTextExtractor()
        #else
            nil
        #endif
    }
}

#if canImport(PDFKit)
    /// PDF text through PDFKit. Scanned pages without a text layer come back
    /// empty; a PDF with no text at all stays `needsExtraction` for OCR.
    public struct PDFKitTextExtractor: PDFTextExtractor {
        public init() {}

        public var identifier: String { "PDFKit" }

        public func pages(of data: Data) throws -> [String] {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw PDFExtractionError.unreadable }
            return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        }
    }
#endif

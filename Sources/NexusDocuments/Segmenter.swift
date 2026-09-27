import Foundation

/// Text formats the segmenter understands.
public enum TextFormat: String, Sendable, Hashable, Codable {
    case plainText
    case markdown
}

/// One passage as a byte range of the source. `start..<end` are UTF-8 byte
/// offsets into the blob, so a passage can always be re-read from the exact
/// bytes it came from.
public struct PassageSpan: Sendable, Hashable, Codable {
    public var index: Int
    public var start: Int
    public var end: Int
    /// The bytes `start..<end`, verbatim (line endings included).
    public var text: String
    /// Index into `Segmentation.sections`, nil before the first heading.
    public var section: Int?
}

/// A Markdown heading and the passages under it (until the next heading).
public struct SectionSpan: Sendable, Hashable, Codable {
    public var index: Int
    public var title: String
    /// 1 for `#`, up to 6.
    public var level: Int
    /// Byte offset of the heading line.
    public var start: Int
}

public struct Segmentation: Sendable, Hashable {
    public var passages: [PassageSpan]
    public var sections: [SectionSpan]
}

public enum SegmentationError: Error, Equatable, Sendable {
    case notUTF8
}

/// Splits text into passages deterministically: the same bytes always give
/// the same passages, offsets and sections, on every platform.
///
/// - Plain text: a passage is a run of non-blank lines.
/// - Markdown: the same, plus ATX headings (`#` … `######`) start sections and
///   are not passages themselves, and a fenced code block (```` ``` ```` or
///   `~~~`) is one passage even across blank lines. Setext headings are read
///   as ordinary paragraph text.
///
/// The segmentation rules are versioned by `version`; change it whenever the
/// output for existing input would change.
public enum Segmenter {
    public static let version = 1

    public static func segment(_ data: Data, as format: TextFormat) throws -> Segmentation {
        guard String(data: data, encoding: .utf8) != nil else { throw SegmentationError.notUTF8 }
        let bytes = [UInt8](data)
        var passages: [PassageSpan] = []
        var sections: [SectionSpan] = []
        var paragraph: (start: Int, end: Int)?
        var fence: (marker: UInt8, start: Int)?

        func flush() {
            guard let open = paragraph else { return }
            passages.append(PassageSpan(
                index: passages.count, start: open.start, end: open.end,
                text: String(decoding: bytes[open.start..<open.end], as: UTF8.self),
                section: sections.isEmpty ? nil : sections.count - 1
            ))
            paragraph = nil
        }

        // Skip a UTF-8 byte-order mark; offsets stay relative to the blob.
        var lineStart = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while lineStart < bytes.count {
            var newline = lineStart
            while newline < bytes.count, bytes[newline] != 0x0A { newline += 1 }
            var contentEnd = newline
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = bytes[lineStart..<contentEnd]
            defer { lineStart = newline + 1 }

            if format == .markdown {
                if let open = fence {
                    paragraph = (paragraph?.start ?? open.start, contentEnd)
                    if fenceMarker(line) == open.marker {
                        fence = nil
                        flush()
                    }
                    continue
                }
                if let marker = fenceMarker(line) {
                    flush()
                    fence = (marker, lineStart)
                    paragraph = (lineStart, contentEnd)
                    continue
                }
                if let heading = heading(line) {
                    flush()
                    sections.append(SectionSpan(index: sections.count, title: heading.title, level: heading.level, start: lineStart))
                    continue
                }
            }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                flush()
            } else {
                paragraph = (paragraph?.start ?? lineStart, contentEnd)
            }
        }
        flush()
        return Segmentation(passages: passages, sections: sections)
    }

    /// The fence character if `line` opens or closes a fenced code block.
    private static func fenceMarker(_ line: ArraySlice<UInt8>) -> UInt8? {
        let trimmed = line.drop { $0 == 0x20 }
        guard line.count - trimmed.count <= 3, let first = trimmed.first, first == 0x60 || first == 0x7E else { return nil }
        return trimmed.prefix(3).count == 3 && trimmed.prefix(3).allSatisfy({ $0 == first }) ? first : nil
    }

    /// An ATX heading: up to three spaces, one to six `#`, then a space or the end of the line.
    private static func heading(_ line: ArraySlice<UInt8>) -> (level: Int, title: String)? {
        let trimmed = line.drop { $0 == 0x20 }
        guard line.count - trimmed.count <= 3 else { return nil }
        let level = trimmed.prefix { $0 == 0x23 }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == 0x20 || rest.first == 0x09 else { return nil }
        let title = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        // Optional closing sequence, "## Title ##", only after a space so "C#" survives.
        let body = title.reversed().drop { $0 == "#" }
        if body.isEmpty || body.first == " " {
            return (level, String(body.reversed()).trimmingCharacters(in: .whitespaces))
        }
        return (level, title)
    }
}

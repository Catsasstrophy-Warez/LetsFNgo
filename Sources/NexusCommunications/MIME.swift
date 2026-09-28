import Foundation

/// One header field, unfolded, with encoded words still encoded.
public struct MIMEHeaderField: Sendable, Hashable {
    public var name: String
    public var value: String
}

/// An RFC 5322 header block. Lookups ignore case; the first field wins.
public struct MIMEHeaders: Sendable, Hashable {
    public var fields: [MIMEHeaderField]

    public init(_ fields: [MIMEHeaderField] = []) { self.fields = fields }

    public subscript(name: String) -> String? {
        let lower = name.lowercased()
        return fields.first { $0.name.lowercased() == lower }?.value
    }

    public func all(_ name: String) -> [String] {
        let lower = name.lowercased()
        return fields.filter { $0.name.lowercased() == lower }.map(\.value)
    }

    /// Parses an unfolded or folded header block. Lines without a colon
    /// (an mbox "From " line) are skipped.
    public static func parse(_ text: String) -> MIMEHeaders {
        var fields: [MIMEHeaderField] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if let first = line.first, first == " " || first == "\t" {
                guard !fields.isEmpty else { continue }
                fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            fields.append(MIMEHeaderField(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return MIMEHeaders(fields)
    }
}

/// A header value with parameters: `text/plain; charset="utf-8"`.
public struct MIMEParameterized: Sendable, Hashable {
    /// Lowercased, e.g. "text/plain" or "attachment".
    public var value: String
    /// Lowercased names; RFC 2231 continuations joined and decoded.
    public var parameters: [String: String]

    public init(_ header: String?) {
        let parts = MIMEParameterized.split(header ?? "")
        value = (parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, text: String)]] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var name = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var text = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            // RFC 2231: name*=charset'lang'pct-encoded, name*0=…, name*1*=…
            guard name.contains("*") else {
                plain[name] = text
                continue
            }
            let encoded = name.hasSuffix("*")
            if encoded { name.removeLast() }
            var index = 0
            if let star = name.firstIndex(of: "*") {
                index = Int(name[name.index(after: star)...]) ?? 0
                name = String(name[..<star])
            }
            extended[name, default: []].append((index, encoded, text))
        }
        for (name, pieces) in extended {
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for piece in pieces.sorted(by: { $0.index < $1.index }) {
                var text = Substring(piece.text)
                if piece.encoded, piece.index == 0 {
                    let quotes = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if quotes.count == 3 {
                        charset = quotes[0].isEmpty ? charset : String(quotes[0])
                        text = quotes[2]
                    }
                }
                bytes += piece.encoded ? MIMEDecoding.percentDecoded(text) : Array(text.utf8)
            }
            plain[name] = MIMEDecoding.string(bytes, charset: charset)
        }
        parameters = plain
    }

    /// Splits on `;` outside quotes.
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where quoted:
                current.append(character)
                escaped = true
            case "\"":
                quoted.toggle()
                current.append(character)
            case ";" where !quoted:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// One MIME entity: its headers and its body, still transfer-encoded, with
/// the parts of a multipart body parsed out.
public struct MIMEPart: Sendable, Hashable {
    public var headers: MIMEHeaders
    /// Body bytes as they appear in the message.
    public var rawBody: [UInt8]
    public var parts: [MIMEPart]

    /// Parses a message or a body part. Line endings may be CRLF or LF.
    public init(_ bytes: [UInt8]) {
        let (header, body) = MIMEPart.splitHeader(bytes[...])
        headers = MIMEHeaders.parse(String(decoding: header, as: UTF8.self))
        rawBody = Array(body)
        parts = []
        let type = contentType
        if type.value.hasPrefix("multipart/"), let boundary = type.parameters["boundary"], !boundary.isEmpty {
            parts = MIMEPart.split(body, boundary: boundary).map(MIMEPart.init)
        }
    }

    public var contentType: MIMEParameterized {
        let type = MIMEParameterized(headers["Content-Type"])
        return type.value.isEmpty ? MIMEParameterized("text/plain; charset=us-ascii") : type
    }

    public var disposition: MIMEParameterized { MIMEParameterized(headers["Content-Disposition"]) }

    /// The body with its Content-Transfer-Encoding undone.
    public var decodedBody: Data {
        switch headers["Content-Transfer-Encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": MIMEDecoding.base64(rawBody)
        case "quoted-printable": Data(MIMEDecoding.quotedPrintable(rawBody))
        default: Data(rawBody)
        }
    }

    /// The decoded body as text in its declared charset.
    public var text: String {
        MIMEDecoding.string(Array(decodedBody), charset: contentType.parameters["charset"] ?? "utf-8")
    }

    /// A file name from Content-Disposition or Content-Type, decoded.
    public var filename: String? {
        (disposition.parameters["filename"] ?? contentType.parameters["name"]).map(MIMEDecoding.decodeWords)
    }

    /// Every leaf part, depth first.
    public var leaves: [MIMEPart] {
        parts.isEmpty ? [self] : parts.flatMap(\.leaves)
    }

    // MARK: Byte scanning

    /// Splits at the first empty line. No empty line: everything is header
    /// when it looks like headers, otherwise everything is body.
    static func splitHeader(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        for line in lines(bytes) where line.content.isEmpty {
            return (bytes[bytes.startIndex..<line.content.startIndex], bytes[line.next...])
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    /// Each line's content (no terminator) and the index just past its terminator.
    static func lines(_ bytes: ArraySlice<UInt8>) -> [(content: ArraySlice<UInt8>, next: Int)] {
        var result: [(content: ArraySlice<UInt8>, next: Int)] = []
        var start = bytes.startIndex
        var index = start
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                let end = index > start && bytes[index - 1] == 0x0D ? index - 1 : index
                result.append((content: bytes[start..<end], next: index + 1))
                start = index + 1
            }
            index += 1
        }
        if start < bytes.endIndex { result.append((content: bytes[start..<bytes.endIndex], next: bytes.endIndex)) }
        return result
    }

    /// The body parts between `--boundary` lines, up to `--boundary--`.
    /// The line break before each delimiter belongs to the delimiter.
    static func split(_ body: ArraySlice<UInt8>, boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [[UInt8]] = []
        var partStart: Int?
        var previousEnd: Int?
        for line in lines(body) {
            var content = line.content
            while let last = content.last, last == 0x20 || last == 0x09 { content = content.dropLast() }
            if content.starts(with: delimiter) {
                let rest = content.dropFirst(delimiter.count)
                let closing = rest.elementsEqual([0x2D, 0x2D])
                if rest.isEmpty || closing {
                    if let partStart, let previousEnd, previousEnd >= partStart {
                        parts.append(Array(body[partStart..<previousEnd]))
                    } else if partStart != nil {
                        parts.append([])
                    }
                    if closing { return parts }
                    partStart = line.next
                    previousEnd = nil
                    continue
                }
            }
            previousEnd = line.content.endIndex
        }
        if let partStart, partStart < body.endIndex { parts.append(Array(body[partStart...])) }
        return parts
    }
}

/// Transfer encodings, charsets and RFC 2047 encoded words.
public enum MIMEDecoding {
    public static func base64(_ bytes: [UInt8]) -> Data {
        var clean = bytes.filter { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2B || $0 == 0x2F }
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(0x3D) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    /// Quoted-printable (RFC 2045 §6.7): `=XX` escapes and `=` soft line breaks.
    public static func quotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            output.append(underscoreIsSpace && byte == 0x5F ? 0x20 : byte)
            index += 1
        }
        return output
    }

    static func percentDecoded(_ text: Substring) -> [UInt8] {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// Decodes bytes in a named charset, falling back to UTF-8 and then Latin-1.
    public static func string(_ bytes: [UInt8], charset: String) -> String {
        let data = Data(bytes)
        if let encoding = encoding(charset), let text = String(data: data, encoding: encoding) { return text }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func encoding(_ charset: String) -> String.Encoding? {
        switch charset.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8": .utf8
        case "us-ascii", "ascii": .utf8
        case "iso-8859-1", "latin1", "iso_8859-1", "l1": .isoLatin1
        case "iso-8859-2", "latin2": .isoLatin2
        case "windows-1252", "cp1252": .windowsCP1252
        case "windows-1251", "cp1251": .windowsCP1251
        case "utf-16", "utf16": .utf16
        case "utf-16le": .utf16LittleEndian
        case "utf-16be": .utf16BigEndian
        case "shift_jis", "shift-jis": .shiftJIS
        case "iso-2022-jp": .iso2022JP
        case "euc-jp": .japaneseEUC
        default: nil
        }
    }

    /// Decodes RFC 2047 encoded words (`=?utf-8?B?…?=`, `=?iso-8859-1?Q?…?=`).
    /// Whitespace between two adjacent encoded words is dropped.
    public static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var output = ""
        var rest = Substring(text)
        var lastWasEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            guard let word = encodedWord(rest[start.lowerBound...]) else {
                output += before + "=?"
                rest = rest[start.upperBound...]
                lastWasEncoded = false
                continue
            }
            if !(lastWasEncoded && before.allSatisfy(\.isWhitespace)) { output += before }
            output += word.text
            rest = rest[word.end...]
            lastWasEncoded = true
        }
        return output + rest
    }

    private static func encodedWord(_ text: Substring) -> (text: String, end: Substring.Index)? {
        let body = text.dropFirst(2)
        let pieces = body.split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[3].hasPrefix("=") else { return nil }
        let charset = pieces[0].split(separator: "*").first.map(String.init) ?? "utf-8"
        let payload = Array(pieces[2].utf8)
        let bytes: [UInt8]
        switch pieces[1].uppercased() {
        case "B": bytes = Array(base64(payload))
        case "Q": bytes = quotedPrintable(payload, underscoreIsSpace: true)
        default: return nil
        }
        return (string(bytes, charset: charset), pieces[3].index(after: pieces[3].startIndex))
    }
}

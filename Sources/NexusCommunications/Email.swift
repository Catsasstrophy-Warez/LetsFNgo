import Foundation

/// A mailbox: `"Ana Ruiz" <ana@example.com>`.
public struct EmailAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    public var name: String?
    /// Lowercased.
    public var address: String

    public init(name: String? = nil, address: String) {
        let name = name?.trimmingCharacters(in: .whitespaces)
        self.name = name?.isEmpty == false ? name : nil
        self.address = address.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public var displayName: String { name ?? address }

    /// `Name <address>`, quoting the name when it holds a comma or other specials.
    public var description: String {
        guard let name else { return address }
        let special = name.contains { ",;:<>@()\"\\".contains($0) }
        let shown = special ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : name
        return "\(shown) <\(address)>"
    }

    /// Parses an address list: `Ana <a@x>, "Ruiz, B" <b@x>, c@x (Carl), team: d@x;`.
    public static func list(_ header: String?) -> [EmailAddress] {
        guard let header else { return [] }
        return split(MIMEDecoding.decodeWords(header)).compactMap(parse)
    }

    static func parse(_ raw: String) -> EmailAddress? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // Group syntax: "team: a@x, b@x;" — drop the display name and terminator.
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("<"), !text[..<colon].contains("@"), !text[..<colon].contains("\"") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = text[..<open].trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            return address.contains("@") ? EmailAddress(name: name, address: address) : nil
        }
        var name: String?
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            name = String(text[text.index(after: open)..<close])
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return text.contains("@") ? EmailAddress(name: name, address: text) : nil
    }

    /// Splits on commas outside quotes, angle brackets and comments.
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var angle = 0
        var comment = 0
        for character in text {
            switch character {
            case "\"": quoted.toggle()
            case "<" where !quoted: angle += 1
            case ">" where !quoted: angle = max(0, angle - 1)
            case "(" where !quoted: comment += 1
            case ")" where !quoted: comment = max(0, comment - 1)
            case "," where !quoted && angle == 0 && comment == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }
}

/// A file carried in a message.
public struct EmailAttachment: Sendable, Hashable {
    public var filename: String
    public var mediaType: String
    public var data: Data
    /// `Content-ID` without angle brackets, for inline images.
    public var contentID: String?
    public var isInline: Bool
}

/// One parsed email: identity, people, dates, a readable body and its files.
public struct EmailMessage: Sendable, Hashable {
    public var headers: MIMEHeaders
    /// `Message-ID` without angle brackets.
    public var messageID: String?
    public var inReplyTo: String?
    /// `References`, oldest first.
    public var references: [String]
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date?
    /// The text/plain body; when there is none, the HTML body as text.
    public var text: String
    public var html: String?
    public var attachments: [EmailAttachment]

    /// Parses an RFC 5322 / MIME message (an .eml file).
    public init(_ data: Data) {
        self.init(MIMEPart(Array(data)))
    }

    public init(_ root: MIMEPart) {
        headers = root.headers
        messageID = headers["Message-ID"].flatMap { EmailMessage.ids($0).first }
        inReplyTo = headers["In-Reply-To"].flatMap { EmailMessage.ids($0).first }
        references = headers["References"].map(EmailMessage.ids) ?? []
        subject = MIMEDecoding.decodeWords(headers["Subject"] ?? "").trimmingCharacters(in: .whitespaces)
        from = EmailAddress.list(headers["From"])
        to = EmailAddress.list(headers.all("To").joined(separator: ", "))
        cc = EmailAddress.list(headers.all("Cc").joined(separator: ", "))
        date = headers["Date"].flatMap(RFC5322Date.parse)

        var plain: [String] = []
        var html: [String] = []
        var attachments: [EmailAttachment] = []
        EmailMessage.walk(root, plain: &plain, html: &html, attachments: &attachments)
        self.html = html.isEmpty ? nil : html.joined(separator: "\n")
        let text = plain.isEmpty ? html.map(HTMLText.plain).joined(separator: "\n\n") : plain.joined(separator: "\n\n")
        self.text = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.attachments = attachments
    }

    /// The conversation's subject: "Re:", "Fwd:" and "[list]" prefixes removed, lowercased.
    public var threadSubject: String { EmailMessage.normalizedSubject(subject) }

    public static func normalizedSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            if let prefix = ["re:", "fw:", "fwd:", "aw:", "sv:", "wg:", "tr:", "re :", "fwd :"].first(where: lower.hasPrefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// `<a@x> <b@x>` → ["a@x", "b@x"]; a bare id is kept as is.
    static func ids(_ header: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { ids.append(id) }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            ids = header.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains("@") }
        }
        return ids
    }

    /// Depth first. In multipart/alternative the richest text of each kind is
    /// taken once; text parts marked as attachments stay attachments.
    static func walk(_ part: MIMEPart, plain: inout [String], html: inout [String], attachments: inout [EmailAttachment]) {
        let type = part.contentType.value
        if type.hasPrefix("multipart/") {
            if type == "multipart/alternative" {
                let texts = part.parts.filter { $0.contentType.value == "text/plain" && !isAttachment($0) }
                let htmls = part.parts.filter { $0.contentType.value == "text/html" && !isAttachment($0) }
                if let text = texts.last { plain.append(text.text) }
                if let page = htmls.last { html.append(page.text) }
                for other in part.parts where !texts.contains(other) && !htmls.contains(other) {
                    walk(other, plain: &plain, html: &html, attachments: &attachments)
                }
            } else {
                for child in part.parts { walk(child, plain: &plain, html: &html, attachments: &attachments) }
            }
            return
        }
        if !isAttachment(part) {
            if type == "text/plain" {
                plain.append(part.text)
                return
            }
            if type == "text/html" {
                html.append(part.text)
                return
            }
        }
        let fallback = type == "message/rfc822" ? "message.eml" : "attachment"
        attachments.append(
            EmailAttachment(
                filename: part.filename ?? fallback, mediaType: type, data: part.decodedBody,
                contentID: part.headers["Content-ID"].flatMap { ids($0).first ?? $0 },
                isInline: part.disposition.value == "inline"
            ))
    }

    static func isAttachment(_ part: MIMEPart) -> Bool {
        part.disposition.value == "attachment" || (part.filename != nil && part.disposition.value != "inline")
    }
}

/// RFC 5322 §3.3 dates, with the obsolete zone names, and without locales.
public enum RFC5322Date {
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7,
    ]

    /// "Tue, 1 Jul 2003 10:52:37 +0200", "1 Jul 03 10:52 GMT", "Tue, 01 Jul 2003 10:52:37 +0200 (CEST)".
    public static func parse(_ text: String) -> Date? {
        var cleaned = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) } else if depth == 0 { cleaned.append(character) }
        }
        var tokens = cleaned.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = tokens.first, first.first?.isLetter == true { tokens.removeFirst() }
        guard tokens.count >= 4, let day = Int(tokens[0]), let month = months.firstIndex(of: String(tokens[1].prefix(3)).lowercased()),
            var year = Int(tokens[2])
        else { return nil }
        if tokens[2].count <= 2 { year += year < 50 ? 2000 : 1900 } else if tokens[2].count == 3 { year += 1900 }
        let time = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard time.count >= 2 else { return nil }
        var offset = 0
        if tokens.count >= 5 {
            let zone = tokens[4]
            if let sign = zone.first, sign == "+" || sign == "-", zone.count == 5, let value = Int(zone.dropFirst()) {
                offset = (value / 100 * 3600 + value % 100 * 60) * (sign == "-" ? -1 : 1)
            } else if let hours = zones[zone.lowercased()] {
                offset = hours * 3600
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month + 1, day: day, hour: time[0], minute: time[1], second: time.count > 2 ? time[2] : 0)
        return calendar.date(from: components).map { $0.addingTimeInterval(TimeInterval(-offset)) }
    }

    /// Formats a date for a `Date:` header, in UTC.
    public static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let month = months[parts.month! - 1].capitalized
        return String(
            format: "%@, %d %@ %04d %02d:%02d:%02d +0000", days[parts.weekday! - 1], parts.day!, month, parts.year!, parts.hour!, parts.minute!, parts.second!)
    }
}

/// Readable text from an HTML body: no scripts or styles, block elements as
/// line breaks, entities decoded.
public enum HTMLText {
    public static func plain(_ html: String) -> String {
        // In HTML source a line break is only whitespace.
        var text = html.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        for tag in ["script", "style", "head"] {
            while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
                let close = text.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<text.endIndex)
            {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "<", let close = text[index...].firstIndex(of: ">") else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let tag = text[text.index(after: index)..<close].lowercased().trimmingCharacters(in: .whitespaces)
            let name = tag.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\n" }).first.map(String.init) ?? ""
            if name == "br" {
                output.append("\n")
            } else if ["p", "div", "tr", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table"].contains(name) {
                // Block elements start on a new line; they don't stack blank lines.
                if !output.isEmpty, !output.hasSuffix("\n") { output.append("\n") }
                if name == "li", !tag.hasPrefix("/") { output.append("• ") }
            }
            index = text.index(after: close)
        }
        output = decodeEntities(output)
        // Collapse runs of spaces and of blank lines.
        let lines = output.components(separatedBy: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        var collapsed: [String] = []
        for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) {
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "deg": "°", "euro": "€",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let entity = String(after[..<semi])
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[entity.lowercased()]
                }
                if let decoded {
                    output += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            output += "&"
            rest = after
        }
        return output + rest
    }
}

/// Splits an mbox file into messages. Handles mboxo and mboxrd: a message
/// starts at a "From " line at the top of the file or after an empty line,
/// and one ">" is removed from quoted ">From " lines.
public enum MBox {
    public static func messages(_ data: Data) -> [Data] {
        let bytes = Array(data)
        let lines = MIMEPart.lines(bytes[...])
        let from = Array("From ".utf8)
        var messages: [Data] = []
        var current: [UInt8]?
        var previousEmpty = true
        for line in lines {
            let content = line.content
            if content.starts(with: from), previousEmpty {
                if let message = current { messages.append(finish(message)) }
                current = []
                previousEmpty = false
                continue
            }
            previousEmpty = content.isEmpty
            guard current != nil else { continue }
            var unquoted = content
            if unquoted.first == 0x3E {
                let stripped = unquoted.drop { $0 == 0x3E }
                if stripped.starts(with: from) { unquoted = unquoted.dropFirst() }
            }
            current! += unquoted
            current! += [0x0A]
        }
        if let message = current { messages.append(finish(message)) }
        return messages.filter { !$0.isEmpty }
    }

    /// Drops the blank line that separates a message from the next "From ".
    private static func finish(_ message: [UInt8]) -> Data {
        var message = message[...]
        while message.suffix(2).elementsEqual([0x0A, 0x0A]) { message = message.dropLast() }
        return Data(message)
    }
}

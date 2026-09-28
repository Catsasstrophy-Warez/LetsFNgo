import Foundation

/// One contact, from a vCard or an address book, before it is stored.
public struct ContactCard: Sendable, Hashable {
    public var formattedName: String
    public var givenName: String?
    public var familyName: String?
    public var organization: String?
    public var department: String?
    public var title: String?
    public var emails: [String]
    public var phones: [String]
    /// "1985-04-12", or "--04-12" without a year.
    public var birthday: String?
    public var note: String?
    public var uid: String?
    public var categories: [String]

    public init(
        formattedName: String, givenName: String? = nil, familyName: String? = nil, organization: String? = nil, department: String? = nil,
        title: String? = nil, emails: [String] = [], phones: [String] = [], birthday: String? = nil, note: String? = nil, uid: String? = nil,
        categories: [String] = []
    ) {
        self.formattedName = formattedName
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.department = department
        self.title = title
        self.emails = emails
        self.phones = phones
        self.birthday = birthday
        self.note = note
        self.uid = uid
        self.categories = categories
    }
}

/// A vCard 2.1, 3.0 and 4.0 reader for the properties contacts need: FN, N,
/// ORG, TITLE, EMAIL, TEL, BDAY, NOTE, UID and CATEGORIES. It unfolds lines,
/// drops group prefixes (`item1.EMAIL`), undoes escapes, decodes 2.1
/// quoted-printable values and strips 4.0 `tel:` URIs. Photos, addresses and
/// other properties are skipped. A card with no usable name is skipped.
public enum VCard {
    struct Line {
        var name: String
        var parameters: [String: String]
        var value: String
        var number: Int
    }

    public static func parse(_ text: String) throws -> [ContactCard] {
        var cards: [ContactCard] = []
        var current: [Line]?
        var cardLine = 0
        for line in try lines(text) {
            switch (line.name, line.value.uppercased()) {
            case ("BEGIN", "VCARD"):
                guard current == nil else { throw ContactsError.malformedVCard(line: line.number, reason: "BEGIN:VCARD inside a card") }
                current = []
                cardLine = line.number
            case ("END", "VCARD"):
                guard let properties = current else { throw ContactsError.malformedVCard(line: line.number, reason: "END:VCARD without BEGIN") }
                if let card = card(properties) { cards.append(card) }
                current = nil
            default:
                current?.append(line)
            }
        }
        if current != nil { throw ContactsError.malformedVCard(line: cardLine, reason: "card not closed with END:VCARD") }
        return cards
    }

    /// Content lines after unfolding. Handles RFC folding (a leading space or
    /// tab) and quoted-printable soft breaks (a value ending in "=").
    static func lines(_ text: String) throws -> [Line] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var raw: [(text: String, number: Int)] = []
        var softBreak = false
        for (offset, piece) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(piece)
            if offset == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if softBreak, !raw.isEmpty {
                raw[raw.count - 1].text.removeLast()  // the "="
                raw[raw.count - 1].text += line.drop { $0 == " " || $0 == "\t" }
            } else if let first = line.first, first == " " || first == "\t", !raw.isEmpty {
                raw[raw.count - 1].text += line.dropFirst()
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                raw.append((line, offset + 1))
            }
            let last = raw.last?.text ?? ""
            softBreak = last.uppercased().contains("QUOTED-PRINTABLE") && last.hasSuffix("=")
        }
        return try raw.map { text, number in
            guard let line = split(text, number: number) else { throw ContactsError.malformedVCard(line: number, reason: "no ':' in content line") }
            return line
        }
    }

    static func split(_ raw: String, number: Int) -> Line? {
        var inQuotes = false
        guard
            let colon = raw.indices.first(where: { index in
                if raw[index] == "\"" { inQuotes.toggle() }
                return raw[index] == ":" && !inQuotes
            })
        else { return nil }
        var fields = raw[..<colon].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let fullName = fields.removeFirst().uppercased()
        let name = fullName.split(separator: ".").last.map(String.init) ?? fullName
        var parameters: [String: String] = [:]
        for field in fields where !field.isEmpty {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            let key = pair.count == 2 ? pair[0].uppercased() : "TYPE"
            // 2.1 writes bare values: "TEL;CELL:" and "NOTE;QUOTED-PRINTABLE:".
            let value = (pair.count == 2 ? pair[1] : pair[0]).replacingOccurrences(of: "\"", with: "")
            if pair.count == 1, ["QUOTED-PRINTABLE", "BASE64", "8BIT"].contains(value.uppercased()) {
                parameters["ENCODING"] = value
            } else {
                parameters[key] = parameters[key].map { "\($0),\(value)" } ?? value
            }
        }
        return Line(name: name, parameters: parameters, value: String(raw[raw.index(after: colon)...]), number: number)
    }

    static func card(_ lines: [Line]) -> ContactCard? {
        func decoded(_ line: Line) -> String {
            guard line.parameters["ENCODING"]?.uppercased() == "QUOTED-PRINTABLE" else { return line.value }
            return quotedPrintable(line.value)
        }
        func text(_ name: String) -> String? {
            lines.first { $0.name == name }.map { unescape(decoded($0)).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func components(_ name: String) -> [String] {
            lines.first { $0.name == name }.map { VCard.components(of: decoded($0)) } ?? []
        }
        let n = components("N")
        let family = n.first.flatMap { $0.isEmpty ? nil : $0 }
        let given = n.count > 1 && !n[1].isEmpty ? n[1] : nil
        let org = components("ORG")
        let emails = lines.filter { $0.name == "EMAIL" }.map { unescape(decoded($0)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let phones = lines.filter { $0.name == "TEL" }.map { line -> String in
            var value = unescape(decoded(line)).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("tel:") { value = String(value.dropFirst(4)) }
            return value
        }.filter { !$0.isEmpty }
        let organization = org.first.flatMap { $0.isEmpty ? nil : $0 }
        let name = text("FN") ?? [given, family].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? organization ?? emails.first
        guard let name else { return nil }
        return ContactCard(
            formattedName: name, givenName: given, familyName: family, organization: organization,
            department: org.count > 1 && !org[1].isEmpty ? org[1] : nil, title: text("TITLE"), emails: emails, phones: phones,
            birthday: text("BDAY").flatMap(birthday), note: text("NOTE"), uid: text("UID"),
            categories: lines.filter { $0.name == "CATEGORIES" }.flatMap { VCard.components(of: decoded($0), separator: ",") }.filter { !$0.isEmpty }
        )
    }

    /// "1985-04-12", "19850412", "1985-04-12T00:00:00Z" → "1985-04-12";
    /// "--0412", "--04-12" → "--04-12". Anything else is dropped.
    public static func birthday(_ text: String) -> String? {
        let value = text.split(separator: "T").first.map(String.init) ?? text
        if value.hasPrefix("--") {
            let digits = value.dropFirst(2).filter(\.isNumber)
            guard digits.count == 4, let month = Int(digits.prefix(2)), let day = Int(digits.suffix(2)), (1...12).contains(month), (1...31).contains(day)
            else { return nil }
            return String(format: "--%02d-%02d", month, day)
        }
        let digits = value.filter(\.isNumber)
        guard digits.count == 8, value.allSatisfy({ $0.isNumber || $0 == "-" }), let year = Int(digits.prefix(4)),
            let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Splits a structured value on unescaped separators, then unescapes each part.
    static func components(of text: String, separator: Character = ";") -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for character in text {
            if escaping {
                current += "\\" + String(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == separator {
                parts.append(unescape(current).trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(unescape(current).trimmingCharacters(in: .whitespaces))
        return parts
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Decodes `=XX` bytes as UTF-8 (Latin-1 when that fails).
    static func quotedPrintable(_ text: String) -> String {
        var bytes: [UInt8] = []
        var index = text.utf8.startIndex
        let utf8 = text.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "="), let high = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex), high < utf8.endIndex,
                let low = utf8.index(index, offsetBy: 2, limitedBy: utf8.endIndex), low < utf8.endIndex,
                let value = UInt8(String(decoding: [utf8[high], utf8[low]], as: UTF8.self), radix: 16)
            {
                bytes.append(value)
                index = utf8.index(after: low)
            } else {
                bytes.append(byte)
                index = utf8.index(after: index)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? text
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

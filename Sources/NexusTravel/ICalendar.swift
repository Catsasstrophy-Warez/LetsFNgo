import Foundation

/// One content line of an iCalendar (RFC 5545) or vCard file, after unfolding.
public struct ContentLine: Sendable, Hashable {
    /// Upper-cased property name, without any group prefix.
    public var name: String
    /// Upper-cased parameter names; values as written, quotes removed.
    public var parameters: [String: String]
    public var value: String
    /// Line number in the file where the (folded) line starts.
    public var line: Int

    /// Splits `NAME;PARAM=a;PARAM="b:c":value`. Nil when there is no colon.
    public init?(_ raw: String, line: Int) {
        var head = ""
        var inQuotes = false
        var splitIndex: String.Index?
        for index in raw.indices {
            let character = raw[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":" && !inQuotes {
                splitIndex = index
                break
            }
            head.append(character)
        }
        guard let splitIndex else { return nil }
        value = String(raw[raw.index(after: splitIndex)...])
        var fields: [String] = []
        var current = ""
        inQuotes = false
        for character in head {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == ";" && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        let fullName = fields.removeFirst().uppercased()
        // vCard groups: "item1.EMAIL".
        name = fullName.split(separator: ".").last.map(String.init) ?? fullName
        guard !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for field in fields {
            if let equals = field.firstIndex(of: "=") {
                let key = field[..<equals].uppercased()
                let value = String(field[field.index(after: equals)...])
                parameters[key] = parameters[key].map { "\($0),\(value)" } ?? value
            } else if !field.isEmpty {
                // vCard 2.1 bare parameters ("TEL;CELL:") are TYPE values.
                parameters["TYPE"] = parameters["TYPE"].map { "\($0),\(field)" } ?? field
            }
        }
        self.parameters = parameters
        self.line = line
    }

    /// Unfolds a file: a line starting with a space or tab continues the previous one.
    public static func unfold(_ text: String) -> [(text: String, line: Int)] {
        var result: [(text: String, line: Int)] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (offset, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)
            if offset == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1].text += line.dropFirst()
            } else if !line.isEmpty {
                result.append((line, offset + 1))
            }
        }
        return result
    }

    /// Undoes text escaping: `\n`, `\,`, `\;`, `\\`.
    public static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Splits on `separator` where it is not escaped, then unescapes each part.
    public static func split(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for character in text {
            if escaping {
                current.append("\\")
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == separator {
                parts.append(unescape(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(unescape(current))
        return parts
    }
}

/// A VEVENT from an iCalendar file.
public struct CalendarEvent: Sendable, Hashable {
    public var uid: String?
    public var summary: String
    public var description: String?
    public var location: String?
    public var start: Date
    public var end: Date?
    /// A DATE rather than DATE-TIME start: the event covers whole days.
    public var isAllDay: Bool
    public var line: Int
}

/// A parsed iCalendar file.
public struct CalendarFile: Sendable, Hashable {
    /// X-WR-CALNAME, when the file names itself.
    public var name: String?
    public var events: [CalendarEvent]
}

/// A small RFC 5545 reader: VEVENTs with UID, SUMMARY, DESCRIPTION, LOCATION,
/// DTSTART, DTEND and DURATION. Times may be UTC (`Z`), carry a TZID, or be
/// floating (read in `floatingTimeZone`). All-day dates are UTC midnights.
/// Other components (VTIMEZONE, VALARM, VTODO) are skipped.
public enum ICalendar {
    public static func parse(_ text: String, floatingTimeZone: TimeZone = TravelCalendar.utc) throws -> CalendarFile {
        let lines = ContentLine.unfold(text)
        guard let first = lines.first, first.text.uppercased() == "BEGIN:VCALENDAR" else {
            throw TravelError.malformedCalendar(line: lines.first?.line ?? 1, reason: "missing BEGIN:VCALENDAR")
        }
        var name: String?
        var events: [CalendarEvent] = []
        var stack: [String] = []
        var current: [ContentLine]?
        var eventLine = 0
        for (raw, number) in lines {
            guard let line = ContentLine(raw, line: number) else {
                throw TravelError.malformedCalendar(line: number, reason: "no ':' in content line")
            }
            switch line.name {
            case "BEGIN":
                let component = line.value.uppercased()
                stack.append(component)
                if component == "VEVENT" && stack.count == 2 {
                    current = []
                    eventLine = number
                }
            case "END":
                let component = line.value.uppercased()
                guard stack.last == component else {
                    throw TravelError.malformedCalendar(line: number, reason: "END:\(component) does not close \(stack.last ?? "anything")")
                }
                stack.removeLast()
                if component == "VEVENT", stack.count == 1, let properties = current {
                    events.append(try event(properties, line: eventLine, floatingTimeZone: floatingTimeZone))
                    current = nil
                }
            default:
                if stack == ["VCALENDAR"], line.name == "X-WR-CALNAME" { name = ContentLine.unescape(line.value) }
                // Only the event's own properties, not those of a nested VALARM.
                if stack.count == 2, stack.last == "VEVENT" { current?.append(line) }
            }
        }
        guard stack.isEmpty else {
            throw TravelError.malformedCalendar(line: lines.last?.line ?? 1, reason: "unclosed \(stack.last!)")
        }
        return CalendarFile(name: name, events: events)
    }

    static func event(_ properties: [ContentLine], line: Int, floatingTimeZone: TimeZone) throws -> CalendarEvent {
        func first(_ name: String) -> ContentLine? { properties.first { $0.name == name } }
        guard let startLine = first("DTSTART") else { throw TravelError.malformedCalendar(line: line, reason: "VEVENT without DTSTART") }
        let (start, isAllDay) = try date(startLine, floatingTimeZone: floatingTimeZone)
        var end: Date?
        if let endLine = first("DTEND") {
            end = try date(endLine, floatingTimeZone: floatingTimeZone).date
        } else if let durationLine = first("DURATION") {
            guard let seconds = duration(durationLine.value) else { throw TravelError.unparsableDate(durationLine.value, line: durationLine.line) }
            end = start.addingTimeInterval(seconds)
        } else if isAllDay {
            end = start.addingTimeInterval(86_400)
        }
        if let end, end < start { throw TravelError.invalidInterval(start: start, end: end) }
        let text = { (name: String) in first(name).map { ContentLine.unescape($0.value).trimmingCharacters(in: .whitespacesAndNewlines) } }
        return CalendarEvent(
            uid: text("UID").flatMap { $0.isEmpty ? nil : $0 }, summary: text("SUMMARY") ?? "",
            description: text("DESCRIPTION").flatMap { $0.isEmpty ? nil : $0 }, location: text("LOCATION").flatMap { $0.isEmpty ? nil : $0 },
            start: start, end: end, isAllDay: isAllDay, line: line
        )
    }

    /// DATE (`20260105`) or DATE-TIME (`20260105T093000`, with `Z` or a TZID).
    static func date(_ line: ContentLine, floatingTimeZone: TimeZone) throws -> (date: Date, isAllDay: Bool) {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        let digits = value.filter(\.isNumber)
        func number(_ range: Range<Int>) -> Int? {
            guard digits.count >= range.upperBound else { return nil }
            let start = digits.index(digits.startIndex, offsetBy: range.lowerBound)
            return Int(digits[start..<digits.index(start, offsetBy: range.count)])
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8), (1...12).contains(month), (1...31).contains(day) else {
            throw TravelError.unparsableDate(value, line: line.line)
        }
        if value.count == 8 || line.parameters["VALUE"]?.uppercased() == "DATE" {
            return (TravelCalendar.date(year, month, day), true)
        }
        guard value.count >= 15, value[value.index(value.startIndex, offsetBy: 8)] == "T", let hour = number(8..<10), let minute = number(10..<12),
            let second = number(12..<14), hour < 24, minute < 60, second < 61
        else { throw TravelError.unparsableDate(value, line: line.line) }
        var zone = floatingTimeZone
        if value.hasSuffix("Z") {
            zone = TravelCalendar.utc
        } else if let tzid = line.parameters["TZID"] {
            // Some producers prefix Olson names with "/".
            zone = TimeZone(identifier: tzid.hasPrefix("/") ? String(tzid.dropFirst()) : tzid) ?? floatingTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else {
            throw TravelError.unparsableDate(value, line: line.line)
        }
        return (date, false)
    }

    /// RFC 5545 DURATION: `P1W`, `P1DT2H30M`, `PT45M`, `-PT5M`.
    public static func duration(_ text: String) -> TimeInterval? {
        var text = Substring(text.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1.0
        if text.first == "-" || text.first == "+" {
            if text.first == "-" { sign = -1 }
            text = text.dropFirst()
        }
        guard text.first == "P" else { return nil }
        text = text.dropFirst()
        var total = 0.0
        var digits = ""
        var inTime = false
        var sawUnit = false
        for character in text {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if character == "T" {
                guard digits.isEmpty, !inTime else { return nil }
                inTime = true
                continue
            }
            guard let value = Double(digits) else { return nil }
            digits = ""
            switch (character, inTime) {
            case ("W", false): total += value * 604_800
            case ("D", false): total += value * 86_400
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
            sawUnit = true
        }
        guard digits.isEmpty, sawUnit else { return nil }
        return sign * total
    }
}

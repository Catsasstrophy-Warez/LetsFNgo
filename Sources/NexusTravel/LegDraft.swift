import Foundation

/// A leg as entered or read from a file, before it is stored.
public struct LegDraft: Sendable, Hashable {
    public var title: String
    public var mode: LegMode
    public var start: Date
    public var end: Date?
    public var origin: String?
    public var destination: String?
    public var number: String?
    public var carrier: String?
    public var seat: String?
    public var confirmation: String?
    public var notes: String?
    public var uid: String?

    public init(
        title: String, mode: LegMode, start: Date, end: Date? = nil, origin: String? = nil, destination: String? = nil, number: String? = nil,
        carrier: String? = nil, seat: String? = nil, confirmation: String? = nil, notes: String? = nil, uid: String? = nil
    ) {
        self.title = title
        self.mode = mode
        self.start = start
        self.end = end
        self.origin = origin
        self.destination = destination
        self.number = number
        self.carrier = carrier
        self.seat = seat
        self.confirmation = confirmation
        self.notes = notes
        self.uid = uid
    }
}

/// Reads a leg out of a calendar event's free text. Everything here is a
/// guess from wording, so the importer stores the mode it chose as derived
/// truth; a person's correction (observed) is never replaced by a re-import.
public enum LegClassifier {
    public static func draft(from event: CalendarEvent) -> LegDraft {
        let text = [event.summary, event.description ?? "", event.location ?? ""].joined(separator: "\n")
        let mode = mode(of: event)
        var draft = LegDraft(
            title: event.summary.isEmpty ? "Untitled leg" : event.summary, mode: mode, start: event.start, end: event.end, notes: event.description,
            uid: event.uid
        )
        draft.number = transportNumber(in: event.summary) ?? (mode == .flight ? transportNumber(in: text) : nil)
        draft.confirmation = confirmation(in: text)
        if mode == .stay {
            draft.destination = event.location ?? stayName(event.summary)
        } else if let route = route(in: event.summary) ?? event.description.flatMap(route(in:)) {
            draft.origin = route.from
            draft.destination = route.to
        } else {
            draft.origin = event.location
        }
        return draft
    }

    public static func mode(of event: CalendarEvent) -> LegMode {
        let summary = event.summary.lowercased()
        let text = (summary + " " + (event.description ?? "").lowercased())
        func has(_ words: [String], in text: String) -> Bool { words.contains { text.contains($0) } }
        if has(["flight", "✈", "airline", "boarding"], in: summary) || (transportNumber(in: event.summary) != nil && iataRoute(in: event.summary) != nil) {
            return .flight
        }
        if has(["train", "rail", "amtrak", "eurostar", "tgv", "ice ", "shinkansen"], in: summary) { return .train }
        if has(["hotel", "stay", "airbnb", "lodging", "hostel", "inn ", "resort", "check-in:", "accommodation"], in: summary) { return .stay }
        if has(["drive", "car rental", "rental car", "road trip", "hertz", "avis"], in: summary) { return .drive }
        if has(["flight", "boarding pass"], in: text) { return .flight }
        if has(["hotel", "check-in", "check in", "check-out"], in: text)
            || (event.isAllDay && (event.end ?? event.start) > event.start.addingTimeInterval(86_400))
        {
            return .stay
        }
        return .other
    }

    /// "UA 123", "BA0283", "LH400" → "UA123". Two-character airline or rail designator and 1–4 digits.
    public static func transportNumber(in text: String) -> String? {
        let pattern = #/\b([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\s?0*([1-9][0-9]{0,3})\b/#
        for match in text.matches(of: pattern) {
            let designator = String(match.output.1)
            // Skip routes like "SFO" read as "SF" + nothing, and ordinals.
            guard designator.contains(where: \.isLetter) else { continue }
            return designator + String(match.output.2)
        }
        return nil
    }

    /// "SFO → JFK", "SFO-JFK", "SFO to JFK".
    static func iataRoute(in text: String) -> (from: String, to: String)? {
        guard let match = text.firstMatch(of: #/\b([A-Z]{3})\s*(?:→|->|–|—|-|/|\bto\b)\s*([A-Z]{3})\b/#) else { return nil }
        return (String(match.output.1), String(match.output.2))
    }

    /// An IATA pair, or "from X to Y", or "X to Y" / "X → Y" after a mode word.
    public static func route(in text: String) -> (from: String, to: String)? {
        if let route = iataRoute(in: text) { return route }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        if let match = line.firstMatch(of: #/(?i)\bfrom\s+(.+?)\s+to\s+(.+?)\s*(?:$|[,;(])/#) {
            return (clean(match.output.1), clean(match.output.2))
        }
        if let match = line.firstMatch(
            of: #/(?i)^(?:flight|train|drive|bus|ferry)?\s*(?:[A-Z0-9]{2}\s?[0-9]{1,4}\s+)?:?\s*(.+?)\s+(?:to|→|->)\s+(.+?)\s*(?:$|[,;(])/#)
        {
            return (clean(match.output.1), clean(match.output.2))
        }
        return nil
    }

    /// "Confirmation: ABC123", "Record locator XYZ9QK", "PNR: K7Q2LM". A code in
    /// mixed case is a word, not a code.
    public static func confirmation(in text: String) -> String? {
        let pattern = #/(?i)(?:confirmation|booking|record locator|pnr|reservation|reference)\s*(?:code|number|no\.?|#)?\s*[:#]?\s*([A-Z0-9]{5,8})\b/#
        guard let match = text.firstMatch(of: pattern) else { return nil }
        let code = String(match.output.1).uppercased()
        // Words such as "number" slip through when there is no code.
        guard code.contains(where: \.isNumber) || code == String(match.output.1) else { return nil }
        return code
    }

    static func stayName(_ summary: String) -> String? {
        let trimmed = summary.replacing(#/(?i)^(?:hotel|stay|check-in)\s*[:\-–]?\s*/#, with: "")
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clean(_ text: Substring) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " .:-–"))
    }
}

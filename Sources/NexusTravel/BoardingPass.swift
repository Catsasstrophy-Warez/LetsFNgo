import Foundation

/// A boarding pass, from an IATA Bar Coded Boarding Pass string or from a
/// Wallet pass's `pass.json`. Only the first leg of a multi-leg barcode is read.
public struct BoardingPass: Sendable, Hashable {
    public var passenger: String?
    public var confirmation: String?
    public var origin: String?
    public var destination: String?
    /// Carrier and number, e.g. "UA123".
    public var flight: String?
    public var carrier: String?
    public var seat: String?
    /// The departure day, or the pass's relevant date (usually boarding time).
    public var date: Date?
    public var mode: LegMode

    public init(
        passenger: String? = nil, confirmation: String? = nil, origin: String? = nil, destination: String? = nil, flight: String? = nil,
        carrier: String? = nil, seat: String? = nil, date: Date? = nil, mode: LegMode = .flight
    ) {
        self.passenger = passenger
        self.confirmation = confirmation
        self.origin = origin
        self.destination = destination
        self.flight = flight
        self.carrier = carrier
        self.seat = seat
        self.date = date
        self.mode = mode
    }

    /// Reads the mandatory items of an IATA BCBP (Resolution 792) string:
    ///
    ///     M1DOE/JANE            EK7Q2LMN SFOJFKUA 0123 245Y012A0042 100
    ///
    /// The flight date is a day of the year without a year; it resolves to the
    /// year that puts it nearest `reference`.
    public static func bcbp(_ message: String, reference: Date) throws -> BoardingPass {
        let characters = Array(message)
        guard characters.count >= 58, characters[0] == "M", characters[1].isNumber else {
            throw TravelError.malformedBoardingPass("not an IATA BCBP string")
        }
        func field(_ start: Int, _ length: Int) -> String {
            String(characters[start..<start + length]).trimmingCharacters(in: .whitespaces)
        }
        let carrier = field(36, 3)
        let number = field(39, 5).drop { $0 == "0" }
        guard let dayOfYear = Int(field(44, 3)), (1...366).contains(dayOfYear), !carrier.isEmpty, !number.isEmpty else {
            throw TravelError.malformedBoardingPass("unreadable flight or date")
        }
        let seatText = field(48, 4)
        let seat = seatText.drop { $0 == "0" }
        let name = field(2, 20).split(separator: "/").reversed().joined(separator: " ")
        return BoardingPass(
            passenger: name.isEmpty ? nil : name, confirmation: field(23, 7).nilIfEmpty, origin: field(30, 3).nilIfEmpty,
            destination: field(33, 3).nilIfEmpty, flight: carrier + number, carrier: carrier,
            seat: seat.isEmpty ? nil : String(seat), date: nearestDate(dayOfYear: dayOfYear, to: reference)
        )
    }

    /// Reads a Wallet pass.json: the barcode when it is BCBP, otherwise the
    /// boarding pass fields by their keys.
    public static func passJSON(_ data: Data, reference: Date) throws -> BoardingPass {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TravelError.malformedBoardingPass("pass.json is not a JSON object")
        }
        let relevant = (root["relevantDate"] as? String).flatMap(parseISODate)
        var messages: [String] = []
        if let barcode = root["barcode"] as? [String: Any], let message = barcode["message"] as? String { messages.append(message) }
        for barcode in root["barcodes"] as? [[String: Any]] ?? [] {
            if let message = barcode["message"] as? String { messages.append(message) }
        }
        let style = (root["boardingPass"] as? [String: Any]) ?? [:]
        let mode: LegMode =
            switch style["transitType"] as? String {
            case "PKTransitTypeTrain": .train
            case "PKTransitTypeAir", nil: .flight
            default: .other
            }
        if let parsed = messages.lazy.compactMap({ try? bcbp($0, reference: relevant ?? reference) }).first {
            var pass = parsed
            pass.mode = mode
            // The relevant date carries the boarding time; the barcode only the day.
            if let relevant, let day = parsed.date, abs(relevant.timeIntervalSince(day)) < 2 * 86_400 { pass.date = relevant }
            return pass
        }
        var fields: [(key: String, value: String)] = []
        for group in ["headerFields", "primaryFields", "secondaryFields", "auxiliaryFields", "backFields"] {
            for entry in style[group] as? [[String: Any]] ?? [] {
                guard let key = entry["key"] as? String else { continue }
                let value = (entry["value"] as? String) ?? (entry["value"] as? NSNumber)?.stringValue
                if let value, !value.isEmpty { fields.append((key.lowercased(), value)) }
            }
        }
        func value(_ keys: [String]) -> String? {
            fields.first { field in keys.contains { field.key == $0 || field.key.contains($0) } }?.value
        }
        let pass = BoardingPass(
            passenger: value(["passenger", "name"]), confirmation: value(["confirmation", "pnr", "locator"]),
            origin: value(["origin", "from", "depart"]), destination: value(["destination", "to", "arriv"]),
            flight: value(["flight", "train", "number"]).map { $0.replacingOccurrences(of: " ", with: "") },
            carrier: root["organizationName"] as? String, seat: value(["seat"]), date: relevant, mode: mode
        )
        guard pass.origin != nil || pass.destination != nil || pass.flight != nil else {
            throw TravelError.malformedBoardingPass("no barcode or route fields")
        }
        return pass
    }

    static func nearestDate(dayOfYear: Int, to reference: Date) -> Date? {
        let year = TravelCalendar.calendar.component(.year, from: reference)
        return (year - 1...year + 1).compactMap { year -> Date? in
            let start = TravelCalendar.date(year, 1, 1)
            let date = TravelCalendar.calendar.date(byAdding: .day, value: dayOfYear - 1, to: start)!
            return TravelCalendar.calendar.component(.year, from: date) == year ? date : nil
        }
        .min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    static func parseISODate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        // Wallet also accepts dates without seconds: "2026-09-02T08:05-07:00".
        let withSeconds = text.replacing(#/T(\d{2}):(\d{2})(?=[+\-Z])/#) { "T\($0.output.1):\($0.output.2):00" }
        return formatter.date(from: withSeconds)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation
import NexusCore
import NexusModel

// Travel terms on NexusModel's open vocabularies. Trips, legs, bookings and
// places are ordinary objects in the shared store; imported itinerary files
// are `document` objects whose bytes are a blob. Timelines and conflicts are
// derived on read and never stored. Nothing here keeps state of its own.

extension ObjectType {
    /// A journey: a named plan made of legs.
    public static let trip: ObjectType = "trip"
    /// One flight, train, drive or stay within a trip.
    public static let travelLeg: ObjectType = "travelLeg"
    /// A reservation with a confirmation code, covering one or more legs.
    public static let booking: ObjectType = "booking"
    /// An airport, station, city or lodging.
    public static let place: ObjectType = "place"
}

extension RelationKind {
    /// Trip → leg. Not `contains`: a trip in a project shows as one member, not every leg.
    public static let hasLeg: RelationKind = "hasLeg"
    /// Leg → the place it leaves from.
    public static let departsFrom: RelationKind = "departsFrom"
    /// Leg → the place it arrives at (for a stay, the lodging).
    public static let arrivesAt: RelationKind = "arrivesAt"
    /// Booking → a leg it pays for or reserves.
    public static let covers: RelationKind = "covers"
}

extension EventKind {
    /// An itinerary file (.ics, boarding pass) was imported. Payload: counts.
    public static let itineraryImported: EventKind = "itineraryImported"
}

/// Attribute and payload keys used on travel objects.
public enum TravelKey {
    /// A leg's `LegMode` raw value.
    public static let mode = "mode"
    public static let start = "start"
    public static let end = "end"
    /// Name or code of where a leg departs.
    public static let origin = "origin"
    /// Name or code of where a leg arrives (for a stay, the lodging).
    public static let destination = "destination"
    /// Flight or train number, e.g. "UA123".
    public static let number = "number"
    public static let carrier = "carrier"
    public static let seat = "seat"
    public static let confirmation = "confirmation"
    public static let provider = "provider"
    public static let notes = "notes"
    public static let location = "location"
    /// iCalendar UID of the event a leg was imported from, for re-import.
    public static let uid = "uid"
    /// IATA code of a place, when it is an airport.
    public static let code = "code"
    public static let blob = "blob"
    public static let mediaType = "mediaType"
    public static let format = "format"
}

/// How a leg moves the traveller, or that it is a stay.
public enum LegMode: String, Codable, Sendable, CaseIterable {
    case flight
    case train
    case drive
    case stay
    case other

    public var isTransport: Bool { self != .stay }

    /// The shortest connection onto a leg of this mode that is not tight.
    public var minimumConnection: TimeInterval {
        switch self {
        case .flight: 60 * 60
        case .train: 15 * 60
        case .drive, .stay, .other: 0
        }
    }
}

public enum TravelError: Error, Equatable, Sendable {
    case notFound(ObjectID, expected: ObjectType)
    case malformedCalendar(line: Int, reason: String)
    case unparsableDate(String, line: Int)
    case malformedBoardingPass(String)
    case invalidInterval(start: Date, end: Date)
}

/// The UTC Gregorian calendar travel uses for all-day values and day matching.
public enum TravelCalendar {
    public static let utc = TimeZone(identifier: "UTC")!

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    public static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in zone: TimeZone = utc) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// "2026-09-05".
    public static func isoDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

extension Origin {
    /// The truth class of a value this author enters: a person's entry is an
    /// observation, an importer's a record, an agent's an interpretation.
    var entryTruth: TruthClass {
        if case .user = self { return .observed }
        return defaultTruth
    }
}

extension ObjectRecord {
    func string(_ key: String) -> String? {
        if case .string(let text)? = attributes[key]?.value { return text }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let date)? = attributes[key]?.value { return date }
        return nil
    }
}

/// Lower-cased letters and digits only, for matching names and codes.
func matchKey(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
}

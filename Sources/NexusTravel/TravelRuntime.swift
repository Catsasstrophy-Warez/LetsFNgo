import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// A typed view of a trip object. The canonical state stays in the store.
public struct Trip: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var name: String { record.title }
}

/// A typed view of a leg object.
public struct TravelLeg: Sendable, Hashable, Identifiable {
    public var record: ObjectRecord

    public var id: ObjectID { record.id }
    public var title: String { record.title }
    public var mode: LegMode { record.string(TravelKey.mode).flatMap(LegMode.init(rawValue:)) ?? .other }
    /// Derived when the importer guessed it from wording; observed once a person set it.
    public var modeTruth: TruthClass? { record.truth(of: TravelKey.mode) }
    public var start: Date { record.date(TravelKey.start) ?? record.createdAt }
    public var end: Date? { record.date(TravelKey.end) }
    /// The end, or the start when the end is unknown.
    public var finish: Date { end ?? start }
    public var origin: String? { record.string(TravelKey.origin) }
    public var destination: String? { record.string(TravelKey.destination) }
    public var number: String? { record.string(TravelKey.number) }
    public var seat: String? { record.string(TravelKey.seat) }
    public var confirmation: String? { record.string(TravelKey.confirmation) }
    public var uid: String? { record.string(TravelKey.uid) }
}

/// One row of a trip's timeline: a leg, or the time between two transport legs.
public enum TimelineEntry: Sendable, Hashable {
    case leg(TravelLeg)
    /// Time between one transport leg's arrival and the next one's departure.
    case connection(after: ObjectID, before: ObjectID, duration: TimeInterval)
}

/// A trip's legs in order, with derived span and connections.
public struct TripTimeline: Sendable, Hashable {
    public var trip: Trip
    public var entries: [TimelineEntry]
    /// First start to last finish. Derived from the legs.
    public var span: DateInterval?
    public var conflicts: [TravelConflict]

    public var legs: [TravelLeg] { entries.compactMap { if case .leg(let leg) = $0 { leg } else { nil } } }
}

/// A problem found by comparing legs. Always derived truth; never stored.
public struct TravelConflict: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Two transport legs, or two stays, at the same time.
        case overlap
        /// Less time between legs than the next leg's mode needs.
        case tightConnection
        /// A leg departs from somewhere other than where the previous one arrived.
        case placeMismatch
    }

    public var kind: Kind
    public var legs: [ObjectID]
    public var message: String
    public var truth: TruthClass { .derived }
}

/// Trips, legs, bookings and places as objects and relationships in the
/// shared store, and the timeline and conflict checks derived from them.
public struct TravelRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    /// Connections longer than this are separate journeys, not connections.
    public static let connectionWindow: TimeInterval = 12 * 3_600

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Trips

    @discardableResult
    public func addTrip(_ name: String, by author: Origin) throws -> Trip {
        Trip(
            record: try store.create(
                ObjectRecord(type: .trip, title: name, provenance: Provenance(origin: author, truth: author.entryTruth, timestamp: clock.now()))
            ))
    }

    public func trip(_ id: ObjectID) throws -> Trip {
        guard let record = try store.object(id), record.type == .trip else { throw TravelError.notFound(id, expected: .trip) }
        return Trip(record: record)
    }

    /// Live trips, soonest first by their first leg.
    public func trips() throws -> [Trip] {
        let trips = try store.objects(ofType: .trip).filter { $0.lifecycle != .deleted }.map(Trip.init)
        let starts = try Dictionary(uniqueKeysWithValues: trips.map { ($0.id, try legs(of: $0.id).first?.start ?? .distantFuture) })
        return trips.sorted { (starts[$0.id]!, $0.name) < (starts[$1.id]!, $1.name) }
    }

    // MARK: Legs

    /// A person adds a leg: an observation of their own plans.
    @discardableResult
    public func addLeg(_ draft: LegDraft, to tripID: ObjectID, by author: Origin) throws -> TravelLeg {
        let provenance = Provenance(origin: author, truth: author.entryTruth, timestamp: clock.now(), method: "entered")
        return try addLeg(draft, to: tripID, provenance: provenance, modeProvenance: nil)
    }

    func addLeg(_ draft: LegDraft, to tripID: ObjectID, provenance: Provenance, modeProvenance: Provenance?) throws -> TravelLeg {
        if let end = draft.end, end < draft.start { throw TravelError.invalidInterval(start: draft.start, end: end) }
        return try store.batch { store in
            _ = try trip(tripID)
            var attributes = Self.attributes(of: draft)
            attributes[TravelKey.mode] = Attribute(.string(draft.mode.rawValue), provenance: modeProvenance)
            let record = try store.create(ObjectRecord(type: .travelLeg, title: draft.title, attributes: attributes, provenance: provenance))
            try store.relate(Relationship(kind: .hasLeg, from: tripID, to: record.id, provenance: provenance))
            try linkPlaces(record.id, draft: draft, provenance: provenance)
            if let confirmation = draft.confirmation {
                try linkBooking(confirmation, provider: draft.carrier, to: record.id, provenance: provenance)
            }
            return TravelLeg(record: record)
        }
    }

    static func attributes(of draft: LegDraft) -> [String: Attribute] {
        var attributes: [String: Attribute] = [TravelKey.start: Attribute(.date(draft.start))]
        let optional: [(String, String?)] = [
            (TravelKey.origin, draft.origin), (TravelKey.destination, draft.destination), (TravelKey.number, draft.number),
            (TravelKey.carrier, draft.carrier), (TravelKey.seat, draft.seat), (TravelKey.confirmation, draft.confirmation),
            (TravelKey.notes, draft.notes), (TravelKey.uid, draft.uid),
        ]
        for (key, value) in optional {
            if let value, !value.isEmpty { attributes[key] = Attribute(.string(value)) }
        }
        if let end = draft.end { attributes[TravelKey.end] = Attribute(.date(end)) }
        return attributes
    }

    public func leg(_ id: ObjectID) throws -> TravelLeg {
        guard let record = try store.object(id), record.type == .travelLeg else { throw TravelError.notFound(id, expected: .travelLeg) }
        return TravelLeg(record: record)
    }

    /// A trip's live legs, by start.
    public func legs(of tripID: ObjectID) throws -> [TravelLeg] {
        let ids = try store.relationships(from: tripID, kind: .hasLeg).filter { $0.validTo == nil }.map(\.to)
        return try store.objects(ids).filter { $0.lifecycle == .active }.map(TravelLeg.init).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The trip a leg belongs to.
    public func trip(of legID: ObjectID) throws -> Trip? {
        guard let edge = try store.relationships(to: legID, kind: .hasLeg).first(where: { $0.validTo == nil }) else { return nil }
        return try trip(edge.from)
    }

    /// A person corrects a leg's mode. Observed truth: a later import's guess never replaces it.
    @discardableResult
    public func setMode(_ mode: LegMode, of legID: ObjectID, by author: Origin) throws -> TravelLeg {
        _ = try leg(legID)
        let provenance = Provenance(origin: author, truth: author.entryTruth, timestamp: clock.now(), method: "set by hand")
        return TravelLeg(
            record: try store.update(legID, by: author, instruction: "Set mode to \(mode.rawValue)") {
                $0.attributes[TravelKey.mode] = Attribute(.string(mode.rawValue), provenance: provenance)
            })
    }

    // MARK: Places and bookings

    /// The place with this name or code, created when there is none.
    @discardableResult
    public func place(named name: String, provenance: Provenance) throws -> ObjectRecord {
        let key = matchKey(name)
        if let existing = try store.objects(ofType: .place).first(where: {
            $0.lifecycle != .deleted && (matchKey($0.title) == key || $0.string(TravelKey.code).map(matchKey) == key)
        }) {
            return existing
        }
        var attributes: [String: Attribute] = [:]
        if name.count == 3, name.allSatisfy({ $0.isUppercase && $0.isLetter }) { attributes[TravelKey.code] = Attribute(.string(name)) }
        return try store.create(ObjectRecord(type: .place, title: name, attributes: attributes, provenance: provenance))
    }

    func linkPlaces(_ legID: ObjectID, draft: LegDraft, provenance: Provenance) throws {
        if let origin = draft.origin, !origin.isEmpty {
            try store.relate(Relationship(kind: .departsFrom, from: legID, to: try place(named: origin, provenance: provenance).id, provenance: provenance))
        }
        if let destination = draft.destination, !destination.isEmpty {
            try store.relate(
                Relationship(kind: .arrivesAt, from: legID, to: try place(named: destination, provenance: provenance).id, provenance: provenance))
        }
    }

    /// The booking with this confirmation code, created when there is none, covering the leg.
    @discardableResult
    func linkBooking(_ confirmation: String, provider: String?, to legID: ObjectID, provenance: Provenance) throws -> ObjectRecord {
        let booking: ObjectRecord
        if let existing = try bookings().first(where: { $0.string(TravelKey.confirmation) == confirmation }) {
            booking = existing
        } else {
            var attributes = [TravelKey.confirmation: Attribute(.string(confirmation))]
            if let provider { attributes[TravelKey.provider] = Attribute(.string(provider)) }
            booking = try store.create(
                ObjectRecord(type: .booking, title: "Booking \(confirmation)", attributes: attributes, provenance: provenance))
        }
        let covered = try store.relationships(from: booking.id, kind: .covers).contains { $0.to == legID && $0.validTo == nil }
        if !covered { try store.relate(Relationship(kind: .covers, from: booking.id, to: legID, provenance: provenance)) }
        return booking
    }

    public func bookings() throws -> [ObjectRecord] {
        try store.objects(ofType: .booking).filter { $0.lifecycle != .deleted }
    }

    /// Bookings covering any of a trip's legs.
    public func bookings(of tripID: ObjectID) throws -> [ObjectRecord] {
        var ids: [ObjectID] = []
        for leg in try legs(of: tripID) {
            for edge in try store.relationships(to: leg.id, kind: .covers) where edge.validTo == nil && !ids.contains(edge.from) {
                ids.append(edge.from)
            }
        }
        return try store.objects(ids)
    }

    // MARK: Derived

    /// The trip's legs in order, with the connections between transport legs and every conflict.
    public func timeline(of tripID: ObjectID) throws -> TripTimeline {
        let trip = try trip(tripID)
        let legs = try legs(of: tripID)
        var entries: [TimelineEntry] = []
        var previousTransport: TravelLeg?
        for leg in legs {
            if leg.mode.isTransport {
                if let previous = previousTransport {
                    let gap = leg.start.timeIntervalSince(previous.finish)
                    if gap >= 0, gap <= Self.connectionWindow {
                        entries.append(.connection(after: previous.id, before: leg.id, duration: gap))
                    }
                }
                previousTransport = leg
            }
            entries.append(.leg(leg))
        }
        let span = legs.isEmpty ? nil : DateInterval(start: legs.map(\.start).min()!, end: legs.map(\.finish).max()!)
        return TripTimeline(trip: trip, entries: entries, span: span, conflicts: Self.conflicts(in: legs))
    }

    /// Overlapping legs, tight connections and place mismatches, by comparing legs.
    ///
    /// - Transport legs may not overlap each other, nor stays each other; a
    ///   flight during a stay is normal.
    /// - A transport leg starting within `connectionWindow` of the previous
    ///   one's arrival is a connection, which needs its mode's
    ///   `minimumConnection` and should leave from where the previous arrived.
    public static func conflicts(in legs: [TravelLeg]) -> [TravelConflict] {
        let sorted = legs.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var conflicts: [TravelConflict] = []
        for (index, first) in sorted.enumerated() {
            for second in sorted[(index + 1)...] where first.mode.isTransport == second.mode.isTransport {
                guard second.start < first.finish else { continue }
                conflicts.append(
                    TravelConflict(kind: .overlap, legs: [first.id, second.id], message: "\(first.title) overlaps \(second.title)"))
            }
        }
        let transport = sorted.filter(\.mode.isTransport)
        for (previous, next) in zip(transport, transport.dropFirst()) {
            let gap = next.start.timeIntervalSince(previous.finish)
            guard gap >= 0, gap <= connectionWindow, previous.end != nil else { continue }
            if gap < next.mode.minimumConnection {
                conflicts.append(
                    TravelConflict(
                        kind: .tightConnection, legs: [previous.id, next.id],
                        message:
                            "\(Int(gap / 60)) min to connect from \(previous.title) to \(next.title); \(next.mode.rawValue) needs \(Int(next.mode.minimumConnection / 60)) min"
                    ))
            }
            if let arrival = previous.destination, let departure = next.origin, matchKey(arrival) != matchKey(departure) {
                conflicts.append(
                    TravelConflict(
                        kind: .placeMismatch, legs: [previous.id, next.id],
                        message: "\(previous.title) arrives at \(arrival) but \(next.title) leaves from \(departure)"
                    ))
            }
        }
        return conflicts
    }
}

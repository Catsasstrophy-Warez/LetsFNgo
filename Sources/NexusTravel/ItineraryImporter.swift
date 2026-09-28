import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// What one itinerary import did.
public struct ItineraryImportResult: Sendable, Hashable {
    /// The `document` object holding the file (its bytes are a blob).
    public var document: ObjectRecord
    public var trip: Trip
    public var created: [TravelLeg]
    public var updated: [TravelLeg]
    /// Events whose leg was already stored exactly as the file has it.
    public var unchanged: Int
}

/// Imports iCalendar itineraries and boarding passes.
///
/// The file is stored first, as a blob behind a `document` object. Each leg
/// is **recorded** truth whose origin is `importer(source:)` naming that
/// document. The leg's mode is a guess from the event's wording, so it
/// carries its own **derived** provenance; a person's correction is observed
/// truth, which a later import leaves alone.
///
/// Re-importing a file is idempotent: an event whose UID matches a stored
/// leg updates that leg instead of adding another.
public struct ItineraryImporter: Sendable {
    public let store: NexusStore
    public let travel: TravelRuntime
    let clock: NexusClock

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.travel = TravelRuntime(store: store, clock: clock)
        self.clock = clock
    }

    /// Imports every VEVENT of an .ics file as a leg of `tripID`, or of a new
    /// trip named after the calendar or the file.
    @discardableResult
    public func importICS(
        _ data: Data, named fileName: String, into tripID: ObjectID? = nil, floatingTimeZone: TimeZone = TravelCalendar.utc, by author: Origin
    ) throws -> ItineraryImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw TravelError.malformedCalendar(line: 0, reason: "not text")
        }
        let calendar = try ICalendar.parse(text, floatingTimeZone: floatingTimeZone)
        return try store.batch { _ in
            let document = try storeDocument(data, named: fileName, mediaType: "text/calendar", format: "iCalendar", by: author)
            let importer = Origin.importer(source: document.id)
            let trip = try resolveTrip(tripID, name: calendar.name ?? tripName(fileName), document: document)
            let existing = Dictionary(
                try store.objects(ofType: .travelLeg).filter { $0.lifecycle != .deleted }.compactMap { record in
                    TravelLeg(record: record).uid.map { ($0, TravelLeg(record: record)) }
                }, uniquingKeysWith: { first, _ in first })
            var created: [TravelLeg] = []
            var updated: [TravelLeg] = []
            var unchanged = 0
            for event in calendar.events {
                let draft = LegClassifier.draft(from: event)
                let provenance = Provenance(
                    origin: importer, truth: .recorded, timestamp: clock.now(), method: "VEVENT line \(event.line), imported by \(author.travelLabel)",
                    dependencies: [document.id]
                )
                let modeProvenance = Provenance(
                    origin: importer, truth: .derived, timestamp: clock.now(), method: "mode classified from the event's wording",
                    dependencies: [document.id]
                )
                if let uid = draft.uid, let leg = existing[uid] {
                    if let changed = try refresh(leg, from: draft, provenance: provenance, modeProvenance: modeProvenance) {
                        updated.append(changed)
                    } else {
                        unchanged += 1
                    }
                } else {
                    created.append(try travel.addLeg(draft, to: trip.id, provenance: provenance, modeProvenance: modeProvenance))
                }
            }
            try recordImport(document: document, trip: trip, created: created.count, updated: updated.count, format: "iCalendar", by: author)
            return ItineraryImportResult(document: document, trip: trip, created: created, updated: updated, unchanged: unchanged)
        }
    }

    /// Imports a Wallet `pass.json` (or a bare BCBP barcode string). A pass for
    /// a flight already on the trip, same number within a day, adds its seat
    /// and confirmation to that leg; otherwise the pass becomes a new leg.
    @discardableResult
    public func importBoardingPass(_ data: Data, named fileName: String, into tripID: ObjectID? = nil, by author: Origin) throws -> ItineraryImportResult {
        let now = clock.now()
        let pass: BoardingPass
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("M") {
            pass = try BoardingPass.bcbp(text, reference: now)
        } else {
            pass = try BoardingPass.passJSON(data, reference: now)
        }
        guard let date = pass.date else { throw TravelError.malformedBoardingPass("no date") }
        return try store.batch { _ in
            let document = try storeDocument(data, named: fileName, mediaType: "application/json", format: "Boarding pass", by: author)
            let importer = Origin.importer(source: document.id)
            let provenance = Provenance(
                origin: importer, truth: .recorded, timestamp: now, method: "boarding pass, imported by \(author.travelLabel)", dependencies: [document.id]
            )
            let candidates =
                try tripID.map { try travel.legs(of: $0) }
                ?? store.objects(ofType: .travelLeg).filter { $0.lifecycle == .active }.map(TravelLeg.init)
            let match = candidates.first { leg in
                guard let number = leg.number, let flight = pass.flight else { return false }
                return matchKey(number) == matchKey(flight) && abs(leg.start.timeIntervalSince(date)) < 86_400
            }
            if let match {
                let trip = try travel.trip(of: match.id) ?? resolveTrip(tripID, name: tripName(fileName), document: document)
                let record = try store.update(match.id, by: importer, instruction: "Boarding pass") { record in
                    for (key, value) in [(TravelKey.seat, pass.seat), (TravelKey.confirmation, pass.confirmation)] {
                        guard let value, record.string(key) != value else { continue }
                        record.attributes[key] = Attribute(.string(value), provenance: provenance)
                    }
                }
                if let confirmation = pass.confirmation {
                    try travel.linkBooking(confirmation, provider: pass.carrier, to: match.id, provenance: provenance)
                }
                try recordImport(document: document, trip: trip, created: 0, updated: 1, format: "Boarding pass", by: author)
                return ItineraryImportResult(document: document, trip: trip, created: [], updated: [TravelLeg(record: record)], unchanged: 0)
            }
            let trip = try resolveTrip(tripID, name: pass.destination.map { "Trip to \($0)" } ?? tripName(fileName), document: document)
            let route = [pass.origin, pass.destination].compactMap { $0 }.joined(separator: " → ")
            let draft = LegDraft(
                title: [pass.flight, route].compactMap { $0?.nilIfEmpty }.joined(separator: " "), mode: pass.mode, start: date,
                origin: pass.origin, destination: pass.destination, number: pass.flight, carrier: pass.carrier, seat: pass.seat,
                confirmation: pass.confirmation
            )
            let leg = try travel.addLeg(draft, to: trip.id, provenance: provenance, modeProvenance: nil)
            try recordImport(document: document, trip: trip, created: 1, updated: 0, format: "Boarding pass", by: author)
            return ItineraryImportResult(document: document, trip: trip, created: [leg], updated: [], unchanged: 0)
        }
    }

    // MARK: Helpers

    /// Applies an event's newer values to its stored leg. Returns nil when nothing changed.
    private func refresh(_ leg: TravelLeg, from draft: LegDraft, provenance: Provenance, modeProvenance: Provenance) throws -> TravelLeg? {
        var fresh = TravelRuntime.attributes(of: draft)
        // A person's mode (observed) outranks the importer's guess (derived).
        if TruthPolicy.canReplace(existing: leg.modeTruth ?? .derived, with: .derived) {
            fresh[TravelKey.mode] = Attribute(.string(draft.mode.rawValue), provenance: modeProvenance)
        }
        // A value a person entered (observed) stays; the file's differing value is not forced over it.
        let changedKeys = fresh.keys.filter { key in
            leg.record.attributes[key]?.value != fresh[key]!.value && (key == TravelKey.mode || leg.record.truth(of: key) != .observed)
        }
        guard !changedKeys.isEmpty || leg.title != draft.title else { return nil }
        let record = try store.update(leg.id, by: provenance.origin, instruction: "Re-imported from calendar") { record in
            record.title = draft.title
            for key in changedKeys {
                record.attributes[key] = Attribute(fresh[key]!.value, provenance: fresh[key]!.provenance ?? provenance)
            }
        }
        return TravelLeg(record: record)
    }

    private func resolveTrip(_ tripID: ObjectID?, name: String, document: ObjectRecord) throws -> Trip {
        if let tripID { return try travel.trip(tripID) }
        let provenance = Provenance(
            origin: .importer(source: document.id), truth: .recorded, timestamp: clock.now(), method: "trip for \(document.title)",
            dependencies: [document.id]
        )
        return Trip(record: try store.create(ObjectRecord(type: .trip, title: name, provenance: provenance)))
    }

    private func tripName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? "Imported trip" : base
    }

    private func recordImport(document: ObjectRecord, trip: Trip, created: Int, updated: Int, format: String, by author: Origin) throws {
        try store.record(
            Event(
                at: clock.now(), kind: .itineraryImported, subjects: [document.id, trip.id],
                summary: "Imported \(created) legs (\(updated) updated) from \(document.title)",
                payload: ["created": .int(Int64(created)), "updated": .int(Int64(updated)), TravelKey.format: .string(format)],
                provenance: Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "\(format) import")
            ))
    }

    /// Stores the file's bytes as a blob and returns its document object,
    /// reusing the document when the same bytes were imported before.
    func storeDocument(_ data: Data, named fileName: String, mediaType: String, format: String, by author: Origin) throws -> ObjectRecord {
        let blob = try store.putBlob(data, mediaType: mediaType)
        if let existing = try store.objects(ofType: .document).first(where: { $0.string(TravelKey.blob) == blob.sha256 }) {
            return existing
        }
        return try store.create(
            ObjectRecord(
                type: .document, title: fileName,
                attributes: [
                    TravelKey.blob: Attribute(.string(blob.sha256)),
                    TravelKey.mediaType: Attribute(.string(mediaType)),
                    TravelKey.format: Attribute(.string(format)),
                    "byteCount": Attribute(.int(Int64(blob.byteCount))),
                ],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "\(format) import")
            ))
    }
}

extension Origin {
    var travelLabel: String {
        switch self {
        case .user(let id): "user:\(id)"
        case .agent(let id, _): "agent:\(id)"
        case .importer(let source): "importer:\(source)"
        case .simulation(let run): "simulation:\(run)"
        case .instrument(let id): "instrument:\(id)"
        case .model(let ref): "model:\(ref.provider)/\(ref.modelID)"
        case .system: "system"
        }
    }
}

import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTravel
import Testing

enum TravelFixtures {
    static let t0 = TravelCalendar.date(2026, 9, 1)

    /// A Lisbon offsite: two flights with a 35-minute connection, a hotel
    /// (all-day), and a train. Folded lines, escapes, a VTIMEZONE and a VALARM.
    static let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        PRODID:-//Nexus Tests//Trip//EN\r
        X-WR-CALNAME:Lisbon offsite\r
        BEGIN:VTIMEZONE\r
        TZID:America/Los_Angeles\r
        BEGIN:STANDARD\r
        DTSTART:19701101T020000\r
        TZOFFSETFROM:-0700\r
        TZOFFSETTO:-0800\r
        END:STANDARD\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        UID:flight-1@example.com\r
        SUMMARY:Flight UA 901 SFO → LHR\r
        DTSTART;TZID=America/Los_Angeles:20261005T163000\r
        DTEND:20261006T104500Z\r
        LOCATION:San Francisco International Airport\r
        DESCRIPTION:Confirmation: K7Q2LM\\nSeat 32A\\, window\r
        BEGIN:VALARM\r
        TRIGGER:-PT3H\r
        ACTION:DISPLAY\r
        DESCRIPTION:Leave for the airport\r
        END:VALARM\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:flight-2@example.com\r
        SUMMARY:Flight TP 1351 LHR-LIS\r
        DTSTART:20261006T112000Z\r
        DURATION:PT2H45M\r
        DESCRIPTION:Record locator K7Q2LM\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:hotel-1@example.com\r
        SUMMARY:Hotel: Memmo Alfama\r
        DTSTART;VALUE=DATE:20261006\r
        DTEND;VALUE=DATE:20261009\r
        LOCATION:Memmo Alfama\\, Lisbon\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:train-1@example.com\r
        SUMMARY:Train Lisbon to Porto\r
        DTSTART:20261009T090000Z\r
        DTEND:20261009T115000Z\r
        DESCRIPTION:Alfa Pendular\\, coa\r
         ch 4. Booking reference: CP88341\r
        END:VEVENT\r
        END:VCALENDAR\r

        """

    /// An IATA BCBP for UA901 SFO→LHR on day 278 (5 October), seat 32A.
    static var bcbp: String {
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
        return "M1" + pad("DOE/JANE", 20) + "E" + pad("K7Q2LM", 7) + "SFO" + "LHR" + pad("UA", 3) + pad("0901", 5) + "278" + "Y" + "032A"
            + pad("0042", 5) + "1" + "00"
    }
}

@Suite struct CalendarParsingTests {
    @Test func parsesEventsZonesDurationsAndEscapes() throws {
        let file = try ICalendar.parse(TravelFixtures.ics)
        #expect(file.name == "Lisbon offsite")
        #expect(file.events.count == 4, "The VALARM and VTIMEZONE are not events")
        let flight = file.events[0]
        #expect(flight.start == TravelCalendar.date(2026, 10, 5, 23, 30), "16:30 PDT is 23:30 UTC")
        #expect(flight.end == TravelCalendar.date(2026, 10, 6, 10, 45))
        #expect(flight.description == "Confirmation: K7Q2LM\nSeat 32A, window", "The alarm's DESCRIPTION is not the event's")
        #expect(file.events[1].end == TravelCalendar.date(2026, 10, 6, 14, 5))
        #expect(file.events[2].isAllDay && file.events[2].location == "Memmo Alfama, Lisbon")
        #expect(file.events[3].description == "Alfa Pendular, coach 4. Booking reference: CP88341", "Folded lines are joined")
    }

    @Test func durationsAndErrors() {
        #expect(ICalendar.duration("PT2H45M") == 9_900)
        #expect(ICalendar.duration("P1W") == 604_800)
        #expect(ICalendar.duration("P1DT1S") == 86_401)
        #expect(ICalendar.duration("-PT5M") == -300)
        #expect(ICalendar.duration("PT") == nil && ICalendar.duration("1H") == nil && ICalendar.duration("P1H") == nil)
        #expect(throws: TravelError.malformedCalendar(line: 1, reason: "missing BEGIN:VCALENDAR")) { try ICalendar.parse("hello") }
        #expect(throws: TravelError.unparsableDate("2026-13-01", line: 4)) {
            try ICalendar.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:x\nDTSTART:2026-13-01\nEND:VEVENT\nEND:VCALENDAR")
        }
        #expect(throws: TravelError.malformedCalendar(line: 2, reason: "unclosed VEVENT")) {
            try ICalendar.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\n")
        }
    }

    @Test func classifiesLegsFromWording() throws {
        let events = try ICalendar.parse(TravelFixtures.ics).events
        let drafts = events.map(LegClassifier.draft(from:))
        #expect(drafts.map(\.mode) == [.flight, .flight, .stay, .train])
        #expect(drafts[0].number == "UA901" && drafts[0].origin == "SFO" && drafts[0].destination == "LHR" && drafts[0].confirmation == "K7Q2LM")
        #expect(drafts[1].number == "TP1351" && drafts[1].origin == "LHR" && drafts[1].destination == "LIS")
        #expect(drafts[2].destination == "Memmo Alfama, Lisbon")
        #expect(drafts[3].origin == "Lisbon" && drafts[3].destination == "Porto" && drafts[3].confirmation == "CP88341")
        let drive = LegClassifier.route(in: "Drive from Porto to Braga, scenic")
        #expect(drive?.from == "Porto" && drive?.to == "Braga")
        #expect(LegClassifier.confirmation(in: "Booking for Smith") == nil, "A mixed-case word is not a code")
        #expect(LegClassifier.transportNumber(in: "Meet at 10 in room B2") == nil)
    }
}

@Suite struct BoardingPassTests {
    @Test func readsIATABarcode() throws {
        let pass = try BoardingPass.bcbp(TravelFixtures.bcbp, reference: TravelFixtures.t0)
        #expect(pass.passenger == "JANE DOE" && pass.confirmation == "K7Q2LM")
        #expect(pass.origin == "SFO" && pass.destination == "LHR" && pass.flight == "UA901" && pass.seat == "32A")
        #expect(pass.date == TravelCalendar.date(2026, 10, 5))
        // Early January reference: day 278 is last October, not next.
        #expect(try BoardingPass.bcbp(TravelFixtures.bcbp, reference: TravelCalendar.date(2027, 1, 3)).date == TravelCalendar.date(2026, 10, 5))
        #expect(throws: TravelError.malformedBoardingPass("not an IATA BCBP string")) { try BoardingPass.bcbp("M1SHORT", reference: .now) }
    }

    @Test func readsPassJSONFieldsWithoutABarcode() throws {
        let json = """
            {"formatVersion":1,"organizationName":"Rail Europe","relevantDate":"2026-10-09T09:00+00:00",
             "boardingPass":{"transitType":"PKTransitTypeTrain",
               "primaryFields":[{"key":"origin","value":"Lisbon"},{"key":"destination","value":"Porto"}],
               "auxiliaryFields":[{"key":"train","value":"AP 131"},{"key":"seat","value":"41"}]}}
            """
        let pass = try BoardingPass.passJSON(Data(json.utf8), reference: TravelFixtures.t0)
        #expect(pass.mode == .train && pass.origin == "Lisbon" && pass.destination == "Porto" && pass.flight == "AP131" && pass.seat == "41")
        #expect(pass.date == TravelCalendar.date(2026, 10, 9, 9))
    }
}

@Suite struct TravelImportTests {
    let person = Origin.user(id: "sam")

    func makeStore() throws -> (NexusStore, ItineraryImporter, ManualClock) {
        let clock = ManualClock(TravelFixtures.t0)
        let store = try NexusStore(.inMemory, clock: clock)
        return (store, ItineraryImporter(store: store, clock: clock), clock)
    }

    @Test func importsLegsAsRecordedWithDerivedModes() throws {
        let (store, importer, _) = try makeStore()
        let result = try importer.importICS(Data(TravelFixtures.ics.utf8), named: "lisbon.ics", by: person)
        #expect(result.trip.name == "Lisbon offsite" && result.created.count == 4)
        for leg in result.created {
            #expect(leg.record.provenance.truth == .recorded)
            #expect(leg.record.provenance.origin == .importer(source: result.document.id))
            #expect(leg.modeTruth == .derived, "The mode is a guess from wording")
        }
        let travel = TravelRuntime(store: store)
        let legs = try travel.legs(of: result.trip.id)
        #expect(legs.map(\.mode) == [.flight, .stay, .flight, .train], "By start: the all-day stay begins at midnight")
        #expect(try travel.bookings(of: result.trip.id).count == 2, "Both flights share one booking")
        #expect(try store.objects(ofType: .place).filter { $0.title == "LHR" }.count == 1, "Places are shared, not duplicated")
        let lhr = try #require(try store.objects(ofType: .place).first { $0.title == "LHR" })
        #expect(try store.relationships(to: lhr.id, kind: .arrivesAt).count == 1 && store.relationships(to: lhr.id, kind: .departsFrom).count == 1)
        #expect(try store.events(about: result.document.id).contains { $0.kind == .itineraryImported })
    }

    @Test func timelineShowsConnectionsAndConflicts() throws {
        let (store, importer, _) = try makeStore()
        let trip = try importer.importICS(Data(TravelFixtures.ics.utf8), named: "lisbon.ics", by: person).trip
        let travel = TravelRuntime(store: store)
        let timeline = try travel.timeline(of: trip.id)
        #expect(timeline.span == DateInterval(start: TravelCalendar.date(2026, 10, 5, 23, 30), end: TravelCalendar.date(2026, 10, 9, 11, 50)))
        let connections = timeline.entries.compactMap { if case .connection(_, _, let gap) = $0 { gap } else { nil } }
        #expect(connections == [TimeInterval(35 * 60)], "The train three days later is a new journey, not a connection")
        #expect(timeline.conflicts.map(\.kind) == [.tightConnection])
        #expect(timeline.conflicts.allSatisfy { $0.truth == .derived })

        // A person adds a drive that overlaps the train and leaves from elsewhere.
        try travel.addLeg(
            LegDraft(
                title: "Drive to Sintra", mode: .drive, start: TravelCalendar.date(2026, 10, 9, 11), end: TravelCalendar.date(2026, 10, 9, 12),
                origin: "Porto", destination: "Sintra"), to: trip.id, by: person)
        let kinds = Set(try travel.timeline(of: trip.id).conflicts.map(\.kind))
        #expect(kinds == [.tightConnection, .overlap])
        try travel.addLeg(
            LegDraft(
                title: "Drive home", mode: .drive, start: TravelCalendar.date(2026, 10, 9, 14), end: TravelCalendar.date(2026, 10, 9, 15), origin: "Lisbon"),
            to: trip.id, by: person)
        #expect(try travel.timeline(of: trip.id).conflicts.contains { $0.kind == .placeMismatch })
    }

    @Test func reimportIsIdempotentAndKeepsAPersonsCorrection() throws {
        let (store, importer, clock) = try makeStore()
        let first = try importer.importICS(Data(TravelFixtures.ics.utf8), named: "lisbon.ics", by: person)
        let again = try importer.importICS(Data(TravelFixtures.ics.utf8), named: "lisbon.ics", into: first.trip.id, by: person)
        #expect(again.created.isEmpty && again.updated.isEmpty && again.unchanged == 4)
        #expect(again.document.id == first.document.id, "Same bytes, same document")

        let travel = TravelRuntime(store: store, clock: clock)
        let train = try #require(first.created.first { $0.mode == .train })
        clock.advance(by: 60)
        let corrected = try travel.setMode(.drive, of: train.id, by: person)
        #expect(corrected.modeTruth == .observed)

        let moved = TravelFixtures.ics.replacingOccurrences(of: "DTSTART:20261009T090000Z", with: "DTSTART:20261009T100000Z")
        clock.advance(by: 60)
        let third = try importer.importICS(Data(moved.utf8), named: "lisbon-v2.ics", into: first.trip.id, by: person)
        #expect(third.created.isEmpty && third.updated.count == 1)
        let refreshed = try travel.leg(train.id)
        #expect(refreshed.start == TravelCalendar.date(2026, 10, 9, 10), "The file's new time is recorded")
        #expect(refreshed.mode == .drive && refreshed.modeTruth == .observed, "The import's guess does not replace a person's mode")
    }

    @Test func boardingPassAddsSeatToTheMatchingFlight() throws {
        let (store, importer, _) = try makeStore()
        let trip = try importer.importICS(Data(TravelFixtures.ics.utf8), named: "lisbon.ics", by: person).trip
        let result = try importer.importBoardingPass(Data(TravelFixtures.bcbp.utf8), named: "boarding.txt", into: trip.id, by: person)
        #expect(result.created.isEmpty && result.updated.count == 1)
        let flight = try #require(result.updated.first)
        #expect(flight.number == "UA901" && flight.seat == "32A")
        #expect(flight.record.truth(of: TravelKey.seat) == .recorded)
        #expect(try TravelRuntime(store: store).legs(of: trip.id).count == 4)

        // A pass for a flight not on any trip becomes a new trip.
        let other = TravelFixtures.bcbp.replacingOccurrences(of: "UA 0901", with: "BA 0283")
        let added = try importer.importBoardingPass(Data(other.utf8), named: "ba.txt", by: person)
        #expect(added.created.count == 1 && added.trip.name == "Trip to LHR" && added.created[0].number == "BA283")
    }
}

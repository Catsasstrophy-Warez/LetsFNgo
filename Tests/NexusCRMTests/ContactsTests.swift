import Foundation
import NexusCRM
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks
import Testing

enum ContactFixtures {
    static let today = Date(timeIntervalSince1970: 1_790_553_600)  // 2026-09-28 UTC

    /// Three versions and the awkward parts of each: groups, folding, escapes,
    /// 4.0 tel: URIs, 2.1 bare parameters and quoted-printable.
    static let vcf = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        N:Silva;Ana;;Dr.;\r
        FN:Ana Silva\r
        ORG:Harbor Automation;Controls\r
        TITLE:Lead Engineer\r
        item1.EMAIL;TYPE=INTERNET,WORK:ana.silva@harbor.example\r
        item1.X-ABLabel:work\r
        TEL;TYPE=CELL:+1 (555) 010-0100\r
        BDAY:1985-04-12\r
        NOTE:Met at the Lisbon offsite\\, loves PLCs.\\nPrefers email.\r
        CATEGORIES:Work,Controls\r
        UID:ana-0001\r
        END:VCARD\r
        BEGIN:VCARD\r
        VERSION:4.0\r
        FN:Bruno Costa\r
        N:Costa;Bruno;;;\r
        EMAIL;TYPE=home:bruno@example.org\r
        TEL;VALUE=uri;TYPE="voice,cell":tel:+351-912-000-111\r
        BDAY:--0704\r
        UID:urn:uuid:4fbe8971-0bc3-424c-9c26-36c3e1eff6b1\r
        NOTE:Long note that the exporter\r
          folded across two lines.\r
        END:VCARD\r
        BEGIN:VCARD\r
        VERSION:2.1\r
        N:Ferreira;Carla\r
        TEL;WORK;VOICE:+44 20 7946 0000\r
        NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:Caf=C3=A9 on Tuesdays =\r
        and Fridays\r
        END:VCARD\r
        BEGIN:VCARD\r
        VERSION:3.0\r
        PHOTO;ENCODING=b;TYPE=JPEG:AAAA\r
        END:VCARD\r

        """
}

@Suite struct VCardTests {
    @Test func parsesThreeVersions() throws {
        let cards = try VCard.parse(ContactFixtures.vcf)
        #expect(cards.count == 3, "A card with no name, email or organisation is skipped")
        let ana = cards[0]
        #expect(ana.formattedName == "Ana Silva" && ana.givenName == "Ana" && ana.familyName == "Silva")
        #expect(ana.organization == "Harbor Automation" && ana.department == "Controls" && ana.title == "Lead Engineer")
        #expect(ana.emails == ["ana.silva@harbor.example"] && ana.phones == ["+1 (555) 010-0100"])
        #expect(ana.birthday == "1985-04-12" && ana.uid == "ana-0001" && ana.categories == ["Work", "Controls"])
        #expect(ana.note == "Met at the Lisbon offsite, loves PLCs.\nPrefers email.")
        let bruno = cards[1]
        #expect(bruno.phones == ["+351-912-000-111"], "tel: URI stripped")
        #expect(bruno.birthday == "--07-04" && bruno.uid == "urn:uuid:4fbe8971-0bc3-424c-9c26-36c3e1eff6b1")
        #expect(bruno.note == "Long note that the exporter folded across two lines.")
        let carla = cards[2]
        #expect(carla.formattedName == "Carla Ferreira", "No FN: built from N")
        #expect(carla.phones == ["+44 20 7946 0000"])
        #expect(carla.note == "Café on Tuesdays and Fridays", "Quoted-printable with a soft break")
    }

    @Test func birthdaysAndErrors() {
        #expect(VCard.birthday("19850412") == "1985-04-12")
        #expect(VCard.birthday("1985-04-12T00:00:00Z") == "1985-04-12")
        #expect(VCard.birthday("--04-12") == "--04-12")
        #expect(VCard.birthday("April 12") == nil && VCard.birthday("1985-13-01") == nil)
        #expect(throws: ContactsError.malformedVCard(line: 1, reason: "card not closed with END:VCARD")) { try VCard.parse("BEGIN:VCARD\nFN:A\n") }
        #expect(throws: ContactsError.malformedVCard(line: 1, reason: "END:VCARD without BEGIN")) { try VCard.parse("END:VCARD") }
    }
}

@Suite struct ContactImportTests {
    let person = Origin.user(id: "sam")

    @Test func importsPeopleAndOrganisationsAsRecorded() throws {
        let clock = ManualClock(ContactFixtures.today)
        let store = try NexusStore(.inMemory, clock: clock)
        let importer = ContactImporter(store: store, clock: clock)
        let result = try importer.importVCards(Data(ContactFixtures.vcf.utf8), named: "contacts.vcf", by: person)
        #expect(result.created.count == 3 && result.merged.isEmpty)
        let ana = try #require(result.created.first)
        #expect(ana.record.type == .person && ana.record.provenance.truth == .recorded)
        #expect(ana.record.provenance.origin == .importer(source: result.source.id))
        #expect(try importer.contacts.organizations(of: ana.id).map(\.title) == ["Harbor Automation"])

        let again = try importer.importVCards(Data(ContactFixtures.vcf.utf8), named: "contacts.vcf", by: person)
        #expect(again.created.isEmpty && again.merged.isEmpty && again.unchanged == 3)
        #expect(try store.objects(ofType: .person).count == 3)
    }

    @Test func mergeAddsButNeverOverwritesAPersonsEntry() throws {
        let clock = ManualClock(ContactFixtures.today)
        let store = try NexusStore(.inMemory, clock: clock)
        let contacts = ContactsRuntime(store: store, clock: clock)
        let entered = try contacts.addPerson("Ana S.", emails: ["Ana.Silva@harbor.example"], by: person)
        try store.update(entered.id, by: person) {
            $0.attributes[ContactKey.jobTitle] = Attribute(.string("CTO"), provenance: Provenance(origin: person, truth: .observed, timestamp: clock.now()))
        }
        let result = try ContactImporter(store: store, clock: clock).importVCards(Data(ContactFixtures.vcf.utf8), named: "contacts.vcf", by: person)
        #expect(result.created.count == 2 && result.merged.count == 1, "Ana matched by email, ignoring case")
        let ana = try contacts.contact(entered.id)
        #expect(ana.name == "Ana S." && ana.jobTitle == "CTO", "The person's own entries stay")
        #expect(ana.record.truth(of: ContactKey.jobTitle) == .observed)
        #expect(ana.phones == ["+1 (555) 010-0100"] && ana.record.truth(of: ContactKey.phones) == .recorded)
        #expect(ana.birthday == "1985-04-12")
    }
}

@Suite struct CadenceTests {
    let person = Origin.user(id: "sam")

    func day(_ offset: Int) -> Date { ContactFixtures.today.addingTimeInterval(Double(offset) * 86_400) }

    @Test func lastContactedAndOverdueAreDerivedFromInteractions() throws {
        let clock = ManualClock(ContactFixtures.today)
        let store = try NexusStore(.inMemory, clock: clock)
        let contacts = ContactsRuntime(store: store, clock: clock)
        let ana = try contacts.addPerson("Ana Silva", organization: "Harbor Automation", by: person)
        let bruno = try contacts.addPerson("Bruno Costa", by: person)
        let carla = try contacts.addPerson("Carla Ferreira", by: person)
        let dora = try contacts.addPerson("Dora Lima", by: person)

        try contacts.logInteraction(with: [ana.id, bruno.id], channel: .meeting, at: day(-120), summary: "Kickoff", by: person)
        try contacts.logInteraction(with: [bruno.id], channel: .call, at: day(-10), summary: "Quick call", by: person)
        // An agent's inference is kept but never resets the clock.
        try contacts.logInteraction(with: [ana.id], channel: .email, at: day(-2), summary: "Probably replied", by: .agent(id: "writing", run: nil))
        try contacts.setCadence(30, for: carla.id, by: person)

        #expect(try contacts.lastContacted(ana.id) == day(-120))
        #expect(try contacts.lastContacted(bruno.id) == day(-10))
        #expect(try contacts.interactions(with: ana.id).count == 2)
        let standing = try contacts.standing(of: ana.id, asOf: ContactFixtures.today)
        #expect(standing.daysSince == 120 && standing.cadenceDays == 90 && standing.isOverdue && standing.daysOverdue == 30 && standing.truth == .derived)

        let overdue = try contacts.overdue(asOf: ContactFixtures.today)
        #expect(overdue.map(\.contact.name) == ["Ana Silva", "Carla Ferreira"], "Dora has no cadence and no history; Bruno is recent")
        #expect(!(try contacts.overdue(asOf: ContactFixtures.today).contains { $0.contact.id == dora.id }))
        #expect(throws: ContactsError.invalidCadence(0)) { try contacts.setCadence(0, for: dora.id, by: person) }
        #expect(throws: ContactsError.noPeople) { try contacts.logInteraction(with: [], channel: .call, summary: "x", by: person) }
        #expect(try store.events(about: ana.id).first { $0.kind == .interaction }?.provenance.truth == .observed)
    }

    @Test func overdueContactsGetOneFollowUpEach() throws {
        let clock = ManualClock(ContactFixtures.today)
        let store = try NexusStore(.inMemory, clock: clock)
        let contacts = ContactsRuntime(store: store, clock: clock)
        let ana = try contacts.addPerson("Ana Silva", by: person)
        try contacts.logInteraction(with: [ana.id], channel: .call, at: day(-100), summary: "Call", by: person)

        let tasks = try contacts.scheduleFollowUps(asOf: ContactFixtures.today, by: .system)
        #expect(tasks.map(\.title) == ["Catch up with Ana Silva (last contact 100 days ago)"] && tasks[0].dueAt == ContactFixtures.today)
        #expect(try contacts.scheduleFollowUps(asOf: ContactFixtures.today, by: .system).isEmpty, "Already has an open follow-up")
        #expect(try contacts.followUps(for: ana.id).count == 1)

        let draft = try contacts.addFollowUp(with: ana.id, by: .agent(id: "project", run: nil))
        #expect(draft.isDraft && draft.title == "Follow up with Ana Silva")
    }
}

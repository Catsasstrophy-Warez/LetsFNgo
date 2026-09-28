import Foundation
import NexusCommunications
import NexusCore
import NexusModel
import NexusPersistence
import Testing

@Suite struct CommunicationImportTests {
    let person = Origin.user(id: "sam")

    private func plant() throws -> (NexusStore, transmitter: ObjectID, pump: ObjectID) {
        let store = try NexusStore(.inMemory)
        let recorded = Provenance(origin: person, truth: .recorded, timestamp: Fixtures.t0)
        let transmitter = try store.create(
            ObjectRecord(
                type: .instrument, title: "Tank 1 level transmitter", attributes: ["tag": Attribute(.string("LT-101"))], provenance: recorded
            ))
        let pump = try store.create(ObjectRecord(type: .equipment, title: "Pump P-7", provenance: recorded))
        return (store, transmitter.id, pump.id)
    }

    @Test func emlBecomesThreadMessagePeopleAndAttachment() throws {
        let (store, transmitter, _) = try plant()
        let result = try CommunicationImporter(store: store, clock: FixedTestClock(Fixtures.t0))
            .importEML(Fixtures.loopReport, named: "loop.eml", by: person)
        #expect(result.messages.count == 1 && result.threads.count == 1 && result.duplicates.isEmpty)

        // The file itself is a document whose bytes are a blob.
        #expect(result.document.type == .document)
        guard case .string(let digest)? = result.document.attributes[CommsKey.blob]?.value else {
            Issue.record("no blob")
            return
        }
        #expect(try store.blobData(sha256: digest) == Fixtures.loopReport)

        let message = try #require(try store.object(result.messages[0]))
        #expect(message.type == .message && message.title == "LT-101 reads low — 4.0 mA at empty")
        #expect(message.provenance.truth == .recorded)
        #expect(message.provenance.origin == .importer(source: result.document.id))
        #expect(message.provenance.dependencies == [result.document.id])
        #expect(message.attributes[CommsKey.messageID]?.value == .string("loop-1@plant.example"))
        guard case .string(let html)? = message.attributes[CommsKey.htmlBlob]?.value else {
            Issue.record("no HTML blob")
            return
        }
        #expect(try store.blob(sha256: html)?.mediaType == "text/html")

        // People, by address; the sender is linked by `sent`, the rest by `addressedTo`.
        let people = try store.objects(ofType: .person)
        #expect(Set(people.map(\.title)) == ["Ruiz, Ana", "Ben Okafor", "Chloé Martin", "Ops desk"])
        let ana = try #require(people.first { $0.title == "Ruiz, Ana" })
        #expect(ana.attributes[CommsKey.email]?.value == .string("ana@plant.example"))
        #expect(try store.relationships(from: ana.id, kind: .sent).map(\.to) == [message.id])
        #expect(try store.relationships(from: message.id, kind: .addressedTo).count == 3)

        // The attachment is a document of its own.
        let attached = try store.relationships(to: message.id, kind: .attachedTo)
        let edge = try #require(attached.first)
        let pdf = try #require(try store.object(edge.from))
        #expect(pdf.title == "loop check – LT-101.pdf")
        #expect(pdf.attributes[CommsKey.mediaType]?.value == .string("application/pdf"))

        // LT-101 in the text links the message and its thread to the transmitter (derived).
        #expect(result.mentions.map(\.object) == [transmitter])
        let about = try #require(try store.relationships(from: message.id, kind: .about).first)
        #expect(about.to == transmitter && about.provenance.truth == .derived && about.provenance.method == "mentions LT-101")
        let library = CommunicationLibrary(store: store)
        #expect(try library.threads(about: transmitter).map(\.id) == result.threads)
        let thread = try #require(try library.thread(result.threads[0]))
        #expect(thread.messageCount == 1 && thread.participants.count == 4)
        #expect(try library.messages(in: thread.id).first?.attachments.map(\.id) == [pdf.id])

        #expect(try store.events(about: result.document.id).contains { $0.kind == .communicationImported })
    }

    @Test func reimportingAddsNothing() throws {
        let (store, _, _) = try plant()
        let importer = CommunicationImporter(store: store)
        try importer.importEML(Fixtures.loopReport, named: "loop.eml", by: person)
        let again = try importer.importEML(Fixtures.loopReport, named: "loop copy.eml", by: person)
        #expect(again.messages.isEmpty && again.duplicates == ["loop-1@plant.example"])
        #expect(try store.objects(ofType: .message).count == 1)
        #expect(try store.objects(ofType: .person).count == 4)
    }

    @Test func mboxThreadsRepliesAndLinksToAnObject() throws {
        let (store, _, pump) = try plant()
        let result = try CommunicationImporter(store: store).importFile(Fixtures.mailbox, named: "Inbox.mbox", about: [pump], by: person)
        #expect(result.messages.count == 3)
        #expect(result.threads.count == 2)
        let library = CommunicationLibrary(store: store)
        let seal = try #require(try library.threads(about: pump).first { $0.record.title == "Pump P-7 seal" })
        let messages = try library.messages(in: seal.id)
        #expect(messages.map(\.subject) == ["Pump P-7 seal", "Re: Pump P-7 seal"])
        #expect(messages[1].body == "Yes, two kits.\nFrom the stores list.")
        #expect(messages[1].from == ["Ben Okafor <ben@plant.example>"])
        // "about" set by the person on import is recorded, by them.
        let about = try #require(try store.relationships(from: seal.id, kind: .about).first { $0.to == pump })
        #expect(about.provenance.origin == person && about.provenance.truth == .recorded)

        // The message without a Message-ID dedups by its bytes.
        let again = try CommunicationImporter(store: store).importMBox(Fixtures.mailbox, named: "Inbox.mbox", by: person)
        #expect(again.messages.isEmpty && again.duplicates.count == 3)

        // A later reply that only shares the subject joins the thread.
        let reply = Data("Message-ID: <q-3@plant.example>\nFrom: ana@plant.example\nSubject: RE: pump p-7 seal\n\nThanks!\n".utf8)
        let joined = try CommunicationImporter(store: store).importEML(reply, named: "reply.eml", by: person)
        #expect(joined.threads == [seal.id])
        // Ana is the same person as before, found by address.
        #expect(try store.objects(ofType: .person).filter { $0.attributes[CommsKey.email]?.value == .string("ana@plant.example") }.count == 1)
    }

    @Test func mentionsByNexusIDAndNotByLooseText() throws {
        let (store, transmitter, pump) = try plant()
        let linker = MentionLinker(store: store)
        let found = try linker.mentions(in: ["See nexus://object/\(pump) and LT 101.", "Tank levels are fine; P-7 unrelated? 2026"])
        #expect(found.map(\.object) == [pump, transmitter])
        #expect(found.map(\.evidence) == [pump.description, "LT-101"])
        #expect(try linker.mentions(in: ["level transmitter"]).isEmpty)
    }

    @Test func emptyFilesAreRefused() throws {
        let (store, _, _) = try plant()
        #expect(throws: CommunicationError.empty("x.mbox")) {
            try CommunicationImporter(store: store).importMBox(Data("nothing".utf8), named: "x.mbox", by: person)
        }
        #expect(try store.objects(ofType: .document).isEmpty)
    }
}

struct FixedTestClock: NexusClock {
    let date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date { date }
}

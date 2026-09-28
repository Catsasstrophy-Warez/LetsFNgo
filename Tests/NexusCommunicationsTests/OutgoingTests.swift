import Foundation
import NexusCommunications
import NexusCore
import NexusModel
import NexusPersistence
import Testing

@Suite struct OutgoingTests {
    let person = Origin.user(id: "sam")

    @Test func draftPrefillsFromTheObjectAndRelatedPeople() throws {
        let store = try NexusStore(.inMemory)
        let recorded = Provenance(origin: person, truth: .recorded, timestamp: Fixtures.t0)
        let pump = try store.create(
            ObjectRecord(
                type: .equipment, title: "Pump P-7",
                attributes: [
                    "tag": Attribute(.string("P-7")), "notes": Attribute(.string("Seal weeps under load.")), "transcript": Attribute(.string("long")),
                ],
                provenance: recorded
            ))
        let ben = try store.create(
            ObjectRecord(
                type: .person, title: "Ben",
                attributes: [CommsKey.email: Attribute(.string("ben@plant.example")), CommsKey.phone: Attribute(.string("+15550100"))],
                provenance: recorded
            ))
        let motor = try store.create(ObjectRecord(type: .component, title: "Motor M-7", provenance: recorded))
        try store.relate(Relationship(kind: .connectedTo, from: ben.id, to: pump.id, provenance: recorded))
        try store.relate(Relationship(kind: .contains, from: pump.id, to: motor.id, provenance: recorded))

        let email = try CommunicationComposer.draft(about: pump.id, channel: .email, in: store)
        #expect(email.subject == "Pump P-7")
        #expect(email.recipients == ["ben@plant.example"])
        #expect(email.about == [pump.id])
        #expect(email.body.hasPrefix("Pump P-7 (equipment)\n\nSeal weeps under load.\n\n- tag: P-7"))
        #expect(email.body.contains("Related:\n- Motor M-7 (component)"))
        #expect(!email.body.contains("Ben (person)") && !email.body.contains("transcript"))
        #expect(email.body.hasSuffix("Nexus: nexus://object/\(pump.id)"))

        let text = try CommunicationComposer.draft(about: pump.id, channel: .textMessage, in: store)
        #expect(text.recipients == ["+15550100"])
    }

    @Test func draftForAnInvestigationUsesItsNewestReport() throws {
        let store = try NexusStore(.inMemory)
        let recorded = Provenance(origin: person, truth: .recorded, timestamp: Fixtures.t0)
        let investigation = try store.create(ObjectRecord(type: .investigation, title: "Low level reading", provenance: recorded))
        let report = try store.create(
            ObjectRecord(
                type: "report", title: "Report: Low level reading", attributes: ["body": Attribute(.string("# Findings\nLoop open at JB-3."))],
                provenance: Provenance(origin: person, truth: .derived, timestamp: Fixtures.t0)
            ))
        try store.relate(Relationship(kind: .produced, from: investigation.id, to: report.id, provenance: recorded))
        let draft = try CommunicationComposer.draft(about: investigation.id, channel: .email, in: store)
        #expect(draft.body.hasPrefix("# Findings\nLoop open at JB-3.\n\nNexus: nexus://object/"))
    }

    @Test func mailtoURLEncodesEverything() throws {
        let draft = OutgoingCommunication(
            channel: .email, recipients: ["a+b@x.io", "c@x.io"], subject: "LT-101 & you?", body: "Line 1\nLine 2 = 50%"
        )
        let url = try #require(CommunicationComposer.mailtoURL(draft))
        #expect(url.absoluteString == "mailto:a+b@x.io,c@x.io?subject=LT-101%20%26%20you%3F&body=Line%201%0D%0ALine%202%20%3D%2050%25")
    }

    @Test func recordingASentMessage() throws {
        let store = try NexusStore(.inMemory)
        let recorded = Provenance(origin: person, truth: .recorded, timestamp: Fixtures.t0)
        let pump = try store.create(ObjectRecord(type: .equipment, title: "Pump P-7", provenance: recorded))
        var draft = try CommunicationComposer.draft(about: pump.id, channel: .email, in: store)
        draft.recipients = ["Ben Okafor <ben@plant.example>"]
        let sent = try CommunicationComposer.recordSent(
            draft, method: "MFMailComposeViewController reported sent", in: store, by: person, at: Fixtures.t0
        )
        let message = try #require(try store.object(sent.message))
        #expect(message.provenance.truth == .recorded && message.provenance.method == "MFMailComposeViewController reported sent")
        #expect(message.attributes[CommsKey.direction]?.value == .string("outgoing"))
        let ben = try #require(try store.objects(ofType: .person).first)
        #expect(ben.title == "Ben Okafor" && ben.attributes[CommsKey.email]?.value == .string("ben@plant.example"))

        let library = CommunicationLibrary(store: store)
        let threads = try library.threads(about: pump.id)
        #expect(threads.map(\.id) == [sent.thread])
        #expect(try library.messages(in: sent.thread).map(\.isOutgoing) == [true])
        let event = try #require(try store.events(about: pump.id).first { $0.kind == .communicationSent })
        #expect(event.subjects.contains(sent.message) && event.provenance.origin == person)

        // A follow-up text in the same thread.
        let text = OutgoingCommunication(channel: .textMessage, recipients: ["+15550100"], subject: "Pump P-7", body: "Done", about: [pump.id])
        let second = try CommunicationComposer.recordSent(
            text, method: "MFMessageComposeViewController reported sent", thread: sent.thread, in: store, by: person, at: Fixtures.t0.addingTimeInterval(60))
        #expect(second.thread == sent.thread)
        #expect(try library.thread(sent.thread)?.messageCount == 2)
        #expect(try store.relationships(from: sent.thread, kind: .about).count == 1)
    }
}

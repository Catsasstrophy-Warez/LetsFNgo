import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import NexusTasks
import Testing
@testable import NexusMeetings

private let transcript = """
Dana: The loop reads 86.9 percent but the tank is overflowing.
Sam: According to the manual the transmitter needs 12 volts at the terminals.
Decision: replace the TB-4 terminal block this shift
Sam: I will pull a work order for TB-4.
Action: update the loop drawing
Dana: Do we have a spare terminal block?
Dana: ok
"""

@Suite struct NotePromotionTests {
    @Test func classifiesLinesConservatively() {
        let items = NotePromotion.extract(from: transcript)
        #expect(items.map(\.kind) == [.claim, .decision, .task, .task, .question])
        #expect(items[0].speaker == "Sam" && items[0].line == 1)
        #expect(items[1].text == "replace the TB-4 terminal block this shift" && items[1].speaker == nil)
        #expect(items[2].text == "I will pull a work order for TB-4.")
        #expect(items[3].text == "update the loop drawing")
    }

    @Test func promotionStoresTypedObjectsWithHonestTruth() throws {
        let store = try NexusStore(.inMemory)
        let author = Origin.user(id: "dana")
        let (meeting, items) = try NotePromotion.promote(transcript: transcript, title: "Shift huddle", in: store, by: author, at: Date())
        let records = try store.objects(items)
        #expect(records.map(\.type) == [.claim, .decision, .task, .task, .question])
        #expect(records[0].provenance.truth == .claimed)
        #expect(records[1].provenance.truth == .recorded)
        #expect(try store.claim(items[0])?.sources == [meeting])
        #expect(try store.relationships(from: meeting, kind: .produced).count == 5)
        #expect(try store.search("TB-4", types: [.decision]).map(\.id) == [items[1]])
    }

    @Test func tasksGoThroughTheTaskRuntime() throws {
        let store = try NexusStore(.inMemory)
        let author = Origin.user(id: "dana")
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (_, items) = try NotePromotion.promote(transcript: transcript, title: "Shift huddle", in: store, by: author, at: at)
        let runtime = TaskRuntime(store: store)
        let tasks = try [items[2], items[3]].map(runtime.task)
        #expect(tasks.map(\.status) == [.open, .open])
        #expect(tasks.allSatisfy { $0.lifecycle == .active && $0.record.provenance.timestamp == at })
        #expect(tasks[1].owner == author, "An action item without a first-person speaker belongs to the note's author")
        #expect(tasks[1].record.attributes["line"]?.value == .int(4))
        // The runtime's rules apply: done is a status transition with an event.
        try runtime.setStatus(.done, of: tasks[1].id, by: author)
        #expect(try store.events(about: tasks[1].id).map(\.kind).filter { $0 != .objectEdited } == [.taskStatusChanged])
    }

    @Test func participantsAttendAndCommitmentsHaveOwners() throws {
        let store = try NexusStore(.inMemory)
        let author = Origin.user(id: "dana")
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let existing = try store.create(ObjectRecord(
            type: .person, title: "Sam", provenance: Provenance(origin: author, truth: .recorded, timestamp: at)
        ))
        let promotion = try NotePromotion.promote(
            transcript: transcript, title: "Shift huddle", participants: ["Lee", "Dana"], in: store, by: author, at: at
        )
        #expect(NotePromotion.speakers(in: transcript) == ["Dana", "Sam"])
        #expect(Set(promotion.participants.keys) == ["Lee", "Dana", "Sam"])
        #expect(promotion.participants["Sam"] == existing.id, "An existing person is reused, not duplicated")
        #expect(try store.objects(ofType: .person).count == 3)
        let attendees = Set(try store.relationships(to: promotion.meeting, kind: .attended).map(\.from))
        #expect(attendees == Set(promotion.participants.values))

        #expect(promotion.commitments == [promotion.items[2]])
        let commitment = try TaskRuntime(store: store).task(promotion.items[2])
        #expect(commitment.owner == .user(id: "Sam"))
        #expect(commitment.record.attributes["commitment"]?.value == .bool(true))
        #expect(commitment.record.attributes["ownerPerson"]?.value == .reference(existing.id))
        #expect(try store.relationships(from: existing.id, kind: .created).map(\.to) == [commitment.id])
    }
}

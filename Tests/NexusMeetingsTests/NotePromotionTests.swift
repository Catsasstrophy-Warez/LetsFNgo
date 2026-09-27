import Foundation
import NexusCore
import NexusModel
import NexusPersistence
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
}

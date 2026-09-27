import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import Testing
@testable import NexusSearch

@Suite struct NameplateMatcherTests {
    @Test func extractsTagsAndSerialsFromOCRLines() {
        let tokens = NameplateMatcher.candidateTokens(in: ["Rosemount 3051 LT 101", "s/n 7K3X99812A", "range 0-100%", "fic_2001a"])
        #expect(tokens.contains("LT-101"))
        #expect(tokens.contains("FIC-2001A"))
        #expect(tokens.contains("7K3X99812A"))
        #expect(!tokens.contains("7K3X99812A-"))
    }

    @Test func exactTagOutranksPassingMentions() throws {
        let store = try NexusStore(.inMemory)
        let provenance = Provenance(origin: .user(id: "t"), truth: .recorded, timestamp: Date())
        let transmitter = try store.create(ObjectRecord(
            type: .sensor, title: "Level transmitter", attributes: ["tag": Attribute(.string("LT-101"))], provenance: provenance
        )).id
        let note = try store.create(ObjectRecord(
            type: .document, title: "Shift log", attributes: ["body": Attribute(.string("checked LT 101 today"))], provenance: provenance
        )).id
        let matcher = NameplateMatcher(engine: SearchEngine(store: store, graph: ObjectGraph(store: store)))
        let matches = try matcher.match(lines: ["ROSEMOUNT", "TAG LT-101"])
        #expect(matches.first?.object == transmitter)
        #expect(matches.first?.confidence == 0.95)
        #expect(matches.first?.evidence == "LT-101")
        #expect(matches.contains { $0.object == note && $0.confidence < 0.95 })
        #expect(try matcher.match(lines: ["nothing useful here"]).isEmpty)
    }
}

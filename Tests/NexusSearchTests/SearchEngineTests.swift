import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import Testing
@testable import NexusSearch

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

private func prov(_ truth: TruthClass = .recorded) -> Provenance {
    Provenance(origin: tech, truth: truth, timestamp: t0)
}

/// Returns a fixed list, standing in for an embedding index.
private struct StubSemanticIndex: SemanticIndex {
    var results: [ObjectID]
    func nearest(to text: String, limit: Int) throws -> [ObjectID] { Array(results.prefix(limit)) }
}

private struct World {
    let store: NexusStore
    let graph: ObjectGraph

    init() throws {
        store = try NexusStore(.inMemory)
        graph = ObjectGraph(store: store)
    }

    @discardableResult
    func make(_ title: String, _ type: ObjectType = .component, truth: TruthClass = .recorded, body: String? = nil) throws -> ObjectID {
        var attributes: [String: Attribute] = [:]
        if let body { attributes["body"] = Attribute(.string(body)) }
        return try store.create(ObjectRecord(type: type, title: title, attributes: attributes, provenance: prov(truth))).id
    }

    func contain(_ parent: ObjectID, _ child: ObjectID) throws {
        try store.relate(Relationship(kind: .contains, from: parent, to: child, provenance: prov()))
    }

    func engine(semantic: [ObjectID]? = nil) -> SearchEngine {
        SearchEngine(store: store, graph: graph, semantic: semantic.map { StubSemanticIndex(results: $0) })
    }
}

@Suite struct SearchEngineTests {
    @Test func exactIDAlwaysRanksFirst() throws {
        let world = try World()
        let target = try world.make("Pressure switch")
        try world.make("Note", body: "see \(target.description)")
        let results = try world.engine().search(SearchQuery(target.description))
        #expect(results.first?.id == target)
        #expect(results.first?.matchedBy == [.exactID])
    }

    @Test func exactTitleOutranksPartialMatches() throws {
        let world = try World()
        try world.make("LT-101 spare parts list", .document)
        try world.make("LT-101 calibration record", .document)
        let exact = try world.make("LT-101", .sensor)
        let results = try world.engine().search(SearchQuery("lt-101"))
        #expect(results.first?.id == exact)
        #expect(results.first?.matchedBy == [.exactTitle, .fullText])
        #expect(results.count == 3)
    }

    @Test func fusionRewardsAgreementBetweenRetrievers() throws {
        let world = try World()
        let both = try world.make("Loop compliance voltage check", .procedure)
        let textOnly = try world.make("Voltage drop worksheet", .document)
        let semanticOnly = try world.make("Transmitter lift-off explained", .document)
        let results = try world.engine(semantic: [semanticOnly, both]).search(SearchQuery("voltage"))
        #expect(results.first?.id == both)
        #expect(results.first?.matchedBy == [.fullText, .semantic])
        #expect(Set(results.map(\.id)) == [both, textOnly, semanticOnly])
    }

    @Test func semanticCandidatesObeyTheSameFilters() throws {
        let world = try World()
        let project = try world.make("Level loop project", .project)
        let member = try world.make("Terminal block TB-4", .component)
        let outsider = try world.make("Terminal block TB-9", .component)
        let draft = try world.make("Agent guess about TB-4", .component, truth: .agentInterpretation)
        try world.contain(project, member)
        try world.contain(project, draft)

        let engine = world.engine(semantic: [outsider, draft, member])
        let scoped = try engine.search(SearchQuery("terminal", scope: project))
        #expect(Set(scoped.map(\.id)) == [member, draft])

        let recordedOnly = try engine.search(SearchQuery("terminal", truth: [.recorded], scope: project))
        #expect(recordedOnly.map(\.id) == [member])

        let wrongType = try engine.search(SearchQuery("terminal", types: [.document]))
        #expect(wrongType.isEmpty)
    }

    @Test func scopeIncludesNestedContainment() throws {
        let world = try World()
        let project = try world.make("Plant", .project)
        let tank = try world.make("Tank T-1", .equipment)
        let valve = try world.make("Tank outlet valve", .component)
        try world.make("Tank T-2", .equipment)
        try world.contain(project, tank)
        try world.contain(tank, valve)
        let results = try world.engine().search(SearchQuery("tank", scope: project))
        #expect(Set(results.map(\.id)) == [tank, valve])
    }

    @Test func deletedObjectsBlankQueriesAndLimits() throws {
        let world = try World()
        let gone = try world.make("Obsolete pump")
        try world.store.update(gone, by: tech) { $0.lifecycle = .deleted }
        let engine = world.engine(semantic: [gone])
        #expect(try engine.search(SearchQuery("pump")).isEmpty)
        #expect(try engine.search(SearchQuery(gone.description)).isEmpty)
        #expect(try engine.search(SearchQuery("  ")).isEmpty)

        for index in 0..<5 {
            try world.make("Valve \(index)")
        }
        #expect(try engine.search(SearchQuery("valve", limit: 3)).count == 3)
    }
}

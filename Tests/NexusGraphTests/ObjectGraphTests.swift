import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import Testing
@testable import NexusGraph

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)

/// Loop topology: tank ⊃ transmitter → terminal → AI card → PID → valve → tank (a cycle).
private struct Loop {
    let store: NexusStore
    let clock = ManualClock(t0 + 100)
    let graph: ObjectGraph
    var ids: [String: ObjectID] = [:]

    init() throws {
        store = try NexusStore(.inMemory, clock: clock)
        graph = ObjectGraph(store: store, clock: clock)
        for name in ["tank", "transmitter", "terminal", "card", "pid", "valve"] {
            ids[name] = try store.create(ObjectRecord(type: .component, title: name, provenance: recorded)).id
        }
        try link("tank", .contains, "transmitter")
        for (from, to) in [("transmitter", "terminal"), ("terminal", "card"), ("card", "pid"), ("pid", "valve"), ("valve", "tank")] {
            try link(from, .connectedTo, to)
        }
    }

    subscript(name: String) -> ObjectID { ids[name]! }

    @discardableResult
    func link(_ from: String, _ kind: RelationKind, _ to: String, validFrom: Date? = nil) throws -> Relationship {
        try store.relate(Relationship(kind: kind, from: ids[from]!, to: ids[to]!, validFrom: validFrom, provenance: recorded))
    }
}

@Suite struct ObjectGraphTests {
    @Test func edgesRespectDirectionAndKind() throws {
        let loop = try Loop()
        let out = try loop.graph.edges(of: loop["tank"], direction: .outgoing)
        #expect(out.map(\.neighbor) == [loop["transmitter"]])
        #expect(out.first?.direction == .outgoing)

        let incoming = try loop.graph.edges(of: loop["tank"], direction: .incoming)
        #expect(incoming.map(\.neighbor) == [loop["valve"]])
        #expect(incoming.first?.direction == .incoming)

        #expect(try loop.graph.edges(of: loop["tank"], kinds: [.contains]).map(\.neighbor) == [loop["transmitter"]])
        #expect(try loop.graph.edges(of: loop["tank"]).count == 2)
    }

    @Test func traversalIsBreadthFirstCycleSafeAndDepthLimited() throws {
        let loop = try Loop()
        let reached = try loop.graph.traverse(from: loop["transmitter"], kinds: [.connectedTo])
        #expect(reached.map(\.id) == ["terminal", "card", "pid", "valve", "tank"].map { loop[$0] })
        #expect(reached.map(\.depth) == [1, 2, 3, 4, 5])
        #expect(reached.last?.path.map(\.neighbor) == ["terminal", "card", "pid", "valve", "tank"].map { loop[$0] })
        // Following every kind returns to the start through the tank; the start is never re-reported.
        #expect(!(try loop.graph.traverse(from: loop["transmitter"]).map(\.id).contains(loop["transmitter"])))
        #expect(try loop.graph.traverse(from: loop["transmitter"], maxDepth: 2).map(\.id) == [loop["terminal"], loop["card"]])
        #expect(try loop.graph.traverse(from: loop["transmitter"], maxDepth: 0).isEmpty)
    }

    @Test func shortestPathPrefersFewerHops() throws {
        let loop = try Loop()
        // Undirected: valve–tank–transmitter (2 hops) beats valve–pid–card–terminal–transmitter.
        let path = try #require(try loop.graph.shortestPath(from: loop["valve"], to: loop["transmitter"]))
        #expect(path.map(\.neighbor) == [loop["tank"], loop["transmitter"]])
        #expect(try loop.graph.shortestPath(from: loop["valve"], to: loop["valve"]) == [])
        #expect(try loop.graph.shortestPath(from: loop["valve"], to: loop["transmitter"], maxDepth: 1) == nil)

        let island = try loop.store.create(ObjectRecord(type: .component, title: "spare", provenance: recorded)).id
        #expect(try loop.graph.shortestPath(from: loop["valve"], to: island) == nil)
    }

    @Test func validityIntervalsControlWhatIsCurrent() throws {
        var loop = try Loop()
        loop.ids["bypass"] = try loop.store.create(ObjectRecord(type: .component, title: "bypass", provenance: recorded)).id
        let future = try loop.link("tank", .contains, "bypass", validFrom: t0 + 1_000)
        let installed = try loop.link("tank", .contains, "card")
        try loop.store.end(installed.id, at: t0 + 50, by: tech)

        let current = try loop.graph.edges(of: loop["tank"], kinds: [.contains]).map(\.neighbor)
        #expect(current == [loop["transmitter"]])
        let earlier = try loop.graph.edges(of: loop["tank"], kinds: [.contains], validity: .at(t0 + 10)).map(\.neighbor)
        #expect(Set(earlier) == [loop["transmitter"], loop["card"]])
        let everything = try loop.graph.edges(of: loop["tank"], kinds: [.contains], validity: .any)
        #expect(everything.count == 3)
        #expect(everything.contains { $0.relationship.id == future.id })

        loop.clock.advance(by: 2_000)
        #expect(Set(try loop.graph.edges(of: loop["tank"], kinds: [.contains]).map(\.neighbor)) == [loop["transmitter"], loop["bypass"]])
    }
}

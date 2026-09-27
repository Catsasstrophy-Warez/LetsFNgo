import Foundation
import NexusCore
import Testing

@testable import NexusVisualization

@Suite struct SankeyTests {
    @Test func flowsBecomeColumnsWithMergedLinksAndThroughput() throws {
        let diagram = try SankeyDiagram(
            flows: [
                Flow("Grid", "Heater", 5), Flow("Solar", "Heater", 2), Flow("Heater", "Tank", 7), Flow("Heater", "Losses", 1),
                Flow("Grid", "Heater", 1), Flow("Tank", "Process", 7), Flow("Grid", "Process", 0),
            ],
            unit: "kW"
        )
        #expect(diagram.columnCount == 4)
        #expect(diagram.node("Grid")?.column == 0)
        #expect(diagram.node("Heater")?.column == 1)
        #expect(diagram.node("Process")?.column == 3, "Longest path, not the zero-valued shortcut")
        #expect(diagram.node("Heater")?.inflow == 8, "Duplicate Grid→Heater flows are summed")
        #expect(diagram.node("Heater")?.imbalance == 0)
        #expect(diagram.node("Losses")?.imbalance == 1)
        #expect(diagram.links.count == 5)
        #expect(diagram.links.first?.source == "Grid", "Links are ordered by source column, then size")
    }

    @Test func cyclesAndBadFlowsAreRejected() {
        #expect(throws: VisualizationError.self) { try SankeyDiagram(flows: [Flow("A", "B", 1), Flow("B", "C", 1), Flow("C", "A", 1)], unit: "") }
        #expect(throws: VisualizationError.cyclicFlow(["A", "A"])) { try SankeyDiagram(flows: [Flow("A", "A", 1)], unit: "") }
        #expect(throws: VisualizationError.self) { try SankeyDiagram(flows: [Flow("A", "B", -1)], unit: "") }
        #expect(throws: VisualizationError.emptyInput) { try SankeyDiagram(flows: [], unit: "") }
    }
}

@Suite struct NetworkLayoutTests {
    let chain = ["supply", "terminal", "card", "controller"].map { NetworkNode(id: $0) }
    let chainEdges = [NetworkEdge("supply", "terminal"), NetworkEdge("terminal", "card"), NetworkEdge("card", "controller")]

    @Test func layeredLayoutPutsEachStepOfAPathOnItsOwnLayer() {
        let positions = NetworkLayout.layered(nodes: chain, edges: chainEdges)
        #expect(positions.count == 4)
        #expect(positions["supply"]?.y == 0)
        #expect(positions["controller"]?.y == 1)
        #expect(chain.map { positions[$0.id]!.y } == [0, 1.0 / 3, 2.0 / 3, 1])
    }

    @Test func layeredLayoutSurvivesCyclesAndOrdersByBarycentre() {
        let nodes = ["a", "b", "c", "x", "y"].map { NetworkNode(id: $0) }
        // x feeds c, y feeds a; barycentre ordering uncrosses the edges.
        let edges = [NetworkEdge("x", "c"), NetworkEdge("y", "a"), NetworkEdge("x", "b"), NetworkEdge("a", "y")]
        let positions = NetworkLayout.layered(nodes: nodes, edges: edges)
        #expect(positions.count == 5)
        #expect(positions.values.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        #expect(NetworkLayout.layered(nodes: nodes, edges: edges) == positions, "Deterministic")
    }

    @Test func forceLayoutIsDeterministicBoundedAndKeepsNeighboursClose() {
        let nodes = (0..<8).map { NetworkNode(id: "n\($0)") }
        // Two clusters joined by one bridge.
        let edges = [
            NetworkEdge("n0", "n1"), NetworkEdge("n1", "n2"), NetworkEdge("n2", "n0"), NetworkEdge("n3", "n0"),
            NetworkEdge("n4", "n5"), NetworkEdge("n5", "n6"), NetworkEdge("n6", "n4"), NetworkEdge("n7", "n4"), NetworkEdge("n2", "n5"),
        ]
        let a = NetworkLayout.force(nodes: nodes, edges: edges)
        let b = NetworkLayout.force(nodes: nodes, edges: edges)
        #expect(a == b)
        #expect(a.values.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        func distance(_ p: String, _ q: String) -> Double {
            let (u, v) = (a[p]!, a[q]!)
            return ((u.x - v.x) * (u.x - v.x) + (u.y - v.y) * (u.y - v.y)).squareRoot()
        }
        #expect(distance("n0", "n1") < distance("n0", "n6"))
        #expect(NetworkLayout.force(nodes: [NetworkNode(id: "solo")], edges: [])["solo"] == LayoutPoint(0.5, 0.5))
    }
}

@Suite struct StateGraphTests {
    @Test func eventsBecomeStatesWithDwellAndTransitionCounts() {
        let events = [
            StateEvent(time: 0, state: "Stopped"), StateEvent(time: 10, state: "Starting"), StateEvent(time: 12, state: "Running"),
            StateEvent(time: 15, state: "Running"),  // No change: merged.
            StateEvent(time: 40, state: "Tripped"), StateEvent(time: 45, state: "Stopped"), StateEvent(time: 50, state: "Starting"),
            StateEvent(time: 52, state: "Running"),
        ]
        var generator = FixedShuffle()
        let graph = StateGraph(events: events.shuffled(using: &generator), end: 60)
        #expect(graph.sequence.map(\.state) == ["Stopped", "Starting", "Running", "Tripped", "Stopped", "Starting", "Running"])
        #expect(graph.states.map(\.name) == ["Stopped", "Starting", "Running", "Tripped"])
        let running = graph.states.first { $0.name == "Running" }!
        #expect(running.entries == 2)
        #expect(running.dwell == 28 + 8)
        let total = graph.states.map(\.dwell).reduce(0, +)
        #expect(total == 60)
        #expect(graph.transitions.first { $0.from == "Starting" && $0.to == "Running" }?.count == 2)
        #expect(graph.transitions.count == 4)
        #expect(graph.finalState == "Running")
    }

    @Test func numericSeriesMapToStateEvents() {
        let points = [DataPoint(0, 0), DataPoint(1, 1), DataPoint(2, 1), DataPoint(3, 0), DataPoint(4, 7)]
        let events = StateGraph.events(from: points) { value in [0: "Closed", 1: "Open"][value] }
        let graph = StateGraph(events: events)
        #expect(graph.sequence.map(\.state) == ["Closed", "Open", "Closed"])
        #expect(graph.transitions.map(\.count) == [1, 1])
    }
}

/// A deterministic RandomNumberGenerator for shuffles in tests.
struct FixedShuffle: RandomNumberGenerator {
    var state: UInt64 = 42

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

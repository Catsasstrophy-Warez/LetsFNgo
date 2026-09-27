import Foundation

/// One flow from a source node to a target node: "3.2 kW from Heater to Tank".
public struct Flow: Codable, Sendable, Hashable {
    public var source: String
    public var target: String
    public var value: Double

    public init(_ source: String, _ target: String, _ value: Double) {
        self.source = source
        self.target = target
        self.value = value
    }
}

/// A Sankey layout: nodes placed in columns by their depth from the sources,
/// with each node's throughput.
public struct SankeyDiagram: Codable, Sendable, Hashable {
    public struct Node: Codable, Sendable, Hashable {
        public var id: String
        /// 0 for pure sources, increasing downstream (longest path from a source).
        public var column: Int
        public var inflow: Double
        public var outflow: Double
        /// Node height: the larger of inflow and outflow.
        public var value: Double { max(inflow, outflow) }
        /// Inflow not passed on (a sink or a loss), for conservation checks.
        public var imbalance: Double { inflow - outflow }
    }

    public var nodes: [Node]
    /// Merged flows (duplicates summed), sorted by source column then value.
    public var links: [Flow]
    public var unit: String

    public var columnCount: Int { (nodes.map(\.column).max() ?? -1) + 1 }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// Builds a diagram from flows. Duplicate source→target flows are summed;
    /// zero flows are dropped; negative flows and self-loops are rejected;
    /// cycles throw `VisualizationError.cyclicFlow`.
    public init(flows: [Flow], unit: String) throws {
        var merged: [String: [String: Double]] = [:]
        var order: [String] = []
        var seen: Set<String> = []
        func note(_ id: String) {
            if seen.insert(id).inserted { order.append(id) }
        }
        for flow in flows {
            guard flow.value.isFinite, flow.value >= 0 else { throw VisualizationError.invalidParameter("flow \(flow.source)→\(flow.target)") }
            guard flow.source != flow.target else { throw VisualizationError.cyclicFlow([flow.source, flow.target]) }
            note(flow.source)
            note(flow.target)
            guard flow.value > 0 else { continue }
            merged[flow.source, default: [:]][flow.target, default: 0] += flow.value
        }
        guard !order.isEmpty else { throw VisualizationError.emptyInput }

        // Longest-path depth by DFS, detecting cycles on the way.
        var depth: [String: Int] = [:]
        var visiting: [String] = []
        var predecessors: [String: [String]] = [:]
        for (source, targets) in merged {
            for target in targets.keys { predecessors[target, default: []].append(source) }
        }
        func resolve(_ id: String) throws -> Int {
            if let known = depth[id] { return known }
            if let start = visiting.firstIndex(of: id) {
                throw VisualizationError.cyclicFlow(Array(visiting[start...]) + [id])
            }
            visiting.append(id)
            var result = 0
            for predecessor in (predecessors[id] ?? []).sorted() {
                result = max(result, try resolve(predecessor) + 1)
            }
            visiting.removeLast()
            depth[id] = result
            return result
        }

        var nodes: [Node] = []
        for id in order {
            let inflow = merged.values.reduce(0) { $0 + ($1[id] ?? 0) }
            let outflow = merged[id]?.values.reduce(0, +) ?? 0
            nodes.append(Node(id: id, column: try resolve(id), inflow: inflow, outflow: outflow))
        }
        var links: [Flow] = []
        for (source, targets) in merged {
            for (target, value) in targets { links.append(Flow(source, target, value)) }
        }
        links.sort { lhs, rhs in
            let (l, r) = (depth[lhs.source] ?? 0, depth[rhs.source] ?? 0)
            if l != r { return l < r }
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return (lhs.source, lhs.target) < (rhs.source, rhs.target)
        }
        self.nodes = nodes
        self.links = links
        self.unit = unit
    }
}

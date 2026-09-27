import Foundation

public struct NetworkNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var group: String?

    public init(id: String, label: String? = nil, group: String? = nil) {
        self.id = id
        self.label = label ?? id
        self.group = group
    }
}

public struct NetworkEdge: Codable, Sendable, Hashable {
    public var from: String
    public var to: String
    public var label: String?

    public init(_ from: String, _ to: String, label: String? = nil) {
        self.from = from
        self.to = to
        self.label = label
    }
}

public struct LayoutPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Deterministic graph layouts in a unit square (0...1 on both axes). The
/// same graph always lays out the same way, so screenshots, tests and
/// people's spatial memory stay stable.
public enum NetworkLayout {
    /// Layered (Sugiyama-style) layout for directed graphs such as signal
    /// paths: longest-path layering top to bottom, then barycentre ordering
    /// within layers. Back edges of cycles are ignored for layering.
    public static func layered(nodes: [NetworkNode], edges: [NetworkEdge], sweeps: Int = 4) -> [String: LayoutPoint] {
        let ids = nodes.map(\.id)
        guard !ids.isEmpty else { return [:] }
        let known = Set(ids)
        let usable = edges.filter { known.contains($0.from) && known.contains($0.to) && $0.from != $0.to }
        let forward = acyclic(ids: ids, edges: usable)

        var incoming: [String: [String]] = [:]
        var outgoing: [String: [String]] = [:]
        for edge in forward {
            incoming[edge.to, default: []].append(edge.from)
            outgoing[edge.from, default: []].append(edge.to)
        }

        // Longest-path layering in topological order.
        var layer: [String: Int] = [:]
        var remaining = Dictionary(uniqueKeysWithValues: ids.map { ($0, incoming[$0]?.count ?? 0) })
        var queue = ids.filter { remaining[$0] == 0 }
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]
            cursor += 1
            let depth = (incoming[id] ?? []).map { (layer[$0] ?? 0) + 1 }.max() ?? 0
            layer[id] = depth
            for next in outgoing[id] ?? [] {
                remaining[next, default: 0] -= 1
                if remaining[next] == 0 { queue.append(next) }
            }
        }

        let layerCount = (layer.values.max() ?? 0) + 1
        var layers = [[String]](repeating: [], count: layerCount)
        for id in ids { layers[layer[id] ?? 0].append(id) }

        // Barycentre sweeps: down using parents, then up using children.
        func position(_ layers: [[String]]) -> [String: Double] {
            var result: [String: Double] = [:]
            for row in layers {
                for (index, id) in row.enumerated() { result[id] = Double(index) }
            }
            return result
        }
        for sweep in 0..<max(0, sweeps) {
            let down = sweep % 2 == 0
            let order = down ? Array(1..<max(1, layerCount)) : Array((0..<max(0, layerCount - 1)).reversed())
            for index in order {
                let current = position(layers)
                let neighbours = down ? incoming : outgoing
                layers[index] = layers[index].enumerated().map { offset, id -> (String, Double, Int) in
                    let adjacent = (neighbours[id] ?? []).compactMap { current[$0] }
                    let centre = adjacent.isEmpty ? Double(offset) : adjacent.reduce(0, +) / Double(adjacent.count)
                    return (id, centre, offset)
                }
                .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
                .map(\.0)
            }
        }

        var result: [String: LayoutPoint] = [:]
        for (depth, row) in layers.enumerated() {
            let y = layerCount == 1 ? 0.5 : Double(depth) / Double(layerCount - 1)
            for (index, id) in row.enumerated() {
                result[id] = LayoutPoint(Double(index + 1) / Double(row.count + 1), y)
            }
        }
        return result
    }

    /// Fruchterman–Reingold force-directed layout from a fixed circular start,
    /// with a linearly cooling temperature. Deterministic: no randomness.
    public static func force(nodes: [NetworkNode], edges: [NetworkEdge], iterations: Int = 200) -> [String: LayoutPoint] {
        let ids = nodes.map(\.id)
        let n = ids.count
        guard n > 0 else { return [:] }
        guard n > 1 else { return [ids[0]: LayoutPoint(0.5, 0.5)] }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.from], let b = index[edge.to], a != b else { return nil }
            return (a, b)
        }

        var x = (0..<n).map { 0.5 + 0.4 * cos(2 * Double.pi * Double($0) / Double(n)) }
        var y = (0..<n).map { 0.5 + 0.4 * sin(2 * Double.pi * Double($0) / Double(n)) }
        let k = (1.0 / Double(n)).squareRoot()
        let steps = max(1, iterations)
        for step in 0..<steps {
            let temperature = 0.1 * (1 - Double(step) / Double(steps))
            var dx = [Double](repeating: 0, count: n)
            var dy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = x[i] - x[j]
                    var ddy = y[i] - y[j]
                    var distance = (ddx * ddx + ddy * ddy).squareRoot()
                    if distance < 1e-9 {
                        // Coincident nodes: separate along a fixed direction.
                        ddx = 1e-3 * Double(j - i)
                        ddy = 0
                        distance = abs(ddx)
                    }
                    let repulse = k * k / distance
                    dx[i] += ddx / distance * repulse
                    dy[i] += ddy / distance * repulse
                    dx[j] -= ddx / distance * repulse
                    dy[j] -= ddy / distance * repulse
                }
            }
            for (a, b) in links {
                let ddx = x[a] - x[b]
                let ddy = y[a] - y[b]
                let distance = max(1e-9, (ddx * ddx + ddy * ddy).squareRoot())
                let attract = distance * distance / k
                dx[a] -= ddx / distance * attract
                dy[a] -= ddy / distance * attract
                dx[b] += ddx / distance * attract
                dy[b] += ddy / distance * attract
            }
            for i in 0..<n {
                let length = max(1e-9, (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot())
                let move = min(length, temperature)
                x[i] += dx[i] / length * move
                y[i] += dy[i] / length * move
            }
        }

        // Normalise into the unit square with a small margin.
        let (minX, maxX) = (x.min()!, x.max()!)
        let (minY, maxY) = (y.min()!, y.max()!)
        func scale(_ value: Double, _ low: Double, _ high: Double) -> Double {
            high - low < 1e-12 ? 0.5 : 0.05 + 0.9 * (value - low) / (high - low)
        }
        var result: [String: LayoutPoint] = [:]
        for (i, id) in ids.enumerated() {
            result[id] = LayoutPoint(scale(x[i], minX, maxX), scale(y[i], minY, maxY))
        }
        return result
    }

    /// Edges with back edges (those closing a cycle in a DFS from nodes in
    /// input order) removed.
    private static func acyclic(ids: [String], edges: [NetworkEdge]) -> [NetworkEdge] {
        var adjacency: [String: [NetworkEdge]] = [:]
        for edge in edges { adjacency[edge.from, default: []].append(edge) }
        var state: [String: Int] = [:]  // 1 visiting, 2 done
        var kept: [NetworkEdge] = []
        func visit(_ id: String) {
            state[id] = 1
            for edge in adjacency[id] ?? [] {
                switch state[edge.to] {
                case 1: continue  // Back edge.
                case 2: kept.append(edge)
                default:
                    kept.append(edge)
                    visit(edge.to)
                }
            }
            state[id] = 2
        }
        for id in ids where state[id] == nil { visit(id) }
        return kept
    }
}

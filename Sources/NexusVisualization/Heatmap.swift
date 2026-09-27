import Foundation

/// A 2D grid of cell values, rows along y and columns along x.
public struct HeatmapGrid: Codable, Sendable, Hashable {
    public enum Aggregate: String, Codable, Sendable, Hashable {
        /// Number of points in each cell.
        case count
        /// Mean of the points' z values; empty cells are nil.
        case mean
        /// Largest z value; empty cells are nil.
        case max
    }

    public var xEdges: [Double]
    public var yEdges: [Double]
    /// `cells[row][column]`, row = y bin, column = x bin. Nil marks an empty
    /// cell under `.mean` or `.max`, which has no value rather than zero.
    public var cells: [[Double?]]
    public var aggregate: Aggregate
    /// Points outside the ranges or non-finite, reported rather than dropped silently.
    public var excluded: Int

    public var columns: Int { xEdges.count - 1 }
    public var rows: Int { yEdges.count - 1 }

    /// Bins (x, y, z) points into `xBins` × `yBins` cells. With `.count`, z is
    /// ignored. Ranges default to the finite data's extent.
    public static func bin(
        x: [Double], y: [Double], z: [Double]? = nil, xBins: Int, yBins: Int,
        xRange: ClosedRange<Double>? = nil, yRange: ClosedRange<Double>? = nil, aggregate: Aggregate = .count
    ) throws -> HeatmapGrid {
        guard x.count == y.count, z.map({ $0.count == x.count }) ?? true else { throw VisualizationError.invalidParameter("lengths") }
        guard xBins > 0 else { throw VisualizationError.invalidParameter("xBins") }
        guard yBins > 0 else { throw VisualizationError.invalidParameter("yBins") }
        if aggregate != .count, z == nil { throw VisualizationError.invalidParameter("z") }
        guard let xr = xRange ?? extent(x), let yr = yRange ?? extent(y) else { throw VisualizationError.emptyInput }

        let xEdges = edges(xr, xBins)
        let yEdges = edges(yr, yBins)
        var sums = [[Double]](repeating: [Double](repeating: 0, count: xBins), count: yBins)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: xBins), count: yBins)
        var maxima = [[Double]](repeating: [Double](repeating: -.infinity, count: xBins), count: yBins)
        var excluded = 0

        for index in x.indices {
            let px = x[index]
            let py = y[index]
            let pz = z?[index] ?? 1
            guard px.isFinite, py.isFinite, pz.isFinite,
                let column = cell(px, xEdges), let row = cell(py, yEdges)
            else {
                excluded += 1
                continue
            }
            counts[row][column] += 1
            sums[row][column] += pz
            maxima[row][column] = Swift.max(maxima[row][column], pz)
        }

        let cells: [[Double?]] = (0..<yBins).map { row in
            (0..<xBins).map { column in
                let n = counts[row][column]
                switch aggregate {
                case .count: return Double(n)
                case .mean: return n == 0 ? nil : sums[row][column] / Double(n)
                case .max: return n == 0 ? nil : maxima[row][column]
                }
            }
        }
        return HeatmapGrid(xEdges: xEdges, yEdges: yEdges, cells: cells, aggregate: aggregate, excluded: excluded)
    }

    private static func extent(_ values: [Double]) -> ClosedRange<Double>? {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        return low...(high > low ? high : low + 1)
    }

    private static func edges(_ range: ClosedRange<Double>, _ bins: Int) -> [Double] {
        let width = (range.upperBound - range.lowerBound) / Double(bins)
        return (0...bins).map { $0 == bins ? range.upperBound : range.lowerBound + Double($0) * width }
    }

    /// The bin holding `value`; the last bin is closed.
    private static func cell(_ value: Double, _ edges: [Double]) -> Int? {
        guard let first = edges.first, let last = edges.last, value >= first, value <= last, last > first else { return nil }
        let bins = edges.count - 1
        return Swift.min(bins - 1, Int((value - first) / (last - first) * Double(bins)))
    }
}

import Foundation

/// Counts of values in equal-width bins over `[lowerBound, upperBound]`.
/// The last bin is closed so the maximum value is counted.
public struct Histogram: Codable, Sendable, Hashable {
    /// `binCount + 1` ascending edges.
    public var edges: [Double]
    public var counts: [Int]
    /// Values below the first edge or above the last, and non-finite values,
    /// are counted here rather than silently dropped.
    public var underflow: Int
    public var overflow: Int
    public var nonFinite: Int

    public var binCount: Int { counts.count }
    public var total: Int { counts.reduce(0, +) }
    public var binWidth: Double { edges.count > 1 ? edges[1] - edges[0] : 0 }

    /// Bin centres, for plotting.
    public var centers: [Double] {
        zip(edges, edges.dropFirst()).map { ($0 + $1) / 2 }
    }

    /// Bins `values`. With no `range`, the bins span the finite data exactly.
    /// With no `binCount`, Sturges' rule picks one (⌈log2 n⌉ + 1).
    public static func bin(_ values: [Double], binCount: Int? = nil, range: ClosedRange<Double>? = nil) throws -> Histogram {
        let finite = values.filter(\.isFinite)
        guard let low = range?.lowerBound ?? finite.min(), let high = range?.upperBound ?? finite.max() else {
            throw VisualizationError.emptyInput
        }
        let bins = binCount ?? max(1, Int(ceil(log2(Double(max(1, finite.count))))) + 1)
        guard bins > 0 else { throw VisualizationError.invalidParameter("binCount") }
        // A single distinct value still gets a bin of non-zero width.
        let span = high > low ? high - low : 1
        let lower = low
        let upper = high > low ? high : low + span
        let width = span / Double(bins)
        let edges = (0...bins).map { $0 == bins ? upper : lower + Double($0) * width }

        var counts = [Int](repeating: 0, count: bins)
        var underflow = 0
        var overflow = 0
        for value in finite {
            if value < lower {
                underflow += 1
            } else if value > upper {
                overflow += 1
            } else {
                let index = min(bins - 1, Int((value - lower) / width))
                counts[index] += 1
            }
        }
        return Histogram(edges: edges, counts: counts, underflow: underflow, overflow: overflow, nonFinite: values.count - finite.count)
    }
}

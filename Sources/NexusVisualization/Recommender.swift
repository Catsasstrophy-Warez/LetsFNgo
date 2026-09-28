import Foundation

/// What is being visualized, beyond plain series.
public struct DataProfile: Sendable, Hashable {
    public var series: [SeriesSpec]
    /// Labels for categorical comparisons (per-machine totals…); empty if none.
    public var categories: [String]
    public var hasFlows: Bool
    public var hasGraph: Bool
    public var hasGeography: Bool
    /// Values attach to objects that exist in a 3D scene or twin.
    public var hasSpatialAnchors: Bool
    public var hasStateEvents: Bool
    /// Known scale for a single value (enables a gauge).
    public var valueRange: ClosedRange<Double>?

    public init(
        series: [SeriesSpec] = [], categories: [String] = [], hasFlows: Bool = false, hasGraph: Bool = false, hasGeography: Bool = false,
        hasSpatialAnchors: Bool = false, hasStateEvents: Bool = false, valueRange: ClosedRange<Double>? = nil
    ) {
        self.series = series
        self.categories = categories
        self.hasFlows = hasFlows
        self.hasGraph = hasGraph
        self.hasGeography = hasGeography
        self.hasSpatialAnchors = hasSpatialAnchors
        self.hasStateEvents = hasStateEvents
        self.valueRange = valueRange
    }
}

public struct Recommendation: Sendable, Hashable {
    public var kind: VisualizationKind
    /// 0...1; higher is a better fit.
    public var score: Double
    /// Why, in words a person can check.
    public var reason: String
}

/// Picks sensible kinds for the data at hand. Rules, not a model: every
/// choice comes with a reason. A table is always offered last, since every
/// visualization must have one.
public enum VisualizationRecommender {
    /// Series whose sampling is at least this fast (Hz) are waveforms: scope and spectrum apply.
    public static let waveformRate = 100.0
    /// Series with at most this many distinct integer values look like states.
    public static let maxStateValues = 8

    public static func recommend(_ profile: DataProfile, mode: DensityMode = .technician) -> [Recommendation] {
        var picks: [Recommendation] = []
        func add(_ kind: VisualizationKind, _ score: Double, _ reason: String) {
            picks.append(Recommendation(kind: kind, score: score, reason: reason))
        }

        let series = profile.series.filter { !$0.points.isEmpty }
        let units = Set(series.map(\.unit))
        if series.count == 1, let only = series.first {
            let shape = SeriesShape(only)
            if only.points.count == 1 {
                add(.value, 0.95, "One current value.")
                if profile.valueRange != nil { add(.gauge, 0.85, "One value with a known scale.") }
            } else if shape.isStateLike {
                add(.stateGraph, 0.9, "\(only.name) takes a few discrete values, like states.")
                add(.timeline, 0.8, "Shows when each state began.")
                add(.line, 0.5, "Trend of the raw values.")
            } else {
                add(.line, 0.9, "\(only.name) changes over time.")
                add(.value, 0.6, "The latest reading.")
                if profile.valueRange != nil { add(.gauge, 0.55, "The latest reading against its scale.") }
                if shape.isWaveform {
                    add(.scope, 0.85, "Sampled at \(Int(shape.sampleRate ?? 0)) Hz: a waveform.")
                    add(.spectrum, 0.8, "A waveform's frequency content.")
                }
                if only.points.count >= 30 { add(.histogram, 0.5, "Distribution of \(only.points.count) readings.") }
            }
        } else if series.count > 1 {
            if series.count > 6 {
                add(.heatmap, 0.8, "\(series.count) series are easier to compare as rows of a heatmap.")
                add(.line, 0.6, "Overlaid trends.")
            } else {
                add(.line, 0.9, "\(series.count) series over time\(units.count > 1 ? " on \(units.count) axes" : "").")
                if units.count == 1 { add(.area, 0.5, "Same unit: parts of a whole can stack.") }
            }
            if series.count == 2, units.count == 2 { add(.scatter, 0.65, "Two quantities: does one follow the other?") }
            if series.allSatisfy({ SeriesShape($0).isWaveform }) { add(.scope, 0.8, "Several waveforms on one time base.") }
        }

        if !profile.categories.isEmpty { add(.bar, 0.9, "Compare \(profile.categories.count) categories.") }
        if profile.hasFlows {
            add(.sankey, 0.9, "Quantities flowing between parts.")
            add(.network, 0.5, "The same flows as connections.")
        }
        if profile.hasGraph { add(.network, 0.9, "Connections between objects.") }
        if profile.hasGeography { add(.map, 0.95, "Values have locations.") }
        if profile.hasSpatialAnchors { add(.threeDOverlay, 0.9, "Values belong to objects in the 3D view.") }
        if profile.hasStateEvents {
            add(.stateGraph, 0.9, "State changes and how often each happens.")
            add(.timeline, 0.85, "When each change happened.")
        }
        add(.table, 0.3, "The data as a table.")

        let policy = DensityPolicy.for(mode)
        var best: [VisualizationKind: Recommendation] = [:]
        for pick in picks where policy.allows(pick.kind) {
            if pick.score > best[pick.kind]?.score ?? -1 { best[pick.kind] = pick }
        }
        return best.values.sorted { ($0.score, $1.kind.rawValue) > ($1.score, $0.kind.rawValue) }
    }
}

/// Measured properties of one series.
struct SeriesShape {
    var sampleRate: Double?
    var isStateLike: Bool
    var isWaveform: Bool

    init(_ series: SeriesSpec) {
        let points = series.points
        // Median spacing is robust to gaps.
        let gaps = zip(points, points.dropFirst()).map { $1.x - $0.x }.filter { $0 > 0 }.sorted()
        let median = gaps.isEmpty ? nil : gaps[gaps.count / 2]
        sampleRate = median.map { 1 / $0 }
        var distinct: Set<Double> = []
        var allIntegers = true
        for point in points {
            if point.y != point.y.rounded() { allIntegers = false }
            distinct.insert(point.y)
            if distinct.count > VisualizationRecommender.maxStateValues { break }
        }
        isStateLike = points.count > 1 && allIntegers && distinct.count <= VisualizationRecommender.maxStateValues
        isWaveform = !isStateLike && points.count >= 64 && (sampleRate ?? 0) >= VisualizationRecommender.waveformRate
    }
}

import Foundation
import NexusCore

// One Sendable spec per kind. Everything a renderer needs is here; nothing
// here renders. SwiftUI/Charts and Metal renderers live in Apple-only targets.

/// A single current value: "Level 72.4 %".
public struct ValueSpec: Codable, Sendable, Hashable {
    public var series: SeriesSpec
    public var thresholds: [Threshold]
    public var bands: [Band]

    public init(series: SeriesSpec, thresholds: [Threshold] = [], bands: [Band] = []) {
        self.series = series
        self.thresholds = thresholds
        self.bands = bands
    }

    public var value: Double? { series.latest?.y }
    public var status: Severity { value.map { severity(of: $0, thresholds: thresholds, bands: bands) } ?? .normal }
}

/// A value against a scale with zones.
public struct GaugeSpec: Codable, Sendable, Hashable {
    public var series: SeriesSpec
    public var minimum: Double
    public var maximum: Double
    public var thresholds: [Threshold]
    public var bands: [Band]

    public init(series: SeriesSpec, minimum: Double, maximum: Double, thresholds: [Threshold] = [], bands: [Band] = []) {
        self.series = series
        self.minimum = min(minimum, maximum)
        self.maximum = max(minimum, maximum)
        self.thresholds = thresholds
        self.bands = bands
    }

    public var value: Double? { series.latest?.y }

    /// Needle position 0...1, clamped to the scale.
    public var fraction: Double? {
        guard let value, maximum > minimum else { return nil }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }

    public var status: Severity { value.map { severity(of: $0, thresholds: thresholds, bands: bands) } ?? .normal }
}

/// Line, area and scatter charts share this spec.
public struct CartesianSpec: Codable, Sendable, Hashable {
    public var series: [SeriesSpec]
    public var xAxis: AxisSpec
    /// One or more y axes; series pick one by id.
    public var yAxes: [AxisSpec]
    public var thresholds: [Threshold]
    public var bands: [Band]
    /// Area charts only: stack series instead of overlaying them.
    public var stacked: Bool

    public init(
        series: [SeriesSpec], xAxis: AxisSpec = .time(), yAxes: [AxisSpec] = [], thresholds: [Threshold] = [], bands: [Band] = [],
        stacked: Bool = false
    ) {
        self.series = series
        self.xAxis = xAxis
        self.yAxes = yAxes.isEmpty ? Self.defaultAxes(for: series) : yAxes
        self.thresholds = thresholds
        self.bands = bands
        self.stacked = stacked
    }

    /// One y axis per distinct unit, first unit on "y", others on "y2", "y3"….
    public static func defaultAxes(for series: [SeriesSpec]) -> [AxisSpec] {
        var units: [String] = []
        for item in series where !units.contains(item.unit) { units.append(item.unit) }
        if units.isEmpty { return [AxisSpec(label: "Value")] }
        return units.enumerated().map { index, unit in
            AxisSpec(id: index == 0 ? "y" : "y\(index + 1)", label: unit.isEmpty ? "Value" : unit, unit: unit)
        }
    }
}

public struct BarSeries: Codable, Sendable, Hashable {
    public var name: String
    public var unit: String
    public var truth: TruthClass
    /// One value per category; nil for a missing value.
    public var values: [Double?]

    public init(name: String, unit: String, truth: TruthClass, values: [Double?]) {
        self.name = name
        self.unit = unit
        self.truth = truth
        self.values = values
    }
}

public struct BarSpec: Codable, Sendable, Hashable {
    public var categories: [String]
    public var series: [BarSeries]
    public var valueAxis: AxisSpec
    public var thresholds: [Threshold]
    public var horizontal: Bool

    public init(categories: [String], series: [BarSeries], valueAxis: AxisSpec? = nil, thresholds: [Threshold] = [], horizontal: Bool = false) {
        self.categories = categories
        self.series = series
        self.valueAxis = valueAxis ?? AxisSpec(label: series.first?.unit ?? "Value", unit: series.first?.unit)
        self.thresholds = thresholds
        self.horizontal = horizontal
    }
}

public struct HistogramSpec: Codable, Sendable, Hashable {
    public var histogram: Histogram
    public var name: String
    /// Unit of the binned values.
    public var unit: String
    public var truth: TruthClass
    public var thresholds: [Threshold]

    public init(histogram: Histogram, name: String, unit: String, truth: TruthClass, thresholds: [Threshold] = []) {
        self.histogram = histogram
        self.name = name
        self.unit = unit
        self.truth = truth
        self.thresholds = thresholds
    }

    public init(series: SeriesSpec, binCount: Int? = nil, range: ClosedRange<Double>? = nil, thresholds: [Threshold] = []) throws {
        self.init(
            histogram: try Histogram.bin(series.points.map(\.y), binCount: binCount, range: range), name: series.name, unit: series.unit,
            truth: series.truth, thresholds: thresholds
        )
    }
}

public struct HeatmapSpec: Codable, Sendable, Hashable {
    public var grid: HeatmapGrid
    public var xAxis: AxisSpec
    public var yAxis: AxisSpec
    public var valueName: String
    public var valueUnit: String
    public var truth: TruthClass

    public init(grid: HeatmapGrid, xAxis: AxisSpec, yAxis: AxisSpec, valueName: String, valueUnit: String, truth: TruthClass) {
        self.grid = grid
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.valueName = valueName
        self.valueUnit = valueUnit
        self.truth = truth
    }
}

/// An oscilloscope view: channels on a divided time base with a trigger.
public struct ScopeSpec: Codable, Sendable, Hashable {
    public var channels: [SeriesSpec]
    public var trigger: TriggerMode?
    /// Channel id the trigger watches; the first channel when nil.
    public var triggerChannel: String?
    public var secondsPerDivision: Double
    public var horizontalDivisions: Int
    /// Vertical scale per channel id, in the channel's unit per division.
    public var unitsPerDivision: [String: Double]
    public var thresholds: [Threshold]

    public init(
        channels: [SeriesSpec], trigger: TriggerMode? = nil, triggerChannel: String? = nil, secondsPerDivision: Double,
        horizontalDivisions: Int = 10, unitsPerDivision: [String: Double] = [:], thresholds: [Threshold] = []
    ) {
        self.channels = channels
        self.trigger = trigger
        self.triggerChannel = triggerChannel
        self.secondsPerDivision = secondsPerDivision
        self.horizontalDivisions = horizontalDivisions
        self.unitsPerDivision = unitsPerDivision
        self.thresholds = thresholds
    }

    /// The first trigger on the trigger channel, if any.
    public var triggerPoint: TriggerPoint? {
        guard let trigger else { return nil }
        let channel = channels.first { $0.id == triggerChannel } ?? channels.first
        return channel.flatMap { ScopeTrigger.first(in: $0.points, mode: trigger) }
    }
}

public struct SpectrumSpec: Codable, Sendable, Hashable {
    public var spectrum: Spectrum
    public var name: String
    /// Unit of the analysed signal (amplitudes are in this unit).
    public var unit: String
    public var truth: TruthClass
    /// Limits on magnitude in dB.
    public var thresholds: [Threshold]

    public init(spectrum: Spectrum, name: String, unit: String, truth: TruthClass, thresholds: [Threshold] = []) {
        self.spectrum = spectrum
        self.name = name
        self.unit = unit
        self.truth = truth
        self.thresholds = thresholds
    }

    /// Analyses a uniformly sampled series.
    public init(series: SeriesSpec, sampleRate: Double, window: WindowFunction = .hann, thresholds: [Threshold] = []) throws {
        self.init(
            spectrum: try Spectrum.analyze(series.points.map(\.y), sampleRate: sampleRate, window: window), name: series.name,
            unit: series.unit, truth: series.truth, thresholds: thresholds
        )
    }
}

public struct TimelineItem: Codable, Sendable, Hashable {
    public var start: Double
    /// Nil for an instant.
    public var end: Double?
    public var label: String
    public var lane: String
    public var truth: TruthClass
    public var severity: Severity

    public init(start: Double, end: Double? = nil, label: String, lane: String, truth: TruthClass, severity: Severity = .normal) {
        self.start = start
        self.end = end
        self.label = label
        self.lane = lane
        self.truth = truth
        self.severity = severity
    }
}

public struct TimelineSpec: Codable, Sendable, Hashable {
    public var items: [TimelineItem]
    public var axis: AxisSpec

    public init(items: [TimelineItem], axis: AxisSpec = .time()) {
        self.items = items.sorted { ($0.start, $0.lane, $0.label) < ($1.start, $1.lane, $1.label) }
        self.axis = axis
    }

    public var lanes: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.lane) { seen.append(item.lane) }
        return seen
    }
}

public struct MapPoint: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var label: String
    public var value: Double?
    public var unit: String?
    public var truth: TruthClass
    public var severity: Severity

    public init(
        latitude: Double, longitude: Double, label: String, value: Double? = nil, unit: String? = nil, truth: TruthClass,
        severity: Severity = .normal
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
        self.value = value
        self.unit = unit
        self.truth = truth
        self.severity = severity
    }
}

public struct MapSpec: Codable, Sendable, Hashable {
    public var points: [MapPoint]

    public init(points: [MapPoint]) {
        self.points = points
    }
}

public struct NetworkSpec: Codable, Sendable, Hashable {
    public enum Layout: String, Codable, Sendable, Hashable {
        case layered
        case force
    }

    public var nodes: [NetworkNode]
    public var edges: [NetworkEdge]
    public var layout: Layout
    /// Node positions in the unit square, computed at creation.
    public var positions: [String: LayoutPoint]
    public var truth: TruthClass

    public init(nodes: [NetworkNode], edges: [NetworkEdge], layout: Layout = .layered, truth: TruthClass) {
        self.nodes = nodes
        self.edges = edges
        self.layout = layout
        self.truth = truth
        switch layout {
        case .layered: positions = NetworkLayout.layered(nodes: nodes, edges: edges)
        case .force: positions = NetworkLayout.force(nodes: nodes, edges: edges)
        }
    }
}

public struct SankeySpec: Codable, Sendable, Hashable {
    public var diagram: SankeyDiagram
    public var truth: TruthClass

    public init(diagram: SankeyDiagram, truth: TruthClass) {
        self.diagram = diagram
        self.truth = truth
    }
}

public struct StateGraphSpec: Codable, Sendable, Hashable {
    public var graph: StateGraph
    /// What changed state: "Inlet valve".
    public var subject: String
    public var truth: TruthClass

    public init(graph: StateGraph, subject: String, truth: TruthClass) {
        self.graph = graph
        self.subject = subject
        self.truth = truth
    }
}

/// A label pinned to a canonical object in a 3D scene. The renderer finds the
/// entity by ObjectID; the overlay never owns geometry.
public struct OverlayAnchor: Codable, Sendable, Hashable {
    public var object: ObjectID
    public var label: String
    public var value: Double?
    public var unit: String?
    public var truth: TruthClass
    public var severity: Severity

    public init(object: ObjectID, label: String, value: Double? = nil, unit: String? = nil, truth: TruthClass, severity: Severity = .normal) {
        self.object = object
        self.label = label
        self.value = value
        self.unit = unit
        self.truth = truth
        self.severity = severity
    }
}

public struct OverlaySpec: Codable, Sendable, Hashable {
    public var anchors: [OverlayAnchor]

    public init(anchors: [OverlayAnchor]) {
        self.anchors = anchors
    }
}

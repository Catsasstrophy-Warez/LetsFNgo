import Foundation

/// The Telemetry screen's three depths (spec, screen family 14).
public enum DensityMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Plain answers for someone new: few series, current values, normal ranges.
    case guided
    /// Working views for a technician: trends, scopes, distributions.
    case technician
    /// Everything: raw density, spectra, heatmaps, all axes.
    case expert
}

/// What a density mode shows. Truth classes are shown in every mode; density
/// never hides whether a value was modeled or observed.
public struct DensityPolicy: Codable, Sendable, Hashable {
    public var mode: DensityMode
    /// Kinds offered in this mode. `table` is always allowed.
    public var kinds: Set<VisualizationKind>
    /// Series or channels shown at once; nil for no limit.
    public var maxSeries: Int?
    /// Points per series after LTTB downsampling; nil keeps every point.
    public var maxPoints: Int?
    public var showsBands: Bool
    public var showsThresholds: Bool
    /// Additional y axes for mixed units. Without them, only the first unit's
    /// series are shown, rather than plotting mixed units on one axis.
    public var showsSecondaryAxes: Bool
    /// Rows in the table equivalent before "show all"; nil for no limit.
    public var maxTableRows: Int?

    public static func `for`(_ mode: DensityMode) -> DensityPolicy {
        switch mode {
        case .guided:
            DensityPolicy(
                mode: mode, kinds: [.value, .gauge, .line, .bar, .timeline, .table, .map, .threeDOverlay, .stateGraph], maxSeries: 3,
                maxPoints: 200, showsBands: true, showsThresholds: true, showsSecondaryAxes: false, maxTableRows: 50
            )
        case .technician:
            DensityPolicy(
                mode: mode,
                kinds: [
                    .value, .gauge, .line, .area, .bar, .scatter, .histogram, .scope, .table, .timeline, .map, .network, .sankey, .stateGraph,
                    .threeDOverlay,
                ],
                maxSeries: 6, maxPoints: 1_000, showsBands: true, showsThresholds: true, showsSecondaryAxes: true, maxTableRows: 500
            )
        case .expert:
            DensityPolicy(
                mode: mode, kinds: Set(VisualizationKind.allCases), maxSeries: nil, maxPoints: 5_000, showsBands: true, showsThresholds: true,
                showsSecondaryAxes: true, maxTableRows: nil
            )
        }
    }

    public func allows(_ kind: VisualizationKind) -> Bool {
        kind == .table || kinds.contains(kind)
    }

    /// The visualization trimmed to this mode: fewer series, downsampled
    /// points, and optional decorations removed. Kinds the mode doesn't offer
    /// are returned unchanged; check `allows` before showing them.
    public func apply(to visualization: Visualization) -> Visualization {
        var copy = visualization
        switch visualization.content {
        case .line(let spec): copy.content = .line(trim(spec))
        case .area(let spec): copy.content = .area(trim(spec))
        case .scatter(let spec): copy.content = .scatter(trim(spec))
        case .scope(var spec):
            spec.channels = limit(spec.channels).map(downsample)
            if !showsThresholds { spec.thresholds = [] }
            copy.content = .scope(spec)
        case .value(var spec):
            if !showsBands { spec.bands = [] }
            if !showsThresholds { spec.thresholds = [] }
            copy.content = .value(spec)
        case .gauge(var spec):
            if !showsBands { spec.bands = [] }
            if !showsThresholds { spec.thresholds = [] }
            copy.content = .gauge(spec)
        case .bar(var spec):
            spec.series = limit(spec.series)
            if !showsThresholds { spec.thresholds = [] }
            copy.content = .bar(spec)
        case .histogram, .heatmap, .spectrum, .table, .timeline, .map, .network, .sankey, .stateGraph, .threeDOverlay:
            break
        }
        return copy
    }

    /// The table equivalent limited to `maxTableRows`.
    public func table(for visualization: Visualization) -> DataTable {
        var table = visualization.table
        if let maxTableRows, table.rows.count > maxTableRows {
            table.caption += " (first \(maxTableRows) of \(table.rows.count) rows)"
            table.rows = Array(table.rows.prefix(maxTableRows))
        }
        return table
    }

    private func trim(_ spec: CartesianSpec) -> CartesianSpec {
        var spec = spec
        var series = spec.series
        if !showsSecondaryAxes, let primary = spec.yAxes.first {
            series = series.filter { ($0.axis ?? CartesianSpec.axisID(for: $0, in: spec.yAxes)) == primary.id }
            spec.yAxes = [primary]
        }
        spec.series = limit(series).map(downsample)
        if !showsBands { spec.bands = [] }
        if !showsThresholds { spec.thresholds = [] }
        return spec
    }

    private func limit<T>(_ items: [T]) -> [T] {
        guard let maxSeries else { return items }
        return Array(items.prefix(maxSeries))
    }

    private func downsample(_ series: SeriesSpec) -> SeriesSpec {
        guard let maxPoints else { return series }
        return Downsampling.lttb(series, threshold: maxPoints)
    }
}

extension CartesianSpec {
    /// The axis a series plots against: its own `axis`, else the axis whose
    /// unit matches, else the first.
    public static func axisID(for series: SeriesSpec, in axes: [AxisSpec]) -> String {
        if let axis = series.axis { return axis }
        return axes.first { $0.unit == series.unit }?.id ?? axes.first?.id ?? "y"
    }
}

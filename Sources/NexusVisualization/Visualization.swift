import Foundation
import NexusCore

/// One visualization: a title plus a kind-specific spec. `table` is its
/// accessible equivalent. The switch over `Content` is exhaustive, so a new
/// kind can't ship without one.
public struct Visualization: Codable, Sendable, Hashable, Identifiable {
    public enum Content: Codable, Sendable, Hashable {
        case value(ValueSpec)
        case gauge(GaugeSpec)
        case line(CartesianSpec)
        case area(CartesianSpec)
        case bar(BarSpec)
        case scatter(CartesianSpec)
        case histogram(HistogramSpec)
        case heatmap(HeatmapSpec)
        case scope(ScopeSpec)
        case spectrum(SpectrumSpec)
        case table(DataTable)
        case timeline(TimelineSpec)
        case map(MapSpec)
        case network(NetworkSpec)
        case sankey(SankeySpec)
        case stateGraph(StateGraphSpec)
        case threeDOverlay(OverlaySpec)
    }

    public var id: String
    public var title: String
    public var content: Content

    public init(id: String? = nil, title: String, content: Content) {
        self.id = id ?? title
        self.title = title
        self.content = content
    }

    public var kind: VisualizationKind {
        switch content {
        case .value: .value
        case .gauge: .gauge
        case .line: .line
        case .area: .area
        case .bar: .bar
        case .scatter: .scatter
        case .histogram: .histogram
        case .heatmap: .heatmap
        case .scope: .scope
        case .spectrum: .spectrum
        case .table: .table
        case .timeline: .timeline
        case .map: .map
        case .network: .network
        case .sankey: .sankey
        case .stateGraph: .stateGraph
        case .threeDOverlay: .threeDOverlay
        }
    }

    /// Every truth class shown, so a view can badge "modeled" or "observed".
    public var truthClasses: Set<TruthClass> {
        switch content {
        case .value(let spec): [spec.series.truth]
        case .gauge(let spec): [spec.series.truth]
        case .line(let spec), .area(let spec), .scatter(let spec): Set(spec.series.map(\.truth))
        case .bar(let spec): Set(spec.series.map(\.truth))
        case .histogram(let spec): [spec.truth]
        case .heatmap(let spec): [spec.truth]
        case .scope(let spec): Set(spec.channels.map(\.truth))
        case .spectrum(let spec): [spec.truth]
        case .table(let table): Set(table.columns.compactMap(\.truth))
        case .timeline(let spec): Set(spec.items.map(\.truth))
        case .map(let spec): Set(spec.points.map(\.truth))
        case .network(let spec): [spec.truth]
        case .sankey(let spec): [spec.truth]
        case .stateGraph(let spec): [spec.truth]
        case .threeDOverlay(let spec): Set(spec.anchors.map(\.truth))
        }
    }

    /// The table equivalent: the same data, readable without the chart.
    public var table: DataTable {
        switch content {
        case .value(let spec):
            return DataTable(
                caption: title,
                columns: [.init("Series"), .init("Value", unit: spec.series.unit), .init("Truth"), .init("Status")],
                rows: [[.text(spec.series.name), spec.value.cell, .text(spec.series.truth.rawValue), .text(spec.status.rawValue)]]
            )
        case .gauge(let spec):
            return DataTable(
                caption: title,
                columns: [
                    .init("Series"), .init("Value", unit: spec.series.unit), .init("Minimum", unit: spec.series.unit),
                    .init("Maximum", unit: spec.series.unit), .init("Truth"), .init("Status"),
                ],
                rows: [
                    [
                        .text(spec.series.name), spec.value.cell, .number(spec.minimum), .number(spec.maximum), .text(spec.series.truth.rawValue),
                        .text(spec.status.rawValue),
                    ]
                ]
            )
        case .line(let spec), .area(let spec), .scatter(let spec):
            return Self.longTable(title, series: spec.series, xTitle: spec.xAxis.label, xUnit: spec.xAxis.unit)
        case .bar(let spec):
            let columns = [DataTable.Column("Category")] + spec.series.map { DataTable.Column($0.name, unit: $0.unit, truth: $0.truth) }
            let rows = spec.categories.enumerated().map { index, category in
                [TableCell.text(category)] + spec.series.map { index < $0.values.count ? $0.values[index].cell : .empty }
            }
            return DataTable(caption: title, columns: columns, rows: rows)
        case .histogram(let spec):
            let histogram = spec.histogram
            var rows = histogram.counts.indices.map { index in
                [TableCell.number(histogram.edges[index]), .number(histogram.edges[index + 1]), .number(Double(histogram.counts[index]))]
            }
            if histogram.underflow > 0 { rows.insert([.text("below"), .number(histogram.edges[0]), .number(Double(histogram.underflow))], at: 0) }
            if histogram.overflow > 0 {
                rows.append([.number(histogram.edges[histogram.edges.count - 1]), .text("above"), .number(Double(histogram.overflow))])
            }
            return DataTable(
                caption: "\(title): \(spec.name)",
                columns: [.init("From", unit: spec.unit, truth: spec.truth), .init("To", unit: spec.unit, truth: spec.truth), .init("Count")], rows: rows
            )
        case .heatmap(let spec):
            let grid = spec.grid
            var rows: [[TableCell]] = []
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    rows.append([
                        .number(grid.yEdges[row]), .number(grid.yEdges[row + 1]), .number(grid.xEdges[column]), .number(grid.xEdges[column + 1]),
                        grid.cells[row][column].cell,
                    ])
                }
            }
            return DataTable(
                caption: title,
                columns: [
                    .init("\(spec.yAxis.label) from", unit: spec.yAxis.unit), .init("\(spec.yAxis.label) to", unit: spec.yAxis.unit),
                    .init("\(spec.xAxis.label) from", unit: spec.xAxis.unit), .init("\(spec.xAxis.label) to", unit: spec.xAxis.unit),
                    .init(spec.valueName, unit: spec.valueUnit, truth: spec.truth),
                ],
                rows: rows
            )
        case .scope(let spec):
            var table = Self.longTable(title, series: spec.channels, xTitle: "Time", xUnit: "s")
            if let trigger = spec.triggerPoint {
                table.caption += " (triggered at \(TableCell.number(trigger.time).formatted()) s)"
            }
            return table
        case .spectrum(let spec):
            let spectrum = spec.spectrum
            let rows = spectrum.frequencies.indices.map { index in
                [TableCell.number(spectrum.frequencies[index]), .number(spectrum.amplitudes[index]), .number(spectrum.magnitudesDB[index])]
            }
            return DataTable(
                caption: "\(title): \(spec.name), \(spectrum.window.rawValue) window",
                columns: [
                    .init("Frequency", unit: "Hz"), .init("Amplitude", unit: spec.unit, truth: spec.truth), .init("Magnitude", unit: "dB", truth: spec.truth),
                ],
                rows: rows
            )
        case .table(let table):
            return table
        case .timeline(let spec):
            return DataTable(
                caption: title,
                columns: [
                    .init("Start", unit: spec.axis.unit), .init("End", unit: spec.axis.unit), .init("Lane"), .init("Event"), .init("Truth"), .init("Status"),
                ],
                rows: spec.items.map { item in
                    [.number(item.start), item.end.cell, .text(item.lane), .text(item.label), .text(item.truth.rawValue), .text(item.severity.rawValue)]
                }
            )
        case .map(let spec):
            return DataTable(
                caption: title,
                columns: [.init("Place"), .init("Latitude"), .init("Longitude"), .init("Value"), .init("Unit"), .init("Truth"), .init("Status")],
                rows: spec.points.map { point in
                    [
                        .text(point.label), .number(point.latitude), .number(point.longitude), point.value.cell, point.unit.cell,
                        .text(point.truth.rawValue), .text(point.severity.rawValue),
                    ]
                }
            )
        case .network(let spec):
            let labels = Dictionary(spec.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            var rows: [[TableCell]] = spec.edges.map { edge in
                [.text(labels[edge.from] ?? edge.from), .text(labels[edge.to] ?? edge.to), edge.label.cell]
            }
            let connected = Set(spec.edges.flatMap { [$0.from, $0.to] })
            for node in spec.nodes where !connected.contains(node.id) {
                rows.append([.text(node.label), .empty, .text("no connections")])
            }
            return DataTable(caption: title, columns: [.init("From", truth: spec.truth), .init("To", truth: spec.truth), .init("Relationship")], rows: rows)
        case .sankey(let spec):
            return DataTable(
                caption: title,
                columns: [.init("Source"), .init("Target"), .init("Flow", unit: spec.diagram.unit, truth: spec.truth)],
                rows: spec.diagram.links.map { [.text($0.source), .text($0.target), .number($0.value)] }
            )
        case .stateGraph(let spec):
            let graph = spec.graph
            return DataTable(
                caption: "\(title): \(spec.subject)",
                columns: [.init("State", truth: spec.truth), .init("Entries"), .init("Time in state", unit: "s"), .init("Next states")],
                rows: graph.states.map { state in
                    let next = graph.transitions.filter { $0.from == state.name }.map { "\($0.to) ×\($0.count)" }.joined(separator: ", ")
                    return [.text(state.name), .number(Double(state.entries)), .number(state.dwell), .text(next)]
                }
            )
        case .threeDOverlay(let spec):
            return DataTable(
                caption: title,
                columns: [.init("Object"), .init("Label"), .init("Value"), .init("Unit"), .init("Truth"), .init("Status")],
                rows: spec.anchors.map { anchor in
                    [
                        .text(anchor.object.description), .text(anchor.label), anchor.value.cell, anchor.unit.cell, .text(anchor.truth.rawValue),
                        .text(anchor.severity.rawValue),
                    ]
                }
            )
        }
    }

    /// Long format: one row per point, so series of different lengths and
    /// sampling still read correctly.
    private static func longTable(_ caption: String, series: [SeriesSpec], xTitle: String, xUnit: String?) -> DataTable {
        var rows: [[TableCell]] = []
        rows.reserveCapacity(series.reduce(0) { $0 + $1.points.count })
        for item in series {
            for point in item.points {
                rows.append([.text(item.name), .number(point.x), .number(point.y), .text(item.unit), .text(item.truth.rawValue)])
            }
        }
        return DataTable(
            caption: caption, columns: [.init("Series"), .init(xTitle, unit: xUnit), .init("Value"), .init("Unit"), .init("Truth")], rows: rows
        )
    }
}

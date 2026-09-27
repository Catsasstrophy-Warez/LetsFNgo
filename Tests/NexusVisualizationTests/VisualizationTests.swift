import Foundation
import NexusCore
import Testing

@testable import NexusVisualization

private let level = SeriesSpec(
    name: "Tank level", unit: "%", truth: .modeled, points: (0..<100).map { DataPoint(Double($0), 50 + Double($0) * 0.4) }
)
private let current = SeriesSpec(
    name: "Loop current", unit: "mA", truth: .observed, points: (0..<100).map { DataPoint(Double($0), 12 + Double($0) * 0.06) }
)

/// One visualization of every kind.
func everyKind() throws -> [Visualization] {
    let wave = SeriesSpec(name: "Phase A", unit: "V", truth: .observed, points: sine(count: 256, sampleRate: 1_000, frequency: 60, amplitude: 170))
    let thresholds = [Threshold(name: "High", value: 90, direction: .above, severity: .alarm)]
    let contents: [Visualization.Content] = [
        .value(ValueSpec(series: level, thresholds: thresholds)),
        .gauge(GaugeSpec(series: level, minimum: 0, maximum: 100, bands: [Band(name: "Normal", lower: 40, upper: 80)])),
        .line(CartesianSpec(series: [level, current], thresholds: thresholds)),
        .area(CartesianSpec(series: [level], stacked: true)),
        .bar(BarSpec(categories: ["Line 1", "Line 2"], series: [BarSeries(name: "Downtime", unit: "min", truth: .recorded, values: [12, nil])])),
        .scatter(CartesianSpec(series: [current], xAxis: AxisSpec(id: "x", label: "Level", unit: "%"))),
        .histogram(try HistogramSpec(series: current, binCount: 5)),
        .heatmap(
            HeatmapSpec(
                grid: try HeatmapGrid.bin(x: [0, 1, 2], y: [0, 1, 2], xBins: 2, yBins: 2), xAxis: .time(), yAxis: AxisSpec(label: "Loop"),
                valueName: "Faults", valueUnit: "count", truth: .recorded
            )
        ),
        .scope(ScopeSpec(channels: [wave], trigger: .risingEdge(level: 0), secondsPerDivision: 0.005)),
        .spectrum(try SpectrumSpec(series: wave, sampleRate: 1_000)),
        .table(DataTable(caption: "Readings", columns: [.init("TB-4", unit: "V", truth: .observed)], rows: [[20.76]])),
        .timeline(
            TimelineSpec(items: [
                TimelineItem(start: 5, label: "Fault injected", lane: "Simulation", truth: .modeled, severity: .warning),
                TimelineItem(start: 1, end: 3, label: "Measured TB-4", lane: "Technician", truth: .observed),
            ])
        ),
        .map(MapSpec(points: [MapPoint(latitude: 45.5, longitude: -122.6, label: "Pump house", value: 3.2, unit: "bar", truth: .observed)])),
        .network(
            NetworkSpec(
                nodes: [NetworkNode(id: "tx", label: "Transmitter"), NetworkNode(id: "card", label: "AI card"), NetworkNode(id: "spare")],
                edges: [NetworkEdge("tx", "card", label: "4–20 mA")], truth: .recorded
            )
        ),
        .sankey(SankeySpec(diagram: try SankeyDiagram(flows: [Flow("Supply", "Loop", 0.3), Flow("Loop", "Receiver", 0.3)], unit: "W"), truth: .modeled)),
        .stateGraph(
            StateGraphSpec(
                graph: StateGraph(events: [StateEvent(time: 0, state: "Closed"), StateEvent(time: 4, state: "Open")], end: 10), subject: "Inlet valve",
                truth: .modeled
            )
        ),
        .threeDOverlay(OverlaySpec(anchors: [OverlayAnchor(object: .make(), label: "TB-4", value: 20.76, unit: "V", truth: .observed, severity: .warning)])),
    ]
    return contents.map { Visualization(title: "Test", content: $0) }
}

@Suite struct VisualizationTests {
    @Test func everyKindHasASpecAndATableEquivalent() throws {
        let all = try everyKind()
        #expect(Set(all.map(\.kind)) == Set(VisualizationKind.allCases))
        #expect(VisualizationKind.allCases.count == 17)
        #expect(VisualizationKind.threeDOverlay.rawValue == "3DOverlay")
        for visualization in all {
            let table = visualization.table
            #expect(!table.columns.isEmpty, "\(visualization.kind) table has columns")
            #expect(!table.rows.isEmpty, "\(visualization.kind) table has rows")
            #expect(table.rows.allSatisfy { $0.count == table.columns.count }, "\(visualization.kind) rows match columns")
            // Truth is carried in a column header or in the cells.
            let text = table.formatted().joined().joined(separator: " ")
            let truths = visualization.truthClasses
            #expect(!truths.isEmpty)
            #expect(truths.allSatisfy { text.contains($0.rawValue) }, "\(visualization.kind) table shows its truth classes")
        }
    }

    @Test func tablesCarryTheSameNumbersAsTheChart() throws {
        let line = Visualization(title: "Loop", content: .line(CartesianSpec(series: [level, current])))
        let table = line.table
        #expect(table.rows.count == level.points.count + current.points.count)
        #expect(table.rows[0] == [.text("Tank level"), .number(0), .number(50), .text("%"), .text("modeled")])

        let histogram = Visualization(title: "Spread", content: .histogram(try HistogramSpec(series: level, binCount: 4)))
        #expect(histogram.table.rows.compactMap { $0[2].number }.reduce(0, +) == 100)
    }

    @Test func mixedUnitsGetTheirOwnAxesAndStatusUsesWorstSeverity() {
        let spec = CartesianSpec(series: [level, current])
        #expect(spec.yAxes.map(\.id) == ["y", "y2"])
        #expect(spec.yAxes.map(\.unit) == ["%", "mA"])

        let value = ValueSpec(
            series: level,
            thresholds: [Threshold(name: "High", value: 80, direction: .above), Threshold(name: "High high", value: 85, direction: .above, severity: .alarm)]
        )
        #expect(abs(value.value! - 89.6) < 1e-9)
        #expect(value.status == .alarm)
        let gauge = GaugeSpec(series: level, minimum: 100, maximum: 0)
        #expect(gauge.minimum == 0 && abs(gauge.fraction! - 0.896) < 1e-12)
    }

    @Test func visualizationsRoundTripThroughJSON() throws {
        for visualization in try everyKind() {
            let data = try JSONEncoder().encode(visualization)
            let decoded = try JSONDecoder().decode(Visualization.self, from: data)
            #expect(decoded == visualization, "\(visualization.kind) survives encoding")
        }
    }

    @Test func errorsAreClassified() {
        #expect(classify(VisualizationError.emptyInput).category == .dataSource)
        #expect(classify(VisualizationError.invalidParameter("bins")).category == .userInput)
    }
}

@Suite struct DensityTests {
    private func manySeries(_ count: Int, points: Int = 2_000) -> [SeriesSpec] {
        (0..<count).map { index in
            SeriesSpec(
                name: "S\(index)", unit: index == 1 ? "mA" : "%", truth: .modeled, points: (0..<points).map { DataPoint(Double($0), Double(index)) }
            )
        }
    }

    @Test func guidedShowsFewSeriesFewPointsAndOneAxis() {
        let chart = Visualization(title: "Trend", content: .line(CartesianSpec(series: manySeries(8))))
        let guided = DensityPolicy.for(.guided).apply(to: chart)
        guard case .line(let spec) = guided.content else {
            Issue.record("Kind changed")
            return
        }
        #expect(spec.series.count == 3)
        #expect(spec.series.allSatisfy { $0.unit == "%" }, "Guided drops the secondary mA axis rather than mixing units")
        #expect(spec.series.allSatisfy { $0.points.count == 200 })
        #expect(spec.yAxes.count == 1)
    }

    @Test func technicianAndExpertShowMore() {
        let chart = Visualization(title: "Trend", content: .line(CartesianSpec(series: manySeries(8))))
        guard case .line(let technician) = DensityPolicy.for(.technician).apply(to: chart).content,
            case .line(let expert) = DensityPolicy.for(.expert).apply(to: chart).content
        else {
            Issue.record("Kind changed")
            return
        }
        #expect(technician.series.count == 6)
        #expect(technician.series.first?.points.count == 1_000)
        #expect(expert.series.count == 8)
        #expect(expert.series.first?.points.count == 2_000, "Under the expert cap, every point is kept")
        #expect(expert.yAxes.count == 2)
    }

    @Test func modesGateKindsButAlwaysAllowTables() {
        let guided = DensityPolicy.for(.guided)
        #expect(!guided.allows(.spectrum) && !guided.allows(.scope) && guided.allows(.gauge))
        #expect(DensityPolicy.for(.technician).allows(.scope))
        #expect(!DensityPolicy.for(.technician).allows(.spectrum))
        #expect(VisualizationKind.allCases.allSatisfy { DensityPolicy.for(.expert).allows($0) })
        #expect(DensityMode.allCases.allSatisfy { DensityPolicy.for($0).allows(.table) })

        let chart = Visualization(title: "Trend", content: .line(CartesianSpec(series: manySeries(2, points: 100))))
        let table = DensityPolicy.for(.guided).table(for: chart)
        #expect(table.rows.count == 50)
        #expect(table.caption.contains("first 50 of 200"))
    }
}

@Suite struct RecommenderTests {
    @Test func aFastWaveformGetsScopeAndSpectrumForExperts() {
        let wave = SeriesSpec(name: "Phase A", unit: "V", truth: .observed, points: sine(count: 1_024, sampleRate: 5_000, frequency: 60))
        let expert = VisualizationRecommender.recommend(DataProfile(series: [wave]), mode: .expert).map(\.kind)
        #expect(expert.first == .line)
        #expect(expert.contains(.scope) && expert.contains(.spectrum) && expert.contains(.histogram))
        #expect(expert.last == .table)

        let guided = VisualizationRecommender.recommend(DataProfile(series: [wave]), mode: .guided).map(\.kind)
        #expect(!guided.contains(.scope) && !guided.contains(.spectrum))
        #expect(guided.contains(.line) && guided.contains(.table))
    }

    @Test func shapesMapToSensibleKinds() {
        let single = SeriesSpec(name: "Level", unit: "%", truth: .modeled, points: [DataPoint(0, 72)])
        let one = VisualizationRecommender.recommend(DataProfile(series: [single], valueRange: 0...100))
        #expect(one.map(\.kind).prefix(2) == [.value, .gauge])

        let valve = SeriesSpec(name: "Valve", unit: "", truth: .modeled, points: (0..<50).map { DataPoint(Double($0), Double($0 / 10 % 2)) })
        #expect(VisualizationRecommender.recommend(DataProfile(series: [valve])).first?.kind == .stateGraph)

        let pair = VisualizationRecommender.recommend(DataProfile(series: [level, current])).map(\.kind)
        #expect(pair.first == .line && pair.contains(.scatter))

        let many = (0..<10).map { SeriesSpec(name: "T\($0)", unit: "°C", truth: .observed, points: [DataPoint(0, 1), DataPoint(1, 2)]) }
        #expect(VisualizationRecommender.recommend(DataProfile(series: many), mode: .expert).first?.kind == .heatmap)

        #expect(VisualizationRecommender.recommend(DataProfile(categories: ["A", "B"])).first?.kind == .bar)
        #expect(VisualizationRecommender.recommend(DataProfile(hasFlows: true)).first?.kind == .sankey)
        #expect(VisualizationRecommender.recommend(DataProfile(hasGeography: true)).first?.kind == .map)
        #expect(VisualizationRecommender.recommend(DataProfile(hasSpatialAnchors: true)).first?.kind == .threeDOverlay)
        #expect(VisualizationRecommender.recommend(DataProfile()).map(\.kind) == [.table])
    }

    @Test func everyRecommendationExplainsItself() {
        let picks = VisualizationRecommender.recommend(DataProfile(series: [level, current], categories: ["x"], hasGraph: true, hasStateEvents: true))
        #expect(picks.allSatisfy { !$0.reason.isEmpty })
        #expect(Set(picks.map(\.kind)).count == picks.count, "Each kind appears once")
        #expect(zip(picks, picks.dropFirst()).allSatisfy { $0.score >= $1.score })
    }
}

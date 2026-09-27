#if canImport(SwiftUI)
import Charts
import NexusActions
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusReality
import NexusSimulation
import NexusVisualization
import SwiftUI
#if canImport(RealityKit)
import NexusRealityKit
import RealityKit
#endif

/// Observations, hypotheses, evidence, the discriminating next test, and the
/// first divergence, for the focused investigation (or the demo's). Every
/// action goes through a command, so the field workflow is the same here, in
/// the palette and in Siri.
struct InvestigationScreen: View {
    @Environment(NexusEnvironment.self) private var env

    private var investigationID: ObjectID? {
        if let focus = env.object(env.context.focus), focus.type == .investigation { return focus.id }
        return env.demo?.investigation
    }

    var body: some View {
        _ = env.revision
        return Group {
            if let id = investigationID, let record = env.object(id) {
                content(id, record)
            } else {
                NextActionEmptyState("No investigation", message: "Select equipment and choose Start Investigation from ⌘K.", systemImage: "stethoscope")
            }
        }
    }

    /// What the screen shows for one investigation, computed once per render.
    private struct Model {
        var id: ObjectID
        var record: ObjectRecord
        var hypotheses: [Hypothesis]
        var evidence: [MeasurementRecord]
        var tests: [TestOption]
        var ranked: [TestRecommendation]
        var closed: Bool
        var confirmed: Hypothesis?
    }

    private func model(_ id: ObjectID, _ record: ObjectRecord) -> Model {
        let hypotheses = (try? env.investigations.hypotheses(of: id)) ?? []
        let members = (try? env.store.relationships(from: id, kind: .contains).map(\.to)) ?? []
        let evidence = members.compactMap { (try? env.store.measurement($0)) ?? nil }
        let tests = options(for: hypotheses, in: id)
        let ranked = (try? env.investigations.rankTests(tests, for: id)) ?? []
        let closed = record.attributes["status"]?.value == Value.string("closed")
        let confirmed = hypotheses.first { $0.state == .confirmed }
        return Model(
            id: id, record: record, hypotheses: hypotheses, evidence: evidence, tests: tests, ranked: ranked, closed: closed, confirmed: confirmed
        )
    }

    private func content(_ id: ObjectID, _ record: ObjectRecord) -> some View {
        let model = model(id, record)
        return Form {
            symptomSection(model)
            if !model.closed { nextTestSection(model) }
            hypothesesSection(model)
            evidenceSection(model)
            resolveSection(model)
        }
        .formStyle(.grouped)
    }

    private func symptomSection(_ model: Model) -> some View {
        Section("Symptom") {
            Text(model.record.title).font(.headline)
            if let summary = divergenceSummary(model.record) {
                Label(summary, systemImage: "arrow.triangle.branch").foregroundStyle(.orange)
            }
            if model.closed { Label("Closed", systemImage: "checkmark.seal.fill") }
        }
    }

    private func divergenceSummary(_ record: ObjectRecord) -> String? {
        guard case .map(let divergence)? = record.attributes["firstDivergence"]?.value, case .string(let summary)? = divergence["summary"] else {
            return nil
        }
        return summary
    }

    /// The next action comes first: on iPhone, hypotheses fill the screen.
    private func nextTestSection(_ model: Model) -> some View {
        Section("Next test") {
            ForEach(Array(model.ranked.enumerated()), id: \.offset) { index, recommendation in
                RankedTestRow(index: index, recommendation: recommendation)
            }
            Button {
                record(in: model.id, tests: model.tests, suggested: model.ranked.first?.option)
            } label: {
                Label("Record measurement", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            .accessibilityIdentifier("investigation.record")
        }
    }

    private func hypothesesSection(_ model: Model) -> some View {
        Section("Hypotheses") {
            ForEach(model.hypotheses) { hypothesis in
                HypothesisRow(hypothesis: hypothesis)
                if hypothesis.state.isLive && !model.closed {
                    HypothesisActions(hypothesis: hypothesis.id, investigation: model.id)
                }
            }
            if !model.closed {
                Button("Add hypothesis") { env.commands.run(.proposeHypothesis, title: "Add hypothesis", selection: [model.id]) }
            }
        }
    }

    /// System truth (observed, recorded) and display truth side by side, never merged.
    private func evidenceSection(_ model: Model) -> some View {
        Section("Evidence") {
            if model.evidence.isEmpty {
                NextActionEmptyState("No readings yet", message: "Take the best next test above and record it.", systemImage: "gauge")
            }
            evidenceGroup("System truth", model.evidence.filter { $0.truth == .observed || $0.truth == .recorded })
            evidenceGroup("Display truth", model.evidence.filter { $0.truth == .display })
            evidenceGroup("Modeled", model.evidence.filter { $0.truth == .modeled || $0.truth == .derived })
        }
    }

    private func resolveSection(_ model: Model) -> some View {
        Section("Resolve") {
            if let confirmed = model.confirmed, !model.closed {
                Label("Cause: \(confirmed.statement)", systemImage: "checkmark.seal")
                Button("Create repair task") { env.commands.run(.createRepairTask, title: "Create repair task", selection: [model.id]) }
                Button("Close investigation") { env.commands.run(.closeInvestigation, title: "Close investigation", selection: [model.id]) }
            }
            Button("Generate report") { env.commands.run(.generateReport, title: "Report", selection: [model.id]) }
            if model.confirmed != nil {
                Button("Make a training scenario") {
                    env.commands.run(.generateTrainingScenario, title: "Training scenario", selection: [model.id])
                }
            }
        }
    }

    @ViewBuilder
    private func evidenceGroup(_ title: String, _ readings: [MeasurementRecord]) -> some View {
        if !readings.isEmpty {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(readings) { reading in
                HStack {
                    Text("\(reading.quantityName) = \(reading.value.value.formatted()) \(reading.value.unit)")
                    if let spread = reading.uncertainty { Text("± \(spread.formatted())").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    TruthBadge(reading.truth)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Opens the reading form, prefilled with the best next test.
    private func record(in investigation: ObjectID, tests: [TestOption], suggested: TestOption?) {
        let parameters = ActionParameters.with {
            $0.investigation = investigation
            $0.tests = tests
            $0.testPoint = suggested?.testPoint
            $0.quantity = suggested?.quantity
            $0.truth = .observed
        }
        env.commands.run(.recordMeasurement, title: "Record measurement", selection: [investigation], parameters: parameters)
    }

    private func options(for hypotheses: [Hypothesis], in investigation: ObjectID) -> [TestOption] {
        if let demo = env.demo, demo.investigation == investigation { return demo.tests }
        var seen: Set<String> = []
        return hypotheses.flatMap(\.predictions).compactMap { prediction in
            let key = "\(prediction.testPoint)|\(prediction.quantity)|\(prediction.condition ?? "")"
            guard seen.insert(key).inserted else { return nil }
            return TestOption(
                title: "\(prediction.quantity) at \(env.title(prediction.testPoint))", testPoint: prediction.testPoint,
                quantity: prediction.quantity, condition: prediction.condition, cost: 5
            )
        }
    }
}

struct RankedTestRow: View {
    let index: Int
    let recommendation: TestRecommendation

    var body: some View {
        HStack {
            Text(index == 0 ? "Best" : "#\(index + 1)").font(.caption.bold()).frame(minWidth: 40, alignment: .leading)
            Text(recommendation.option.title)
            Spacer()
            Text("\(recommendation.informationGain.formatted(.number.precision(.fractionLength(2)))) bits")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HypothesisRow: View {
    @Environment(NexusEnvironment.self) private var env
    let hypothesis: Hypothesis

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hypothesis.statement)
                Spacer()
                HypothesisStateBadge(hypothesis.state)
            }
            ForEach(hypothesis.predictions, id: \.self) { prediction in
                Text(describe(prediction)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func describe(_ prediction: Prediction) -> String {
        "predicts \(prediction.quantity) \(prediction.low.formatted())–\(prediction.high.formatted()) \(prediction.unit) at \(env.title(prediction.testPoint))"
    }
}

/// Confirm or reject: people only, through commands.
struct HypothesisActions: View {
    @Environment(NexusEnvironment.self) private var env
    let hypothesis: ObjectID
    let investigation: ObjectID

    var body: some View {
        HStack {
            Button("Confirm as cause") {
                env.commands.run(.confirmHypothesis, title: "Confirm", selection: [hypothesis], parameters: parameters)
            }
            Button("Reject", role: .destructive) {
                env.commands.run(.rejectHypothesis, title: "Reject", selection: [hypothesis], parameters: parameters)
            }
        }
        .buttonStyle(.bordered)
    }

    private var parameters: ActionParameters {
        var parameters = ActionParameters()
        parameters.investigation = investigation
        return parameters
    }
}

/// The equipment as a scene: tap to select, with truth-labeled overlays.
///
/// The scene follows the focused object when it contains components;
/// otherwise it shows the demo equipment. Modeled values are computed off
/// the main thread.
struct DigitalTwinScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var overlays: [OverlayValue] = []

    private func scene() -> SceneDescription? {
        let candidates = [env.context.focus, env.demo?.loop.tank].compactMap { $0 }
        for root in candidates {
            if let scene = try? SceneBuilder.build(root: root, graph: env.graph), scene.nodes.count > 1 { return scene }
        }
        return nil
    }

    var body: some View {
        _ = env.revision
        return Group {
            if let scene = scene(), let root = scene.object(for: scene.root) {
                HStack(spacing: 0) {
                    #if canImport(RealityKit)
                    RealityView { content in
                        content.add(RealityKitSceneBuilder.makeEntities(for: scene, selected: env.context.focus, overlays: overlays))
                    } update: { content in
                        content.entities.removeAll()
                        content.add(RealityKitSceneBuilder.makeEntities(for: scene, selected: env.context.focus, overlays: overlays))
                    }
                    .realityViewCameraControls(.orbit)
                    .gesture(
                        SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                            if let object = RealityKitSceneBuilder.object(for: value.entity) {
                                try? env.context.select(object, from: .spatial)
                            }
                        }
                    )
                    .accessibilityLabel("3D view of \(env.title(root)). Selection is also available in the list.")
                    #endif
                    List(scene.nodes) { node in
                        Button {
                            try? env.context.select(node.object, from: .spatial)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(node.title).fontWeight(env.context.focus == node.object ? .bold : .regular)
                                ForEach(overlays.filter { $0.entity == node.entity }, id: \.self) { overlay in
                                    HStack {
                                        Text("\(overlay.quantity) \(overlay.value.formatted(.number.precision(.significantDigits(1...4)))) \(overlay.unit)")
                                            .font(.caption.monospacedDigit())
                                        TruthBadge(overlay.truth)
                                    }
                                }
                            }
                        }
                        .accessibilityAddTraits(env.context.focus == node.object ? .isSelected : [])
                    }
                    .frame(maxWidth: 360)
                }
                .task(id: RefreshKey(root: root, revision: env.revision)) { await refresh(scene) }
            } else {
                NextActionEmptyState("No twin", message: "Select equipment that contains components to see it in 3D.", systemImage: "cube.transparent")
            }
        }
    }

    private struct RefreshKey: Hashable {
        var root: ObjectID
        var revision: Int
    }

    private func refresh(_ scene: SceneDescription) async {
        var values = (try? OverlayBuilder.measured(in: scene, store: env.store)) ?? []
        if let demo = env.demo, scene.object(for: scene.root) == demo.loop.tank {
            let snapshot = await Task.detached(priority: .userInitiated) { (try? demo.makeTwin())?.history.last }.value
            if let snapshot {
                values += OverlayBuilder.modeled(snapshot, in: scene, units: ["terminalVoltage": "V", "loopCurrent": "mA", "level": "%", "measuredLevel": "%"])
            }
        }
        overlays = values
    }
}

/// Guided, Technician and Expert depth over the same simulated signals.
struct TelemetryScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var depth = Depth.technician
    @State private var showTable = false
    @State private var series: [Sample] = []

    enum Depth: String, CaseIterable {
        case guided = "Guided"
        case technician = "Technician"
        case expert = "Expert"
    }

    struct Sample: Identifiable, Hashable {
        var id: String { "\(signal)-\(seconds)" }
        var signal: String
        var seconds: Double
        var value: Double
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Depth", selection: $depth) {
                ForEach(Depth.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if series.isEmpty {
                NextActionEmptyState("No signals", message: "Run a simulation of the selected equipment to see its signals.", systemImage: "waveform.path.ecg")
            } else if depth == .guided {
                guided
            } else {
                Chart(visibleSeries) { sample in
                    LineMark(x: .value("Time (s)", sample.seconds), y: .value("Value", sample.value))
                        .foregroundStyle(by: .value("Signal", sample.signal))
                }
                .chartXAxisLabel("Time (s)")
                .padding()
                .accessibilityLabel("Chart of \(Set(visibleSeries.map(\.signal)).sorted().joined(separator: ", ")) over time")
                Toggle("Show as table", isOn: $showTable).padding(.horizontal)
                if depth == .expert {
                    expertViews
                }
                if showTable || depth == .expert {
                    Table(visibleSeries.filter { Int($0.seconds) % 30 == 0 }) {
                        TableColumn("Signal", value: \.signal)
                        TableColumn("t (s)") { Text($0.seconds.formatted()) }
                        TableColumn("Value") { Text($0.value.formatted(.number.precision(.significantDigits(1...5)))) }
                    }
                }
            }
        }
        .task { await load() }
    }

    /// Distribution and spectrum of the terminal voltage, from NexusVisualization.
    @ViewBuilder
    private var expertViews: some View {
        let values = series.filter { $0.signal == "terminalVoltage" }
        if let histogram = try? Histogram.bin(values.map(\.value), binCount: 20) {
            Chart {
                ForEach(histogram.counts.indices, id: \.self) { index in
                    BarMark(x: .value("Terminal voltage (V)", histogram.centers[index]), y: .value("Samples", histogram.counts[index]))
                }
            }
            .frame(height: 140)
            .padding(.horizontal)
            .accessibilityLabel("Histogram of terminal voltage, \(histogram.total) samples")
        }
        if values.count > 8, let dt = zip(values.dropFirst(), values).map({ $0.seconds - $1.seconds }).first, dt > 0,
            let spectrum = try? Spectrum.analyze(values.map(\.value), sampleRate: 1 / dt)
        {
            Chart {
                ForEach(spectrum.frequencies.indices.dropFirst(), id: \.self) { index in
                    LineMark(x: .value("Frequency (Hz)", spectrum.frequencies[index]), y: .value("dB", spectrum.magnitudesDB[index]))
                }
            }
            .frame(height: 140)
            .padding(.horizontal)
            .accessibilityLabel("Spectrum of terminal voltage")
        }
    }

    private var visibleSeries: [Sample] {
        depth == .expert ? series : series.filter { $0.signal != "loopCurrent" }
    }

    private var guided: some View {
        let latest = Dictionary(series.map { ($0.signal, $0) }, uniquingKeysWith: { lhs, rhs in lhs.seconds > rhs.seconds ? lhs : rhs })
        return Form {
            if let level = latest["level"], let reading = latest["measuredLevel"] {
                Section("Level") {
                    Gauge(value: min(max(level.value, 0), 100), in: 0...100) { Text("Tank") } currentValueLabel: {
                        Text("\(level.value.formatted(.number.precision(.fractionLength(0)))) %")
                    }
                    Gauge(value: min(max(reading.value, 0), 100), in: 0...100) { Text("Transmitter") } currentValueLabel: {
                        Text("\(reading.value.formatted(.number.precision(.fractionLength(0)))) %")
                    }
                }
                Section("What's happening") {
                    Text("The tank is at \(level.value.formatted(.number.precision(.fractionLength(1)))) % but the transmitter reports \(reading.value.formatted(.number.precision(.fractionLength(1)))) %.")
                    if abs(level.value - reading.value) > 2 {
                        Label("The reading does not match the process. Start an investigation.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let demo = env.demo else { return }
        // The simulation runs off the main thread; only the samples come back.
        series = await Task.detached(priority: .userInitiated) { () -> [Sample] in
            guard let field = try? demo.makeField() else { return [] }
            let names: [(StateKey, String)] = [
                (demo.loop.level, "level"), (demo.loop.measuredLevel, "measuredLevel"),
                (demo.loop.terminalVoltage, "terminalVoltage"), (demo.loop.loopCurrent, "loopCurrent"),
            ]
            return field.history.filter { $0.tick % 10 == 0 }.flatMap { snapshot in
                names.compactMap { key, name in snapshot.values[key].map { Sample(signal: name, seconds: snapshot.seconds, value: $0) } }
            }
        }.value
    }

}
#endif

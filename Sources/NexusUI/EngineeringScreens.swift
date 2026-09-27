#if canImport(SwiftUI)
import Charts
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusReality
import NexusSimulation
import SwiftUI
#if canImport(RealityKit)
import NexusRealityKit
import RealityKit
#endif

/// Observations, hypotheses, evidence, the discriminating next test, and the
/// first divergence, for the focused investigation (or the demo's).
struct InvestigationScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var error: String?

    private var investigationID: ObjectID? {
        if let focus = env.object(env.context.focus), focus.type == .investigation { return focus.id }
        return env.demo?.investigation
    }

    var body: some View {
        if let id = investigationID, let record = env.object(id) {
            let hypotheses = (try? env.investigations.hypotheses(of: id)) ?? []
            let evidence = (try? env.store.relationships(from: id, kind: .contains).map(\.to).compactMap { try env.store.measurement($0) }) ?? []
            let tests = options(for: hypotheses)
            let ranked = (try? env.investigations.rankTests(tests, for: id)) ?? []
            Form {
                Section("Symptom") {
                    Text(record.title).font(.headline)
                    if case .map(let divergence)? = record.attributes["firstDivergence"]?.value, case .string(let summary)? = divergence["summary"] {
                        Label(summary, systemImage: "arrow.triangle.branch").foregroundStyle(.orange)
                    }
                }
                // The next action comes first: on iPhone, hypotheses fill the screen.
                Section("Next test") {
                    ForEach(Array(ranked.enumerated()), id: \.offset) { index, recommendation in
                        HStack {
                            Text(index == 0 ? "Best" : "#\(index + 1)").font(.caption.bold()).frame(width: 40, alignment: .leading)
                            Text(recommendation.option.title)
                            Spacer()
                            Text("\(recommendation.informationGain.formatted(.number.precision(.fractionLength(2)))) bits")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Hypotheses") {
                    ForEach(hypotheses) { hypothesis in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hypothesis.statement)
                                Spacer()
                                HypothesisStateBadge(hypothesis.state)
                            }
                            ForEach(hypothesis.predictions, id: \.self) { prediction in
                                Text("predicts \(prediction.quantity) \(prediction.low.formatted())–\(prediction.high.formatted()) \(prediction.unit) at \(env.title(prediction.testPoint))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if hypothesis.state.isLive {
                                Button("Confirm as cause") { confirm(hypothesis.id, in: id) }
                                    .font(.caption)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Evidence") {
                    ForEach(evidence) { reading in
                        HStack {
                            Text("\(reading.quantityName) = \(reading.value.value.formatted()) \(reading.value.unit)")
                            Spacer()
                            TruthBadge(reading.truth)
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
        } else {
            NextActionEmptyState("No investigation", message: "Select equipment and choose Start Investigation from ⌘K.", systemImage: "stethoscope")
        }
    }

    private func options(for hypotheses: [Hypothesis]) -> [TestOption] {
        if let demo = env.demo { return demo.tests }
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

    private func confirm(_ hypothesis: ObjectID, in investigation: ObjectID) {
        do {
            try env.investigations.confirm(hypothesis, in: investigation, by: env.user)
            error = nil
        } catch {
            // Errors explain what happened and what survived.
            self.error = "Not confirmed: \(error). Nothing was changed; take a supporting field measurement first."
        }
    }
}

/// The equipment as a scene: tap to select, with truth-labeled overlays.
struct DigitalTwinScreen: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var overlays: [OverlayValue] = []

    var body: some View {
        let root = env.demo?.loop.tank ?? env.context.focus
        if let root, let scene = try? SceneBuilder.build(root: root, graph: env.graph) {
            HStack(spacing: 0) {
                #if canImport(RealityKit)
                RealityView { content in
                    content.add(RealityKitSceneBuilder.makeEntities(for: scene))
                }
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
                }
                .frame(maxWidth: 360)
            }
            .task(id: env.revision) { refresh(scene) }
        } else {
            NextActionEmptyState("No twin", message: "Select equipment that contains components to see it in 3D.", systemImage: "cube.transparent")
        }
    }

    private func refresh(_ scene: SceneDescription) {
        var values = (try? OverlayBuilder.measured(in: scene, store: env.store)) ?? []
        if let demo = env.demo, let twin = try? demo.makeTwin(), let snapshot = twin.history.last {
            values += OverlayBuilder.modeled(snapshot, in: scene, units: ["terminalVoltage": "V", "loopCurrent": "mA", "level": "%", "measuredLevel": "%"])
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
                if showTable || depth == .expert {
                    Table(visibleSeries.filter { Int($0.seconds) % 30 == 0 }) {
                        TableColumn("Signal", value: \.signal)
                        TableColumn("t (s)") { Text($0.seconds.formatted()) }
                        TableColumn("Value") { Text($0.value.formatted(.number.precision(.significantDigits(1...5)))) }
                    }
                }
            }
        }
        .task { load() }
    }

    private var visibleSeries: [Sample] {
        depth == .expert ? series : series.filter { $0.signal != "loopCurrent" }
    }

    private var guided: some View {
        let latest = Dictionary(series.map { ($0.signal, $0) }, uniquingKeysWith: { lhs, rhs in lhs.seconds > rhs.seconds ? lhs : rhs })
        return Form {
            if let level = latest["level"], let reading = latest["measuredLevel"] {
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

    private func load() {
        guard let demo = env.demo, let field = try? demo.makeField() else { return }
        let names: [(StateKey, String)] = [
            (demo.loop.level, "level"), (demo.loop.measuredLevel, "measuredLevel"),
            (demo.loop.terminalVoltage, "terminalVoltage"), (demo.loop.loopCurrent, "loopCurrent"),
        ]
        series = field.history.filter { $0.tick % 10 == 0 }.flatMap { snapshot in
            names.compactMap { key, name in snapshot.values[key].map { Sample(signal: name, seconds: snapshot.seconds, value: $0) } }
        }
    }
}
#endif

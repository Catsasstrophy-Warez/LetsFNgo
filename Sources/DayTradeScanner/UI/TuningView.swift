import SwiftUI

struct TuningView: View {
    @Environment(Settings.self) private var settings
    @Environment(PaperTradeLog.self) private var paperLog
    @Environment(ScannerEngine.self) private var engine
    @Environment(SwingEngine.self) private var swingEngine
    @Environment(LongTermEngine.self) private var longTermEngine

    @State private var showResetConfirm = false
    /// Which horizon's tuning is shown. Previously the swing and long-term
    /// weight/evidence sections existed but were never added to `body`, so
    /// there was no way to reach them from the UI — this picker is the fix.
    @State private var tuningHorizon: TradeHorizon = .dayTrade

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Picker("Horizon", selection: $tuningHorizon) {
                        ForEach(TradeHorizon.allCases) { horizon in
                            Text(horizon.displayName).tag(horizon)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                switch tuningHorizon {
                case .dayTrade:
                    sensitivitySection
                    budgetSection
                    AdvancedOnly { weightsSection }
                    AdvancedOnly { normalizationSection }
                    AdvancedOnly { gatesSection }
                    evidenceSection
                case .swing:
                    AdvancedOnly { swingWeightsSection }
                    swingEvidenceSection
                case .longTerm:
                    AdvancedOnly { longTermWeightsSection }
                    longTermEvidenceSection
                }

                if settings.interfaceMode == .simple {
                    Section {
                        Text("Switch to advanced to set individual signal weights, normalization anchors and liquidity gates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ModeToggle() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") { showResetConfirm = true }
                }
            }
            .confirmationDialog("Reset weights to defaults?", isPresented: $showResetConfirm) {
                Button("Reset weights", role: .destructive) {
                    switch tuningHorizon {
                    case .dayTrade: settings.resetWeights()
                    case .swing:
                        settings.swingWeights = Dictionary(uniqueKeysWithValues: SwingComponent.allCases.map { ($0, $0.defaultWeight) })
                    case .longTerm:
                        settings.longTermWeights = Dictionary(uniqueKeysWithValues: LongTermComponent.allCases.map { ($0, $0.defaultWeight) })
                    }
                }
            }
        }
    }

    // MARK: - Simple controls

    /// One slider that means something. Alert threshold is the only knob most
    /// people need: everything else changes ranking, this changes how often
    /// the phone buzzes.
    private var sensitivitySection: some View {
        @Bindable var settings = settings

        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Alert when score reaches")
                    Spacer()
                    Text(Fmt.score(settings.scoring.alertThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.scoring.alertThreshold, in: 0.3...0.95, step: 0.01)
                Text(sensitivityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Preset", selection: presetBinding) {
                Text("Fewer, stronger").tag(Preset.selective)
                Text("Balanced").tag(Preset.balanced)
                Text("More, earlier").tag(Preset.permissive)
            }
            .pickerStyle(.segmented)

            Stepper(
                "Don't repeat for \(Int(settings.scoring.alertCooldownMinutes)) min",
                value: $settings.scoring.alertCooldownMinutes,
                in: 5...120,
                step: 5
            )
        } header: {
            Text("Alerts")
        } footer: {
            Text("A lower threshold surfaces setups earlier and produces more false positives. The paper log below is how you find out which end of that trade-off is working.")
        }
    }

    private var sensitivityDescription: String {
        switch settings.scoring.alertThreshold {
        case ..<0.45: return "Very talkative. Expect several alerts an hour on an active day."
        case ..<0.65: return "A handful of alerts on a normal session."
        case ..<0.8: return "Only setups where several signals line up."
        default: return "Rare. Most days will produce nothing at all."
        }
    }

    enum Preset: Hashable { case selective, balanced, permissive, custom }

    private var presetBinding: Binding<Preset> {
        Binding(
            get: {
                let config = settings.scoring
                if config.minRVOL >= 2.5 && config.alertThreshold >= 0.72 { return .selective }
                if config.minRVOL <= 1.2 && config.alertThreshold <= 0.5 { return .permissive }
                return .balanced
            },
            set: { preset in
                switch preset {
                case .selective:
                    settings.scoring.minRVOL = 2.5
                    settings.scoring.alertThreshold = 0.75
                    settings.scoring.minAbsChangePercent = 0.025
                    settings.scoring.minDollarVolume = 500_000
                case .balanced:
                    settings.scoring.minRVOL = 1.5
                    settings.scoring.alertThreshold = 0.62
                    settings.scoring.minAbsChangePercent = 0.015
                    settings.scoring.minDollarVolume = 250_000
                case .permissive:
                    settings.scoring.minRVOL = 1.2
                    settings.scoring.alertThreshold = 0.48
                    settings.scoring.minAbsChangePercent = 0.008
                    settings.scoring.minDollarVolume = 100_000
                case .custom:
                    break
                }
            }
        )
    }

    /// The attention budget.
    private var budgetSection: some View {
        @Bindable var settings = settings

        return Section {
            Stepper(
                "\(settings.alertBudget.slotsPerWindow) alerts per \(Int(settings.alertBudget.windowMinutes)) min",
                value: $settings.alertBudget.slotsPerWindow,
                in: 1...20
            )
            Stepper(
                "\(settings.alertBudget.openingSlotsPerWindow) during the first \(settings.alertBudget.openingWindowMinutes) min",
                value: $settings.alertBudget.openingSlotsPerWindow,
                in: 1...30
            )
            Stepper(
                "Ranked list capped at \(settings.maxRankedResults)",
                value: $settings.maxRankedResults,
                in: 5...100,
                step: 5
            )

            HStack {
                Text("Slots available now")
                Spacer()
                Text("\(engine.slotsRemaining) of \(engine.slotsCapacity)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(engine.slotsRemaining == 0 ? Palette.down : .secondary)
            }

            if let minutes = engine.minutesUntilNextSlot {
                Text("Next slot frees up in about \(minutes) minute\(minutes == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AdvancedOnly {
                Toggle("Let exceptional setups preempt", isOn: $settings.alertBudget.allowPreemption)
                labeledSlider(
                    "Preemption margin",
                    value: $settings.alertBudget.preemptionMargin,
                    range: 0.05...0.4,
                    format: "%.2f"
                )
                labeledSlider(
                    "Holding delay",
                    value: $settings.alertBudget.holdingSeconds,
                    range: 0...20,
                    format: "%.0fs"
                )

                if !engine.suppressedAlerts.isEmpty {
                    let summary = engine.suppressedAlerts
                    HStack {
                        Text("Suppressed this window")
                        Spacer()
                        Text("\(summary.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let best = summary.map(\.score).max() {
                        Text("Best suppressed score was \(Fmt.score(best)). A window that's constantly full means the threshold is set too low for the budget.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Alert budget")
        } footer: {
            Text("A scanner that fires on everything washes out the alerts worth acting on. Slots go to the highest scores in each window; a short holding delay lets a burst resolve to its best member rather than its earliest.")
        }
    }

    // MARK: - Advanced controls (day trade)

    private var weightsSection: some View {
        @Bindable var settings = settings

        return Section {
            ForEach(SignalComponent.allCases) { component in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(component.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f%%", settings.scoring.normalizedWeight(component) * 100))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.scoring.weights[component] ?? 0 },
                            set: { settings.scoring.weights[component] = $0 }
                        ),
                        in: 0...1
                    )
                    Text(component.explanation)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Signal weights")
        } footer: {
            Text("Weights are normalized at use, so you can raise one without rebalancing the rest. Percentages shown are the effective share.")
        }
    }

    private var normalizationSection: some View {
        @Bindable var settings = settings

        return Section {
            labeledSlider("RVOL saturation", value: $settings.scoring.rvolSaturation, range: 2...15, format: "%.1f×")
            labeledSlider("RVOL floor", value: $settings.scoring.rvolFloor, range: 0.5...3, format: "%.2f×")
            labeledSlider("Gap saturation", value: $settings.scoring.gapSaturation, range: 0.02...0.30, format: "%.0f%%", scale: 100)
            labeledSlider("VWAP σ saturation", value: $settings.scoring.vwapZSaturation, range: 1...6, format: "%.1fσ")
            labeledSlider("News half-life", value: $settings.scoring.newsHalfLifeMinutes, range: 5...120, format: "%.0f min")
            labeledSlider("VWAP event decay", value: $settings.scoring.vwapEventDecayMinutes, range: 5...120, format: "%.0f min")
        } header: {
            Text("Normalization")
        } footer: {
            Text("Where each raw signal reaches full marks. Lowering saturation makes a component reach 1.0 sooner, which flattens the difference between good and exceptional readings.")
        }
    }

    private var gatesSection: some View {
        @Bindable var settings = settings

        return Section {
            labeledSlider("Minimum RVOL", value: $settings.scoring.minRVOL, range: 1...6, format: "%.1f×")
            labeledSlider("Minimum move", value: $settings.scoring.minAbsChangePercent, range: 0...0.08, format: "%.1f%%", scale: 100)
            labeledSlider("Minimum price", value: $settings.scoring.minPrice, range: 0.5...50, format: "$%.2f")
            labeledSlider("Maximum price", value: $settings.scoring.maxPrice, range: 50...2000, format: "$%.0f")
            labeledSlider("Minimum dollar volume", value: $settings.scoring.minDollarVolume, range: 25_000...5_000_000, format: "$%.0fK", scale: 0.001)
            Stepper("Minimum prints: \(settings.scoring.minTradeCount)", value: $settings.scoring.minTradeCount, in: 0...500, step: 10)
        } header: {
            Text("Hard gates")
        } footer: {
            Text("Applied before scoring. Dollar volume is measured on the IEX feed, so it is far smaller than consolidated dollar volume — tune it by watching what actually gets filtered, not by what looks right in absolute terms.")
        }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        scale: Double = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Evidence (day trade)

    /// The loop that makes tuning honest: measured outcome per component,
    /// straight from the paper log, in both modes.
    private var evidenceSection: some View {
        let performance = paperLog.componentPerformance()

        return Section {
            if performance.isEmpty {
                Text("Not enough resolved paper trades yet. Each alert gets logged automatically and marked at 15, 30 and 60 minutes — come back once a few dozen have played out.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(performance) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.component.displayName)
                                .font(.subheadline)
                            Spacer()
                            Text(Fmt.percent(row.edge))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Palette.direction(row.edge))
                        }
                        Text("\(row.tradeCount) trades · \(Int(row.winRate * 100))% up · avg \(Fmt.percent(row.averageReturn))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }

                AdvancedOnly {
                    Button("Set weights from measured edge") {
                        applyMeasuredWeights(performance)
                    }
                    .disabled(performance.count < 3)
                }
            }
        } header: {
            Text("What's actually working")
        } footer: {
            Text("Edge is the average outcome of alerts where a component contributed, minus the average where it didn't. A negative number means that signal is currently costing you.")
        }
    }

    /// Rescales weights toward measured edge, but only partway.
    private func applyMeasuredWeights(_ performance: [ComponentPerformance]) {
        let edges = Dictionary(uniqueKeysWithValues: performance.map { ($0.component, $0.edge) })
        guard let maxEdge = edges.values.map(abs).max(), maxEdge > 0 else { return }

        for component in SignalComponent.allCases {
            let current = settings.scoring.weights[component] ?? component.defaultWeight
            guard let edge = edges[component] else { continue }
            let target = max(0.02, min(1.0, 0.5 + (edge / maxEdge) * 0.5))
            // Move 40% of the way, so repeated presses converge rather than thrash.
            settings.scoring.weights[component] = current + (target - current) * 0.4
        }
    }

    // MARK: - Swing tuning

    private var swingWeightsSection: some View {
        @Bindable var settings = settings
        return Section {
            ForEach(SwingComponent.allCases) { component in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(component.displayName).font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f%%", weightShare(component, in: settings.swingWeights) * 100))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.swingWeights[component] ?? 0 },
                            set: { settings.swingWeights[component] = $0 }
                        ),
                        in: 0...1
                    )
                    AdvancedOnly {
                        Text(component.explanation)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Swing signal weights")
        } footer: {
            Text("Refreshes every 15 minutes from daily bars — a swing setup doesn't change fast enough to need a faster cadence than that.")
        }
    }

    private var swingEvidenceSection: some View {
        let summary = paperLog.summary(for: .swing)
        return Section {
            MetricRow(label: "Trades logged", value: "\(summary.total)")
            if summary.resolved > 0 {
                MetricRow(label: "Went the right way", value: "\(Int(summary.winRate * 100))%")
                MetricRow(label: "Average outcome", value: Fmt.percent(summary.averageReturn), tint: Palette.direction(summary.averageReturn))
            } else {
                Text("Log a few swing trades from the Scan tab to see outcomes here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Swing paper log")
        }
    }

    // MARK: - Long-term tuning

    private var longTermWeightsSection: some View {
        @Bindable var settings = settings
        return Section {
            ForEach(LongTermComponent.allCases) { component in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(component.displayName).font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f%%", weightShare(component, in: settings.longTermWeights) * 100))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.longTermWeights[component] ?? 0 },
                            set: { settings.longTermWeights[component] = $0 }
                        ),
                        in: 0...1
                    )
                    AdvancedOnly {
                        Text(component.explanation)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Long-term signal weights")
        } footer: {
            Text("Refreshes every few hours from SEC filings, which themselves only update quarterly. A faster cadence would just re-fetch the same numbers.")
        }
    }

    private var longTermEvidenceSection: some View {
        let summary = paperLog.summary(for: .longTerm)
        return Section {
            MetricRow(label: "Positions logged", value: "\(summary.total)")
            if summary.resolved > 0 {
                MetricRow(label: "Went the right way", value: "\(Int(summary.winRate * 100))%")
                MetricRow(label: "Average outcome", value: Fmt.percent(summary.averageReturn), tint: Palette.direction(summary.averageReturn))
            } else {
                Text("Long-term outcomes take weeks to months to resolve — check back later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Long-term paper log")
        }
    }

    private func weightShare<T: Hashable>(_ key: T, in weights: [T: Double]) -> Double {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return (weights[key] ?? 0) / total
    }
}

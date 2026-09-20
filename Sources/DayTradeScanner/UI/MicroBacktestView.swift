import SwiftUI

struct MicroBacktestView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var engine = MicroBacktestEngine(rest: AlpacaREST())
    @State private var lookbackDays = 5
    @State private var forwardMinutes = 15
    @State private var scoreThreshold = 0.6

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper("Lookback: \(lookbackDays) day\(lookbackDays == 1 ? "" : "s")", value: $lookbackDays, in: 2...14)
                    Stepper("Holding period: \(forwardMinutes) min", value: $forwardMinutes, in: 5...60, step: 5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Signal threshold: \(Fmt.score(scoreThreshold))")
                            .font(.caption)
                        Slider(value: $scoreThreshold, in: 0.3...0.9, step: 0.02)
                    }
                    Button {
                        Task {
                            await engine.run(
                                symbols: settings.universe,
                                lookbackDays: lookbackDays,
                                forwardMinutes: forwardMinutes,
                                scoreThreshold: scoreThreshold
                            )
                        }
                    } label: {
                        if engine.isRunning {
                            HStack { ProgressView(); Text("Running…") }
                        } else {
                            Text("Run micro-backtest")
                        }
                    }
                    .disabled(engine.isRunning || settings.universe.isEmpty)
                } header: {
                    Text("Micro-backtest \(settings.universe.count) day-trade watchlist symbols")
                } footer: {
                    Text("Uses whatever recent minute-bar history the free Alpaca IEX feed retains — usually just a handful of trading days. Relative volume and gap are approximated from this same short window rather than the live engine's proper multi-week baseline, since that baseline needs far more history than a short lookback provides. VWAP, VWAP z-score, and range position replay with full fidelity, using the same SymbolState accumulator the live engine runs.")
                }

                if let error = engine.lastError {
                    Section {
                        Text(error).foregroundStyle(Palette.down).font(.footnote)
                    }
                }

                if let summary = engine.summary {
                    Section("Results") {
                        MetricRow(label: "Bars scored", value: "\(summary.totalBars)")
                        MetricRow(label: "Bars at/above threshold", value: "\(summary.signalBars)")
                        MetricRow(
                            label: "Win rate at threshold",
                            value: String(format: "%.0f%%", summary.signalWinRate * 100),
                            tint: summary.signalWinRate >= 0.5 ? Palette.up : Palette.down
                        )
                        MetricRow(
                            label: "Avg forward return, signal bars",
                            value: Fmt.percent(summary.signalAverageReturn),
                            tint: Palette.direction(summary.signalAverageReturn)
                        )
                        MetricRow(
                            label: "Avg forward return, all bars",
                            value: Fmt.percent(summary.baselineAverageReturn)
                        )
                        MetricRow(
                            label: "Edge over baseline",
                            value: Fmt.percent(summary.edge),
                            tint: Palette.direction(summary.edge)
                        )
                    }
                }
            }
            .navigationTitle("Micro-backtest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

import SwiftUI

struct BacktestView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var engine = BacktestEngine(rest: AlpacaREST())
    @State private var holdingDays = 5
    @State private var scoreThreshold = 0.6

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper("Holding period: \(holdingDays) session\(holdingDays == 1 ? "" : "s")", value: $holdingDays, in: 1...20)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Signal threshold: \(Fmt.score(scoreThreshold))")
                            .font(.caption)
                        Slider(value: $scoreThreshold, in: 0.3...0.9, step: 0.02)
                    }
                    Button {
                        Task { await engine.run(symbols: settings.swingUniverse, holdingDays: holdingDays, scoreThreshold: scoreThreshold) }
                    } label: {
                        if engine.isRunning {
                            HStack { ProgressView(); Text("Running…") }
                        } else {
                            Text("Run backtest")
                        }
                    }
                    .disabled(engine.isRunning || settings.swingUniverse.isEmpty)
                } header: {
                    Text("Backtest \(settings.swingUniverse.count) swing watchlist symbols")
                } footer: {
                    Text("Uses whatever daily-bar history the free Alpaca tier returns (up to ~900 sessions). Float and insider-filing context are left out of every historical day's score, since that data isn't reconstructable retroactively — real-time scores use it, so live and backtested scores aren't perfectly apples-to-apples.")
                }

                if let error = engine.lastError {
                    Section {
                        Text(error).foregroundStyle(Palette.down).font(.footnote)
                    }
                }

                if let summary = engine.summary {
                    Section("Results") {
                        MetricRow(label: "Trading days scored", value: "\(summary.totalDays)")
                        MetricRow(label: "Days at/above threshold", value: "\(summary.signalDays)")
                        MetricRow(
                            label: "Win rate at threshold",
                            value: String(format: "%.0f%%", summary.signalWinRate * 100),
                            tint: summary.signalWinRate >= 0.5 ? Palette.up : Palette.down
                        )
                        MetricRow(
                            label: "Avg forward return, signal days",
                            value: Fmt.percent(summary.signalAverageReturn),
                            tint: Palette.direction(summary.signalAverageReturn)
                        )
                        MetricRow(
                            label: "Avg forward return, all days",
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
            .navigationTitle("Backtest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

import SwiftUI

/// A single rollup across every open paper position — equity trades at any
/// horizon plus options strategies — since a trader managing risk cares
/// about total exposure, not which engine happened to log a position.
struct PortfolioView: View {
    @Environment(PaperTradeLog.self) private var paperLog
    @Environment(OptionsPaperTradeLog.self) private var optionsPaperLog

    private var openEquityTrades: [PaperTrade] {
        paperLog.trades.filter { $0.status == .open }
    }

    private var openOptionsTrades: [OptionsPaperTrade] {
        optionsPaperLog.trades.filter { $0.status == .open }
    }

    /// Equity trades carry no continuous live price — only the fixed
    /// mark-to-market checkpoints — so there's no equivalent single-number
    /// unrealized total the way options positions have one from live marks.
    private var optionsUnrealizedTotal: Double {
        openOptionsTrades.compactMap(\.profitAndLoss).reduce(0, +)
    }

    private var byHorizon: [(TradeHorizon, [PaperTrade])] {
        Dictionary(grouping: openEquityTrades, by: \.horizon)
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(openEquityTrades.count + openOptionsTrades.count)")
                                .font(.title2.monospacedDigit().weight(.semibold))
                            Text("open positions").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.price(optionsUnrealizedTotal))
                                .font(.title2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Palette.direction(optionsUnrealizedTotal))
                            Text("options unrealized P&L").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Equity positions show their most recent resolved mark-to-market checkpoint rather than a live price, since only options positions re-mark on every chain refresh.")
                }

                if !openOptionsTrades.isEmpty {
                    Section("Options") {
                        ForEach(openOptionsTrades) { trade in
                            PortfolioOptionsRow(trade: trade)
                        }
                    }
                }

                ForEach(byHorizon, id: \.0) { horizon, trades in
                    Section(horizon.displayName) {
                        ForEach(trades) { trade in
                            PortfolioEquityRow(trade: trade)
                        }
                    }
                }

                if openEquityTrades.isEmpty && openOptionsTrades.isEmpty {
                    ContentUnavailableView(
                        "No open positions",
                        systemImage: "briefcase",
                        description: Text("Positions you log from any scan or the options chain appear here until closed.")
                    )
                }
            }
            .navigationTitle("Portfolio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let url = CSVExporter.writeTempFile(CSVExporter.export(paperLog.trades), named: "equity-journal") {
                            ShareLink(item: url) { Label("Export equity CSV", systemImage: "square.and.arrow.up") }
                        }
                        if let url = CSVExporter.writeTempFile(CSVExporter.export(optionsPaperLog.trades), named: "options-journal") {
                            ShareLink(item: url) { Label("Export options CSV", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export portfolio")
                }
            }
        }
    }
}

private struct PortfolioEquityRow: View {
    let trade: PaperTrade

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(trade.symbol).font(.subheadline.monospaced().weight(.medium))
                    Text(trade.direction.label).font(.caption2).foregroundStyle(.secondary)
                }
                Text("entry \(Fmt.price(trade.entryPrice))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let ret = trade.bestAvailableReturn {
                Text(Fmt.percent(ret))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(Palette.direction(ret))
            } else {
                Text("pending").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct PortfolioOptionsRow: View {
    let trade: OptionsPaperTrade

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(trade.underlying).font(.subheadline.monospaced().weight(.medium))
                Text("\(trade.legCount) leg\(trade.legCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let pnl = trade.profitAndLoss {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.price(pnl))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(Palette.direction(pnl))
                    if let percent = trade.profitAndLossPercent {
                        Text(Fmt.percent(percent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

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

    /// Cumulative sum of each closed equity trade's resolved return, in the
    /// order they closed. Not a dollar equity curve — equity paper trades
    /// carry no position size, only an entry price and a % return — but a
    /// running sum of per-trade returns is still the standard way to show
    /// "how has this been going" assuming roughly equal-sized bets, the same
    /// approximation any journal without real position sizing makes.
    private var equityCumulativeReturns: [Double] {
        let closed = paperLog.trades
            .filter { $0.status == .closed }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        var running = 0.0
        return closed.compactMap { trade -> Double? in
            guard let ret = trade.bestAvailableReturn else { return nil }
            running += ret
            return running
        }
    }

    /// Cumulative dollar P&L across closed options trades, in the order
    /// they closed — a real dollar equity curve, since options positions
    /// carry an actual premium cost basis.
    private var optionsCumulativePnL: [Double] {
        let closed = optionsPaperLog.trades
            .filter { $0.status == .closed }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        var running = 0.0
        return closed.compactMap { trade -> Double? in
            guard let pnl = trade.profitAndLoss else { return nil }
            running += pnl
            return running
        }
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

                if equityCumulativeReturns.count >= 2 || optionsCumulativePnL.count >= 2 {
                    Section {
                        if equityCumulativeReturns.count >= 2 {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Equity, cumulative return").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Fmt.percent(equityCumulativeReturns.last ?? 0))
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .foregroundStyle(Palette.direction(equityCumulativeReturns.last ?? 0))
                                }
                                FundamentalSparklineView(values: equityCumulativeReturns, color: Palette.cyan)
                                    .frame(height: 44)
                            }
                        }
                        if optionsCumulativePnL.count >= 2 {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Options, cumulative P&L").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Fmt.price(optionsCumulativePnL.last ?? 0))
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .foregroundStyle(Palette.direction(optionsCumulativePnL.last ?? 0))
                                }
                                FundamentalSparklineView(values: optionsCumulativePnL, color: Palette.amber)
                                    .frame(height: 44)
                            }
                        }
                    } header: {
                        Text("Equity curve")
                    } footer: {
                        Text("The equity curve sums each closed trade's resolved return in the order it closed, assuming equal-sized bets — equity paper trades carry no real position size to weight by. The options curve is real dollar P&L, since options positions have an actual premium cost basis.")
                    }
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

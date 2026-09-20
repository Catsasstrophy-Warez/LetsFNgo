import SwiftUI

/// The outermost selector in the app. Placed above everything else because
/// switching horizons is a bigger decision than switching profiles within
/// one: it changes the engine, the data source, and what "done" even means
/// for a position.
struct HorizonPicker: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Picker("Trading horizon", selection: $settings.tradeHorizon) {
            ForEach(TradeHorizon.allCases) { horizon in
                Label(horizon.displayName, systemImage: horizon.systemImage).tag(horizon)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Swing scan

struct SwingScanView: View {
    @Environment(SwingEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Environment(PaperTradeLog.self) private var paperLog
    @State private var selectedSymbol: String?

    var body: some View {
        Group {
            if engine.isRefreshing && engine.candidates.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ProgressView(value: engine.refreshProgress)
                            .frame(maxWidth: 240)
                        Text(engine.refreshMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                }
            } else if engine.candidates.isEmpty {
                EmptyStateView(
                    title: "No swing setups yet",
                    message: "Refreshes every 15 minutes from daily bars. Pull to refresh, or check your watchlist in Settings if this stays empty.",
                    systemImage: "chart.line.uptrend.xyaxis",
                    actionTitle: "Refresh now",
                    action: { Task { await engine.refresh() } }
                )
            } else {
                List {
                    Section {
                        ForEach(engine.candidates) { candidate in
                            Button { selectedSymbol = candidate.symbol } label: {
                                SwingCandidateRow(candidate: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("\(engine.candidates.count) ranked")
                            Spacer()
                            if let refreshed = engine.lastRefreshedAt {
                                Text("updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await engine.refresh() }
            }
        }
        .navigationDestination(item: $selectedSymbol) { symbol in
            SwingDetailView(symbol: symbol)
        }
    }
}

struct SwingCandidateRow: View {
    @Environment(Settings.self) private var settings
    let candidate: SwingCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.symbol)
                    .font(.headline.monospaced())
                Text(Fmt.percent(candidate.snapshot.changePercent))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(Palette.direction(candidate.snapshot.changePercent))
                Text(candidate.setup.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                Spacer()
                Text(Fmt.price(candidate.snapshot.last))
                    .font(.subheadline.monospacedDigit())
                Text(Fmt.score(candidate.score))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            ScoreBar(score: candidate.score)
            Text(candidate.plainReason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let hazard = candidate.hazardNote {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.caption2)
                    Text(hazard).font(.caption2)
                }
                .foregroundStyle(Palette.down)
            }
            AdvancedOnly {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        metric("RS20", Fmt.percent(candidate.snapshot.relativeStrength20Day))
                        metric("vol", Fmt.multiple(candidate.snapshot.volumeVsAverage))
                        metric("52wk", String(format: "%.0f%%", candidate.snapshot.positionIn52WeekRange * 100))
                        metric("ATR", String(format: "%.1f%%", candidate.snapshot.atrPercent * 100))
                    }
                }
                .font(.caption2.monospacedDigit())
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }
}

struct SwingDetailView: View {
    @Environment(SwingEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Environment(PaperTradeLog.self) private var paperLog
    let symbol: String
    @State private var showPositionSizer = false

    private var candidate: SwingCandidate? { engine.candidate(for: symbol) }

    var body: some View {
        List {
            if let candidate {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Fmt.price(candidate.snapshot.last))
                                .font(.system(size: 32, weight: .medium, design: .monospaced))
                            Text(Fmt.percent(candidate.snapshot.changePercent))
                                .font(.title3.monospacedDigit().weight(.medium))
                                .foregroundStyle(Palette.direction(candidate.snapshot.changePercent))
                        }
                        ScoreBar(score: candidate.score, height: 8)
                        Text(candidate.plainReason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let sector = candidate.snapshot.sector {
                            Text(sector)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Trend") {
                    MetricRow(label: "20-day average", value: Fmt.price(candidate.snapshot.sma20))
                    MetricRow(label: "50-day average", value: Fmt.price(candidate.snapshot.sma50))
                    MetricRow(label: "200-day average", value: Fmt.price(candidate.snapshot.sma200))
                    MetricRow(
                        label: "50-day slope (10d)",
                        value: Fmt.percent(candidate.snapshot.sma50SlopePercent),
                        tint: Palette.direction(candidate.snapshot.sma50SlopePercent)
                    )
                    MetricRow(label: "Relative strength, 20d", value: Fmt.percent(candidate.snapshot.relativeStrength20Day))
                    MetricRow(label: "Relative strength, 60d", value: Fmt.percent(candidate.snapshot.relativeStrength60Day))
                }

                Section("Range") {
                    MetricRow(label: "52-week range", value: "\(Fmt.price(candidate.snapshot.low52Week))–\(Fmt.price(candidate.snapshot.high52Week))")
                    MetricRow(label: "Position in range", value: String(format: "%.0f%%", candidate.snapshot.positionIn52WeekRange * 100))
                    MetricRow(label: "20-day high", value: Fmt.price(candidate.snapshot.priorRangeHigh20))
                }

                Section("Volume") {
                    MetricRow(label: "Vs 20-day average", value: Fmt.multiple(candidate.snapshot.volumeVsAverage))
                    MetricRow(label: "5d/20d volume trend", value: Fmt.multiple(candidate.snapshot.volumeTrend))
                }

                if let category = candidate.snapshot.floatCategory {
                    Section {
                        MetricRow(label: "Float", value: category.displayName, tint: category.carriesElevatedRisk ? .orange : .primary)
                        MetricRow(label: "Insider filings, 90d", value: "\(candidate.snapshot.insiderFilingsRecent)")
                        if let days = candidate.snapshot.estimatedDaysToNextFiling {
                            MetricRow(
                                label: "Est. days to next filing",
                                value: "\(days)",
                                tint: days <= 7 ? .orange : .primary
                            )
                        }
                    } header: { Text("Float & filings") } footer: {
                        Text("Next-filing estimate is projected from filing cadence, not a confirmed date — free EDGAR data has no forward-looking earnings field.")
                    }
                }

                Section {
                    RevealSection(title: "How this score was built") {
                        VStack(spacing: 10) {
                            ForEach(candidate.breakdown.sortedContributions, id: \.0) { component, contribution in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(component.displayName).font(.footnote)
                                        Spacer()
                                        Text(Fmt.score(contribution))
                                            .font(.footnote.monospacedDigit())
                                            .foregroundStyle(contribution >= 0 ? .primary : Palette.down)
                                    }
                                    ScoreBar(score: max(contribution / max(candidate.score, 0.01), 0), height: 4)
                                    AdvancedOnly {
                                        Text(component.explanation)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button("Position size calculator") { showPositionSizer = true }
                }

                Section {
                    Button("Log as paper trade") {
                        paperLog.openGeneric(
                            symbol: candidate.symbol,
                            entryPrice: candidate.snapshot.last,
                            direction: .long,
                            score: candidate.score,
                            reason: candidate.plainReason,
                            horizon: .swing,
                            floatCategory: candidate.snapshot.floatCategory
                        )
                    }
                }
            } else {
                EmptyStateView(
                    title: "\(symbol) isn't ranked right now",
                    message: "It didn't clear the swing gates on the last refresh.",
                    systemImage: "magnifyingglass"
                )
            }
        }
        .navigationTitle(symbol)
        .sheet(isPresented: $showPositionSizer) {
            if let candidate {
                let atrEstimate = candidate.snapshot.atrPercent * candidate.snapshot.last
                let stop = PositionSizer.suggestedStop(
                    entry: candidate.snapshot.last,
                    atr: max(atrEstimate, candidate.snapshot.last * 0.01),
                    direction: .long,
                    multiple: 2.0
                )
                PositionSizerView(entryPrice: candidate.snapshot.last, stopPrice: stop, direction: .long)
            }
        }
    }
}

import SwiftUI

struct LongTermScanView: View {
    @Environment(LongTermEngine.self) private var engine
    @Environment(Settings.self) private var settings
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
                        Text("Fundamentals come from SEC filings, one company at a time — a short watchlist refreshes in under a minute.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.top, 40)
                }
            } else if engine.candidates.isEmpty {
                EmptyStateView(
                    title: "No fundamentals yet",
                    message: "Add companies to your long-term watchlist in Settings, then refresh.",
                    systemImage: "building.columns",
                    actionTitle: "Refresh now",
                    action: { Task { await engine.refresh() } }
                )
            } else {
                List {
                    Section {
                        ForEach(engine.candidates) { candidate in
                            Button { selectedSymbol = candidate.symbol } label: {
                                LongTermCandidateRow(candidate: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("\(engine.candidates.count) ranked")
                            Spacer()
                            if let refreshed = engine.lastRefreshedAt {
                                Text("updated \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    } footer: {
                        Text("Scores can go slightly negative — a shrinking, overleveraged, richly-valued business should visibly rank below zero rather than just scoring low.")
                    }
                }
                .listStyle(.plain)
                .refreshable { await engine.refresh() }
            }
        }
        .navigationDestination(item: $selectedSymbol) { symbol in
            LongTermDetailView(symbol: symbol)
        }
    }
}

struct LongTermCandidateRow: View {
    let candidate: LongTermCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.symbol)
                    .font(.headline.monospaced())
                Spacer()
                if let ps = candidate.snapshot.priceToSales {
                    Text(String(format: "%.1f× sales", ps))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(Fmt.score(candidate.score))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            ScoreBar(score: max(candidate.score, 0))
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
        }
    }
}

struct LongTermDetailView: View {
    @Environment(LongTermEngine.self) private var engine
    @Environment(PaperTradeLog.self) private var paperLog
    let symbol: String
    @State private var showPositionSizer = false

    private var candidate: LongTermCandidate? { engine.candidate(for: symbol) }

    var body: some View {
        List {
            if let candidate {
                let snapshot = candidate.snapshot

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(snapshot.entityName)
                            .font(.headline)
                        if let sector = snapshot.sector {
                            Text(sector)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(Fmt.price(snapshot.lastPrice))
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                        ScoreBar(score: max(candidate.score, 0), height: 8)
                        Text(candidate.plainReason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Growth & profitability") {
                    if let growth = snapshot.revenueGrowthYoY {
                        MetricRow(label: "Revenue growth, YoY", value: Fmt.percent(growth), tint: Palette.direction(growth))
                    }
                    if let revenue = snapshot.revenueTTM {
                        MetricRow(label: "Revenue, TTM", value: "$\(Fmt.compactVolume(revenue))")
                    }
                    if let margin = snapshot.netMarginTTM {
                        MetricRow(label: "Net margin, TTM", value: Fmt.percent(margin, signed: false), tint: Palette.direction(margin))
                    }
                    if let trend = snapshot.marginTrend {
                        MetricRow(label: "Margin trend, YoY", value: Fmt.percent(trend), tint: Palette.direction(trend))
                    }
                }

                Section {
                    if let marketCap = snapshot.marketCap {
                        MetricRow(label: "Market cap", value: "$\(Fmt.compactVolume(marketCap))")
                    }
                    if let ps = snapshot.priceToSales {
                        MetricRow(label: "Price / sales", value: String(format: "%.1f×", ps))
                    }
                } header: { Text("Valuation") } footer: {
                    Text("Price-to-sales rather than P/E, since P/E is undefined for any company without positive trailing earnings.")
                }

                Section("Balance sheet") {
                    if let assets = snapshot.totalAssets {
                        MetricRow(label: "Total assets", value: "$\(Fmt.compactVolume(assets))")
                    }
                    if let liabilities = snapshot.totalLiabilities {
                        MetricRow(label: "Total liabilities", value: "$\(Fmt.compactVolume(liabilities))")
                    }
                    if let leverage = snapshot.leverageRatio {
                        MetricRow(
                            label: "Liabilities / assets",
                            value: String(format: "%.0f%%", leverage * 100),
                            tint: leverage > 0.8 ? .orange : .primary
                        )
                    }
                }

                Section("Price trend") {
                    if let vsSMA = snapshot.priceVsSMA200Percent {
                        MetricRow(label: "Vs 200-day average", value: Fmt.percent(vsSMA), tint: Palette.direction(vsSMA))
                    }
                    if let distance = snapshot.distanceFrom52WeekHighPercent {
                        MetricRow(label: "Vs 52-week high", value: Fmt.percent(distance), tint: Palette.direction(distance))
                    }
                }

                if let category = snapshot.floatCategory {
                    Section {
                        MetricRow(label: "Float", value: category.displayName, tint: category.carriesElevatedRisk ? .orange : .primary)
                        MetricRow(label: "Insider filings, \(snapshot.insiderFilingWindowDays)d", value: "\(snapshot.insiderFilingsRecent)")
                    } header: { Text("Float & insiders") } footer: {
                        Text("Filing frequency, not a signed buy/sell signal — free EDGAR data doesn't expose transaction direction without parsing each filing's ownership XML.")
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
                                    ScoreBar(score: max(contribution / max(abs(candidate.score), 0.01), 0), height: 4)
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
                    Button("Log as paper position") {
                        paperLog.openGeneric(
                            symbol: candidate.symbol,
                            entryPrice: snapshot.lastPrice,
                            direction: .long,
                            score: candidate.score,
                            reason: candidate.plainReason,
                            horizon: .longTerm,
                            floatCategory: snapshot.floatCategory
                        )
                    }
                }
            } else {
                EmptyStateView(
                    title: "\(symbol) isn't scored yet",
                    message: "Either it's still loading or SEC EDGAR didn't return enough fundamentals data for it.",
                    systemImage: "magnifyingglass"
                )
            }
        }
        .navigationTitle(symbol)
        .sheet(isPresented: $showPositionSizer) {
            if let candidate {
                // No ATR in a fundamentals snapshot — an 8% stop is a common
                // long-term position-sizing convention, not a technical level.
                PositionSizerView(
                    entryPrice: candidate.snapshot.lastPrice,
                    stopPrice: candidate.snapshot.lastPrice * 0.92,
                    direction: .long
                )
            }
        }
    }
}

import SwiftUI

struct SymbolDetailView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    let symbol: String

    @State private var baseline: VolumeBaseline?
    @State private var showPositionSizer = false
    @State private var haltEvent: HaltMonitor.HaltEvent?

    private var candidate: Candidate? { engine.candidate(for: symbol) }
    private var state: SymbolState? { engine.state(for: symbol) }

    var body: some View {
        List {
            if let candidate {
                headerSection(candidate)
                NarrativeSectionView(narrative: NarrativeGenerator.forDayTrade(candidate))
                chartSection
                signalSection(candidate)
                floatSection
                socialSection
                haltSection
                newsSection
                contributionSection(candidate)
                AdvancedOnly { rawSection(candidate) }
                AdvancedOnly { baselineSection }
            } else {
                Section {
                    EmptyStateView(
                        title: "\(symbol) isn't ranked right now",
                        message: "It's either gated out or hasn't moved enough to score. Check the filtered list on the scan screen.",
                        systemImage: "magnifyingglass"
                    )
                }
            }
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .principal) { ModeToggle() } }
        .task {
            baseline = await engine.baseline(for: symbol)
            haltEvent = await engine.haltEvent(for: symbol)
        }
        .sheet(isPresented: $showPositionSizer) {
            if let candidate {
                let atr = candidate.snapshot.atr14 > 0 ? candidate.snapshot.atr14 : candidate.snapshot.last * 0.01
                let suggestedStop = PositionSizer.suggestedStop(
                    entry: candidate.snapshot.last,
                    atr: atr,
                    direction: candidate.snapshot.vwapEvent == .loss ? .short : .long
                )
                PositionSizerView(
                    entryPrice: candidate.snapshot.last,
                    stopPrice: suggestedStop,
                    direction: candidate.snapshot.vwapEvent == .loss ? .short : .long
                )
            }
        }
    }

    // MARK: - Sections

    private func headerSection(_ candidate: Candidate) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.price(candidate.snapshot.last))
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                    Text(Fmt.percent(candidate.snapshot.changePercent))
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(Palette.direction(candidate.snapshot.changePercent))
                    Spacer()
                }
                ScoreBar(score: candidate.score, height: 8)
                HStack {
                    Text(candidate.plainReason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.score(candidate.score))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
                Button("Position size calculator") { showPositionSizer = true }
                    .font(.footnote)
            }
            .padding(.vertical, 4)
        }
    }

    /// Metal-backed candlestick + VWAP + volume chart (`Rendering/CandleChartRenderer.swift`),
    /// falling back to the lightweight `VWAPSparkline` if fewer than a handful
    /// of bars have streamed in yet.
    private var chartSection: some View {
        Section {
            if let state, state.recentBars.count > 2 {
                CandleChartView(bars: state.recentBars, vwaps: state.recentVWAPs)
                    .frame(height: 220)
                    .padding(.vertical, 4)
                if let candidate {
                    ChartAnnotationStrip(candidate: candidate, state: state)
                }
            } else if let state, state.recentCloses.count > 2 {
                VStack(alignment: .leading, spacing: 6) {
                    VWAPSparkline(prices: state.recentCloses, vwaps: state.recentVWAPs, height: 70)
                    HStack(spacing: 14) {
                        Label("Price", systemImage: "minus").foregroundStyle(.primary)
                        Label("VWAP", systemImage: "ellipsis").foregroundStyle(.secondary)
                        Spacer()
                        Text("last \(state.recentCloses.count) min").foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                }
                .padding(.vertical, 4)
            } else {
                Text("Waiting for enough bars to draw a chart.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The plain-language reading. This is what simple mode is for: the same
    /// facts as the advanced panel, stated as sentences rather than numbers.
    private func signalSection(_ candidate: Candidate) -> some View {
        let snapshot = candidate.snapshot
        return Section("What's happening") {
            MetricRow(
                label: "Volume",
                value: "\(Fmt.multiple(snapshot.rvol)) normal pace",
                tint: snapshot.rvol >= 2 ? Palette.up : .primary
            )
            MetricRow(
                label: "VWAP",
                value: snapshot.trend == .aboveVWAP
                    ? "\(Fmt.price(snapshot.vwap)), trading above"
                    : "\(Fmt.price(snapshot.vwap)), trading below",
                tint: snapshot.trend == .aboveVWAP ? Palette.up : Palette.down
            )
            if snapshot.vwapEvent != .none {
                MetricRow(
                    label: "Last cross",
                    value: "\(snapshot.vwapEvent.label), \(Fmt.minutes(snapshot.minutesSinceVWAPEvent.map(Double.init)))"
                )
            }
            MetricRow(label: "Gap from prior close", value: Fmt.percent(snapshot.gapPercent))
            MetricRow(
                label: "Day range",
                value: "\(Fmt.price(snapshot.dayLow))–\(Fmt.price(snapshot.dayHigh)), \(Int(snapshot.rangePosition * 100))% up"
            )
            if let percentile = snapshot.shortRatioPercentile {
                MetricRow(
                    label: "Short volume rank",
                    value: "higher than \(Int(percentile * 100))% of the market"
                )
            }
        }
    }

    /// Float, sourced from the company's own SEC cover-page filings rather
    /// than estimated. Shown in both modes because it is the single most
    /// load-bearing number in small-cap momentum trading.
    private var floatSection: some View {
        Group {
            if let record = engine.floatRecord(for: symbol) {
                Section {
                    if let category = record.category, let shares = record.floatShares {
                        MetricRow(
                            label: "Float",
                            value: "\(Fmt.compactVolume(shares)) shares · \(category.displayName.lowercased())",
                            tint: category.carriesElevatedRisk ? .orange : .primary
                        )
                    } else {
                        MetricRow(label: "Float", value: "Not filed", tint: .secondary)
                    }

                    if let candidate, let rotation = candidate.snapshot.extended.floatRotation {
                        MetricRow(
                            label: "Float rotation today",
                            value: Fmt.multiple(rotation),
                            tint: rotation >= 1 ? Palette.up : .primary
                        )
                    }

                    AdvancedOnly {
                        if let outstanding = record.sharesOutstanding {
                            MetricRow(label: "Shares outstanding", value: Fmt.compactVolume(outstanding))
                        }
                        if let dollars = record.publicFloatUSD {
                            MetricRow(label: "Public float", value: "$\(Fmt.compactVolume(dollars))")
                        }
                        if let nonFloat = record.nonFloatPercent {
                            MetricRow(label: "Held by affiliates", value: String(format: "%.0f%%", nonFloat * 100))
                        }
                        if let age = record.ageInDays {
                            MetricRow(
                                label: "Filed",
                                value: "\(age) days ago",
                                tint: record.isPotentiallyStale ? .orange : .primary
                            )
                        }
                    }
                } header: {
                    Text("Float")
                } footer: {
                    Text(record.isPotentiallyStale
                         ? "This figure is over four months old and predates any offering priced since. Check the headlines before trusting it."
                         : "From the company's SEC cover-page filings. Quarterly at best, and blind to any share issuance after the last report.")
                }
            }
        }
    }

    /// Retail sentiment and filing-cluster context, from the two free sources
    /// added alongside price and volume.
    private var socialSection: some View {
        Group {
            if let sentiment = engine.socialSentiment(for: symbol) {
                Section {
                    if let rank = candidate?.snapshot.extended.socialTrendingRank {
                        MetricRow(label: "StockTwits trending", value: "#\(rank + 1)")
                    }
                    if sentiment.taggedFraction > 0.2 {
                        MetricRow(
                            label: "Sentiment",
                            value: String(format: "%+.0f%% (%d tagged)", sentiment.sentimentScore * 100, sentiment.bullishCount + sentiment.bearishCount),
                            tint: Palette.direction(sentiment.sentimentScore)
                        )
                    }
                    AdvancedOnly {
                        MetricRow(label: "Messages seen", value: "\(sentiment.messageCount)")
                        MetricRow(label: "Bullish / bearish", value: "\(sentiment.bullishCount) / \(sentiment.bearishCount)")
                    }
                } header: {
                    Text("Social")
                } footer: {
                    Text("From StockTwits' public message stream. Only tagged Bullish/Bearish messages count toward sentiment.")
                }
            }

            if let cluster = engine.insiderCluster(for: symbol) {
                Section {
                    MetricRow(label: "Insider filings", value: "\(cluster.filingCount)", tint: cluster.isSignificant ? .orange : .primary)
                    MetricRow(label: "Company", value: cluster.companyName)
                } header: {
                    Text("Insider activity")
                } footer: {
                    Text("Live from SEC EDGAR's own filing feed, not a third-party summary. Three or more separate filers in a short window is the threshold most cluster-buy research treats as meaningful.")
                }
            }

            if let report = engine.filedReport(for: symbol) {
                Section {
                    MetricRow(label: "Form", value: report.form)
                    MetricRow(label: "Filed", value: MarketClock.timeLabel(report.filedAt) + " ET")
                    Link("Open filing", destination: report.filingURL)
                        .font(.footnote)
                } header: {
                    Text("Recent SEC filing")
                } footer: {
                    Text("The primary source. Any headline covering this is a republication, sometimes minutes behind.")
                }
            }
        }
    }

    private var haltSection: some View {
        Group {
            if let event = haltEvent {
                Section {
                    MetricRow(
                        label: event.isResumed ? "Last halt" : "Halted now",
                        value: "\(event.code.rawValue) · \(event.code.displayName)",
                        tint: event.isResumed ? .primary : Palette.down
                    )
                    MetricRow(label: "Halted at", value: MarketClock.timeLabel(event.haltedAt) + " ET")
                    if let resume = event.resumeTradeAt {
                        MetricRow(label: "Resumed", value: MarketClock.timeLabel(resume) + " ET")
                    }
                    if let percent = event.percentIntoHalt {
                        MetricRow(
                            label: "Into the pause",
                            value: Fmt.percent(percent),
                            tint: Palette.direction(percent)
                        )
                    }
                    Text(event.code.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Halt")
                }
            }
        }
    }

    private var newsSection: some View {
        Group {
            if let state, !state.news.isEmpty {
                Section("Headlines") {
                    ForEach(state.news.prefix(5)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.headline)
                                .font(.subheadline)
                                .lineLimit(3)
                            HStack(spacing: 6) {
                                Text(item.category.rawValue)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                Text(Fmt.minutes(Date().timeIntervalSince(item.createdAt) / 60))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let url = item.url, let link = URL(string: url) {
                                    Spacer()
                                    Link("Open", destination: link)
                                        .font(.caption2)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    /// Available in both modes as a collapsed reveal — this is the local
    /// toggle that lets you inspect the scoring on one symbol without
    /// switching the whole interface to advanced.
    private func contributionSection(_ candidate: Candidate) -> some View {
        Section {
            RevealSection(
                title: "How this score was built",
                subtitle: "Tap to see what each signal contributed"
            ) {
                VStack(spacing: 10) {
                    ForEach(candidate.breakdown.sortedContributions, id: \.0) { component, contribution in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(component.displayName)
                                    .font(.footnote)
                                Spacer()
                                Text(Fmt.score(contribution))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(contribution > 0 ? .primary : Palette.down)
                            }
                            ScoreBar(score: max(contribution / max(candidate.score, 0.01), 0), height: 4)
                            AdvancedOnly {
                                HStack {
                                    Text("raw \(Fmt.score(candidate.breakdown.normalized[component] ?? 0))")
                                    Text("× weight \(Fmt.score(settings.scoring.normalizedWeight(component)))")
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func rawSection(_ candidate: Candidate) -> some View {
        let snapshot = candidate.snapshot
        return Section("Raw values") {
            MetricRow(label: "VWAP z-score", value: Fmt.sigma(snapshot.vwapZ))
            MetricRow(label: "Session VWAP", value: Fmt.price(snapshot.vwap))
            MetricRow(label: "Cumulative volume (IEX)", value: Fmt.compactVolume(snapshot.cumulativeVolume))
            MetricRow(label: "Baseline at minute \(snapshot.minuteOfSession)", value: Fmt.compactVolume(snapshot.baselineVolumeAtMinute))
            MetricRow(label: "Last-bar RVOL", value: Fmt.multiple(snapshot.barRVOL))
            MetricRow(label: "Dollar volume (IEX)", value: "$\(Fmt.compactVolume(snapshot.dollarVolume))")
            MetricRow(label: "Prints in last bar", value: "\(snapshot.tradeCount)")
            MetricRow(label: "ATR(14) daily", value: Fmt.price(snapshot.atr14))
            MetricRow(label: "Session open", value: Fmt.price(snapshot.sessionOpen))
            MetricRow(label: "Prior close", value: Fmt.price(snapshot.priorClose))
        }
    }

    private var baselineSection: some View {
        Group {
            if let baseline {
                Section {
                    MetricRow(label: "Sessions in baseline", value: "\(baseline.sessionsUsed)")
                    MetricRow(label: "Built", value: baseline.builtAt.formatted(date: .abbreviated, time: .shortened))
                    MetricRow(label: "Median daily volume", value: Fmt.compactVolume(baseline.medianDailyVolume))
                } header: {
                    Text("Baseline")
                } footer: {
                    Text("Volume figures come from IEX only, which is a fraction of consolidated volume. The ratio is meaningful; the absolute number is not.")
                }
            }
        }
    }
}

import SwiftUI

struct ScanView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(SwingEngine.self) private var swingEngine
    @Environment(LongTermEngine.self) private var longTermEngine
    @Environment(Settings.self) private var settings
    @State private var selectedSymbol: String?
    @State private var showRejected = false
    @State private var showRecipes = false
    @State private var show3DPulse = false

    var body: some View {
        NavigationStack {
            Group {
                switch settings.tradeHorizon {
                case .dayTrade: dayTradeContent
                case .swing: SwingScanView()
                case .longTerm: LongTermScanView()
                }
            }
            .navigationTitle(settings.tradeHorizon == .dayTrade ? "Scan" : settings.tradeHorizon.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    MarketRegimeBanner()
                    HorizonPicker()
                    if settings.tradeHorizon == .dayTrade {
                        SessionHeader()
                        ProfilePicker()
                        RecipeBar(showRecipes: $showRecipes)
                    }
                    Divider()
                }
                .background(.bar)
            }
            .toolbar {
                if settings.tradeHorizon == .dayTrade {
                    ToolbarItem(placement: .principal) { ModeToggle() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { engine.isRunning ? await engine.stop() : await engine.start() }
                        } label: {
                            Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        }
                        .accessibilityLabel(engine.isRunning ? "Stop scanning" : "Start scanning")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { show3DPulse = true } label: { Image(systemName: "cube") }
                            .disabled(engine.candidates.isEmpty)
                            .accessibilityLabel("3D market pulse")
                    }
                } else {
                    ToolbarItem(placement: .principal) { ModeToggle() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                if settings.tradeHorizon == .swing { await swingEngine.refresh() }
                                else { await longTermEngine.refresh() }
                            }
                        } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .sheet(isPresented: $showRecipes) { RecipePicker() }
            .sheet(isPresented: $show3DPulse) { MarketPulse3DView(candidates: engine.candidates) }
            .navigationDestination(item: $selectedSymbol) { symbol in
                SymbolDetailView(symbol: symbol)
            }
        }
    }

    private var dayTradeContent: some View {
        Group {
                if engine.isPreparing {
                    ScrollView { PreparationView() }
                } else if !settings.hasCredentials {
                    EmptyStateView(
                        title: "Add your Alpaca keys",
                        message: "The scanner needs an Alpaca key and secret to stream market data. A free paper-trading account is enough.",
                        systemImage: "key",
                        actionTitle: nil,
                        action: nil
                    )
                } else if !engine.isRunning {
                    EmptyStateView(
                        title: "Scanner is stopped",
                        message: "Start the scanner to stream minute bars and rank setups. Keep this screen open — iOS suspends background work, so scanning stops when you leave the app.",
                        systemImage: "play.circle",
                        actionTitle: "Start scanning",
                        action: { Task { await engine.start() } }
                    )
                } else if engine.candidates.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            EmptyStateView(
                                title: emptyTitle,
                                message: emptyMessage,
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                            AdvancedOnly { rejectionSummary }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        MarketOverview()
                        list
                    }
                }
            }
        }

    private var emptyTitle: String {
        engine.phase == .regular ? "Nothing qualifies yet" : "Market is \(engine.phase.label.lowercased())"
    }

    private var emptyMessage: String {
        engine.phase == .regular
            ? "No symbol in the universe is clearing the volume and liquidity gates. Loosen them in Tuning, or widen the universe in Settings."
            : "Ranking needs the regular session's volume curve. The list fills in from 9:30 ET."
    }

    private var list: some View {
        List {
            Section {
                ForEach(engine.candidates) { candidate in
                    Button {
                        selectedSymbol = candidate.symbol
                    } label: {
                        CandidateRow(candidate: candidate)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            } header: {
                HStack {
                    Text("\(engine.candidates.count) ranked")
                    Spacer()
                    AdvancedOnly {
                        Text("scored in \(Int(engine.diagnostics.scoringDurationMs))ms")
                            .monospacedDigit()
                    }
                }
            }

            AdvancedOnly {
                Section {
                    DisclosureGroup("Filtered out (\(engine.rejected.count))", isExpanded: $showRejected) {
                        rejectionBreakdown
                    }
                    .font(.subheadline)
                } footer: {
                    Text("Symbols that were gated before scoring. This is where to look when something you expected to see isn't on the list.")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .refreshable { await engine.rescore() }
    }

    private var rejectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why nothing is showing")
                .font(.subheadline.weight(.medium))
            rejectionBreakdown
        }
        .padding()
    }

    private var rejectionBreakdown: some View {
        let grouped = Dictionary(grouping: engine.rejected, by: \.reason)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(grouped.keys.sorted(by: { grouped[$0]!.count > grouped[$1]!.count }), id: \.self) { reason in
                let symbols = grouped[reason]!.map(\.symbol).sorted()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(reason.rawValue)
                            .font(.subheadline)
                        Spacer()
                        Text("\(symbols.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(symbols.prefix(12).joined(separator: ", ") + (symbols.count > 12 ? "…" : ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct MarketOverview: View {
    @Environment(ScannerEngine.self) private var engine

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(status: engine.diagnostics.barStreamStatus)
                    Text("MARKET PULSE")
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }
                Text(engine.phase.label)
                    .font(.title3.weight(.bold))
                Text(engine.diagnostics.barStreamStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)
            SignalBadge(title: "RANKED", value: "\(engine.candidates.count)")
            SignalBadge(title: "ALERTS", value: "\(engine.slotsRemaining)/\(engine.slotsCapacity)", tint: engine.slotsRemaining > 0 ? Palette.up : Palette.down)
        }
        .traderCard(emphasized: true)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - Row

struct CandidateRow: View {
    @Environment(Settings.self) private var settings
    @Environment(ScannerEngine.self) private var engine
    let candidate: Candidate

    private var snapshot: SignalSnapshot { candidate.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScoreBar(score: candidate.score)
            HStack(spacing: 6) {
                SetupStateBadge(state: candidate.setupState)
                SignalBadge(title: "RVOL", value: Fmt.multiple(snapshot.rvol), tint: snapshot.rvol >= 2 ? Palette.up : Palette.cyan)
                SignalBadge(title: "VWAP", value: snapshot.trend == .aboveVWAP ? "ABOVE" : "BELOW", tint: snapshot.trend == .aboveVWAP ? Palette.up : Palette.down)
                if let category = snapshot.extended.floatCategory {
                    SignalBadge(title: "FLOAT", value: category.shortLabel, tint: Palette.amber)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                StatusDot(status: engine.diagnostics.barStreamStatus)
                Text("IEX feed")
                Text("·")
                // Fixed: was a bare string literal (never interpolated), so
                // every row previously rendered the text "updated (Fmt.minutes(...))"
                // verbatim instead of a real freshness label.
                Text("updated \(Fmt.minutes(max(0, Date().timeIntervalSince(snapshot.asOf) / 60)))")
                Spacer()
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            Text(candidate.plainReason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let hazard = candidate.hazardNote {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                    Text(hazard)
                        .font(.caption2)
                }
                .foregroundStyle(Palette.down)
            }

            AdvancedOnly {
                metricGrid
                contributionStrip
            }
        }
        .traderCard(emphasized: candidate.score >= 0.75)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(candidate.symbol)
                .font(.headline.monospaced())

            Text(Fmt.percent(snapshot.changePercent))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(Palette.direction(snapshot.changePercent))

            if snapshot.vwapEvent != .none, let minutes = snapshot.minutesSinceVWAPEvent, minutes <= 5 {
                Text(snapshot.vwapEvent == .reclaim ? "VWAP ↑" : "VWAP ↓")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            (snapshot.vwapEvent == .reclaim ? Palette.up : Palette.down).opacity(0.15)
                        )
                    )
                    .foregroundStyle(snapshot.vwapEvent == .reclaim ? Palette.up : Palette.down)
            }

            if let category = snapshot.extended.floatCategory,
               category != .large, category != .medium {
                Text(category.shortLabel)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }

            if snapshot.newsCategory != nil, let age = snapshot.newsAgeMinutes, age < 60 {
                Image(systemName: "newspaper")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Fmt.price(snapshot.last))
                .font(.subheadline.monospacedDigit())

            Text(Fmt.score(candidate.score))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// Advanced mode: every raw input to the score, so you can sanity-check
    /// the ranking without leaving the list.
    private var metricGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                metric("RVOL", Fmt.multiple(snapshot.rvol))
                metric("bar", Fmt.multiple(snapshot.barRVOL))
                metric("VWAP", Fmt.sigma(snapshot.vwapZ))
                metric("gap", Fmt.percent(snapshot.gapPercent))
            }
            GridRow {
                metric("vol", Fmt.compactVolume(snapshot.cumulativeVolume))
                metric("range", String(format: "%.0f%%", snapshot.rangePosition * 100))
                metric("news", Fmt.minutes(snapshot.newsAgeMinutes))
                metric("short", snapshot.shortRatioPercentile.map { String(format: "p%.0f", $0 * 100) } ?? "—")
            }
            GridRow {
                metric("float", snapshot.extended.floatShares.map { Fmt.compactVolume($0) } ?? "—")
                metric("rot", snapshot.extended.floatRotation.map { Fmt.multiple($0) } ?? "—")
                metric("ext", String(format: "%.1fATR", snapshot.extended.extensionATR))
                metric("halts", "\(snapshot.extended.haltsToday)")
            }
        }
        .font(.caption2.monospacedDigit())
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }

    /// A stacked bar showing which components produced the score.
    private var contributionStrip: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(candidate.breakdown.sortedContributions.filter { $0.1 > 0.001 }, id: \.0) { pair in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3 + (pair.1 / max(candidate.score, 0.01)) * 0.6))
                        .frame(width: geometry.size.width * (pair.1 / max(candidate.score, 0.01)))
                        .accessibilityLabel("\(pair.0.displayName) contributed \(Fmt.score(pair.1))")
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
    }
}

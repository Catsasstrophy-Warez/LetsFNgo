import SwiftUI

/// Horizontal profile selector. Sits above the scan list so switching between
/// day trading and scalping is one tap, not a trip into settings.
struct ProfilePicker: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScanProfile.allCases) { profile in
                    let isSelected = settings.activeProfile == profile
                    Button {
                        engine.switchProfile(to: profile)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: profile.systemImage)
                                .font(.caption)
                            Text(profile.displayName)
                                .font(.subheadline.weight(isSelected ? .medium : .regular))
                            if profile.isActiveNow && !isSelected {
                                Circle()
                                    .fill(Palette.up)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)
                            )
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier("scan.profiles")
        .padding(.vertical, 6)
    }
}

struct DiscoveryView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @State private var selectedGappers: Set<String> = []
    @State private var showScreenConfirm = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Group {
                if settings.tradeHorizon != .dayTrade {
                    horizonMismatch
                } else {
                    dayTradeDiscoveryList
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { HorizonPicker() }
            .toolbar {
                ToolbarItem(placement: .principal) { ModeToggle() }
                if settings.tradeHorizon == .dayTrade {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await engine.scanGappers() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(engine.isScreening)
                        .accessibilityLabel("Rescan gappers")
                    }
                }
            }
            .task {
                if settings.tradeHorizon == .dayTrade, engine.gappers.isEmpty, MarketClock.phase() != .closed {
                    await engine.scanGappers()
                }
            }
            .confirmationDialog(
                "Screen the whole market?",
                isPresented: $showScreenConfirm,
                titleVisibility: .visible
            ) {
                Button("Run full screen") {
                    Task { await engine.screenMarket(criteria: settings.discovery) }
                }
            } message: {
                Text("Pulls 60 sessions of daily bars for every tradable US equity, then replaces your universe with the top candidates. Takes several minutes.")
            }
        }
    }

    private var horizonMismatch: some View {
        EmptyStateView(
            title: "Discovery is day-trade only",
            message: "Swing and long-term watchlists are curated by hand in Settings rather than screened from the whole market — a good long-term list is a dozen companies, not hundreds of tickers.",
            systemImage: "scope"
        )
    }

    private var dayTradeDiscoveryList: some View {
            List {
                if engine.isScreening {
                    Section { screeningProgress }
                }

                gapperSection
                sourcesSection
                screenSection
                AdvancedOnly { criteriaSection }
                potentialSection
            }
    }

    // MARK: - Sections

    private var screeningProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: engine.screeningProgress)
            Text(engine.screeningMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var gapperSection: some View {
        Section {
            if engine.gappers.isEmpty {
                Text(MarketClock.phase() == .premarket
                     ? "No gaps above 3% with volume behind them yet. Gappers usually firm up after 7:00 ET."
                     : "Gapper scanning is most useful before the open. Pull to rescan at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.gappers.prefix(25)) { gapper in
                    GapperRow(gapper: gapper, isSelected: selectedGappers.contains(gapper.symbol))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedGappers.contains(gapper.symbol) {
                                selectedGappers.remove(gapper.symbol)
                            } else {
                                selectedGappers.insert(gapper.symbol)
                            }
                        }
                }

                if !selectedGappers.isEmpty {
                    Button("Add \(selectedGappers.count) to scanner") {
                        Task {
                            await engine.adoptGappers(Array(selectedGappers))
                            selectedGappers.removeAll()
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Pre-market gappers")
                Spacer()
                if !engine.gappers.isEmpty {
                    Text("\(engine.gappers.count) found")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Ranked on gap size, pre-market volume against this symbol's own norm, demonstrated move potential and whether there's a headline behind it. Gap size alone ranks badly — a 12% gap on four thousand shares is a stale quote, not a setup.")
        }
    }

    // MARK: - Sources

    /// Free, keyless real-time sources beyond price and volume: retail social
    /// sentiment and the SEC's own live filing feed. Below them, a short list
    /// of sites worth knowing about but not built into the app, because the
    /// data they offer either costs money or updates too slowly to matter
    /// intraday.
    private var sourcesSection: some View {
        Section {
            RevealSection(
                title: "Trending on StockTwits",
                subtitle: engine.trendingSocial.isEmpty ? "No data yet" : "\(engine.trendingSocial.prefix(10).count) shown"
            ) {
                if engine.trendingSocial.isEmpty {
                    Text("Refreshes automatically every 90 seconds while the scanner runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(engine.trendingSocial.prefix(10).enumerated()), id: \.element.symbol) { index, item in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)
                            Text(item.symbol)
                                .font(.subheadline.monospaced().weight(.medium))
                            Spacer()
                            if let count = item.watchlistCount {
                                Text("\(Fmt.compactVolume(Double(count))) watching")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            RevealSection(
                title: "Insider filing clusters today",
                subtitle: engine.insiderClusterList.isEmpty ? "None yet" : "\(engine.insiderClusterList.count) symbols"
            ) {
                if engine.insiderClusterList.isEmpty {
                    Text("Three or more Form 4s filed close together at the same company, sourced live from SEC EDGAR's own filing feed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(engine.insiderClusterList) { cluster in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(cluster.symbol)
                                    .font(.subheadline.monospaced().weight(.medium))
                                Spacer()
                                Text("\(cluster.filingCount) filings")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(cluster.companyName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            RevealSection(
                title: "Live 8-K filings",
                subtitle: "\(engine.recentFiled8Ks.count) in the last 6 hours"
            ) {
                if engine.recentFiled8Ks.isEmpty {
                    Text("Streamed directly from EDGAR's current-filings feed — the primary source, ahead of any headline republishing it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(engine.recentFiled8Ks.prefix(15)) { event in
                        HStack {
                            Text(event.symbol ?? "—")
                                .font(.subheadline.monospaced().weight(.medium))
                                .frame(width: 60, alignment: .leading)
                            Text(event.companyName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(MarketClock.timeLabel(event.filedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            referenceSitesDisclosure
        } header: {
            Text("Live sources")
        } footer: {
            Text("Both feeds are free and keyless — StockTwits' public endpoints and the SEC's own EDGAR filing feed. Reddit was evaluated and excluded: its API now requires manually-approved registration and bills commercial use per call with a four-figure monthly minimum.")
        }
    }

    /// Sites researched but not integrated, and why.
    private var referenceSitesDisclosure: some View {
        DisclosureGroup("Reference sites worth knowing (not integrated)") {
            VStack(alignment: .leading, spacing: 10) {
                referenceRow(
                    name: "OpenInsider",
                    note: "Free Form 4 screener with pre-built cluster-buy and top-purchase views. This app now sources the same underlying filings live; OpenInsider is a good manual cross-check with more historical screening than a phone app needs."
                )
                referenceRow(
                    name: "BioStockInfo catalyst calendar",
                    note: "Free, built from the same EDGAR 8-K/10-Q filings this app streams, but curated into forward-looking PDUFA and trial-readout dates with the company's own wording preserved. Worth checking before holding a biotech overnight."
                )
                referenceRow(
                    name: "StockAnalysis.com",
                    note: "Free fundamentals reference — the free alternative to Seeking Alpha's statistics pages. Useful for a quick company lookup; not a source of intraday signal, since fundamentals don't change minute to minute."
                )
                referenceRow(
                    name: "Seeking Alpha and similar (Simply Wall St, TIKR, Morningstar)",
                    note: "Thesis-driven, holding-period-agnostic research aimed at investors, not day traders. Analysis is written on a delay and doesn't refresh intraday. The right tool for deciding whether to own something for a year, the wrong tool for deciding whether to trade it today."
                )
                referenceRow(
                    name: "Unusual Whales / FlowAlgo / Cheddar Flow",
                    note: "Options flow and dark pool prints are a genuinely different signal — but every provider that publishes real, current data charges for it. This app's own Options tab now includes a free, self-computed unusual-activity detector from Alpaca's chain data as a starting point."
                )
                referenceRow(
                    name: "Reddit / r/wallstreetbets",
                    note: "Excluded on purpose. Self-service API registration is closed, tokens need manual approval, and commercial use bills per call with a four-figure minimum — not viable to build into a shipped app."
                )
            }
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }

    private func referenceRow(name: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.caption.weight(.medium))
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var screenSection: some View {
        Section {
            Picker("Screen preset", selection: presetBinding) {
                Text("Balanced").tag(Preset.balanced)
                Text("High beta").tag(Preset.aggressive)
                Text("Liquid").tag(Preset.liquid)
            }
            .pickerStyle(.segmented)

            Button("Screen the market") { showScreenConfirm = true }
                .disabled(engine.isScreening)

            Button("Refresh current universe") {
                Task { await engine.refreshDiscovery(criteria: settings.discovery) }
            }
            .disabled(engine.isScreening)

            if let summary = engine.lastScreenSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Find candidates")
        } footer: {
            Text("A full screen is a weekly job. Refreshing the current universe is cheap enough to run every morning — it only updates the volatility profiles, not the symbol list.")
        }
    }

    enum Preset: Hashable { case balanced, aggressive, liquid }

    private var presetBinding: Binding<Preset> {
        Binding(
            get: {
                let criteria = settings.discovery
                if criteria.minATRPercent >= 0.05 { return .aggressive }
                if criteria.minMedianDailyVolume >= 3_000_000 { return .liquid }
                return .balanced
            },
            set: { preset in
                switch preset {
                case .balanced: settings.discovery = .default
                case .aggressive: settings.discovery = .aggressive
                case .liquid: settings.discovery = .liquid
                }
            }
        )
    }

    private var criteriaSection: some View {
        @Bindable var settings = settings

        return Section {
            slider("Minimum ATR", value: $settings.discovery.minATRPercent, range: 0.01...0.20, format: "%.1f%%", scale: 100)
            slider("Runner threshold", value: $settings.discovery.runnerThreshold, range: 0.04...0.40, format: "%.0f%% range", scale: 100)
            Stepper("Minimum runner days: \(settings.discovery.minRunnerDays)", value: $settings.discovery.minRunnerDays, in: 0...20)
            slider("Minimum daily volume", value: $settings.discovery.minMedianDailyVolume, range: 50_000...20_000_000, format: "%.1fM", scale: 0.000001)
            slider("Minimum price", value: $settings.discovery.minPrice, range: 0.25...20, format: "$%.2f")
            slider("Maximum price", value: $settings.discovery.maxPrice, range: 20...1000, format: "$%.0f")
            Stepper("Universe cap: \(settings.discovery.maxUniverseSize)", value: $settings.discovery.maxUniverseSize, in: 25...500, step: 25)
            Toggle("Include coiled symbols", isOn: $settings.discovery.includeCompressed)
        } header: {
            Text("Screen criteria")
        } footer: {
            Text("Runner threshold sets what counts as a big day when measuring how often this symbol has actually made one. That frequency is the app's substitute for float data, which no free feed provides.")
        }
    }

    /// The current universe ranked by demonstrated move potential.
    private var potentialSection: some View {
        let ranked = settings.universe
            .compactMap { engine.volatilityProfile(for: $0) }
            .sorted { $0.gainPotential > $1.gainPotential }
            .prefix(30)

        return Group {
            if !ranked.isEmpty {
                Section {
                    ForEach(Array(ranked), id: \.symbol) { profile in
                        PotentialRow(profile: profile)
                    }
                } header: {
                    Text("Move potential in your universe")
                } footer: {
                    Text("Runner days are sessions where the intraday range exceeded your threshold. A symbol that has genuinely gone 15% four times this quarter is a better candidate than one with a merely elevated ATR.")
                }
            }
        }
    }

    private func slider(
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
}

// MARK: - Rows

struct GapperRow: View {
    @Environment(Settings.self) private var settings
    let gapper: UniverseBuilder.Gapper
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(gapper.symbol)
                        .font(.subheadline.monospaced().weight(.medium))
                    Text(Fmt.percent(gapper.gapPercent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Palette.direction(gapper.gapPercent))
                    if gapper.hasNews {
                        Image(systemName: "newspaper")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.price(gapper.lastPrice))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text("\(Fmt.multiple(gapper.premarketVolumeRatio)) pre-market volume")
                    if let profile = gapper.profile {
                        Text("· \(profile.potentialBand.lowercased()) potential")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

                AdvancedOnly {
                    HStack(spacing: 10) {
                        Text("vol \(Fmt.compactVolume(gapper.premarketVolume))")
                        Text("prior \(Fmt.price(gapper.priorClose))")
                        if let profile = gapper.profile {
                            Text("ATR \(String(format: "%.1f%%", profile.atrPercent * 100))")
                            Text("runners \(profile.runnerDayCount)")
                        }
                        Spacer()
                        Text("q\(Fmt.score(gapper.quality))")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct PotentialRow: View {
    @Environment(Settings.self) private var settings
    let profile: VolatilityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.symbol)
                    .font(.subheadline.monospaced().weight(.medium))
                if profile.isCoiled {
                    Text("coiled")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                Text(profile.potentialBand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScoreBar(score: profile.gainPotential, height: 4)

            HStack(spacing: 10) {
                Text("\(profile.runnerDayCount) runner days")
                Text("ATR \(String(format: "%.1f%%", profile.atrPercent * 100))")
                Text("typical \(String(format: "%.1f%%", profile.medianRangePercent * 100))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            AdvancedOnly {
                HStack(spacing: 10) {
                    Text("best \(String(format: "%.0f%%", profile.maxRangePercent * 100))")
                    Text("p90 \(String(format: "%.1f%%", profile.upperRangePercent * 100))")
                    Text("compression \(String(format: "%.2f", profile.compressionRatio))")
                    Text("5m move ≈\(String(format: "%.2f%%", profile.expectedFiveMinuteMovePercent * 100))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

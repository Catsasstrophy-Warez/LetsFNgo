import SwiftUI

struct OptionsView: View {
    @Environment(OptionsEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Environment(OptionsPaperTradeLog.self) private var optionsPaperLog
    @State private var selectedUnderlying: String?
    @State private var showUniverseEditor = false
    @State private var activityFilter = UnusualActivityFilter.default

    var body: some View {
        NavigationStack {
            Group {
                if !settings.hasCredentials {
                    EmptyStateView(
                        title: "Add your Alpaca keys",
                        message: "Option chains use the same Alpaca account as the equity scanner.",
                        systemImage: "key"
                    )
                } else if engine.isRefreshing && engine.chains.isEmpty {
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
                } else {
                    list
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ModeToggle() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUniverseEditor = true } label: { Image(systemName: "list.bullet") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await engine.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(engine.isRefreshing)
                }
            }
            .task { if engine.chains.isEmpty { await engine.refresh() } }
            .sheet(isPresented: $showUniverseEditor) { OptionsUniverseEditor() }
            .navigationDestination(item: $selectedUnderlying) { underlying in
                OptionChainDetailView(underlying: underlying)
            }
        }
    }

    private var list: some View {
        List {
            strategyBotSection
            positionsSection
            unusualActivitySection

            Section {
                ForEach(settings.optionsUniverse, id: \.self) { underlying in
                    Button { selectedUnderlying = underlying } label: {
                        UnderlyingSummaryRow(underlying: underlying, chain: engine.chain(for: underlying))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Chains")
                    Spacer()
                    if let refreshed = engine.lastRefreshedAt {
                        Text("updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                    }
                }
            } footer: {
                Text("Nearest three expirations to start, to keep the request count reasonable on the free tier. Open a chain and use \"Load more expirations\" to widen just that underlying's window.")
            }
        }
        .refreshable { await engine.refresh() }
    }

    private var strategyBotSection: some View {
        Group {
            if !engine.strategyBot.recentAlerts.isEmpty {
                Section {
                    ForEach(engine.strategyBot.recentAlerts.prefix(8)) { alert in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(alert.underlying) — \(alert.kind.title)")
                                    .font(.caption.weight(.medium))
                                Text(alert.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(alert.firedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Strategy bot")
                } footer: {
                    Text("Mechanical lifecycle checkpoints on your open positions: profit target, 21 DTE, expiration day, and stop loss. Each fires once per position.")
                }
            }
        }
    }

    private var positionsSection: some View {
        Group {
            if optionsPaperLog.openCount > 0 {
                Section {
                    ForEach(optionsPaperLog.trades.filter { $0.status == .open }) { trade in
                        OptionsPositionRow(trade: trade)
                    }
                } header: {
                    Text("Open positions")
                } footer: {
                    Text("Marked against the last successful chain refresh. A leg missing from that refresh (expired or delisted) keeps its last known mark instead of showing as zero.")
                }
            }
        }
    }

    private var filteredActivity: [UnusualActivityDetector.Signal] {
        var spotByUnderlying: [String: Double] = [:]
        for (underlying, chain) in engine.chains { spotByUnderlying[underlying] = chain.spotPrice }
        let matched = engine.unusualActivity.filter(activityFilter.matches)
        return activityFilter.sorted(matched, spotByUnderlying: spotByUnderlying)
    }

    private var unusualActivitySection: some View {
        Group {
            if !engine.unusualActivity.isEmpty {
                Section {
                    UnusualActivityFilterBar(filter: $activityFilter)
                    ForEach(filteredActivity.prefix(15)) { signal in
                        UnusualActivityRow(signal: signal)
                    }
                    if filteredActivity.isEmpty {
                        Text("Nothing matches this filter right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Unusual activity")
                } footer: {
                    Text("Self-computed from Alpaca's own chain data: volume against open interest, volume against this contract's own recent pace, and notional size. This is a ranking aid, not a signed buy/sell signal, and it is never blended into the underlying's own day-trade score.")
                }
            }
        }
    }
}

/// Filter/sort controls for the unusual-activity list, plus a menu to save
/// the current combination as a named preset or reapply a saved one.
struct UnusualActivityFilterBar: View {
    @Binding var filter: UnusualActivityFilter
    private let store = UnusualActivityFilterStore.shared

    @State private var showSaveAlert = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(UnusualActivityFilter.Side.allCases, id: \.self) { side in
                        chip(side.label, isSelected: filter.side == side) { filter.side = side }
                    }
                    Divider().frame(height: 14)
                    Menu {
                        ForEach(UnusualActivityFilter.SortKey.allCases, id: \.self) { key in
                            Button(key.label) { filter.sortKey = key }
                        }
                    } label: {
                        chipLabel("Sort: \(filter.sortKey.label)", isSelected: true)
                    }
                    Divider().frame(height: 14)
                    Menu {
                        Button("Save current as preset") { newPresetName = ""; showSaveAlert = true }
                        if !store.presets.isEmpty {
                            Section("Saved presets") {
                                ForEach(store.presets) { preset in
                                    Button(preset.name) { filter = preset }
                                }
                            }
                        }
                    } label: {
                        chipLabel("Presets", isSelected: false, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .alert("Save preset", isPresented: $showSaveAlert) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                let trimmed = newPresetName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                var toSave = filter
                toSave.name = trimmed
                store.save(toSave)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(label, isSelected: isSelected) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ label: String, isSelected: Bool, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(label)
        }
        .font(.caption.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
    }
}

struct UnderlyingSummaryRow: View {
    let underlying: String
    let chain: OptionChain?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(underlying).font(.subheadline.monospaced().weight(.medium))
                if let chain {
                    Text("\(chain.contracts.count) contracts · \(chain.expirations.count) expirations")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not loaded").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let chain {
                Text(Fmt.price(chain.spotPrice))
                    .font(.subheadline.monospacedDigit())
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct UnusualActivityRow: View {
    let signal: UnusualActivityDetector.Signal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(signal.contract.underlying)
                    .font(.subheadline.monospaced().weight(.medium))
                Text(signal.contract.type == .call ? "CALL" : "PUT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(signal.contract.type == .call ? Palette.up : Palette.down)
                Text(Fmt.price(signal.contract.strike))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(signal.contract.daysToExpiration)d")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                // Displayed 0-100 rather than the underlying 0...1 score —
                // matches the "Activity Score" framing Cheddar Flow's Power
                // Alerts and similar competitor products use, so the number
                // reads the same way a trader coming from those tools expects.
                Text("\(Int(signal.score * 100))")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(Palette.score(signal.score))
                    .frame(width: 24, alignment: .trailing)
                ScoreBar(score: signal.score, height: 4).frame(width: 40)
            }
            Text(signal.reasons.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct OptionsPositionRow: View {
    @Environment(OptionsPaperTradeLog.self) private var log
    let trade: OptionsPaperTrade

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trade.underlying).font(.subheadline.monospaced().weight(.medium))
                Text(trade.strategyName).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let pnl = trade.profitAndLoss {
                    Text(Fmt.price(pnl))
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(Palette.direction(pnl))
                } else {
                    Text("—").font(.subheadline).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 10) {
                Text("\(trade.legCount) leg\(trade.legCount == 1 ? "" : "s")")
                Text("opened \(trade.openedAt.formatted(date: .abbreviated, time: .omitted))")
                if let percent = trade.profitAndLossPercent {
                    Text(String(format: "%+.0f%%", percent * 100))
                        .foregroundStyle(Palette.direction(percent))
                }
                Spacer()
                Button("Close") { log.close(trade) }
                    .font(.caption2)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct OptionsUniverseEditor: View {
    @Environment(Settings.self) private var settings
    @Environment(OptionsEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("A small list — each underlying costs a full chain fetch plus quote snapshots for its nearest expirations.")
                }
            }
            .navigationTitle("Options watchlist")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { text = settings.optionsUniverse.joined(separator: ", ") }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let symbols = text
                            .split(whereSeparator: { ", \n\t".contains($0) })
                            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                            .filter { !$0.isEmpty }
                        if !symbols.isEmpty { settings.optionsUniverse = symbols }
                        dismiss()
                        Task { await engine.refresh() }
                    }
                }
            }
        }
    }
}

// MARK: - Chain detail

struct OptionChainDetailView: View {
    @Environment(OptionsEngine.self) private var engine
    let underlying: String
    @State private var selectedExpiration: Date?
    @State private var selectedLegs: [StrategyLeg] = []
    @State private var showStrategySheet = false
    @State private var isLoadingMore = false

    private var chain: OptionChain? { engine.chain(for: underlying) }

    var body: some View {
        Group {
            if let chain {
                List {
                    Section {
                        HStack {
                            Text(Fmt.price(chain.spotPrice)).font(.title2.monospaced().weight(.medium))
                            Spacer()
                            Text("as of \(chain.asOf.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    ivRankSection

                    Section {
                        Picker("Expiration", selection: $selectedExpiration) {
                            ForEach(chain.expirations, id: \.self) { date in
                                Text(date.formatted(date: .abbreviated, time: .omitted)).tag(Date?.some(date))
                            }
                        }
                        .pickerStyle(.segmented)

                        if engine.hasMoreExpirations(for: underlying) {
                            Button {
                                Task {
                                    isLoadingMore = true
                                    await engine.loadMoreExpirations(for: underlying)
                                    isLoadingMore = false
                                }
                            } label: {
                                if isLoadingMore {
                                    ProgressView()
                                } else {
                                    Text("Load more expirations")
                                }
                            }
                            .disabled(isLoadingMore)
                        }
                    }

                    if let expiration = selectedExpiration ?? chain.expirations.first {
                        let sides = chain.contracts(for: expiration)

                        impliedMoveSection(expiration: expiration, chain: chain)
                        gexSection(chain: chain)

                        Section("Calls") {
                            ForEach(sides.calls) { contract in
                                ContractRow(contract: contract, spot: chain.spotPrice, isSelected: isSelected(contract)) {
                                    toggle(contract)
                                }
                            }
                        }
                        Section("Puts") {
                            ForEach(sides.puts) { contract in
                                ContractRow(contract: contract, spot: chain.spotPrice, isSelected: isSelected(contract)) {
                                    toggle(contract)
                                }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !selectedLegs.isEmpty {
                        Button {
                            showStrategySheet = true
                        } label: {
                            Text("Build strategy from \(selectedLegs.count) leg\(selectedLegs.count == 1 ? "" : "s")")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .background(.bar)
                    }
                }
            } else {
                EmptyStateView(
                    title: "\(underlying) chain not loaded",
                    message: "Pull to refresh from the Options tab, or wait for the next automatic refresh.",
                    systemImage: "magnifyingglass"
                )
            }
        }
        .navigationTitle(underlying)
        .onAppear { selectedExpiration = chain?.expirations.first }
        .sheet(isPresented: $showStrategySheet) {
            StrategyPayoffView(legs: selectedLegs, spot: chain?.spotPrice ?? 0)
        }
    }

    private func isSelected(_ contract: OptionContract) -> Bool {
        selectedLegs.contains { $0.contract.symbol == contract.symbol }
    }

    private func toggle(_ contract: OptionContract) {
        if let index = selectedLegs.firstIndex(where: { $0.contract.symbol == contract.symbol }) {
            selectedLegs.remove(at: index)
        } else {
            selectedLegs.append(StrategyLeg(contract: contract, signedQuantity: 1))
        }
    }

    /// Where today's front-month ATM IV sits against this underlying's own
    /// trailing year, built from the local history this app records on
    /// every chain refresh. Nothing here comes from a paid IV history feed.
    private var ivRankSection: some View {
        Group {
            if let reading = engine.ivHistory.reading(for: underlying) {
                Section {
                    HStack {
                        Text("IV Rank").font(.subheadline)
                        Spacer()
                        Text("\(Int(reading.rank * 100))")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    HStack {
                        Text("IV Percentile").font(.subheadline)
                        Spacer()
                        Text("\(Int(reading.percentile * 100))")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                } footer: {
                    Text("Built from \(reading.sampleCount) day\(reading.sampleCount == 1 ? "" : "s") of this app's own recorded front-month ATM IV — grows more reliable the longer you keep the app running, since no free source publishes historical IV directly.")
                }
            }
        }
    }

    /// Expected move ahead of expiration, from the ATM straddle price —
    /// what a trader sizing a straddle/strangle in the sheet below already
    /// needs, so it's surfaced right where that decision gets made rather
    /// than buried in a separate analytics screen.
    private func impliedMoveSection(expiration: Date, chain: OptionChain) -> some View {
        Group {
            if let move = ImpliedMoveCalculator.expectedMove(chain: chain, expiration: expiration) {
                Section {
                    HStack {
                        Text("Implied move to expiration")
                        Spacer()
                        Text(String(format: "±%.1f%%", move.percent * 100))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                        Text(String(format: "(±%@)", Fmt.price(move.dollars)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("ATM straddle price ÷ spot — the market's own pricing of how far this underlying is expected to move by \(expiration.formatted(date: .abbreviated, time: .omitted)), not a forecast.")
                }
            }
        }
    }

    private func gexSection(chain: OptionChain) -> some View {
        let result = GammaExposureCalculator.compute(contracts: chain.contracts)
        return Group {
            if !result.byStrike.isEmpty {
                Section {
                    GEXChartView(result: result, spot: chain.spotPrice)
                        .frame(height: 160)
                        .padding(.vertical, 4)
                    HStack {
                        Text("Net gamma exposure")
                        Spacer()
                        Text(Fmt.compactVolume(abs(result.netTotal)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(result.netTotal >= 0 ? Palette.up : Palette.down)
                    }
                    if let flip = result.zeroGammaLevel {
                        MetricRow(label: "Zero-gamma level", value: Fmt.price(flip))
                    }
                } header: {
                    Text("Gamma exposure")
                } footer: {
                    Text("Self-computed from open interest and gamma across all loaded expirations, using the standard retail convention (call OI = dealers assumed short, put OI = dealers assumed long) every free GEX chart uses — not a report of actual dealer positioning. Above the zero-gamma level, hedging flow conventionally dampens moves; below it, hedging flow conventionally amplifies them.")
                }
            }
        }
    }
}

/// Bar chart of net gamma exposure by strike, with a marker at spot and, if
/// found, the zero-gamma crossing. Drawn with `Path` like `PayoffChartView`
/// — an occasionally-viewed analytics chart, not the high-frequency price
/// chart the Metal pipeline exists for.
struct GEXChartView: View {
    let result: GammaExposureCalculator.Result
    let spot: Double

    private var strikes: [GammaExposureCalculator.StrikeExposure] { result.byStrike }
    private var maxAbs: Double { max(strikes.map { abs($0.netGamma) }.max() ?? 1, 1) }
    private var low: Double { strikes.map(\.strike).min() ?? spot }
    private var high: Double { strikes.map(\.strike).max() ?? spot }
    private var span: Double { max(high - low, 0.01) }

    var body: some View {
        Group {
            if strikes.isEmpty {
                EmptyView()
            } else {
                GeometryReader { geometry in
                    let barWidth = max(geometry.size.width / CGFloat(strikes.count) * 0.7, 1)

                    ZStack {
                        Path { path in
                            let y = geometry.size.height / 2
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        ForEach(strikes) { row in
                            let x = geometry.size.width * CGFloat((row.strike - low) / span)
                            let barHeight = CGFloat(abs(row.netGamma) / maxAbs) * (geometry.size.height / 2 - 4)
                            let y = row.netGamma >= 0
                                ? geometry.size.height / 2 - barHeight
                                : geometry.size.height / 2
                            Rectangle()
                                .fill(row.netGamma >= 0 ? Palette.up.opacity(0.7) : Palette.down.opacity(0.7))
                                .frame(width: barWidth, height: max(barHeight, 1))
                                .position(x: x, y: y + barHeight / 2)
                        }

                        Path { path in
                            let x = geometry.size.width * CGFloat((spot - low) / span)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(Palette.cyan, lineWidth: 1.5)

                        if let flip = result.zeroGammaLevel {
                            Path { path in
                                let x = geometry.size.width * CGFloat((flip - low) / span)
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }
                            .stroke(Palette.amber, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Gamma exposure by strike")
    }
}

struct ContractRow: View {
    let contract: OptionContract
    let spot: Double
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Fmt.price(contract.strike)).font(.subheadline.monospacedDigit().weight(.medium))
                        if let moneyness = contract.moneynessPercent(spot: spot), abs(moneyness) < 0.01 {
                            Text("ATM").font(.caption2.weight(.bold)).foregroundStyle(Palette.amber)
                        }
                    }
                    if let iv = contract.impliedVolatility {
                        Text("IV \(String(format: "%.0f%%", iv * 100))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let mid = contract.mid {
                        Text(Fmt.price(mid)).font(.subheadline.monospacedDigit())
                    } else {
                        Text("—").font(.subheadline).foregroundStyle(.tertiary)
                    }
                    if let delta = contract.greeks?.delta {
                        Text("Δ \(String(format: "%.2f", delta))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                if let volume = contract.volume, let oi = contract.openInterest {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("v \(volume)").font(.caption2.monospacedDigit())
                        Text("oi \(oi)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Strategy payoff

struct StrategyPayoffView: View {
    let legs: [StrategyLeg]
    let spot: Double
    @Environment(\.dismiss) private var dismiss
    @Environment(OptionsPaperTradeLog.self) private var optionsPaperLog
    @State private var didLog = false

    private var strategy: OptionStrategy {
        OptionStrategy(name: legs.count == 1 ? (legs[0].isLong ? "Long \(legs[0].contract.type.rawValue)" : "Short \(legs[0].contract.type.rawValue)") : "Custom \(legs.count)-leg", legs: legs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PayoffChartView(strategy: strategy, spot: spot)
                        .frame(height: 200)
                        .padding(.vertical, 4)
                }

                Section("Risk") {
                    MetricRow(label: "Net premium", value: Fmt.price(strategy.netPremium), tint: strategy.netPremium < 0 ? Palette.down : Palette.up)
                    if let maxProfit = strategy.maxProfit {
                        MetricRow(label: "Max profit", value: Fmt.price(maxProfit), tint: Palette.up)
                    } else {
                        MetricRow(label: "Max profit", value: "Unbounded", tint: Palette.up)
                    }
                    if let maxLoss = strategy.maxLoss {
                        MetricRow(label: "Max loss", value: Fmt.price(maxLoss), tint: Palette.down)
                    } else {
                        MetricRow(label: "Max loss", value: "Unbounded", tint: Palette.down)
                    }
                    let breakevens = strategy.breakevens(searchLow: max(0.01, spot * 0.5), searchHigh: spot * 1.5)
                    if !breakevens.isEmpty {
                        MetricRow(label: "Breakeven", value: breakevens.map { Fmt.price($0) }.joined(separator: ", "))
                    }
                    if let pop = strategy.approximateProbabilityOfProfit {
                        MetricRow(label: "Approx. probability of profit", value: String(format: "%.0f%%", pop * 100))
                    }
                } footer: {
                    Text("Probability of profit is delta-approximated, the standard retail shorthand, not a rigorous distributional estimate. All figures use mid price and ignore fees, assignment risk, and early exercise.")
                }

                Section("Greeks") {
                    let g = strategy.netGreeks
                    MetricRow(label: "Delta", value: String(format: "%.1f", g.delta))
                    MetricRow(label: "Gamma", value: String(format: "%.2f", g.gamma))
                    MetricRow(label: "Theta / day", value: Fmt.price(g.theta))
                    MetricRow(label: "Vega", value: Fmt.price(g.vega))
                }

                Section("Legs") {
                    ForEach(legs) { leg in
                        HStack {
                            Text(leg.isLong ? "Buy" : "Sell")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(leg.isLong ? Palette.up : Palette.down)
                            Text("\(leg.contract.type == .call ? "Call" : "Put") \(Fmt.price(leg.contract.strike))")
                                .font(.subheadline)
                            Spacer()
                            Text(leg.contract.expiration.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(didLog ? "Logged" : "Log as paper trade") {
                        optionsPaperLog.open(strategy: strategy, underlyingSpot: spot)
                        didLog = true
                    }
                    .disabled(didLog || legs.isEmpty)
                } footer: {
                    Text("Records the current mid price of every leg as the entry cost basis. Marked to market on every options refresh; close it manually whenever you'd exit for real.")
                }
            }
            .navigationTitle(strategy.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Lightweight SwiftUI payoff line — the strategy sheet is a one-off
/// diagnostic view opened rarely, so it draws with `Path` rather than
/// standing up the Metal pipeline reserved for the high-frequency
/// price/volume charts (`Rendering/CandleChartRenderer.swift`).
struct PayoffChartView: View {
    let strategy: OptionStrategy
    let spot: Double

    var body: some View {
        GeometryReader { geometry in
            let low = spot * 0.6
            let high = spot * 1.4
            let curve = strategy.payoffCurve(from: low, to: high)
            let pnls = curve.map(\.pnl)
            let maxAbs = max(pnls.map(abs).max() ?? 1, 1)

            ZStack {
                // Zero line.
                Path { path in
                    let y = geometry.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // Spot marker.
                Path { path in
                    let x = geometry.size.width * CGFloat((spot - low) / (high - low))
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
                .stroke(Palette.cyan.opacity(0.4), lineWidth: 1)

                Path { path in
                    for (index, point) in curve.enumerated() {
                        let x = geometry.size.width * CGFloat((point.spot - low) / (high - low))
                        let y = geometry.size.height / 2 - CGFloat(point.pnl / maxAbs) * (geometry.size.height / 2 - 8)
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Palette.cyan, lineWidth: 2)
            }
        }
        .accessibilityLabel("Payoff diagram")
    }
}

import Foundation
import SwiftData
import Observation

enum TradeDirection: String, Codable, Sendable {
    case long, short

    var label: String { self == .long ? "Long" : "Short" }
    var sign: Double { self == .long ? 1 : -1 }
}

enum TradeStatus: String, Codable, Sendable {
    case open, closed
}

/// One recorded alert, with the full signal snapshot that produced it and the
/// price path that followed.
///
/// This is the part of the app that earns its keep. A scanner that only ranks
/// is a scanner you tune by intuition; a scanner that records what it claimed
/// and what actually happened is one you can tune by evidence.
@Model
final class PaperTrade {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var openedAt: Date
    var closedAt: Date?
    var entryPrice: Double
    var directionRaw: String
    var statusRaw: String

    /// The score and its decomposition at the moment of the alert.
    var score: Double
    var reason: String
    /// JSON-encoded `SignalSnapshot`, so every raw metric survives for analysis.
    var snapshotData: Data?
    /// JSON-encoded `[String: Double]` of component contributions.
    var contributionData: Data?

    // Price path. Nil until the horizon is reached.
    var priceAfter15m: Double?
    var priceAfter30m: Double?
    var priceAfter60m: Double?
    var priceAtClose: Double?

    /// Best and worst excursion seen while the trade was open, in the
    /// direction of the trade. Tells you whether a setup that ended flat
    /// ever actually worked.
    var maxFavorable: Double
    var maxAdverse: Double

    var note: String

    /// Which setup this was. Slicing outcomes by setup answers a more useful
    /// question than slicing by component: knowing gap-and-go works for you and
    /// VWAP reclaims don't is directly actionable.
    var setupRaw: String
    /// Float category at entry, so float-conditional performance is visible.
    var floatCategoryRaw: String?
    var floatSharesAtEntry: Double?
    /// Whether the symbol halted at any point while the trade was open.
    var haltedDuringTrade: Bool
    var recipeName: String?
    /// Which discipline this trade belongs to. Governs whether it force-closes
    /// at the bell and which mark-to-market horizons apply.
    var horizonRaw: String

    init(
        symbol: String,
        openedAt: Date,
        entryPrice: Double,
        direction: TradeDirection,
        score: Double,
        reason: String,
        snapshot: SignalSnapshot?,
        contributions: [SignalComponent: Double],
        setup: SetupType = .unclassified,
        recipeName: String? = nil,
        horizon: TradeHorizon = .dayTrade
    ) {
        self.id = UUID()
        self.symbol = symbol
        self.openedAt = openedAt
        self.entryPrice = entryPrice
        self.directionRaw = direction.rawValue
        self.statusRaw = TradeStatus.open.rawValue
        self.score = score
        self.reason = reason
        self.snapshotData = snapshot.flatMap { try? JSONEncoder().encode($0) }
        self.contributionData = try? JSONEncoder().encode(
            Dictionary(uniqueKeysWithValues: contributions.map { ($0.key.rawValue, $0.value) })
        )
        self.maxFavorable = 0
        self.maxAdverse = 0
        self.note = ""
        self.setupRaw = setup.rawValue
        self.floatCategoryRaw = snapshot?.extended.floatCategory?.rawValue
        self.floatSharesAtEntry = snapshot?.extended.floatShares
        self.haltedDuringTrade = false
        self.recipeName = recipeName
        self.horizonRaw = horizon.rawValue
    }

    var direction: TradeDirection { TradeDirection(rawValue: directionRaw) ?? .long }
    var status: TradeStatus { TradeStatus(rawValue: statusRaw) ?? .open }
    var setup: SetupType { SetupType(rawValue: setupRaw) ?? .unclassified }
    var floatCategory: SECFloatClient.FloatCategory? {
        floatCategoryRaw.flatMap { SECFloatClient.FloatCategory(rawValue: $0) }
    }
    var horizon: TradeHorizon { TradeHorizon(rawValue: horizonRaw) ?? .dayTrade }

    /// Labels for the three mark-to-market checkpoints, sized to this trade's
    /// horizon — "15m/30m/60m" for a day trade, "1d/3d/5d" for a swing.
    var markLabels: (String, String, String) {
        let horizons = horizon.markToMarketHorizons
        return (
            horizons.count > 0 ? horizons[0].label : "—",
            horizons.count > 1 ? horizons[1].label : "—",
            horizons.count > 2 ? horizons[2].label : "—"
        )
    }

    var snapshot: SignalSnapshot? {
        guard let snapshotData else { return nil }
        return try? JSONDecoder().decode(SignalSnapshot.self, from: snapshotData)
    }

    var contributions: [SignalComponent: Double] {
        guard let contributionData,
              let raw = try? JSONDecoder().decode([String: Double].self, from: contributionData)
        else { return [:] }
        var result: [SignalComponent: Double] = [:]
        for (key, value) in raw {
            if let component = SignalComponent(rawValue: key) { result[component] = value }
        }
        return result
    }

    /// Signed return in the direction of the trade, so a short that fell 2%
    /// reads as +2% rather than -2%.
    func returnPercent(at price: Double?) -> Double? {
        guard let price, entryPrice > 0 else { return nil }
        return ((price / entryPrice) - 1.0) * direction.sign
    }

    var closeReturn: Double? { returnPercent(at: priceAtClose) }
    var return15m: Double? { returnPercent(at: priceAfter15m) }
    var return30m: Double? { returnPercent(at: priceAfter30m) }
    var return60m: Double? { returnPercent(at: priceAfter60m) }

    /// The headline number: whichever horizon has resolved most recently.
    var bestAvailableReturn: Double? {
        closeReturn ?? return60m ?? return30m ?? return15m
    }

    /// What share of the best move available was actually captured.
    ///
    /// Nil when MFE was never meaningfully positive, since dividing by a
    /// near-zero favorable excursion produces a number with no real meaning.
    var exitEfficiency: Double? {
        guard maxFavorable > 0.001, let outcome = bestAvailableReturn else { return nil }
        return outcome / maxFavorable
    }
}

// MARK: - Analytics

struct ComponentPerformance: Identifiable, Sendable {
    let component: SignalComponent
    var id: String { component.rawValue }
    let tradeCount: Int
    let averageReturn: Double
    let winRate: Double
    /// Average return of trades where this component did NOT contribute,
    /// so you can see whether it actually adds anything.
    let baselineReturn: Double

    var edge: Double { averageReturn - baselineReturn }
}

struct LogSummary: Sendable {
    var total = 0
    var resolved = 0
    var winRate: Double = 0
    var averageReturn: Double = 0
    var medianReturn: Double = 0
    var averageMFE: Double = 0
    var averageMAE: Double = 0
    /// Average share of the best available move actually captured, across
    /// trades where MFE was meaningfully positive. Nil until there's at
    /// least one such trade.
    var averageExitEfficiency: Double?
    var bestSymbol: String?
    var worstSymbol: String?
}

// MARK: - Store

@MainActor
@Observable
final class PaperTradeLog {
    private var context: ModelContext?

    private(set) var trades: [PaperTrade] = []
    private(set) var summary = LogSummary()

    func attach(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        guard let context else { return }
        let descriptor = FetchDescriptor<PaperTrade>(
            sortBy: [SortDescriptor(\.openedAt, order: .reverse)]
        )
        trades = (try? context.fetch(descriptor)) ?? []
        recomputeSummary()
    }

    func trades(for horizon: TradeHorizon) -> [PaperTrade] {
        trades.filter { $0.horizon == horizon }
    }

    /// Same summary shape as the global one, scoped to one horizon.
    func summary(for horizon: TradeHorizon) -> LogSummary {
        let scoped = trades(for: horizon)
        var result = LogSummary()
        result.total = scoped.count

        let resolved = scoped.compactMap { trade -> (PaperTrade, Double)? in
            guard let value = trade.bestAvailableReturn else { return nil }
            return (trade, value)
        }
        result.resolved = resolved.count
        guard !resolved.isEmpty else { return result }

        let returns = resolved.map(\.1)
        result.averageReturn = returns.reduce(0, +) / Double(returns.count)
        result.medianReturn = BaselineStore.median(returns)
        result.winRate = Double(returns.filter { $0 > 0 }.count) / Double(returns.count)
        result.averageMFE = resolved.map(\.0.maxFavorable).reduce(0, +) / Double(resolved.count)
        result.averageMAE = resolved.map(\.0.maxAdverse).reduce(0, +) / Double(resolved.count)
        let efficiencies = resolved.compactMap(\.0.exitEfficiency)
        if !efficiencies.isEmpty {
            result.averageExitEfficiency = efficiencies.reduce(0, +) / Double(efficiencies.count)
        }
        result.bestSymbol = resolved.max { $0.1 < $1.1 }?.0.symbol
        result.worstSymbol = resolved.min { $0.1 < $1.1 }?.0.symbol
        return result
    }

    // MARK: - Writing

    /// Opens a trade from any horizon's own candidate shape. The day-trade
    /// path (`open(from candidate:)` below) stays as the richer, snapshot-
    /// carrying variant since that's where per-component tuning lives; swing
    /// and long-term trades carry a plain reason string instead, since their
    /// own score breakdowns already live in their engines' candidate types.
    func openGeneric(
        symbol: String,
        entryPrice: Double,
        direction: TradeDirection,
        score: Double,
        reason: String,
        horizon: TradeHorizon,
        floatCategory: SECFloatClient.FloatCategory? = nil
    ) {
        guard let context else { return }
        if trades.contains(where: { $0.symbol == symbol && $0.status == .open && $0.horizon == horizon }) { return }

        let trade = PaperTrade(
            symbol: symbol,
            openedAt: Date(),
            entryPrice: entryPrice,
            direction: direction,
            score: score,
            reason: reason,
            snapshot: nil,
            contributions: [:],
            horizon: horizon
        )
        trade.floatCategoryRaw = floatCategory?.rawValue
        context.insert(trade)
        try? context.save()
        refresh()
    }

    /// Direction is inferred from the setup rather than asked for. A VWAP loss
    /// with heavy volume is a short setup; a reclaim is a long one.
    func open(from candidate: Candidate, setup: SetupType = .unclassified, recipeName: String? = nil) {
        guard let context else { return }
        let snapshot = candidate.snapshot

        // Don't double-log the same symbol while a trade is still open.
        if trades.contains(where: { $0.symbol == snapshot.symbol && $0.status == .open }) { return }

        let direction: TradeDirection
        switch snapshot.vwapEvent {
        case .reclaim: direction = .long
        case .loss: direction = .short
        case .none: direction = snapshot.trend == .aboveVWAP ? .long : .short
        }

        let trade = PaperTrade(
            symbol: snapshot.symbol,
            openedAt: Date(),
            entryPrice: snapshot.last,
            direction: direction,
            score: candidate.score,
            reason: candidate.plainReason,
            snapshot: snapshot,
            contributions: candidate.breakdown.contributions,
            setup: setup,
            recipeName: recipeName
        )
        context.insert(trade)
        try? context.save()
        refresh()
    }

    /// Called from the engine on every rescore. Fills the time-horizon marks
    /// and tracks excursion while the trade is open.
    /// Flags trades whose symbol halted while open. A halt mid-trade is the
    /// difference between a modelled exit and an impossible one, and a paper
    /// log that ignores it will overstate every low-float setup.
    func markHalted(symbols: Set<String>) {
        guard !symbols.isEmpty else { return }
        var changed = false
        for trade in trades where trade.status == .open && !trade.haltedDuringTrade {
            if symbols.contains(trade.symbol) {
                trade.haltedDuringTrade = true
                changed = true
            }
        }
        if changed { try? context?.save() }
    }

    func markToMarket(prices: [String: Double]) {
        guard let context else { return }
        let now = Date()
        var didChange = false

        for trade in trades where trade.status == .open {
            guard let price = prices[trade.symbol], price > 0, trade.entryPrice > 0 else { continue }

            let signedReturn = ((price / trade.entryPrice) - 1.0) * trade.direction.sign
            if signedReturn > trade.maxFavorable { trade.maxFavorable = signedReturn; didChange = true }
            if signedReturn < trade.maxAdverse { trade.maxAdverse = signedReturn; didChange = true }

            let elapsed = now.timeIntervalSince(trade.openedAt)
            let horizons = trade.horizon.markToMarketHorizons
            if elapsed >= horizons[0].duration, trade.priceAfter15m == nil { trade.priceAfter15m = price; didChange = true }
            if horizons.count > 1, elapsed >= horizons[1].duration, trade.priceAfter30m == nil { trade.priceAfter30m = price; didChange = true }
            if horizons.count > 2, elapsed >= horizons[2].duration, trade.priceAfter60m == nil { trade.priceAfter60m = price; didChange = true }

            // Day trades close at the bell, because holding one overnight
            // measures a different strategy than the one being scored. Swing
            // and long-term positions have no such deadline.
            if trade.horizon.forcesEndOfDayClose,
               MarketClock.phase(at: now) != .regular, MarketClock.minutesSinceMidnightET(now) >= 960 {
                trade.priceAtClose = price
                trade.closedAt = now
                trade.statusRaw = TradeStatus.closed.rawValue
                didChange = true
            }
        }

        if didChange {
            try? context.save()
            recomputeSummary()
        }
    }

    func close(_ trade: PaperTrade, at price: Double) {
        guard let context else { return }
        trade.priceAtClose = price
        trade.closedAt = Date()
        trade.statusRaw = TradeStatus.closed.rawValue
        try? context.save()
        refresh()
    }

    func delete(_ trade: PaperTrade) {
        guard let context else { return }
        context.delete(trade)
        try? context.save()
        refresh()
    }

    func deleteAll() {
        guard let context else { return }
        for trade in trades { context.delete(trade) }
        try? context.save()
        refresh()
    }

    func setNote(_ note: String, on trade: PaperTrade) {
        trade.note = note
        try? context?.save()
    }

    // MARK: - Analysis

    private func recomputeSummary() {
        var result = LogSummary()
        result.total = trades.count

        let resolved = trades.compactMap { trade -> (PaperTrade, Double)? in
            guard let value = trade.bestAvailableReturn else { return nil }
            return (trade, value)
        }
        result.resolved = resolved.count

        guard !resolved.isEmpty else { summary = result; return }

        let returns = resolved.map(\.1)
        result.averageReturn = returns.reduce(0, +) / Double(returns.count)
        result.medianReturn = BaselineStore.median(returns)
        result.winRate = Double(returns.filter { $0 > 0 }.count) / Double(returns.count)
        result.averageMFE = resolved.map(\.0.maxFavorable).reduce(0, +) / Double(resolved.count)
        result.averageMAE = resolved.map(\.0.maxAdverse).reduce(0, +) / Double(resolved.count)
        let efficiencies = resolved.compactMap(\.0.exitEfficiency)
        if !efficiencies.isEmpty {
            result.averageExitEfficiency = efficiencies.reduce(0, +) / Double(efficiencies.count)
        }
        result.bestSymbol = resolved.max { $0.1 < $1.1 }?.0.symbol
        result.worstSymbol = resolved.min { $0.1 < $1.1 }?.0.symbol

        summary = result
    }

    /// For each component, compares the average outcome of trades where it
    /// contributed meaningfully against trades where it didn't.
    func componentPerformance(contributionFloor: Double = 0.04) -> [ComponentPerformance] {
        let resolved = trades.compactMap { trade -> (PaperTrade, Double)? in
            guard let value = trade.bestAvailableReturn else { return nil }
            return (trade, value)
        }
        guard resolved.count >= 2 else { return [] }

        return SignalComponent.allCases.compactMap { component in
            let withComponent = resolved.filter { ($0.0.contributions[component] ?? 0) >= contributionFloor }
            let withoutComponent = resolved.filter { ($0.0.contributions[component] ?? 0) < contributionFloor }

            guard !withComponent.isEmpty else { return nil }

            let withReturns = withComponent.map(\.1)
            let baseline = withoutComponent.isEmpty
                ? 0
                : withoutComponent.map(\.1).reduce(0, +) / Double(withoutComponent.count)

            return ComponentPerformance(
                component: component,
                tradeCount: withComponent.count,
                averageReturn: withReturns.reduce(0, +) / Double(withReturns.count),
                winRate: Double(withReturns.filter { $0 > 0 }.count) / Double(withReturns.count),
                baselineReturn: baseline
            )
        }
        .sorted { $0.edge > $1.edge }
    }

    /// Outcome by setup type. The most directly actionable breakdown in the
    /// app — it tells you which strategies to keep running and which to stop.
    func performanceBySetup() -> [(setup: SetupType, count: Int, winRate: Double, averageReturn: Double, averageMFE: Double)] {
        let resolved = trades.compactMap { trade -> (PaperTrade, Double)? in
            guard let value = trade.bestAvailableReturn else { return nil }
            return (trade, value)
        }
        let grouped = Dictionary(grouping: resolved, by: \.0.setup)
        return grouped.map { setup, rows in
            let values = rows.map(\.1)
            return (
                setup: setup,
                count: values.count,
                winRate: Double(values.filter { $0 > 0 }.count) / Double(values.count),
                averageReturn: values.reduce(0, +) / Double(values.count),
                averageMFE: rows.map(\.0.maxFavorable).reduce(0, +) / Double(rows.count)
            )
        }
        .sorted { $0.averageReturn > $1.averageReturn }
    }

    /// Outcome by float band. Answers whether tight floats are actually paying
    /// for the halt risk they carry.
    func performanceByFloat() -> [(category: SECFloatClient.FloatCategory, count: Int, averageReturn: Double, haltRate: Double)] {
        let resolved = trades.compactMap { trade -> (PaperTrade, Double, SECFloatClient.FloatCategory)? in
            guard let value = trade.bestAvailableReturn, let category = trade.floatCategory else { return nil }
            return (trade, value, category)
        }
        let grouped = Dictionary(grouping: resolved, by: \.2)
        return SECFloatClient.FloatCategory.allCases.compactMap { category in
            guard let rows = grouped[category], !rows.isEmpty else { return nil }
            let values = rows.map(\.1)
            let halted = rows.filter(\.0.haltedDuringTrade).count
            return (
                category: category,
                count: values.count,
                averageReturn: values.reduce(0, +) / Double(values.count),
                haltRate: Double(halted) / Double(rows.count)
            )
        }
    }

    /// Share of resolved trades that were halted mid-position.
    var haltExposureRate: Double {
        let resolved = trades.filter { $0.bestAvailableReturn != nil }
        guard !resolved.isEmpty else { return 0 }
        return Double(resolved.filter(\.haltedDuringTrade).count) / Double(resolved.count)
    }

    /// Outcome grouped by half-hour of the session.
    func performanceByTimeOfDay() -> [(bucket: String, count: Int, averageReturn: Double)] {
        let resolved = trades.compactMap { trade -> (Int, Double)? in
            guard let value = trade.bestAvailableReturn,
                  let minute = MarketClock.minuteOfSession(trade.openedAt), minute >= 0 else { return nil }
            return (minute / 30, value)
        }
        let grouped = Dictionary(grouping: resolved, by: \.0)
        return grouped.keys.sorted().map { bucket in
            let values = grouped[bucket]!.map(\.1)
            let startMinute = 570 + (bucket * 30)
            let label = String(format: "%02d:%02d", startMinute / 60, startMinute % 60)
            return (label, values.count, values.reduce(0, +) / Double(values.count))
        }
    }

    /// Score decile against realized outcome. If the curve isn't upward
    /// sloping, the scoring model isn't working, whatever its weights say.
    func performanceByScoreBand() -> [(band: String, count: Int, averageReturn: Double)] {
        let resolved = trades.compactMap { trade -> (Int, Double)? in
            guard let value = trade.bestAvailableReturn else { return nil }
            return (min(Int(trade.score * 10), 9), value)
        }
        let grouped = Dictionary(grouping: resolved, by: \.0)
        return grouped.keys.sorted().map { band in
            let values = grouped[band]!.map(\.1)
            let label = String(format: "%.1f–%.1f", Double(band) / 10, Double(band + 1) / 10)
            return (label, values.count, values.reduce(0, +) / Double(values.count))
        }
    }
}

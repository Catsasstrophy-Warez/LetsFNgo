import Foundation

/// Finds symbols worth watching instead of scanning a hand-typed list.
///
/// This is the piece that turns the app from a watchlist monitor into a
/// hunter. The day's biggest movers are almost never on a list you wrote last
/// month, so the universe has to be rebuilt from what the market is actually
/// doing.
///
/// Two stages, because the full US equity list is roughly 11,000 symbols and
/// pulling minute bars for all of them is not remotely feasible on a phone:
///   1. **Screen** on daily bars — cheap, batched, and enough to rule out the
///      95% of symbols that cannot move far enough to be worth a slot.
///   2. **Rank** the survivors on gain potential, and hand the top N to the
///      scanner as its universe.
actor UniverseBuilder {
    private let rest: AlpacaREST
    private var profiles: [String: VolatilityProfile] = [:]
    private var tier1Symbols: Set<String> = []

    private(set) var isScreening = false
    private(set) var progress: Double = 0
    private(set) var lastScreenedAt: Date?
    private(set) var symbolsExamined = 0

    private let fileURL: URL

    init(rest: AlpacaREST) {
        self.rest = rest
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("volatility-profiles.json")
        // Can't call the actor-isolated loadFromDisk() instance method from
        // init — see BaselineStore's equivalent fix for why.
        profiles = Self.loadProfilesFromDisk(at: fileURL)
    }

    func profile(for symbol: String) -> VolatilityProfile? { profiles[symbol] }
    func allProfiles() -> [VolatilityProfile] { Array(profiles.values) }
    var profileCount: Int { profiles.count }

    /// Rough Tier 1 membership for LULD band width. The real list is the S&P
    /// 500, Russell 1000 and select ETPs; median dollar volume is a workable
    /// stand-in given the free tier exposes no index membership.
    func isTier1(_ symbol: String) -> Bool {
        if tier1Symbols.contains(symbol) { return true }
        guard let profile = profiles[symbol] else { return false }
        return profile.medianDailyVolume * profile.lastClose > 100_000_000
    }

    // MARK: - Screening

    struct ScreenResult: Sendable {
        let universe: [String]
        let profiles: [VolatilityProfile]
        let examined: Int
        let passed: Int
    }

    /// Screens the tradable asset list down to a ranked universe.
    ///
    /// Runs against daily bars only. On a first run over the full market this
    /// takes several minutes and a few hundred requests; the results persist,
    /// so subsequent runs are refreshes rather than rebuilds.
    func screen(
        criteria: DiscoveryCriteria,
        floatLookup: [String: Double] = [:],
        candidatePool: [String]? = nil,
        progress progressHandler: @Sendable @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> ScreenResult {
        guard !isScreening else {
            return ScreenResult(universe: [], profiles: [], examined: 0, passed: 0)
        }
        isScreening = true
        progress = 0
        defer { isScreening = false }

        // 1. Get the symbol pool.
        progressHandler(0.02, "Loading tradable symbols")
        let pool: [String]
        if let candidatePool {
            pool = candidatePool
        } else {
            let assets = try await rest.tradableAssets()
            pool = assets
                .filter { $0.tradable && !$0.symbol.contains(".") && $0.symbol.count <= 5 }
                .map(\.symbol)
        }
        symbolsExamined = pool.count

        // 2. Daily bars in batches. This is the expensive stage, but daily bars
        //    are small — a few hundred symbols per request is fine.
        let batchSize = 200
        let batches = pool.chunked(into: batchSize)
        var built: [VolatilityProfile] = []

        for (index, batch) in batches.enumerated() {
            progressHandler(
                0.05 + (Double(index) / Double(max(batches.count, 1))) * 0.85,
                "Screening \(index * batchSize) of \(pool.count)"
            )

            guard let dailyBySymbol = try? await rest.dailyBars(
                symbols: batch,
                lookbackDays: criteria.lookbackSessions
            ) else { continue }

            for (symbol, bars) in dailyBySymbol {
                guard let profile = VolatilityProfile.build(
                    symbol: symbol,
                    dailyBars: bars,
                    runnerThreshold: criteria.runnerThreshold,
                    lookback: criteria.lookbackSessions
                ) else { continue }

                profiles[symbol] = profile

                // Float gate. Unknown float is kept by default — unknown is not
                // the same as large, and recent listings with no filed cover
                // page are exactly the names that run hardest.
                var passesFloat = true
                if let float = floatLookup[symbol] {
                    if let ceiling = criteria.maxFloatShares, float > ceiling { passesFloat = false }
                    if let floor = criteria.minFloatShares, float < floor { passesFloat = false }
                } else if !criteria.includeUnknownFloat {
                    passesFloat = false
                }

                if passesFloat && profile.passes(criteria) { built.append(profile) }

                if profile.medianDailyVolume * profile.lastClose > 100_000_000 {
                    tier1Symbols.insert(symbol)
                }
            }

            progress = Double(index + 1) / Double(max(batches.count, 1))
            try? await Task.sleep(for: .milliseconds(300))
        }

        // 3. Rank and cut. Gain potential is the primary sort; volume trend
        //    breaks ties, on the theory that rising interest precedes the move.
        progressHandler(0.95, "Ranking candidates")
        let ranked = built
            .sorted { lhs, rhs in
                func rank(_ profile: VolatilityProfile) -> Double {
                    var score = profile.gainPotential
                    score += (min(profile.volumeTrend, 3) - 1) * 0.05
                    if let float = floatLookup[profile.symbol] {
                        score += SECFloatClient.FloatCategory.classify(float).tightnessScore * 0.15
                    }
                    return score
                }
                return rank(lhs) > rank(rhs)
            }
            .prefix(criteria.maxUniverseSize)

        lastScreenedAt = Date()
        saveToDisk()
        progressHandler(1.0, "Done")

        return ScreenResult(
            universe: ranked.map(\.symbol),
            profiles: Array(ranked),
            examined: pool.count,
            passed: built.count
        )
    }

    /// Refreshes profiles for an existing universe without re-screening the
    /// whole market. Run this daily; run the full screen weekly.
    func refresh(universe: [String], criteria: DiscoveryCriteria) async throws {
        for batch in universe.chunked(into: 200) {
            guard let dailyBySymbol = try? await rest.dailyBars(
                symbols: batch,
                lookbackDays: criteria.lookbackSessions
            ) else { continue }
            for (symbol, bars) in dailyBySymbol {
                if let profile = VolatilityProfile.build(
                    symbol: symbol,
                    dailyBars: bars,
                    runnerThreshold: criteria.runnerThreshold,
                    lookback: criteria.lookbackSessions
                ) {
                    profiles[symbol] = profile
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        lastScreenedAt = Date()
        saveToDisk()
    }

    // MARK: - Pre-market gapper scan

    struct Gapper: Identifiable, Sendable {
        var id: String { symbol }
        let symbol: String
        let gapPercent: Double
        let premarketVolume: Double
        let premarketVolumeRatio: Double
        let lastPrice: Double
        let priorClose: Double
        let profile: VolatilityProfile?
        let hasNews: Bool

        /// Gap size alone ranks badly — a 12% gap on 4,000 shares is nothing.
        /// Volume behind the gap is what separates a real pre-market move
        /// from a stale quote.
        var quality: Double {
            let gapTerm = min(abs(gapPercent) / 0.15, 1.0) * 0.4
            let volumeTerm = min(premarketVolumeRatio / 3.0, 1.0) * 0.35
            let potentialTerm = (profile?.gainPotential ?? 0.3) * 0.15
            let newsTerm = hasNews ? 0.10 : 0.0
            return gapTerm + volumeTerm + potentialTerm + newsTerm
        }
    }

    /// Ranks pre-market gappers. Called between roughly 7:00 and 9:30 ET.
    ///
    /// Pre-market volume comes through the same IEX feed, which is thinner
    /// still before the open — so the ratio is compared against this symbol's
    /// own typical pre-market activity rather than any absolute figure.
    func scanGappers(
        universe: [String],
        newsSymbols: Set<String>,
        minGapPercent: Double = 0.03
    ) async throws -> [Gapper] {
        var results: [Gapper] = []

        for batch in universe.chunked(into: 100) {
            guard let snapshots = try? await rest.snapshots(symbols: batch) else { continue }

            for (symbol, snapshot) in snapshots {
                guard let prior = snapshot.prevDailyBar, prior.close > 0 else { continue }
                let lastPrice = snapshot.minuteBar?.close ?? snapshot.dailyBar?.close ?? 0
                guard lastPrice > 0 else { continue }

                let gap = (lastPrice / prior.close) - 1.0
                guard abs(gap) >= minGapPercent else { continue }

                let premarketVolume = snapshot.dailyBar?.volume ?? 0
                let profile = profiles[symbol]
                // Pre-market typically runs a low single-digit percentage of a
                // full session, so that is the reference the ratio uses.
                let expected = (profile?.medianDailyVolume ?? 0) * 0.03
                let ratio = expected > 0 ? premarketVolume / expected : 0

                results.append(Gapper(
                    symbol: symbol,
                    gapPercent: gap,
                    premarketVolume: premarketVolume,
                    premarketVolumeRatio: ratio,
                    lastPrice: lastPrice,
                    priorClose: prior.close,
                    profile: profile,
                    hasNews: newsSymbols.contains(symbol)
                ))
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        return results.sorted { $0.quality > $1.quality }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func loadProfilesFromDisk(at fileURL: URL) -> [String: VolatilityProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: VolatilityProfile].self, from: data) else { return [:] }
        return decoded
    }

    func clear() {
        profiles = [:]
        tier1Symbols = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

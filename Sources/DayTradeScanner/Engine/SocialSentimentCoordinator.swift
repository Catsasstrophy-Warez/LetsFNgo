import Foundation
import Observation

/// Owns the StockTwits trending/sentiment polling loop, split out of
/// ScannerEngine as the first piece of the god-object breakup the
/// architecture review flagged. Chosen first because it's the most
/// self-contained subsystem: its only interface with the rest of the
/// engine is the cached lookups exposed here after each refresh, with no
/// coupling to `states`, baselines, or scoring.
@MainActor
@Observable
final class SocialSentimentCoordinator {
    private(set) var trendingSocial: [StockTwitsClient.TrendingSymbol] = []
    private(set) var socialCache: [String: StockTwitsClient.SentimentSnapshot] = [:]
    private(set) var socialSurge: [String: Double] = [:]
    private(set) var socialLastRefreshed: Date?

    private let stockTwits = StockTwitsClient()
    private var task: Task<Void, Never>?

    /// `universe` is read fresh on every poll rather than captured once, so
    /// a universe edited mid-session (e.g. adopted gappers) is reflected on
    /// the next cycle without a restart.
    func start(universe: @escaping @Sendable () -> [String]) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(universe: universe())
                // Keyless public endpoints deserve a slow, polite cadence —
                // this is retail chatter, not a data feed anyone is paying to
                // keep fast, and hammering it risks losing access for everyone.
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func refresh(universe: [String]) async {
        try? await stockTwits.refreshTrending()
        trendingSocial = await stockTwits.trending()

        // Sentiment is refreshed for the current universe plus anything
        // already trending, so a name trending outside the watchlist still
        // surfaces rather than being invisible until manually added.
        let trendingSymbols = Set(trendingSocial.prefix(30).map(\.symbol))
        let targets = Array(Set(universe).union(trendingSymbols))
        await stockTwits.refreshSentiment(for: targets)

        var sentimentCache: [String: StockTwitsClient.SentimentSnapshot] = [:]
        var surgeCache: [String: Double] = [:]
        for symbol in targets {
            if let snapshot = await stockTwits.sentiment(for: symbol) { sentimentCache[symbol] = snapshot }
            if let surge = await stockTwits.messageCountSurge(for: symbol) { surgeCache[symbol] = surge }
        }
        socialCache = sentimentCache
        socialSurge = surgeCache
        socialLastRefreshed = Date()
    }

    func sentiment(for symbol: String) -> StockTwitsClient.SentimentSnapshot? {
        socialCache[symbol]
    }
}

import Foundation

/// Retail social sentiment from StockTwits' public endpoints.
///
/// This is the one genuinely free, keyless social-sentiment source that
/// survived the research pass. Reddit's API now requires manually-approved
/// OAuth registration and bills commercial use at a per-call rate with a
/// four-figure minimum — not viable for a shipped app, so it's excluded
/// entirely rather than half-integrated. StockTwits' `/trending` and
/// per-symbol `/streams` endpoints require no key, no login, and no app
/// registration.
///
/// What this buys the scanner that price and volume can't: StockTwits
/// messages carry a self-tagged Bullish/Bearish label, so the sentiment ratio
/// is a direct read of retail crowd positioning rather than something inferred
/// from price action. A symbol trending on watch-list adds *before* volume
/// shows up is a leading indicator; one trending only after a big move is
/// already crowded, which is closer to a hazard than an edge.
actor StockTwitsClient {

    // MARK: - Types

    struct TrendingSymbol: Codable, Sendable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let title: String
        let watchlistCount: Int?
    }

    struct SentimentSnapshot: Codable, Sendable {
        let symbol: String
        let bullishCount: Int
        let bearishCount: Int
        let untaggedCount: Int
        let messageCount: Int
        let fetchedAt: Date

        /// -1...1. Only messages the author actually tagged count toward this —
        /// untagged chatter is volume, not sentiment, and folding it in would
        /// dilute a real signal with noise.
        var sentimentScore: Double {
            let tagged = bullishCount + bearishCount
            guard tagged > 0 else { return 0 }
            return Double(bullishCount - bearishCount) / Double(tagged)
        }

        /// What share of the day's messages actually carry a tag. Low values
        /// mean the score above is built on a handful of posts and shouldn't
        /// be trusted at the same weight as a symbol with heavy tagged volume.
        var taggedFraction: Double {
            guard messageCount > 0 else { return 0 }
            return Double(bullishCount + bearishCount) / Double(messageCount)
        }
    }

    // MARK: - State

    private var trendingCache: [TrendingSymbol] = []
    private var trendingFetchedAt: Date?
    private var sentimentCache: [String: SentimentSnapshot] = [:]
    /// Message-count history per symbol, so a sudden spike in chatter volume
    /// is visible even before it shows up anywhere else.
    private var messageCountHistory: [String: [(date: Date, count: Int)]] = [:]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let str = try d.singleValueContainer().decode(String.self)
            // StockTwits uses "2026-09-07T14:32:10Z".
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: str) else {
                throw NSError(domain: "StockTwits", code: 1)
            }
            return date
        }
        return decoder
    }()

    // MARK: - Lookups

    func trending() -> [TrendingSymbol] { trendingCache }
    func sentiment(for symbol: String) -> SentimentSnapshot? { sentimentCache[symbol.uppercased()] }
    var trendingLastFetched: Date? { trendingFetchedAt }

    /// Rank of a symbol in the trending list, 0-based. Nil means not trending
    /// at all, which is the common case and not itself meaningful.
    func trendingRank(for symbol: String) -> Int? {
        trendingCache.firstIndex { $0.symbol.uppercased() == symbol.uppercased() }
    }

    /// Message volume now versus a recent baseline for this symbol. A crude
    /// but useful surge detector — StockTwits chatter about a name can front-run
    /// the volume and news signals by minutes.
    func messageCountSurge(for symbol: String) -> Double? {
        guard let history = messageCountHistory[symbol.uppercased()], history.count >= 3 else { return nil }
        let recent = history.suffix(1).map(\.count).first ?? 0
        let baseline = history.dropLast().map(\.count)
        guard !baseline.isEmpty else { return nil }
        let average = Double(baseline.reduce(0, +)) / Double(baseline.count)
        guard average > 0 else { return nil }
        return Double(recent) / average
    }

    // MARK: - Requests

    private struct TrendingResponse: Decodable {
        struct Symbol: Decodable {
            let symbol: String
            let title: String
            let watchlistCount: Int?
            enum CodingKeys: String, CodingKey {
                case symbol, title
                case watchlistCount = "watchlist_count"
            }
        }
        let symbols: [Symbol]
    }

    /// Trending tickers across the whole platform, ranked by StockTwits' own
    /// momentum metric (a mix of message velocity and watchlist adds).
    func refreshTrending() async throws {
        let url = URL(string: "https://api.stocktwits.com/api/2/trending/symbols.json")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A descriptive UA is good practice even where not required; StockTwits
        // publishes this endpoint without requiring one.
        request.setValue("DayTradeScanner/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StockTwitsError.badResponse
        }
        let decoded = try decoder.decode(TrendingResponse.self, from: data)

        trendingCache = decoded.symbols.map {
            TrendingSymbol(symbol: $0.symbol, title: $0.title, watchlistCount: $0.watchlistCount)
        }
        trendingFetchedAt = Date()
    }

    private struct StreamResponse: Decodable {
        struct Message: Decodable {
            struct Entities: Decodable {
                struct Sentiment: Decodable { let basic: String? }
                let sentiment: Sentiment?
            }
            let entities: Entities?
        }
        let messages: [Message]
    }

    /// Sentiment for one symbol, computed from its most recent public message
    /// stream. One request per symbol, so this is called for the current
    /// universe on a slow cadence rather than per-scoring-pass.
    func refreshSentiment(for symbol: String, messageLimit: Int = 30) async throws {
        let url = URL(string: "https://api.stocktwits.com/api/2/streams/symbol/\(symbol).json?limit=\(messageLimit)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DayTradeScanner/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StockTwitsError.badResponse }
        // A symbol with no StockTwits activity 404s. That's informative, not
        // an error — it just means no sentiment is available.
        guard http.statusCode != 404 else { return }
        guard (200..<300).contains(http.statusCode) else { throw StockTwitsError.badResponse }

        let decoded = try decoder.decode(StreamResponse.self, from: data)

        var bullish = 0, bearish = 0, untagged = 0
        for message in decoded.messages {
            switch message.entities?.sentiment?.basic {
            case "Bullish": bullish += 1
            case "Bearish": bearish += 1
            default: untagged += 1
            }
        }

        let snapshot = SentimentSnapshot(
            symbol: symbol.uppercased(),
            bullishCount: bullish,
            bearishCount: bearish,
            untaggedCount: untagged,
            messageCount: decoded.messages.count,
            fetchedAt: Date()
        )
        sentimentCache[symbol.uppercased()] = snapshot

        var history = messageCountHistory[symbol.uppercased()] ?? []
        history.append((date: Date(), count: decoded.messages.count))
        if history.count > 12 { history.removeFirst() }
        messageCountHistory[symbol.uppercased()] = history
    }

    /// Refreshes sentiment for a whole universe, paced to be a polite
    /// keyless client rather than a burst of parallel requests.
    func refreshSentiment(for symbols: [String]) async {
        for symbol in symbols {
            try? await refreshSentiment(for: symbol)
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    enum StockTwitsError: LocalizedError {
        case badResponse
        var errorDescription: String? { "StockTwits request failed." }
    }
}

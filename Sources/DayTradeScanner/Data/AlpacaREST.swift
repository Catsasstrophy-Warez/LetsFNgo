import Foundation

enum AlpacaFeed: String {
    /// The only live equity feed on the free plan.
    case iex
    /// Available on paid plans. Kept here so upgrading is a one-line change.
    case sip
}

enum AlpacaError: LocalizedError {
    case missingCredentials
    case http(Int, String)
    case decoding(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Add your Alpaca key and secret in Settings."
        case .http(let code, let body):
            return "Alpaca returned \(code). \(body.prefix(200))"
        case .decoding(let detail):
            return "Could not read Alpaca's response. \(detail)"
        case .rateLimited:
            return "Hit Alpaca's rate limit. The scanner will retry."
        }
    }
}

/// REST half of the Alpaca integration. Handles the things a websocket can't:
/// historical bars for baselines, daily bars for ATR and prior closes,
/// the tradable asset list, and news backfill on cold start.
actor AlpacaREST {
    private let dataBase = URL(string: "https://data.alpaca.markets")!
    private let tradingBase = URL(string: "https://paper-api.alpaca.markets")!
    private let session: URLSession
    private let decoder: JSONDecoder

    // ISO8601DateFormatter isn't Sendable, so a local instance can't be
    // captured by JSONDecoder's @Sendable custom-decoding closure under
    // Swift 6 strict concurrency. Hoisted to nonisolated(unsafe) statics —
    // configured once below, read-only from every call site after that —
    // so the closure captures no local, non-Sendable state at all.
    nonisolated(unsafe) private static let withFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        // Alpaca emits RFC 3339 with variable fractional-second precision,
        // which .iso8601 rejects. Parse both shapes.
        decoder.dateDecodingStrategy = .custom { d in
            let str = try d.singleValueContainer().decode(String.self)
            if let date = Self.withFractionFormatter.date(from: str) ?? Self.plainFormatter.date(from: str) { return date }
            throw AlpacaError.decoding("Unparseable timestamp: \(str)")
        }
    }

    // MARK: - Request plumbing

    private func authorized(_ url: URL) throws -> URLRequest {
        let settings = Settings.shared
        guard settings.hasCredentials else { throw AlpacaError.missingCredentials }
        var request = URLRequest(url: url)
        request.setValue(settings.alpacaKeyID, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(settings.alpacaSecret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch<T: Decodable>(_ url: URL, as type: T.Type, retries: Int = 2) async throws -> T {
        let request = try authorized(url)
        await AlpacaRateLimiter.shared.waitForSlot()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AlpacaError.decoding("No HTTP response")
        }
        if http.statusCode == 429 {
            guard retries > 0 else { throw AlpacaError.rateLimited }
            // Free tier is 200 req/min. Back off and try again rather than failing
            // the whole baseline build over one throttled symbol.
            try await Task.sleep(for: .seconds(2))
            return try await fetch(url, as: type, retries: retries - 1)
        }
        if http.statusCode == 401 {
            await MainActor.run { Settings.shared.credentialsAppearInvalid = true }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AlpacaError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        // A successful request from these same keys proves whatever
        // rejected them earlier is no longer true — most commonly, the
        // user just fixed them in Settings and reconnected.
        if Settings.shared.credentialsAppearInvalid {
            await MainActor.run { Settings.shared.credentialsAppearInvalid = false }
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AlpacaError.decoding(String(describing: error))
        }
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Historical minute bars

    private struct MultiBarsResponse: Decodable {
        let bars: [String: [MinuteBar]]?
        let nextPageToken: String?
        enum CodingKeys: String, CodingKey { case bars, nextPageToken = "next_page_token" }
    }

    /// Minute bars for up to ~100 symbols per call, paginated.
    /// Used to build the per-minute volume baseline curve.
    func minuteBars(
        symbols: [String],
        start: Date,
        end: Date,
        feed: AlpacaFeed = .iex
    ) async throws -> [String: [MinuteBar]] {
        var accumulated: [String: [MinuteBar]] = [:]
        var pageToken: String?

        repeat {
            var components = URLComponents(url: dataBase.appendingPathComponent("/v2/stocks/bars"),
                                           resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
                URLQueryItem(name: "timeframe", value: "1Min"),
                URLQueryItem(name: "start", value: Self.rfc3339.string(from: start)),
                URLQueryItem(name: "end", value: Self.rfc3339.string(from: end)),
                URLQueryItem(name: "limit", value: "10000"),
                URLQueryItem(name: "adjustment", value: "raw"),
                URLQueryItem(name: "feed", value: feed.rawValue)
            ]
            if let pageToken { items.append(URLQueryItem(name: "page_token", value: pageToken)) }
            components.queryItems = items

            let page = try await fetch(components.url!, as: MultiBarsResponse.self)
            for (symbol, bars) in page.bars ?? [:] {
                accumulated[symbol, default: []].append(contentsOf: bars)
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        return accumulated
    }

    // MARK: - Daily bars

    private struct MultiDailyResponse: Decodable {
        let bars: [String: [DailyBar]]?
        let nextPageToken: String?
        enum CodingKeys: String, CodingKey { case bars, nextPageToken = "next_page_token" }
    }

    /// Daily bars, used for prior close, ATR(14) and a liquidity pre-screen.
    /// Daily bars are available on the free plan for any feed.
    func dailyBars(symbols: [String], lookbackDays: Int = 30) async throws -> [String: [DailyBar]] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(lookbackDays * 2), to: end)!
        var components = URLComponents(url: dataBase.appendingPathComponent("/v2/stocks/bars"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "timeframe", value: "1Day"),
            URLQueryItem(name: "start", value: Self.rfc3339.string(from: start)),
            URLQueryItem(name: "limit", value: "10000"),
            URLQueryItem(name: "adjustment", value: "split"),
            URLQueryItem(name: "feed", value: "iex")
        ]
        let response = try await fetch(components.url!, as: MultiDailyResponse.self)
        return response.bars ?? [:]
    }

    // MARK: - Snapshots

    struct Snapshot: Decodable {
        let dailyBar: DailyBar?
        let prevDailyBar: DailyBar?
        let minuteBar: MinuteBar?
        enum CodingKeys: String, CodingKey {
            case dailyBar = "dailyBar", prevDailyBar = "prevDailyBar", minuteBar = "minuteBar"
        }
    }

    private struct SnapshotResponse: Decodable {
        let snapshots: [String: Snapshot]?
    }

    /// One call that fills in prior close, today's open and the last minute bar.
    /// Used at startup so the list isn't empty until the first stream tick.
    func snapshots(symbols: [String]) async throws -> [String: Snapshot] {
        var components = URLComponents(url: dataBase.appendingPathComponent("/v2/stocks/snapshots"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "feed", value: "iex")
        ]
        // The multi-snapshot endpoint returns a bare dictionary on some versions
        // and a wrapped object on others. Try the wrapper, fall back to bare.
        if let wrapped = try? await fetch(components.url!, as: SnapshotResponse.self),
           let snapshots = wrapped.snapshots {
            return snapshots
        }
        return try await fetch(components.url!, as: [String: Snapshot].self)
    }

    // MARK: - News backfill

    private struct NewsResponse: Decodable {
        let news: [NewsItem]
        let nextPageToken: String?
        enum CodingKeys: String, CodingKey { case news, nextPageToken = "next_page_token" }
    }

    /// Recent headlines so a symbol that gapped on 6am news still shows a
    /// catalyst when you open the app at 9:25.
    func recentNews(symbols: [String], since: Date, limit: Int = 50) async throws -> [NewsItem] {
        var components = URLComponents(url: dataBase.appendingPathComponent("/v1beta1/news"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "start", value: Self.rfc3339.string(from: since)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "desc")
        ]
        return try await fetch(components.url!, as: NewsResponse.self).news
    }

    // MARK: - Assets

    struct Asset: Decodable {
        let symbol: String
        let name: String
        let tradable: Bool
        let fractionable: Bool
        let easyToBorrow: Bool
        let shortable: Bool
        let exchange: String
        enum CodingKeys: String, CodingKey {
            case symbol, name, tradable, fractionable, exchange, shortable
            case easyToBorrow = "easy_to_borrow"
        }
    }

    // MARK: - Account verification

    /// Minimal decode of `/v2/account` — enough to positively confirm the
    /// saved keys are real, valid, and specifically paper-trading keys.
    /// This isn't just informational: `tradingBase` is hardcoded to
    /// `paper-api.alpaca.markets`, and Alpaca live-account keys are not
    /// valid credentials against that host at all — they're a completely
    /// separate key pair scoped to `api.alpaca.markets`. A successful
    /// response here is itself proof the keys can only ever touch the
    /// paper environment; nothing in this app calls a live endpoint or an
    /// order-submission endpoint of any kind, on any host.
    struct AccountSummary: Decodable, Sendable {
        let accountNumber: String
        let status: String
        let buyingPower: String
        let cash: String

        enum CodingKeys: String, CodingKey {
            case accountNumber = "account_number"
            case status
            case buyingPower = "buying_power"
            case cash
        }
    }

    func verifyPaperAccount() async throws -> AccountSummary {
        let url = tradingBase.appendingPathComponent("/v2/account")
        return try await fetch(url, as: AccountSummary.self)
    }

    /// The tradable US equity list. `shortable` and `easyToBorrow` are the
    /// closest thing to borrow availability the free tier exposes.
    func tradableAssets() async throws -> [Asset] {
        var components = URLComponents(url: tradingBase.appendingPathComponent("/v2/assets"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "status", value: "active"),
            URLQueryItem(name: "asset_class", value: "us_equity")
        ]
        return try await fetch(components.url!, as: [Asset].self)
    }

    // MARK: - Options chains

    struct OptionContractRaw: Decodable {
        let symbol: String
        let name: String?
        let underlyingSymbol: String
        let expirationDate: String
        let strikePrice: Double
        let type: String
        let style: String?
        let openInterest: String?
        let closePrice: String?
        enum CodingKeys: String, CodingKey {
            case symbol, name, type, style
            case underlyingSymbol = "underlying_symbol"
            case expirationDate = "expiration_date"
            case strikePrice = "strike_price"
            case openInterest = "open_interest"
            case closePrice = "close_price"
        }
    }

    private struct OptionContractsResponse: Decodable {
        let optionContracts: [OptionContractRaw]?
        let nextPageToken: String?
        enum CodingKeys: String, CodingKey {
            case optionContracts = "option_contracts"
            case nextPageToken = "next_page_token"
        }
    }

    /// The full contract list for one underlying — strikes, expirations, and
    /// static reference fields. Quotes/greeks come from `optionSnapshots`.
    func optionContracts(underlying: String) async throws -> [OptionContractRaw] {
        var accumulated: [OptionContractRaw] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: tradingBase.appendingPathComponent("/v2/options/contracts"),
                                           resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "underlying_symbols", value: underlying),
                URLQueryItem(name: "status", value: "active"),
                URLQueryItem(name: "limit", value: "1000")
            ]
            if let pageToken { items.append(URLQueryItem(name: "page_token", value: pageToken)) }
            components.queryItems = items
            let page = try await fetch(components.url!, as: OptionContractsResponse.self)
            accumulated.append(contentsOf: page.optionContracts ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return accumulated
    }

    struct OptionQuoteRaw: Decodable {
        let latestQuote: LatestQuote?
        let latestTrade: LatestTrade?
        let greeks: GreeksRaw?
        let impliedVolatility: Double?
        enum CodingKeys: String, CodingKey {
            case latestQuote, latestTrade, greeks
            case impliedVolatility = "impliedVolatility"
        }
    }
    struct LatestQuote: Decodable {
        let bidPrice: Double?
        let askPrice: Double?
        let bidSize: Int?
        let askSize: Int?
    }
    struct LatestTrade: Decodable {
        let price: Double?
        let size: Int?
        let timestamp: Date?
        enum CodingKeys: String, CodingKey { case price, size, timestamp = "t" }
    }
    struct GreeksRaw: Decodable {
        let delta: Double?
        let gamma: Double?
        let theta: Double?
        let vega: Double?
        let rho: Double?
    }

    private struct OptionSnapshotsResponse: Decodable {
        let snapshots: [String: OptionQuoteRaw]?
    }

    /// Live quote/greeks snapshot per contract symbol. Alpaca computes and
    /// returns greeks server-side when available; `GreeksEngine` recomputes
    /// them locally as a fallback and for what-if strategy modeling.
    func optionSnapshots(contractSymbols: [String]) async throws -> [String: OptionQuoteRaw] {
        var components = URLComponents(url: dataBase.appendingPathComponent("/v1beta1/options/snapshots"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: contractSymbols.joined(separator: ","))
        ]
        let wrapped = try await fetch(components.url!, as: OptionSnapshotsResponse.self)
        return wrapped.snapshots ?? [:]
    }
}

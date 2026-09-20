import Foundation

/// Free float data from the SEC's EDGAR XBRL APIs.
///
/// Float is the variable this entire category of scanner is built around — a
/// 4M-share float is why a stock goes 60% on one headline — and it turns out
/// to be free. The EDGAR data APIs require no authentication or API key. Two
/// `dei` concepts carry what we need:
///
///   - `EntityCommonStockSharesOutstanding` — share count from the cover page
///     of every 10-K and 10-Q.
///   - `EntityPublicFloat` — the aggregate *dollar* value of shares held by
///     non-affiliates, i.e. float measured in money rather than shares.
///
/// Dividing public float by the share price on the measurement date converts
/// dollars into the share count traders actually quote.
///
/// The Frames endpoint is what makes this practical on a phone: it flips the
/// axis, returning one concept across every filer for a period. The whole
/// market's float arrives in a handful of requests instead of eleven thousand.
///
/// Two rules the SEC enforces and this client respects:
///   - A `User-Agent` identifying the application and a contact address.
///     Omitting it gets the IP blocked, not rate-limited.
///   - No more than 10 requests per second.
actor SECFloatClient {

    // MARK: - Types

    struct FloatRecord: Codable, Sendable {
        let symbol: String
        let cik: Int
        var entityName: String

        /// Share count from the most recent cover page.
        var sharesOutstanding: Double?
        /// Aggregate market value of shares held by non-affiliates, in dollars.
        var publicFloatUSD: Double?
        /// Float in shares, derived from `publicFloatUSD` and the price on
        /// `publicFloatDate`. Nil when either input is missing.
        var floatShares: Double?

        var sharesOutstandingDate: Date?
        var publicFloatDate: Date?
        var fetchedAt: Date

        /// Insider and affiliate ownership implied by the two figures.
        /// A very high number is often a recent IPO or a controlled company —
        /// both of which trade differently from a normal small cap.
        var nonFloatPercent: Double? {
            guard let floatShares, let sharesOutstanding, sharesOutstanding > 0 else { return nil }
            return max(0, 1 - (floatShares / sharesOutstanding))
        }

        /// How stale the float figure is. Filings are quarterly, so anything
        /// under ~100 days is as fresh as this data ever gets.
        var ageInDays: Int? {
            guard let reference = publicFloatDate ?? sharesOutstandingDate else { return nil }
            return Calendar.current.dateComponents([.day], from: reference, to: Date()).day
        }

        /// The number traders actually use. Nil when float is unknown, which
        /// must stay distinguishable from "large float" — treating unknown as
        /// large silently drops exactly the symbols worth finding.
        var category: FloatCategory? {
            guard let floatShares else { return nil }
            return FloatCategory.classify(floatShares)
        }

        /// Post-filing dilution is invisible here. An offering announced after
        /// the last 10-Q can multiply the float without changing this number,
        /// which is why the news classifier flags offerings separately.
        var isPotentiallyStale: Bool { (ageInDays ?? 999) > 120 }
    }

    enum FloatCategory: String, Codable, CaseIterable, Sendable {
        case nano      // under 5M shares
        case micro     // 5–20M
        case low       // 20–50M
        case medium    // 50–150M
        case large     // 150M+

        static func classify(_ shares: Double) -> FloatCategory {
            switch shares {
            case ..<5_000_000: return .nano
            case ..<20_000_000: return .micro
            case ..<50_000_000: return .low
            case ..<150_000_000: return .medium
            default: return .large
            }
        }

        var displayName: String {
            switch self {
            case .nano: return "Nano float"
            case .micro: return "Micro float"
            case .low: return "Low float"
            case .medium: return "Medium float"
            case .large: return "Large float"
            }
        }

        var shortLabel: String {
            switch self {
            case .nano: return "<5M"
            case .micro: return "5–20M"
            case .low: return "20–50M"
            case .medium: return "50–150M"
            case .large: return "150M+"
            }
        }

        /// How much a tight float amplifies a move. The published momentum
        /// criteria most retail day traders work from prefer under 20M shares
        /// and treat anything over 100M as unsuitable — this curve follows
        /// that shape without hard-cutting, so a good setup on a 60M float
        /// still ranks, just lower.
        var tightnessScore: Double {
            switch self {
            case .nano: return 1.0
            case .micro: return 0.85
            case .low: return 0.55
            case .medium: return 0.25
            case .large: return 0.05
            }
        }

        /// Tight floats move violently in both directions and halt often.
        /// Surfacing that alongside the opportunity is the whole point.
        var carriesElevatedRisk: Bool { self == .nano || self == .micro }
    }

    // MARK: - State

    private var records: [String: FloatRecord] = [:]
    private var tickerToCIK: [String: Int] = [:]
    private var cikToTicker: [Int: String] = [:]
    private(set) var lastRefreshedAt: Date?
    private(set) var isRefreshing = false

    private let session: URLSession
    private let fileURL: URL
    private let mapFileURL: URL

    /// The SEC requires this. It must identify the application and provide a
    /// contact address; a generic or absent value results in a block.
    private let userAgent: String

    /// Simple token-bucket pacing to stay under 10 requests per second.
    private var lastRequestAt: Date = .distantPast
    private let minimumRequestInterval: TimeInterval = 0.12

    init(contactEmail: String? = nil, appName: String = "DayTradeScanner") {
        // EDGAR blocks requests whose User-Agent doesn't identify the caller,
        // so fall back to a placeholder only so the app doesn't crash — the
        // settings screen requires a real address before enabling the refresh.
        let contact = contactEmail?.isEmpty == false ? contactEmail! : "contact-not-set@example.com"
        userAgent = "\(appName) \(contact)"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sec-float.json")
        mapFileURL = directory.appendingPathComponent("sec-ticker-map.json")
        loadFromDisk()
    }

    // MARK: - Public lookups

    func record(for symbol: String) -> FloatRecord? { records[symbol.uppercased()] }
    func floatShares(for symbol: String) -> Double? { records[symbol.uppercased()]?.floatShares }
    func category(for symbol: String) -> FloatCategory? { records[symbol.uppercased()]?.category }
    var recordCount: Int { records.count }
    var mappedTickerCount: Int { tickerToCIK.count }

    /// Resolves a symbol to its CIK from the ticker map alone.
    ///
    /// Deliberately independent of `record(for:)` / the float cache: the
    /// ticker-to-CIK map is one cheap, unconditional fetch, while float
    /// values require the much heavier Frames-based market refresh. Anything
    /// that only needs "which company is this" — like resolving filing-feed
    /// symbols — should never be blocked on the user having refreshed float
    /// data first.
    func cik(for symbol: String) async -> Int? {
        try? await refreshTickerMap()
        return tickerToCIK[symbol.uppercased()]
    }

    /// The whole CIK-to-ticker map, for callers (like the live filing stream)
    /// that need to resolve many filings against many symbols at once rather
    /// than one lookup at a time.
    func fullCIKToTickerMap() async -> [Int: String] {
        try? await refreshTickerMap()
        return cikToTicker
    }

    func symbols(in categories: Set<FloatCategory>) -> [String] {
        records.values
            .filter { record in record.category.map { categories.contains($0) } ?? false }
            .map(\.symbol)
    }

    // MARK: - Request plumbing

    private func paced() async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minimumRequestInterval {
            try? await Task.sleep(for: .seconds(minimumRequestInterval - elapsed))
        }
        lastRequestAt = Date()
    }

    private func fetch(_ url: URL) async throws -> Data {
        await paced()
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SECError.badResponse
        }
        // 403 here almost always means the User-Agent was rejected rather than
        // any genuine permission problem.
        guard http.statusCode != 403 else { throw SECError.userAgentRejected }
        guard http.statusCode != 429 else { throw SECError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            throw SECError.http(http.statusCode)
        }
        return data
    }

    enum SECError: LocalizedError {
        case badResponse
        case userAgentRejected
        case rateLimited
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badResponse: return "No response from EDGAR."
            case .userAgentRejected:
                return "EDGAR rejected the request. It requires a User-Agent naming the app and a contact address."
            case .rateLimited: return "EDGAR rate limit reached. Requests are capped at 10 per second."
            case .http(let code): return "EDGAR returned \(code)."
            }
        }
    }

    // MARK: - Ticker to CIK

    private struct TickerEntry: Decodable {
        let cikStr: Int
        let ticker: String
        let title: String
        enum CodingKeys: String, CodingKey {
            case cikStr = "cik_str", ticker, title
        }
    }

    /// Downloads the ticker-to-CIK map. About 10,000 entries in one request,
    /// keyed by an arbitrary numeric string rather than an array.
    func refreshTickerMap(force: Bool = false) async throws {
        if !force, !tickerToCIK.isEmpty { return }

        let url = URL(string: "https://www.sec.gov/files/company_tickers.json")!
        let data = try await fetch(url)
        let decoded = try JSONDecoder().decode([String: TickerEntry].self, from: data)

        var forward: [String: Int] = [:]
        var reverse: [Int: String] = [:]
        forward.reserveCapacity(decoded.count)

        for entry in decoded.values {
            let symbol = entry.ticker.uppercased()
            forward[symbol] = entry.cikStr
            // A CIK can map to several tickers (share classes). Keep the
            // shortest, which is reliably the common-stock line.
            if let existing = reverse[entry.cikStr], existing.count <= symbol.count { continue }
            reverse[entry.cikStr] = symbol
        }

        tickerToCIK = forward
        cikToTicker = reverse
        saveMapToDisk()
    }

    // MARK: - Frames: the whole market in a few calls

    private struct FramesResponse: Decodable {
        struct Point: Decodable {
            let cik: Int
            let entityName: String
            let end: String
            let val: Double
        }
        let data: [Point]
    }

    private static let frameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Frame identifiers look like `CY2025Q3I` — calendar year, quarter, and a
    /// trailing `I` for instantaneous (point-in-time) facts. Both concepts here
    /// are instantaneous.
    ///
    /// Returns the most recent few quarters so a filer that hasn't reported in
    /// the current one still resolves.
    private func recentFrames(count: Int = 5) -> [String] {
        var frames: [String] = []
        let calendar = Calendar(identifier: .gregorian)
        var date = Date()
        for _ in 0..<count {
            let year = calendar.component(.year, from: date)
            let quarter = (calendar.component(.month, from: date) - 1) / 3 + 1
            frames.append("CY\(year)Q\(quarter)I")
            date = calendar.date(byAdding: .month, value: -3, to: date) ?? date
        }
        return frames
    }

    /// Pulls shares outstanding and public float for the entire market.
    ///
    /// - Parameter priceLookup: resolves a symbol and measurement date to the
    ///   closing price on (or near) that date, used to convert public float in
    ///   dollars into a share count. Supply the daily bars the universe
    ///   screener has already fetched; returning nil simply leaves
    ///   `floatShares` unset rather than producing a wrong number.
    @discardableResult
    func refreshMarketFloat(
        priceLookup: @Sendable (String, Date) async -> Double?,
        progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> Int {
        guard !isRefreshing else { return records.count }
        isRefreshing = true
        defer { isRefreshing = false }

        progress(0.05, "Loading SEC ticker map")
        try await refreshTickerMap()

        var working: [Int: FloatRecord] = [:]

        // Seed from whatever is already cached so a partial refresh doesn't
        // discard last quarter's data for filers that skipped this one.
        for record in records.values {
            working[record.cik] = record
        }

        let frames = recentFrames()

        // --- Shares outstanding -------------------------------------------
        progress(0.15, "Fetching shares outstanding")
        for (index, frame) in frames.enumerated() {
            let url = URL(string: "https://data.sec.gov/api/xbrl/frames/dei/EntityCommonStockSharesOutstanding/shares/\(frame).json")!
            guard let data = try? await fetch(url),
                  let response = try? JSONDecoder().decode(FramesResponse.self, from: data) else { continue }

            for point in response.data {
                guard let symbol = cikToTicker[point.cik] else { continue }
                let end = Self.frameDateFormatter.date(from: point.end)

                var record = working[point.cik] ?? FloatRecord(
                    symbol: symbol,
                    cik: point.cik,
                    entityName: point.entityName,
                    fetchedAt: Date()
                )
                // Frames are walked newest-first, so only fill a gap — never
                // overwrite a fresher figure with an older one.
                if record.sharesOutstanding == nil || (record.sharesOutstandingDate ?? .distantPast) < (end ?? .distantPast) {
                    record.sharesOutstanding = point.val
                    record.sharesOutstandingDate = end
                }
                working[point.cik] = record
            }
            progress(0.15 + (Double(index + 1) / Double(frames.count)) * 0.3, "Shares outstanding \(frame)")
        }

        // --- Public float --------------------------------------------------
        progress(0.5, "Fetching public float")
        for (index, frame) in frames.enumerated() {
            let url = URL(string: "https://data.sec.gov/api/xbrl/frames/dei/EntityPublicFloat/USD/\(frame).json")!
            guard let data = try? await fetch(url),
                  let response = try? JSONDecoder().decode(FramesResponse.self, from: data) else { continue }

            for point in response.data {
                guard let symbol = cikToTicker[point.cik] else { continue }
                let end = Self.frameDateFormatter.date(from: point.end)

                var record = working[point.cik] ?? FloatRecord(
                    symbol: symbol,
                    cik: point.cik,
                    entityName: point.entityName,
                    fetchedAt: Date()
                )
                if record.publicFloatUSD == nil || (record.publicFloatDate ?? .distantPast) < (end ?? .distantPast) {
                    record.publicFloatUSD = point.val
                    record.publicFloatDate = end
                }
                working[point.cik] = record
            }
            progress(0.5 + (Double(index + 1) / Double(frames.count)) * 0.3, "Public float \(frame)")
        }

        // --- Dollars to shares ----------------------------------------------
        progress(0.85, "Converting float to shares")
        var converted: [String: FloatRecord] = [:]
        converted.reserveCapacity(working.count)

        for var record in working.values {
            if let dollars = record.publicFloatUSD,
               let date = record.publicFloatDate,
               let price = await priceLookup(record.symbol, date),
               price > 0 {
                let shares = dollars / price
                // Sanity gate: float cannot exceed shares outstanding. When it
                // does, the price lookup landed on the wrong date or a split
                // sits between the two figures — drop it rather than publish
                // a number that will be trusted.
                if let outstanding = record.sharesOutstanding, shares > outstanding * 1.05 {
                    record.floatShares = nil
                } else {
                    record.floatShares = shares
                }
            }
            record.fetchedAt = Date()
            converted[record.symbol] = record
        }

        records = converted
        lastRefreshedAt = Date()
        saveToDisk()
        progress(1.0, "Done")
        return records.count
    }

    /// Per-symbol fallback via CompanyConcept, for a name the frames missed.
    /// One request per symbol, so this is for filling gaps, not bulk loading.
    func refreshSymbol(_ symbol: String, priceLookup: @Sendable (String, Date) async -> Double?) async throws {
        try await refreshTickerMap()
        let upper = symbol.uppercased()
        guard let cik = tickerToCIK[upper] else { return }
        let padded = String(format: "CIK%010d", cik)

        struct LegacyConceptResponse: Decodable {
            struct Unit: Decodable {
                let end: String
                let val: Double
            }
            let entityName: String
            let units: [String: [Unit]]
        }

        var record = records[upper] ?? FloatRecord(
            symbol: upper, cik: cik, entityName: upper, fetchedAt: Date()
        )

        if let url = URL(string: "https://data.sec.gov/api/xbrl/companyconcept/\(padded)/dei/EntityCommonStockSharesOutstanding.json"),
           let data = try? await fetch(url),
           let decoded = try? JSONDecoder().decode(LegacyConceptResponse.self, from: data),
           let latest = decoded.units["shares"]?.max(by: { $0.end < $1.end }) {
            record.sharesOutstanding = latest.val
            record.sharesOutstandingDate = Self.frameDateFormatter.date(from: latest.end)
            record.entityName = decoded.entityName
        }

        if let url = URL(string: "https://data.sec.gov/api/xbrl/companyconcept/\(padded)/dei/EntityPublicFloat.json"),
           let data = try? await fetch(url),
           let decoded = try? JSONDecoder().decode(LegacyConceptResponse.self, from: data),
           let latest = decoded.units["USD"]?.max(by: { $0.end < $1.end }) {
            record.publicFloatUSD = latest.val
            record.publicFloatDate = Self.frameDateFormatter.date(from: latest.end)

            if let date = record.publicFloatDate,
               let price = await priceLookup(upper, date), price > 0 {
                let shares = latest.val / price
                if let outstanding = record.sharesOutstanding, shares <= outstanding * 1.05 {
                    record.floatShares = shares
                } else if record.sharesOutstanding == nil {
                    record.floatShares = shares
                }
            }
        }

        record.fetchedAt = Date()
        records[upper] = record
        saveToDisk()
    }

    // MARK: - Fundamentals (long-term horizon)

    struct Fundamentals: Sendable {
        var revenueTTM: Double?
        var revenueTTMYearAgo: Double?
        var netIncomeTTM: Double?
        var netIncomeTTMYearAgo: Double?
        var totalAssets: Double?
        var totalLiabilities: Double?
        var entityName: String?
    }

    private struct ConceptResponse: Decodable {
        struct Fact: Decodable {
            let start: String?
            let end: String
            let val: Double
            let form: String
        }
        let entityName: String
        let units: [String: [Fact]]
    }

    /// XBRL concept names vary by filer and revenue-recognition method — the
    /// SEC's own guidance is to try several and use the first that returns
    /// data, which is exactly what this does.
    private static let revenueConceptCandidates = [
        "Revenues",
        "RevenueFromContractWithCustomerExcludingAssessedTax",
        "RevenueFromContractWithCustomerIncludingAssessedTax",
        "SalesRevenueNet"
    ]

    /// Pulls trailing-twelve-month revenue, net income, and the latest
    /// balance-sheet snapshot for one company. One symbol at a time by
    /// design — this is called on the long-term engine's slow refresh for a
    /// short, deliberately curated watchlist, never for a few hundred symbols
    /// the way the day-trade float refresh is.
    func fundamentals(for symbol: String) async -> Fundamentals? {
        try? await refreshTickerMap()
        guard let cik = tickerToCIK[symbol.uppercased()] else { return nil }
        let padded = String(format: "CIK%010d", cik)

        var result = Fundamentals()

        for concept in Self.revenueConceptCandidates {
            guard let (ttm, yearAgo, name) = await quarterlyTTM(padded: padded, taxonomy: "us-gaap", concept: concept) else { continue }
            result.revenueTTM = ttm
            result.revenueTTMYearAgo = yearAgo
            result.entityName = name
            break
        }

        if let (ttm, yearAgo, name) = await quarterlyTTM(padded: padded, taxonomy: "us-gaap", concept: "NetIncomeLoss") {
            result.netIncomeTTM = ttm
            result.netIncomeTTMYearAgo = yearAgo
            if result.entityName == nil { result.entityName = name }
        }

        result.totalAssets = await latestInstant(padded: padded, concept: "Assets")
        result.totalLiabilities = await latestInstant(padded: padded, concept: "Liabilities")

        return result
    }

    /// Sums the four most recent distinct quarterly (duration ~80–100 day)
    /// facts for a concept, and the four quarters ending roughly a year
    /// before that, for a year-over-year comparison. Restated values for the
    /// same period are deduplicated by keeping the most recently filed one.
    private func quarterlyTTM(
        padded: String,
        taxonomy: String,
        concept: String
    ) async -> (ttm: Double, yearAgo: Double?, entityName: String)? {
        guard let url = URL(string: "https://data.sec.gov/api/xbrl/companyconcept/\(padded)/\(taxonomy)/\(concept).json"),
              let data = try? await fetch(url),
              let decoded = try? JSONDecoder().decode(ConceptResponse.self, from: data),
              let facts = decoded.units["USD"] else { return nil }

        let formatter = Self.frameDateFormatter

        var byEnd: [Date: Double] = [:]
        for fact in facts {
            guard let startStr = fact.start, let start = formatter.date(from: startStr),
                  let end = formatter.date(from: fact.end) else { continue }
            let days = end.timeIntervalSince(start) / 86400
            guard days > 75, days < 100 else { continue }   // quarterly duration only
            byEnd[end] = fact.val   // later entries in the array overwrite earlier (restated) ones
        }

        let sortedQuarters = byEnd.sorted { $0.key > $1.key }
        guard sortedQuarters.count >= 4 else { return nil }

        // A concept can return HTTP 200 with real facts and still be the
        // wrong one for this filer — Apple's own "Revenues" tag, for example,
        // has valid-looking quarterly data that stops in 2018, the year the
        // company switched to a different revenue-recognition tag. Without a
        // recency check, that stale data would be silently accepted as
        // current TTM revenue instead of falling through to the concept that
        // actually has recent filings. A quarter is treated as usable only if
        // its period ended within the last ~14 months — generous enough for
        // a company mid-way through a slow filing cycle, tight enough to
        // reject a tag the filer has since abandoned.
        guard let mostRecentEnd = sortedQuarters.first?.key,
              Date().timeIntervalSince(mostRecentEnd) < 425 * 86400 else { return nil }

        let ttm = sortedQuarters.prefix(4).map(\.value).reduce(0, +)
        let yearAgoSlice = sortedQuarters.dropFirst(4).prefix(4)
        let yearAgo = yearAgoSlice.count == 4 ? yearAgoSlice.map(\.value).reduce(0, +) : nil

        return (ttm, yearAgo, decoded.entityName)
    }

    /// Most recent instantaneous (balance-sheet) value for a concept.
    private func latestInstant(padded: String, concept: String) async -> Double? {
        guard let url = URL(string: "https://data.sec.gov/api/xbrl/companyconcept/\(padded)/us-gaap/\(concept).json"),
              let data = try? await fetch(url),
              let decoded = try? JSONDecoder().decode(ConceptResponse.self, from: data),
              let facts = decoded.units["USD"] else { return nil }

        let formatter = Self.frameDateFormatter
        let instants = facts.compactMap { fact -> (Date, Double)? in
            guard fact.start == nil, let end = formatter.date(from: fact.end) else { return nil }
            return (end, fact.val)
        }
        return instants.max { $0.0 < $1.0 }?.1
    }

    // MARK: - Filing frequency, cadence, and sector (all from one submissions fetch)

    private struct SubmissionsResponse: Decodable {
        struct Filings: Decodable {
            struct Recent: Decodable {
                let form: [String]
                let filingDate: [String]
            }
            let recent: Recent
        }
        let filings: Filings
        /// Standard Industrial Classification — a coarse but genuinely free
        /// sector/industry label. This rides along in the exact same response
        /// already fetched for filing frequency and cadence, so surfacing it
        /// costs nothing extra in requests.
        let sic: String?
        let sicDescription: String?
    }

    struct SubmissionsSummary: Sendable {
        let form4CountLast90Days: Int
        let recentPeriodicFilingDates: [Date]
        let sicDescription: String?
    }

    private var submissionsCache: [String: (summary: SubmissionsSummary, fetchedAt: Date)] = [:]

    /// One fetch per symbol, cached for the rest of the session. Consolidates
    /// what were previously two separate calls into one — the swing and
    /// long-term engines both call this per symbol on every refresh, so
    /// consolidating halves the request count for both.
    func submissionsSummary(for symbol: String, useCache: Bool = true) async -> SubmissionsSummary? {
        let upper = symbol.uppercased()
        if useCache, let cached = submissionsCache[upper], Date().timeIntervalSince(cached.fetchedAt) < 3600 {
            return cached.summary
        }

        try? await refreshTickerMap()
        guard let cik = tickerToCIK[upper] else { return nil }
        let padded = String(format: "CIK%010d", cik)
        guard let url = URL(string: "https://data.sec.gov/submissions/\(padded).json"),
              let data = try? await fetch(url),
              let decoded = try? JSONDecoder().decode(SubmissionsResponse.self, from: data) else { return nil }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        var form4Count = 0
        var periodicDates: [Date] = []

        for (index, form) in decoded.filings.recent.form.enumerated() {
            guard index < decoded.filings.recent.filingDate.count,
                  let date = Self.frameDateFormatter.date(from: decoded.filings.recent.filingDate[index]) else { continue }

            if form == "4", date >= cutoff { form4Count += 1 }
            if (form == "10-Q" || form == "10-K"), periodicDates.count < 4 { periodicDates.append(date) }
        }

        let summary = SubmissionsSummary(
            form4CountLast90Days: form4Count,
            recentPeriodicFilingDates: periodicDates,
            sicDescription: decoded.sicDescription
        )
        submissionsCache[upper] = (summary, Date())
        return summary
    }

    /// Thin wrapper kept for call-site compatibility — prefer
    /// `submissionsSummary(for:)` when both filing frequency and cadence are
    /// needed, since that costs one fetch instead of two.
    func recentForm4Count(for symbol: String, withinDays: Int = 90) async -> Int {
        await submissionsSummary(for: symbol)?.form4CountLast90Days ?? 0
    }

    /// Thin wrapper kept for call-site compatibility — see
    /// `submissionsSummary(for:)`.
    func recentPeriodicFilingDates(for symbol: String, limit: Int = 4) async -> [Date] {
        Array((await submissionsSummary(for: symbol))?.recentPeriodicFilingDates.prefix(limit) ?? [])
    }

    // MARK: - Persistence

    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func saveMapToDisk() {
        if let data = try? JSONEncoder().encode(tickerToCIK) {
            try? data.write(to: mapFileURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: FloatRecord].self, from: data) {
            records = decoded
        }
        if let data = try? Data(contentsOf: mapFileURL),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            tickerToCIK = decoded
            cikToTicker = Dictionary(decoded.map { ($0.value, $0.key) }, uniquingKeysWith: { a, b in
                a.count <= b.count ? a : b
            })
        }
    }

    func clear() {
        records = [:]
        lastRefreshedAt = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}

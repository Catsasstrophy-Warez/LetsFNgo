import Foundation

/// Live trading halts from Nasdaq's free Trade Halt RSS feed.
///
/// This replaces the estimated LULD band proximity the scanner previously used
/// with the actual event. Nasdaq publishes the same halt and pause information
/// shown on its Trading Halts page for both Nasdaq-listed and other
/// exchange-listed securities, free, with no key.
///
/// Halts matter in two opposite directions, and the app needs both:
///   - **Hazard.** No orders execute anywhere in the US while a symbol is
///     halted. A position entered thirty seconds before a bad-news halt cannot
///     be exited, sometimes for hours.
///   - **Opportunity.** The reopening auction after a volatility pause often
///     produces a large, fast move — the "halt and go" — which is a deliberate
///     strategy rather than an accident.
actor HaltMonitor {

    // MARK: - Halt codes

    /// Reason codes as published by Nasdaq and NYSE. The distinction that
    /// matters most for trading is bounded versus open-ended: an LUDP clears
    /// automatically in about five minutes, while a T12 has no clock at all.
    enum HaltCode: String, Codable, CaseIterable, Sendable {
        case luld = "LUDP"          // volatility pause, auto-clears
        case luldStraddle = "LUDS"  // NBBO straddles the band
        case volatilityM = "M"      // NYSE volatility pause
        case t1 = "T1"              // news pending
        case t2 = "T2"              // news released
        case t5 = "T5"              // legacy single-stock trading pause
        case t12 = "T12"            // exchange wants more information
        case h4 = "H4"              // non-compliance
        case h10 = "H10"            // SEC trading suspension
        case ipo = "IPO1"
        case mwc1 = "MWC1"
        case mwc2 = "MWC2"
        case mwc3 = "MWC3"
        case other = "OTHER"

        static func parse(_ raw: String) -> HaltCode {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let match = HaltCode(rawValue: cleaned) { return match }
            if cleaned.hasPrefix("LUD") { return .luld }
            if cleaned.hasPrefix("MWC") { return .mwc1 }
            if cleaned.hasPrefix("IPO") { return .ipo }
            return .other
        }

        var displayName: String {
            switch self {
            case .luld, .luldStraddle, .volatilityM, .t5: return "Volatility pause"
            case .t1: return "News pending"
            case .t2: return "News released"
            case .t12: return "Additional information requested"
            case .h4: return "Non-compliance"
            case .h10: return "SEC suspension"
            case .ipo: return "IPO pending"
            case .mwc1, .mwc2, .mwc3: return "Market-wide circuit breaker"
            case .other: return "Halted"
            }
        }

        var explanation: String {
            switch self {
            case .luld, .luldStraddle, .volatilityM:
                return "Price moved outside the Limit Up-Limit Down band. Automatic, and normally clears in about five minutes."
            case .t5:
                return "Legacy single-stock pause, still used on securities outside the LULD plan."
            case .t1:
                return "The exchange halted trading because a material announcement is coming. Duration depends entirely on how fast the company disseminates it."
            case .t2:
                return "News has been released and trading is expected to resume shortly."
            case .t12:
                return "The exchange has asked the company questions and will not resume until satisfied. Open-ended with no published time limit, and often associated with parabolic moves that filings don't explain."
            case .h4:
                return "Halted for a listing-compliance failure. Can last days."
            case .h10:
                return "An SEC trading suspension under Section 12(k). Capped at ten business days by statute, and the security frequently reopens far lower."
            case .ipo:
                return "Pre-opening pause on a new listing."
            case .mwc1, .mwc2, .mwc3:
                return "A market-wide circuit breaker. Levels 1 and 2 pause everything for fifteen minutes; Level 3 ends the session."
            case .other:
                return "Trading is halted. Confirm the reason before acting."
            }
        }

        /// Roughly how long this code historically takes to clear. Used to
        /// decide whether a resume is worth waiting for.
        var expectedDurationMinutes: Int? {
            switch self {
            case .luld, .luldStraddle, .volatilityM, .t5: return 5
            case .t2: return 10
            case .mwc1, .mwc2: return 15
            case .t1: return 60
            case .ipo: return 30
            case .t12, .h4, .h10, .mwc3, .other: return nil
            }
        }

        /// Whether the reopening is worth watching for a trade at all.
        ///
        /// Volatility pauses reopen into continued momentum often enough to be
        /// a recognised setup. A T12 or H10 is a different animal — those
        /// reopen days later and usually far lower, and treating them as a
        /// "halt and go" is a good way to be trapped in something untradeable.
        var isTradeableResume: Bool {
            switch self {
            case .luld, .luldStraddle, .volatilityM, .t5, .t2, .t1: return true
            case .t12, .h4, .h10, .mwc1, .mwc2, .mwc3, .ipo, .other: return false
            }
        }

        var severity: Int {
            switch self {
            case .luld, .luldStraddle, .volatilityM, .t5: return 1
            case .t2, .ipo: return 2
            case .t1, .mwc1, .mwc2: return 3
            case .t12, .h4, .mwc3: return 4
            case .h10, .other: return 5
            }
        }
    }

    // MARK: - Events

    struct HaltEvent: Identifiable, Codable, Sendable, Hashable {
        var id: String { "\(symbol)-\(Int(haltedAt.timeIntervalSince1970))" }

        let symbol: String
        let name: String
        let code: HaltCode
        let haltedAt: Date
        var resumeQuoteAt: Date?
        var resumeTradeAt: Date?
        let marketCategory: String?

        /// Price direction in the minutes leading into the pause, filled in by
        /// the engine from its own bar history. Direction into the halt is the
        /// first thing to check before considering the reopen — a pause to the
        /// upside means it spiked, a pause to the downside means it collapsed.
        var priceIntoHalt: Double?
        var percentIntoHalt: Double?
        var wasClimbing: Bool? {
            guard let percentIntoHalt else { return nil }
            return percentIntoHalt > 0
        }

        var isResumed: Bool {
            guard let resumeTradeAt else { return false }
            return resumeTradeAt <= Date()
        }

        var minutesHalted: Int {
            let end = resumeTradeAt ?? Date()
            return max(0, Int(end.timeIntervalSince(haltedAt) / 60))
        }

        var minutesSinceResume: Int? {
            guard let resumeTradeAt, resumeTradeAt <= Date() else { return nil }
            return max(0, Int(Date().timeIntervalSince(resumeTradeAt) / 60))
        }

        /// A reopen worth looking at: tradeable code, direction known, and
        /// recent enough that the move hasn't already happened.
        var isFreshTradeableResume: Bool {
            guard code.isTradeableResume, let minutes = minutesSinceResume else { return false }
            return minutes <= 10
        }
    }

    // MARK: - State

    private(set) var events: [HaltEvent] = []
    private(set) var lastPolledAt: Date?
    private(set) var lastError: String?
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<HaltEvent>.Continuation?

    private let feedURL = URL(string: "https://www.nasdaqtrader.com/rss.aspx?feed=tradehalts")!
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - Lookups

    func isHalted(_ symbol: String) -> Bool {
        events.contains { $0.symbol == symbol && !$0.isResumed }
    }

    func activeHalt(for symbol: String) -> HaltEvent? {
        events.first { $0.symbol == symbol && !$0.isResumed }
    }

    func latestEvent(for symbol: String) -> HaltEvent? {
        events.filter { $0.symbol == symbol }.max { $0.haltedAt < $1.haltedAt }
    }

    var haltedSymbols: Set<String> {
        Set(events.filter { !$0.isResumed }.map(\.symbol))
    }

    var todaysEvents: [HaltEvent] {
        events.filter { MarketClock.isSameTradingDay($0.haltedAt, Date()) }
    }

    /// Recently reopened symbols where the resume is potentially tradeable.
    var freshResumes: [HaltEvent] {
        events.filter(\.isFreshTradeableResume).sorted { $0.resumeTradeAt ?? .distantPast > $1.resumeTradeAt ?? .distantPast }
    }

    /// Halt count today against a typical day, which is a decent read on how
    /// wild the session is overall.
    func haltIntensity(typicalPerDay: Int = 30) -> Double {
        guard let minute = MarketClock.minuteOfSession(), minute > 0 else { return 0 }
        let expectedByNow = Double(typicalPerDay) * (Double(minute) / 390.0)
        guard expectedByNow > 0.5 else { return 0 }
        return Double(todaysEvents.count) / expectedByNow
    }

    // MARK: - Polling

    /// Streams halt events. The feed updates continuously, so a 20-second poll
    /// is a reasonable compromise between latency and politeness.
    func start(interval: Duration = .seconds(20)) -> AsyncStream<HaltEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
            pollTask = Task {
                while !Task.isCancelled {
                    await poll()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    func poll() async {
        do {
            let (data, _) = try await session.data(from: feedURL)
            let parsed = HaltFeedParser.parse(data)
            lastPolledAt = Date()
            lastError = nil

            var known = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            for event in parsed {
                if var existing = known[event.id] {
                    // The feed republishes an item once resumption times are
                    // known, so update rather than duplicate.
                    if existing.resumeTradeAt == nil, event.resumeTradeAt != nil {
                        existing.resumeQuoteAt = event.resumeQuoteAt
                        existing.resumeTradeAt = event.resumeTradeAt
                        known[event.id] = existing
                        continuation?.yield(existing)
                    }
                } else {
                    known[event.id] = event
                    continuation?.yield(event)
                }
            }

            // Keep two days. Older halts are history, not context.
            let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
            events = known.values
                .filter { $0.haltedAt >= cutoff }
                .sorted { $0.haltedAt > $1.haltedAt }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Records what the price was doing going into the pause. Called by the
    /// engine, which has the bar history the feed lacks.
    func annotate(symbol: String, priceIntoHalt: Double, percentIntoHalt: Double) {
        guard let index = events.firstIndex(where: { $0.symbol == symbol && !$0.isResumed }) else { return }
        events[index].priceIntoHalt = priceIntoHalt
        events[index].percentIntoHalt = percentIntoHalt
    }
}

// MARK: - Feed parsing

/// Parses Nasdaq's halt RSS.
///
/// The feed carries its payload in a vendor namespace (`ndaq:`) rather than in
/// the RSS description, and element availability varies by halt type — a fresh
/// halt has no resumption fields at all. The parser therefore matches on the
/// local element name and tolerates anything missing.
enum HaltFeedParser {

    static func parse(_ data: Data) -> [HaltMonitor.HaltEvent] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.events
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var events: [HaltMonitor.HaltEvent] = []

        private var currentElement = ""
        private var buffer = ""
        private var fields: [String: String] = [:]
        private var insideItem = false

        private static let eastern = TimeZone(identifier: "America/New_York")!

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            currentElement = elementName
            buffer = ""
            if elementName.lowercased() == "item" {
                insideItem = true
                fields = [:]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.lowercased()

            if name == "item" {
                insideItem = false
                if let event = makeEvent() { events.append(event) }
                fields = [:]
                return
            }

            guard insideItem else { return }
            fields[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
        }

        private func value(_ keys: [String]) -> String? {
            for key in keys {
                if let found = fields[key], !found.isEmpty { return found }
            }
            return nil
        }

        private func makeEvent() -> HaltMonitor.HaltEvent? {
            guard let symbol = value(["issuesymbol", "symbol", "ndaq:issuesymbol"])?.uppercased(),
                  !symbol.isEmpty else { return nil }

            let name = value(["issuename", "ndaq:issuename"]) ?? symbol
            let code = HaltMonitor.HaltCode.parse(value(["reasoncode", "ndaq:reasoncode"]) ?? "OTHER")

            let haltDate = value(["haltdate", "ndaq:haltdate"])
            let haltTime = value(["halttime", "ndaq:halttime"])
            guard let haltedAt = combine(date: haltDate, time: haltTime) else { return nil }

            let resumeQuote = combine(
                date: value(["resumptiondate", "ndaq:resumptiondate"]),
                time: value(["resumptionquotetime", "ndaq:resumptionquotetime"])
            )
            let resumeTrade = combine(
                date: value(["resumptiondate", "ndaq:resumptiondate"]),
                time: value(["resumptiontradetime", "ndaq:resumptiontradetime"])
            )

            return HaltMonitor.HaltEvent(
                symbol: symbol,
                name: name,
                code: code,
                haltedAt: haltedAt,
                resumeQuoteAt: resumeQuote,
                resumeTradeAt: resumeTrade,
                marketCategory: value(["market", "marketcategory", "ndaq:market", "ndaq:marketcategory"])
            )
        }

        /// Halt dates arrive as `MM/dd/yyyy` and times as `HH:mm:ss.SSS` — with
        /// milliseconds. `DateFormatter` matches strictly by default: a format
        /// string without a fractional-seconds component fails outright on
        /// input that has one, rather than ignoring the extra digits. Without
        /// stripping them first, every single halt time would fail to parse,
        /// silently fall through to the date-only patterns below, and anchor
        /// to midnight — discarding the actual time of the halt.
        private func combine(date: String?, time: String?) -> Date? {
            guard let date, !date.isEmpty else { return nil }

            let formatter = DateFormatter()
            formatter.timeZone = Delegate.eastern
            formatter.locale = Locale(identifier: "en_US_POSIX")

            if let time, !time.isEmpty {
                let cleanedTime = time.split(separator: ".").first.map(String.init) ?? time
                for pattern in ["MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "yyyy-MM-dd HH:mm:ss"] {
                    formatter.dateFormat = pattern
                    if let parsed = formatter.date(from: "\(date) \(cleanedTime)") { return parsed }
                }
            }
            for pattern in ["MM/dd/yyyy", "yyyy-MM-dd"] {
                formatter.dateFormat = pattern
                if let parsed = formatter.date(from: date) { return parsed }
            }
            return nil
        }
    }
}

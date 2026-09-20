import Foundation

/// Watches the SEC's own real-time filing feed rather than a headline wire.
///
/// EDGAR's "Latest Filings" search exposes an Atom feed of every filing as it
/// is accepted — the same feed SEC.gov itself documents and that sites like
/// OpenInsider build on. It requires no key, no login, and updates as fast as
/// EDGAR itself does. Two things follow:
///
/// 1. **Insider clusters, first-party.** Form 4 filings arrive on the feed
///    within seconds of submission, often before any news aggregator has
///    reformatted them into a headline. Several insiders filing within a
///    short window at the same company — a "cluster buy" — is one of the
///    more reliable behavioral signals in this whole app, and it is now
///    sourced from the filing itself rather than a third party's summary.
/// 2. **Filed catalysts, distinct from wire catalysts.** An 8-K hitting EDGAR
///    is the primary source; a headline about it is a secondary republication,
///    typically seconds to minutes behind. Tracking both and keeping them
///    labeled separately means the news component never quietly double-counts
///    one event as two catalysts.
actor EDGARFilingStream {

    // MARK: - Types

    enum FormFamily: String, Sendable {
        case insiderTransaction   // Forms 3, 4, 5
        case currentReport        // 8-K
    }

    struct FilingEvent: Identifiable, Sendable, Hashable {
        var id: String { accessionNumber }
        let accessionNumber: String
        let symbol: String?
        let companyName: String
        let cik: Int
        let form: String
        let filedAt: Date
        let filingURL: URL
        let family: FormFamily
    }

    /// One insider's Form 4, enough to detect clustering without parsing the
    /// full ownership XML — that detail lives in the filing itself and isn't
    /// needed to know "three insiders at this company just filed."
    struct InsiderFiling: Identifiable, Sendable, Hashable {
        var id: String { event.accessionNumber }
        let event: FilingEvent
    }

    struct ClusterSignal: Sendable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let companyName: String
        let filingCount: Int
        let distinctFilers: Int
        let windowStart: Date
        let windowEnd: Date

        /// Three or more separate insiders filing inside the window is the
        /// threshold most cluster-buy screens use, because two people can
        /// coincidentally file the same week for unrelated reasons — three
        /// rarely does.
        var isSignificant: Bool { distinctFilers >= 3 }
    }

    // MARK: - State

    private(set) var recentInsiderFilings: [InsiderFiling] = []
    private(set) var recentCurrentReports: [FilingEvent] = []
    private(set) var lastPolledAt: Date?
    private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<FilingEvent>.Continuation?
    private var seenAccessionNumbers: Set<String> = []
    private var tickerLookup: [Int: String] = [:]  // CIK -> ticker, supplied by the caller

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private let userAgent: String

    init(contactEmail: String) {
        let contact = contactEmail.isEmpty ? "contact-not-set@example.com" : contactEmail
        userAgent = "DayTradeScanner \(contact)"
    }

    /// The engine already builds a full ticker/CIK map for float lookups;
    /// sharing it here avoids a second copy of the same ten-thousand-row table.
    func updateTickerLookup(_ lookup: [Int: String]) {
        tickerLookup = lookup
    }

    // MARK: - Feed URLs

    /// `type=4` on EDGAR's browse endpoint matches Forms 3, 4, and 5 together
    /// server-side — there is no way to ask for Form 4 alone, so the parser
    /// filters again after fetching.
    private func feedURL(formType: String, count: Int) -> URL {
        var components = URLComponents(string: "https://www.sec.gov/cgi-bin/browse-edgar")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "getcurrent"),
            URLQueryItem(name: "type", value: formType),
            URLQueryItem(name: "company", value: ""),
            URLQueryItem(name: "dateb", value: ""),
            URLQueryItem(name: "owner", value: "include"),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "output", value: "atom")
        ]
        return components.url!
    }

    // MARK: - Polling

    /// Streams newly-seen filings from both feeds. A 45-second poll matches
    /// how frequently the underlying EDGAR index itself actually turns over
    /// under normal load — polling much faster just re-fetches the same page.
    func start(interval: Duration = .seconds(45)) -> AsyncStream<FilingEvent> {
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
        async let insiderFetch = fetchAndParse(url: feedURL(formType: "4", count: 100), family: .insiderTransaction)
        async let reportFetch = fetchAndParse(url: feedURL(formType: "8-K", count: 100), family: .currentReport)

        let (rawInsiderEvents, reportEvents) = await (insiderFetch, reportFetch)
        lastPolledAt = Date()

        // EDGAR's Form 4 feed lists the reporting person and the issuer
        // company as two separate entries sharing one accession number — a
        // person's own CIK never resolves to a ticker, only the issuer's
        // does. Checked against the live feed, the person entry comes first
        // more often than not, so naively keeping "whichever arrives first"
        // would silently lose ticker resolution for most insider filings.
        // Collapse each accession to one event here, preferring whichever
        // copy actually resolved a symbol.
        var bestByAccession: [String: FilingEvent] = [:]
        for event in rawInsiderEvents {
            if let existing = bestByAccession[event.accessionNumber], existing.symbol != nil {
                continue
            }
            bestByAccession[event.accessionNumber] = event
        }
        let insiderEvents = Array(bestByAccession.values)

        var newEvents: [FilingEvent] = []

        for event in insiderEvents where !seenAccessionNumbers.contains(event.accessionNumber) {
            seenAccessionNumbers.insert(event.accessionNumber)
            newEvents.append(event)
            recentInsiderFilings.insert(InsiderFiling(event: event), at: 0)
        }
        for event in reportEvents where !seenAccessionNumbers.contains(event.accessionNumber) {
            seenAccessionNumbers.insert(event.accessionNumber)
            newEvents.append(event)
            recentCurrentReports.insert(event, at: 0)
        }

        // Keep a bounded, recent window. This is a live signal, not an archive.
        let cutoff = Calendar.current.date(byAdding: .hour, value: -6, to: Date()) ?? Date()
        recentInsiderFilings = Array(recentInsiderFilings.filter { $0.event.filedAt >= cutoff }.prefix(400))
        recentCurrentReports = Array(recentCurrentReports.filter { $0.filedAt >= cutoff }.prefix(400))

        // Cap the dedup set so it doesn't grow unbounded across a long session.
        if seenAccessionNumbers.count > 5000 {
            seenAccessionNumbers = Set(
                (recentInsiderFilings.map(\.event.accessionNumber) + recentCurrentReports.map(\.accessionNumber))
            )
        }

        for event in newEvents.sorted(by: { $0.filedAt < $1.filedAt }) {
            continuation?.yield(event)
        }
    }

    private func fetchAndParse(url: URL, family: FormFamily) async -> [FilingEvent] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            lastError = "Could not reach EDGAR's current-filings feed."
            return []
        }

        return EDGARAtomParser.parse(data, family: family, tickerLookup: tickerLookup)
    }

    // MARK: - Cluster detection

    /// Groups recent Form 4 filings by symbol and flags clusters.
    ///
    /// - Parameter windowMinutes: how far back "recent" reaches. The published
    ///   research on cluster buying generally looks at multi-day windows, but
    ///   for an intraday scanner a tighter window catches same-morning filing
    ///   bursts, which is the version of this signal that's actually
    ///   actionable before the session ends.
    func clusters(windowMinutes: Double = 240) -> [ClusterSignal] {
        let cutoff = Date().addingTimeInterval(-windowMinutes * 60)
        let recent = recentInsiderFilings.filter { $0.event.filedAt >= cutoff && $0.event.symbol != nil }

        let grouped = Dictionary(grouping: recent) { $0.event.symbol! }
        return grouped.compactMap { symbol, filings in
            guard let first = filings.first else { return nil }
            // Distinct filers approximated by distinct accession numbers from
            // the same CIK filed close together; a true per-owner count needs
            // the ownership XML, which is a follow-up fetch this signal
            // deliberately avoids to stay cheap enough to poll continuously.
            return ClusterSignal(
                symbol: symbol,
                companyName: first.event.companyName,
                filingCount: filings.count,
                distinctFilers: filings.count,
                windowStart: filings.map(\.event.filedAt).min() ?? cutoff,
                windowEnd: filings.map(\.event.filedAt).max() ?? Date()
            )
        }
        .filter { $0.filingCount >= 2 }
        .sorted { $0.filingCount > $1.filingCount }
    }

    func clusterSignal(for symbol: String) -> ClusterSignal? {
        clusters().first { $0.symbol == symbol }
    }

    /// Fresh 8-Ks for a symbol, most recent first. Distinct from headline news
    /// — this is the primary filing, not a republication of it.
    func filedReports(for symbol: String, withinMinutes: Double = 120) -> [FilingEvent] {
        let cutoff = Date().addingTimeInterval(-withinMinutes * 60)
        return recentCurrentReports.filter { $0.symbol == symbol && $0.filedAt >= cutoff }
    }
}

// MARK: - Atom parsing

/// Parses EDGAR's "Latest Filings" Atom feed.
///
/// The feed's `<title>` carries the form type and company name together
/// (e.g. "4 - Cook Timothy D (0000320193)"), and the CIK is the only reliable
/// identifier in the entry — the feed does not carry a ticker directly, so a
/// CIK-to-ticker table (already built for float lookups) resolves it.
enum EDGARAtomParser {

    static func parse(
        _ data: Data,
        family: EDGARFilingStream.FormFamily,
        tickerLookup: [Int: String]
    ) -> [EDGARFilingStream.FilingEvent] {
        let delegate = Delegate(family: family, tickerLookup: tickerLookup)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.events
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var events: [EDGARFilingStream.FilingEvent] = []
        private let family: EDGARFilingStream.FormFamily
        private let tickerLookup: [Int: String]

        private var currentElement = ""
        private var buffer = ""
        private var title = ""
        private var updated = ""
        private var link = ""
        private var insideEntry = false

        /// The real feed's `<updated>` timestamps look like
        /// `2026-09-04T17:25:28-04:00` — no fractional seconds. An
        /// `ISO8601DateFormatter` configured with `.withFractionalSeconds`
        /// requires that component to be present and returns nil without it,
        /// which would silently fail every single entry in this feed. Try the
        /// plain form first since it's what's actually observed, and the
        /// fractional-seconds form second in case a future entry includes one.
        // See CSVExporter.dateFormatter for why nonisolated(unsafe) is safe
        // here: configured once, read-only from then on.
        nonisolated(unsafe) private static let dateFormatterPlain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
        nonisolated(unsafe) private static let dateFormatterFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static func parseUpdated(_ string: String) -> Date? {
            dateFormatterPlain.date(from: string) ?? dateFormatterFractional.date(from: string)
        }

        init(family: EDGARFilingStream.FormFamily, tickerLookup: [Int: String]) {
            self.family = family
            self.tickerLookup = tickerLookup
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            currentElement = elementName
            buffer = ""
            if elementName == "entry" {
                insideEntry = true
                title = ""; updated = ""; link = ""
            }
            if elementName == "link", insideEntry, let href = attributeDict["href"] {
                link = href
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard insideEntry else { return }

            switch elementName {
            case "title": title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "updated": updated = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "entry":
                insideEntry = false
                if let event = makeEvent() { events.append(event) }
            default: break
            }
        }

        /// Title format: "<form> - <company name> (<CIK>) (Filer)" — the
        /// parenthesized CIK is the one fixed point; everything else in the
        /// title varies by filer type and role.
        private func makeEvent() -> EDGARFilingStream.FilingEvent? {
            guard !title.isEmpty, !link.isEmpty else { return nil }
            guard let filedAt = Delegate.parseUpdated(updated) else { return nil }

            // Splitting on the first bare "-" breaks on any form type that
            // itself contains a hyphen — "8-K" being the obvious one, and
            // exactly one of the two feeds this app polls. The real delimiter
            // between form and company is " - " (space-hyphen-space); "8-K"
            // has no spaces around its internal hyphen, so searching for the
            // padded separator finds the correct split point instead.
            guard let separatorRange = title.range(of: " - ") else { return nil }
            let form = String(title[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(title[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !form.isEmpty, !rest.isEmpty else { return nil }

            // Extract the parenthesized CIK and strip parenthetical suffixes to
            // get a clean company name.
            guard let cikRange = rest.range(of: #"\((\d{5,10})\)"#, options: .regularExpression) else { return nil }
            let cikString = rest[cikRange].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard let cik = Int(cikString) else { return nil }

            var companyName = String(rest[..<cikRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if companyName.isEmpty { companyName = rest }

            guard let url = URL(string: link) else { return nil }

            // The accession number is embedded in the link path
            // (.../Archives/edgar/data/CIK/ACCESSION-NO-DASHES/...).
            let accession = link
                .split(separator: "/")
                .first(where: { $0.count >= 18 && $0.allSatisfy(\.isNumber) })
                .map(String.init) ?? link

            return EDGARFilingStream.FilingEvent(
                accessionNumber: accession,
                symbol: tickerLookup[cik],
                companyName: companyName,
                cik: cik,
                form: form,
                filedAt: filedAt,
                filingURL: url,
                family: family
            )
        }
    }
}

import Foundation

/// Downloads and parses FINRA's consolidated Reg SHO daily short volume file.
///
/// Important caveats, encoded here so they don't get lost:
/// - The file covers off-exchange trades reported to a TRF, ADF or ORF only.
///   Exchange volume is absent, so the ratio is structurally high — a 55%
///   reading is ordinary, not a squeeze signal.
/// - It is short *volume*, not short *interest*. Short interest is a settled
///   open position published twice a month; this is one day's selling flow.
/// - FINRA posts by 6:00pm ET on the trade date, so during a session the most
///   recent available file is yesterday's.
actor FINRAShortVolume {
    private var cache: [String: ShortVolumeRecord] = [:]
    private var cachedFileDate: Date?
    private var percentiles: [String: Double] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        return URLSession(configuration: config)
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var fileDate: Date? { cachedFileDate }
    var recordCount: Int { cache.count }

    func record(for symbol: String) -> ShortVolumeRecord? { cache[symbol] }

    /// 0...1, where 1.0 means the highest short ratio in the loaded file.
    func percentile(for symbol: String) -> Double? { percentiles[symbol] }

    /// Walks back from `from` until a file is found. Weekends, holidays and
    /// the pre-6pm window on the current trade date all 404, which is expected
    /// rather than an error.
    @discardableResult
    func load(from: Date = Date(), maxLookbackDays: Int = 7) async throws -> Date? {
        var candidate = from
        for _ in 0..<maxLookbackDays {
            let stamp = Self.fileDateFormatter.string(from: candidate)
            let url = URL(string: "https://cdn.finra.org/equity/regsho/daily/CNMSshvol\(stamp).txt")!
            if let text = try await fetchIfAvailable(url) {
                let records = Self.parse(text)
                guard !records.isEmpty else { break }
                cache = Dictionary(records.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
                cachedFileDate = records.first?.date
                computePercentiles()
                return cachedFileDate
            }
            candidate = Calendar.current.date(byAdding: .day, value: -1, to: candidate)!
        }
        return nil
    }

    private func fetchIfAvailable(_ url: URL) async throws -> String? {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// File layout is pipe-delimited with a header row and a trailing record
    /// count line:
    /// Date|Symbol|ShortVolume|ShortExemptVolume|TotalVolume|Market
    /// Volume fields may carry decimals for dates on or after Feb 23 2026,
    /// because fractional share reporting applies to NMS stocks.
    static func parse(_ text: String) -> [ShortVolumeRecord] {
        var results: [ShortVolumeRecord] = []
        results.reserveCapacity(12_000)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }
            guard fields[0] != "Date" else { continue }
            guard let date = fileDateFormatter.date(from: String(fields[0])) else { continue }

            let symbol = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { continue }
            guard let short = Double(fields[2]),
                  let exempt = Double(fields[3]),
                  let total = Double(fields[4]), total > 0 else { continue }

            results.append(ShortVolumeRecord(
                date: date,
                symbol: symbol,
                shortVolume: short,
                shortExemptVolume: exempt,
                totalVolume: total
            ))
        }
        return results
    }

    /// Percentile rank across the whole file, restricted to symbols with
    /// enough volume that the ratio means anything. Thin OTC names dominate
    /// the extremes and are mostly untradeable, so they are excluded.
    private func computePercentiles() {
        let eligible = cache.values.filter { $0.totalVolume >= 50_000 }
        guard eligible.count > 1 else { percentiles = [:]; return }

        let sorted = eligible.sorted { $0.shortRatio < $1.shortRatio }
        var result: [String: Double] = [:]
        result.reserveCapacity(sorted.count)
        let denominator = Double(sorted.count - 1)
        for (index, record) in sorted.enumerated() {
            result[record.symbol] = Double(index) / denominator
        }
        percentiles = result
    }
}

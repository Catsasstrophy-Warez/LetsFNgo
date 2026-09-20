import Foundation

/// The reference curve a symbol's live volume gets compared against.
///
/// This is the piece that makes RVOL work on a partial feed. Both the live
/// numerator and this historical denominator come from IEX, so the exchange's
/// share of the symbol's volume cancels out of the ratio. The absolute volume
/// is wrong; the ratio is not.
struct VolumeBaseline: Codable, Sendable {
    let symbol: String
    let builtAt: Date
    let sessionsUsed: Int

    /// Median cumulative volume at each minute of the session, index 0 = 9:30.
    let cumulativeMedian: [Double]
    /// Median volume in each individual minute slot. Drives the per-bar surge signal.
    let barMedian: [Double]

    let priorClose: Double
    let atr14: Double
    /// Median full-session volume. Used as a liquidity pre-screen.
    let medianDailyVolume: Double

    func cumulative(at minute: Int) -> Double {
        guard !cumulativeMedian.isEmpty else { return 0 }
        let index = max(0, min(minute, cumulativeMedian.count - 1))
        let value = cumulativeMedian[index]
        // Very early in the session the median can be zero for thin names.
        // Fall back to the first non-zero entry so RVOL doesn't divide by zero.
        if value > 0 { return value }
        return cumulativeMedian.first(where: { $0 > 0 }) ?? 0
    }

    func barVolume(at minute: Int) -> Double {
        guard !barMedian.isEmpty else { return 0 }
        let index = max(0, min(minute, barMedian.count - 1))
        return barMedian[index]
    }

    var isUsable: Bool {
        sessionsUsed >= 5 && medianDailyVolume > 0 && priorClose > 0
    }
}

/// Builds, caches and persists baselines.
///
/// Building is the slow part of startup — it pulls N sessions of minute bars
/// for every symbol in the universe. It runs once per trading day, in batches,
/// and the result is written to disk so a relaunch is instant.
actor BaselineStore {
    private var baselines: [String: VolumeBaseline] = [:]
    private let rest: AlpacaREST
    private let fileURL: URL

    private(set) var isBuilding = false
    private(set) var buildProgress: Double = 0

    init(rest: AlpacaREST) {
        self.rest = rest
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("baselines.json")
        loadFromDisk()
    }

    func baseline(for symbol: String) -> VolumeBaseline? { baselines[symbol] }
    func allSymbols() -> [String] { Array(baselines.keys) }
    var count: Int { baselines.count }

    func coverage(for universe: [String]) -> Double {
        guard !universe.isEmpty else { return 0 }
        let have = universe.filter { baselines[$0]?.isUsable == true }.count
        return Double(have) / Double(universe.count)
    }

    /// True if every symbol has a baseline built today. Baselines older than
    /// a day are stale — yesterday's session is now part of the history.
    func isFresh(for universe: [String]) -> Bool {
        let today = Date()
        return universe.allSatisfy { symbol in
            guard let baseline = baselines[symbol] else { return false }
            return MarketClock.isSameTradingDay(baseline.builtAt, today)
        }
    }

    // MARK: - Building

    /// Rebuilds baselines for the given universe.
    /// - Parameter progress: called on the main actor with 0...1 so the UI
    ///   can show something honest during a slow cold start.
    func build(
        universe: [String],
        sessions: Int,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard !isBuilding else { return }
        isBuilding = true
        buildProgress = 0
        defer { isBuilding = false }

        // Pull daily bars first — cheap, one call, gives prior close, ATR and
        // a liquidity screen that lets us skip minute-bar work on dead names.
        let dailyByCynbol = try await rest.dailyBars(symbols: universe, lookbackDays: sessions + 20)

        // Minute bars are the expensive part. Alpaca accepts multiple symbols
        // per request, but the response is paginated by total bar count, so
        // small batches keep each request bounded.
        let batchSize = 8
        let batches = stride(from: 0, to: universe.count, by: batchSize).map {
            Array(universe[$0..<min($0 + batchSize, universe.count)])
        }

        let end = Date()
        // Calendar days, generously padded so weekends and holidays still
        // leave us `sessions` real trading days.
        let start = Calendar.current.date(byAdding: .day, value: -Int(Double(sessions) * 1.6) - 5, to: end)!

        var completed = 0
        for batch in batches {
            do {
                let minuteBySymbol = try await rest.minuteBars(symbols: batch, start: start, end: end)
                for symbol in batch {
                    guard let minutes = minuteBySymbol[symbol],
                          let dailies = dailyByCynbol[symbol], dailies.count >= 2 else { continue }
                    if let baseline = Self.buildBaseline(
                        symbol: symbol,
                        minuteBars: minutes,
                        dailyBars: dailies,
                        sessionLimit: sessions
                    ) {
                        baselines[symbol] = baseline
                    }
                }
            } catch {
                // One failed batch shouldn't abort the whole build. The symbols
                // in it simply won't have baselines and will be gated out.
                continue
            }
            completed += batch.count
            buildProgress = Double(completed) / Double(max(universe.count, 1))
            let snapshot = buildProgress
            progress(snapshot)
            // Stay well under the 200 req/min free-tier ceiling.
            try? await Task.sleep(for: .milliseconds(350))
        }

        saveToDisk()
        progress(1.0)
    }

    // MARK: - Baseline math

    nonisolated static func buildBaseline(
        symbol: String,
        minuteBars: [MinuteBar],
        dailyBars: [DailyBar],
        sessionLimit: Int
    ) -> VolumeBaseline? {
        // Group minute bars by trading day, keeping only regular-hours bars.
        // Pre-market volume is far too erratic to belong in a median curve.
        var byDay: [Date: [Int: Double]] = [:]   // day -> minuteOfSession -> volume

        for bar in minuteBars {
            guard MarketClock.phase(at: bar.timestamp) == .regular,
                  let minute = MarketClock.minuteOfSession(bar.timestamp),
                  minute >= 0 else { continue }
            let day = MarketClock.calendar.startOfDay(for: bar.timestamp)
            byDay[day, default: [:]][minute, default: 0] += bar.volume
        }

        let days = byDay.keys.sorted(by: >).prefix(sessionLimit)
        guard days.count >= 5 else { return nil }

        let minuteCount = MarketClock.regularSessionMinutes

        // For each minute slot, collect that slot's value across all days,
        // then take the median. Median rather than mean because one earnings
        // day with 20× volume would otherwise poison the whole curve.
        var cumulativeSamples = Array(repeating: [Double](), count: minuteCount)
        var barSamples = Array(repeating: [Double](), count: minuteCount)

        for day in days {
            guard let slots = byDay[day] else { continue }
            var running = 0.0
            for minute in 0..<minuteCount {
                let volume = slots[minute] ?? 0
                running += volume
                cumulativeSamples[minute].append(running)
                barSamples[minute].append(volume)
            }
        }

        let cumulativeMedian = cumulativeSamples.map { median($0) }
        let barMedian = barSamples.map { median($0) }

        let sortedDailies = dailyBars.sorted { $0.timestamp < $1.timestamp }
        guard let priorClose = sortedDailies.last?.close else { return nil }
        let atr = averageTrueRange(sortedDailies, period: 14)
        let medianDaily = median(sortedDailies.suffix(sessionLimit).map(\.volume))

        return VolumeBaseline(
            symbol: symbol,
            builtAt: Date(),
            sessionsUsed: days.count,
            cumulativeMedian: cumulativeMedian,
            barMedian: barMedian,
            priorClose: priorClose,
            atr14: atr,
            medianDailyVolume: medianDaily
        )
    }

    nonisolated static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }

    /// Wilder's ATR. Used to normalize VWAP distance so a $4 stock and a
    /// $400 stock are on the same scale.
    nonisolated static func averageTrueRange(_ bars: [DailyBar], period: Int) -> Double {
        guard bars.count > period else { return 0 }
        var trueRanges: [Double] = []
        for index in 1..<bars.count {
            let current = bars[index]
            let previousClose = bars[index - 1].close
            let range = max(
                current.high - current.low,
                max(abs(current.high - previousClose), abs(current.low - previousClose))
            )
            trueRanges.append(range)
        }
        guard trueRanges.count >= period else { return 0 }
        var atr = trueRanges.prefix(period).reduce(0, +) / Double(period)
        for range in trueRanges.dropFirst(period) {
            atr = ((atr * Double(period - 1)) + range) / Double(period)
        }
        return atr
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: VolumeBaseline].self, from: data) else { return }
        baselines = decoded
    }

    func clear() {
        baselines = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }
}

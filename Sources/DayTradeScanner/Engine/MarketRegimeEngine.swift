import Foundation
import Observation

/// A market-regime banner: is the tape actually helping right now? Every
/// scanner in this app ranks symbols *within* the current tape — none of
/// them tell you whether the tape itself is worth trading. This engine
/// answers that separately, from the same free daily-bar endpoint every
/// other engine already uses, so it costs one more small REST call rather
/// than a new data source.
@MainActor
@Observable
final class MarketRegimeEngine {
    struct Reading: Identifiable, Sendable {
        let symbol: String
        let displayName: String
        let last: Double
        let changePercent: Double
        let vsSMA20Percent: Double?
        let vsSMA50Percent: Double?

        var id: String { symbol }

        var isRisingTrend: Bool {
            guard let vsSMA20Percent, let vsSMA50Percent else { return changePercent >= 0 }
            return vsSMA20Percent >= 0 && vsSMA50Percent >= 0
        }
    }

    private(set) var indexReading: Reading?
    private(set) var sectorReadings: [Reading] = []
    private(set) var lastRefreshedAt: Date?
    private(set) var isRefreshing = false

    private let rest: AlpacaREST
    private var refreshTask: Task<Void, Never>?

    /// SPDR sector ETFs — the standard free, keyless proxy for sector
    /// breadth. No sector-level data license required, just eleven more
    /// tickers through the same daily-bars endpoint.
    private static let sectorSymbols: [(symbol: String, name: String)] = [
        ("XLK", "Technology"), ("XLF", "Financials"), ("XLE", "Energy"),
        ("XLV", "Health Care"), ("XLY", "Cons. Discretionary"), ("XLP", "Cons. Staples"),
        ("XLI", "Industrials"), ("XLB", "Materials"), ("XLU", "Utilities"),
        ("XLRE", "Real Estate"), ("XLC", "Communication")
    ]

    init(rest: AlpacaREST) {
        self.rest = rest
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var symbols = ["SPY"]
        symbols.append(contentsOf: Self.sectorSymbols.map(\.symbol))

        guard let bars = try? await rest.dailyBars(symbols: symbols, lookbackDays: 90) else { return }

        if let spyBars = bars["SPY"] {
            indexReading = Self.makeReading(symbol: "SPY", displayName: "S&P 500", bars: spyBars)
        }

        sectorReadings = Self.sectorSymbols.compactMap { entry in
            guard let sectorBars = bars[entry.symbol] else { return nil }
            return Self.makeReading(symbol: entry.symbol, displayName: entry.name, bars: sectorBars)
        }.sorted { $0.changePercent > $1.changePercent }

        lastRefreshedAt = Date()
    }

    private static func makeReading(symbol: String, displayName: String, bars: [DailyBar]) -> Reading? {
        guard let latest = bars.last, latest.close > 0 else { return nil }
        let previous = bars.dropLast().last
        let changePercent = previous.map { (latest.close / $0.close) - 1.0 } ?? 0

        func sma(_ count: Int) -> Double? {
            guard bars.count >= count else { return nil }
            let window = bars.suffix(count)
            return window.map(\.close).reduce(0, +) / Double(count)
        }

        let vs20 = sma(20).map { (latest.close / $0) - 1.0 }
        let vs50 = sma(50).map { (latest.close / $0) - 1.0 }

        return Reading(symbol: symbol, displayName: displayName, last: latest.close, changePercent: changePercent, vsSMA20Percent: vs20, vsSMA50Percent: vs50)
    }
}

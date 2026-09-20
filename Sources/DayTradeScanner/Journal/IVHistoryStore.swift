import Foundation
import SwiftData
import Observation

/// One day's at-the-money implied volatility reading for an underlying.
///
/// IV Rank and IV Percentile are both defined relative to a trailing
/// history of the metric itself — there's no way to compute either from a
/// single chain snapshot. Since free data sources don't publish historical
/// IV, this app has to start building its own the day it's installed: one
/// row per underlying per trading day, recorded from whatever chain refresh
/// happens to run that day.
@Model
final class IVHistoryPoint {
    var symbol: String
    var date: Date
    var atmIV: Double

    init(symbol: String, date: Date, atmIV: Double) {
        self.symbol = symbol
        self.date = date
        self.atmIV = atmIV
    }
}

struct IVRankReading: Sendable {
    /// 0...1 position of today's IV between the trailing min and max.
    let rank: Double
    /// 0...1 fraction of trailing days at or below today's IV.
    let percentile: Double
    let sampleCount: Int
}

@MainActor
@Observable
final class IVHistoryStore {
    private var context: ModelContext?
    private(set) var readings: [String: IVRankReading] = [:]

    /// A year of trading days is the standard IV Rank/Percentile window
    /// used by most retail options platforms.
    private let lookbackDays = 365

    func attach(context: ModelContext) {
        self.context = context
    }

    /// Records at most one point per symbol per calendar day — repeated
    /// intraday refreshes shouldn't inflate the sample toward "whatever IV
    /// happened to be at each refresh today."
    func record(symbol: String, atmIV: Double, on date: Date = Date()) {
        guard let context, atmIV > 0, atmIV.isFinite else { return }
        let day = Calendar.current.startOfDay(for: date)

        var descriptor = FetchDescriptor<IVHistoryPoint>(
            predicate: #Predicate { $0.symbol == symbol && $0.date == day }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor), let point = existing.first {
            point.atmIV = atmIV
        } else {
            context.insert(IVHistoryPoint(symbol: symbol, date: day, atmIV: atmIV))
        }
        try? context.save()
        recompute(for: symbol)
    }

    private func recompute(for symbol: String) {
        guard let context else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? .distantPast
        let descriptor = FetchDescriptor<IVHistoryPoint>(
            predicate: #Predicate { $0.symbol == symbol && $0.date >= cutoff }
        )
        guard let points = try? context.fetch(descriptor), let latest = points.max(by: { $0.date < $1.date }) else { return }

        let values = points.map(\.atmIV)
        guard let low = values.min(), let high = values.max(), high > low else {
            readings[symbol] = IVRankReading(rank: 0.5, percentile: 0.5, sampleCount: values.count)
            return
        }
        let rank = (latest.atmIV - low) / (high - low)
        let below = values.filter { $0 <= latest.atmIV }.count
        let percentile = Double(below) / Double(values.count)
        readings[symbol] = IVRankReading(rank: rank.clamped(to: 0...1), percentile: percentile.clamped(to: 0...1), sampleCount: values.count)
    }

    func reading(for symbol: String) -> IVRankReading? { readings[symbol] }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

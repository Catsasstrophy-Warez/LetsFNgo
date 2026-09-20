import Foundation

/// Fundamentals for one company, pulled from SEC EDGAR's CompanyFacts API.
///
/// Everything here is quarterly at best and some of it is annual, which is
/// the entire point of a separate horizon: a long-term thesis is not supposed
/// to change because of what happened in the market today. The engine that
/// builds this refreshes every few hours at most, and would lose nothing by
/// refreshing once a day.
struct FundamentalSnapshot: Codable, Hashable, Sendable {
    let symbol: String
    let entityName: String
    let asOf: Date

    let lastPrice: Double
    let sharesOutstanding: Double?
    var marketCap: Double? {
        guard let sharesOutstanding else { return nil }
        return sharesOutstanding * lastPrice
    }

    // Revenue, trailing four reported quarters where available.
    let revenueTTM: Double?
    let revenueTTMYearAgo: Double?
    var revenueGrowthYoY: Double? {
        guard let revenueTTM, let revenueTTMYearAgo, revenueTTMYearAgo > 0 else { return nil }
        return (revenueTTM / revenueTTMYearAgo) - 1.0
    }

    // Profitability
    let netIncomeTTM: Double?
    var netMarginTTM: Double? {
        guard let netIncomeTTM, let revenueTTM, revenueTTM > 0 else { return nil }
        return netIncomeTTM / revenueTTM
    }
    /// Net margin now versus four quarters ago — expanding margins are a
    /// different, generally healthier story than growth funded by shrinking
    /// them.
    let netMarginYearAgo: Double?
    var marginTrend: Double? {
        guard let netMarginTTM, let netMarginYearAgo else { return nil }
        return netMarginTTM - netMarginYearAgo
    }

    // Valuation. Price-to-sales rather than P/E, because P/E is undefined or
    /// meaningless for any company without positive trailing earnings, and
    /// this list should not silently drop every growth company that fits.
    var priceToSales: Double? {
        guard let marketCap, let revenueTTM, revenueTTM > 0 else { return nil }
        return marketCap / revenueTTM
    }

    // Balance sheet
    let totalAssets: Double?
    let totalLiabilities: Double?
    /// Liabilities as a share of assets. High leverage isn't disqualifying on
    /// its own — plenty of good businesses run leveraged — but it changes how
    /// much margin for error the thesis has.
    var leverageRatio: Double? {
        guard let totalAssets, totalAssets > 0, let totalLiabilities else { return nil }
        return totalLiabilities / totalAssets
    }

    // Price trend, from daily bars, over a genuinely long-term window.
    let priceVsSMA200Percent: Double?
    let distanceFrom52WeekHighPercent: Double?

    // Float and insider context
    let floatShares: Double?
    let floatCategory: SECFloatClient.FloatCategory?
    let insiderFilingsRecent: Int
    let insiderFilingWindowDays: Int
    /// SIC-code industry description from SEC EDGAR, riding along free in
    /// the same submissions fetch used for insider filing frequency.
    let sector: String?

    var hasEnoughDataToScore: Bool {
        revenueTTM != nil || netIncomeTTM != nil
    }
}

enum LongTermComponent: String, Codable, CaseIterable, Identifiable, Sendable {
    case revenueGrowth
    case profitability
    case marginTrend
    case valuation          // negative when expensive
    case priceTrend
    case insiderConviction
    case leverageRisk       // negative
    case floatRisk          // negative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .revenueGrowth: return "Revenue growth"
        case .profitability: return "Profitability"
        case .marginTrend: return "Margin trend"
        case .valuation: return "Valuation"
        case .priceTrend: return "Long-term price trend"
        case .insiderConviction: return "Insider filing activity"
        case .leverageRisk: return "Leverage"
        case .floatRisk: return "Float risk"
        }
    }

    var explanation: String {
        switch self {
        case .revenueGrowth:
            return "Trailing-twelve-month revenue against the same period a year ago, from SEC XBRL filings — the company's own reported numbers, not a third party's restatement of them."
        case .profitability:
            return "Trailing net margin. Rewards businesses that convert revenue into profit, without disqualifying a richly-valued unprofitable one outright — that's what valuation is for."
        case .marginTrend:
            return "Net margin now versus a year ago. Expanding margins alongside growth is a healthier story than growth bought with shrinking ones."
        case .valuation:
            return "Price-to-sales rather than P/E, because P/E is undefined for any company without positive trailing earnings. Scores negative at rich multiples — this is the one component that can meaningfully subtract from an otherwise strong profile."
        case .priceTrend:
            return "Price against its 200-day average and distance from the 52-week high. A long-term measure of trend, not a timing signal."
        case .insiderConviction:
            return "Form 4 filing frequency at this company over the last 90 days, from SEC EDGAR. A count of filings, not a signed buy/sell signal."
        case .leverageRisk:
            return "Total liabilities as a share of total assets. Negative — a highly leveraged balance sheet has less room for the thesis to be wrong."
        case .floatRisk:
            return "The day-trade engine treats a tight float as opportunity; here it's a hazard. A long hold through a tight float's larger swings is more exposure to volatility that has nothing to do with the business."
        }
    }

    var defaultWeight: Double {
        switch self {
        case .revenueGrowth: return 0.24
        case .profitability: return 0.18
        case .marginTrend: return 0.12
        case .valuation: return 0.16
        case .priceTrend: return 0.14
        case .insiderConviction: return 0.06
        case .leverageRisk: return 0.06
        case .floatRisk: return 0.04
        }
    }
}

struct LongTermScoreBreakdown: Codable, Hashable, Sendable {
    var normalized: [LongTermComponent: Double] = [:]
    var contributions: [LongTermComponent: Double] = [:]
    var total: Double = 0

    var sortedContributions: [(LongTermComponent, Double)] {
        contributions.sorted { $0.value > $1.value }
    }

    func topDrivers(limit: Int = 3, floor: Double = 0.02) -> [LongTermComponent] {
        sortedContributions.filter { $0.1 >= floor }.prefix(limit).map(\.0)
    }
}

struct LongTermCandidate: Identifiable, Hashable, Sendable {
    var id: String { snapshot.symbol }
    let snapshot: FundamentalSnapshot
    let breakdown: LongTermScoreBreakdown

    var symbol: String { snapshot.symbol }
    var score: Double { breakdown.total }

    var plainReason: String {
        var parts: [String] = []
        for component in breakdown.topDrivers() {
            switch component {
            case .revenueGrowth:
                if let growth = snapshot.revenueGrowthYoY {
                    parts.append(String(format: "revenue %+.0f%% YoY", growth * 100))
                }
            case .profitability:
                if let margin = snapshot.netMarginTTM {
                    parts.append(String(format: "%.0f%% net margin", margin * 100))
                }
            case .marginTrend:
                if let trend = snapshot.marginTrend, trend > 0 {
                    parts.append(String(format: "margins expanding %+.1fpp", trend * 100))
                }
            case .valuation:
                if let ps = snapshot.priceToSales {
                    parts.append(String(format: "%.1f× sales", ps))
                }
            case .priceTrend:
                if let vsSMA = snapshot.priceVsSMA200Percent, vsSMA > 0 {
                    parts.append(String(format: "%+.0f%% above 200-day average", vsSMA * 100))
                }
            case .insiderConviction:
                if snapshot.insiderFilingsRecent > 0 {
                    parts.append("\(snapshot.insiderFilingsRecent) insider filings, \(snapshot.insiderFilingWindowDays)d")
                }
            case .leverageRisk, .floatRisk:
                break
            }
        }
        return parts.isEmpty ? "Limited fundamental data available" : parts.joined(separator: ", ")
    }

    var hazardNote: String? {
        var warnings: [String] = []
        if let leverage = snapshot.leverageRatio, leverage > 0.8 {
            warnings.append(String(format: "%.0f%% liabilities/assets", leverage * 100))
        }
        if snapshot.floatCategory?.carriesElevatedRisk == true {
            warnings.append("tight float")
        }
        if !snapshot.hasEnoughDataToScore {
            warnings.append("thin filing history")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }
}

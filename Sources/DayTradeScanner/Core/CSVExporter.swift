import Foundation

/// Plain CSV generation for the paper-trading journal and portfolio — the
/// practical "get my data out" gap every record-keeping feature in this app
/// otherwise lacks. No third-party library: a CSV this shape (flat rows, no
/// embedded newlines in any field) doesn't need one.
enum CSVExporter {
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    // ISO8601DateFormatter predates Sendable and isn't marked as conforming,
    // but it's only ever read from after being configured once here —
    // `nonisolated(unsafe)` is the standard, safe escape hatch for exactly
    // this shape of "effectively immutable after init" Foundation type.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func format(_ date: Date?) -> String {
        date.map(dateFormatter.string(from:)) ?? ""
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? ""
    }

    // MARK: - Equity journal

    static func export(_ trades: [PaperTrade]) -> String {
        var lines = [row([
            "symbol", "horizon", "direction", "status", "setup", "recipe",
            "opened_at", "closed_at", "entry_price", "score",
            "return_15m", "return_30m", "return_60m", "return_close", "best_available_return",
            "max_favorable", "max_adverse", "reason"
        ])]

        for trade in trades {
            lines.append(row([
                trade.symbol,
                trade.horizon.displayName,
                trade.direction.label,
                trade.status.rawValue,
                trade.setup.displayName,
                trade.recipeName ?? "",
                format(trade.openedAt),
                format(trade.closedAt),
                format(trade.entryPrice),
                format(trade.score),
                format(trade.return15m),
                format(trade.return30m),
                format(trade.return60m),
                format(trade.closeReturn),
                format(trade.bestAvailableReturn),
                format(trade.maxFavorable),
                format(trade.maxAdverse),
                trade.reason
            ]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Options journal

    static func export(_ trades: [OptionsPaperTrade]) -> String {
        var lines = [row([
            "underlying", "strategy", "status", "legs",
            "opened_at", "closed_at", "underlying_spot_at_open",
            "net_premium_at_open", "current_value", "closed_value",
            "profit_and_loss", "profit_and_loss_percent"
        ])]

        for trade in trades {
            lines.append(row([
                trade.underlying,
                trade.strategyName,
                trade.status.rawValue,
                "\(trade.legCount)",
                format(trade.openedAt),
                format(trade.closedAt),
                format(trade.underlyingSpotAtOpen),
                format(trade.netPremiumAtOpen),
                format(trade.currentValue),
                format(trade.closedValue),
                format(trade.profitAndLoss),
                format(trade.profitAndLossPercent)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - File writing

    /// Writes CSV text to a temp file so `ShareLink` has a real filename and
    /// a "CSV document" preview, the same pattern already used for recipe
    /// JSON export.
    static func writeTempFile(_ csv: String, named name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

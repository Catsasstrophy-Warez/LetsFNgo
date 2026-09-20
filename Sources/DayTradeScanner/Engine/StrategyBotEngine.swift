import Foundation
import Observation
import UserNotifications

/// A "strategy bot," in the sense tastytrade and similar platforms use the
/// term: not a signal generator, but something that watches positions you
/// already hold through their lifecycle and tells you when a mechanical
/// rule fires — profit target, defensive DTE, expiration risk, stop loss —
/// so managing ten open option positions doesn't mean checking all ten by
/// hand every day.
///
/// Runs against `OptionsPaperTradeLog`'s open trades after every mark, and
/// is persistent in the sense that matters here: it remembers which alerts
/// already fired for which trade (by id + alert kind) so a position sitting
/// at 55% profit for three days gets exactly one "profit target" alert, not
/// one on every refresh.
@MainActor
@Observable
final class StrategyBotEngine {
    enum AlertKind: String, Sendable {
        case profitTarget = "profit-target"
        case defensiveDTE = "defensive-dte"
        case expirationDay = "expiration-day"
        case stopLoss = "stop-loss"

        var title: String {
            switch self {
            case .profitTarget: return "Profit target hit"
            case .defensiveDTE: return "21 DTE reached"
            case .expirationDay: return "Expires today"
            case .stopLoss: return "Stop loss hit"
            }
        }
    }

    struct LifecycleAlert: Identifiable, Sendable {
        let id = UUID()
        let tradeID: UUID
        let underlying: String
        let kind: AlertKind
        let detail: String
        let firedAt: Date
    }

    private(set) var recentAlerts: [LifecycleAlert] = []

    /// Take profit once 50% of a debit strategy's max theoretical gain (or,
    /// lacking that, 50% of premium paid) is captured — the most common
    /// mechanical profit-taking rule for defined-risk options positions.
    var profitTargetPercent: Double = 0.50
    /// Cut losses at 100% of premium paid on a debit strategy — the position
    /// has doubled against you.
    var stopLossPercent: Double = -1.00
    /// The classic tastytrade defensive-management checkpoint: inside 21
    /// days to expiration, gamma risk accelerates sharply.
    var defensiveDTEThreshold: Int = 21

    private var firedAlertKeys: Set<String> = []
    private let paperLog: OptionsPaperTradeLog
    private let squawk: AudioSquawk?

    private var settings: Settings { Settings.shared }

    init(paperLog: OptionsPaperTradeLog, squawk: AudioSquawk? = nil) {
        self.paperLog = paperLog
        self.squawk = squawk
    }

    /// Re-evaluates every open position. Cheap enough to call after every
    /// `OptionsEngine` refresh — it's just arithmetic over already-fetched
    /// data, no new network calls.
    func evaluate() async {
        for trade in paperLog.trades where trade.status == .open {
            await check(trade)
        }
    }

    private func check(_ trade: OptionsPaperTrade) async {
        guard let pnl = trade.profitAndLoss else { return }

        if trade.netPremiumAtOpen > 0 {
            let percent = pnl / trade.netPremiumAtOpen
            if percent >= profitTargetPercent {
                await fire(.profitTarget, trade: trade, detail: "\(Fmt.percent(percent)) of premium paid captured.")
            }
            if percent <= stopLossPercent {
                await fire(.stopLoss, trade: trade, detail: "\(Fmt.percent(percent)) against premium paid.")
            }
        }

        guard let nearestExpiration = trade.legs.map(\.expiration).min() else { return }
        let daysToExpiration = max(0, Calendar.current.dateComponents([.day], from: Date(), to: nearestExpiration).day ?? 0)

        if daysToExpiration == 0 {
            await fire(.expirationDay, trade: trade, detail: "\(trade.underlying) nearest leg expires today.")
        } else if daysToExpiration <= defensiveDTEThreshold {
            await fire(.defensiveDTE, trade: trade, detail: "\(daysToExpiration) days to nearest expiration.")
        }
    }

    private func fire(_ kind: AlertKind, trade: OptionsPaperTrade, detail: String) async {
        let key = "\(trade.id.uuidString)-\(kind.rawValue)"
        guard !firedAlertKeys.contains(key) else { return }
        firedAlertKeys.insert(key)

        let alert = LifecycleAlert(tradeID: trade.id, underlying: trade.underlying, kind: kind, detail: detail, firedAt: Date())
        recentAlerts.insert(alert, at: 0)
        if recentAlerts.count > 100 { recentAlerts.removeLast() }

        if settings.notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "\(trade.underlying) — \(kind.title)"
            content.body = detail
            content.sound = .default
            content.interruptionLevel = .active
            content.userInfo = ["underlying": trade.underlying, "optionsTradeID": trade.id.uuidString]
            let request = UNNotificationRequest(identifier: "strategybot-\(key)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }

        if settings.audioSquawkEnabled, settings.squawkStrategyBot {
            squawk?.speak("\(trade.underlying) strategy bot: \(kind.title.lowercased()).", dedupeKey: "strategybot-\(key)")
        }
    }

    /// Clears memory of already-fired alerts for a trade — called when a
    /// trade closes and a new one might reuse the same underlying, so a
    /// fresh position isn't silently suppressed by an old trade's key.
    func forget(tradeID: UUID) {
        firedAlertKeys = firedAlertKeys.filter { !$0.hasPrefix(tradeID.uuidString) }
    }
}

import ActivityKit
import Observation

/// Keeps a Live Activity running on the Lock Screen / Dynamic Island for
/// every open options paper position, mirrored against `OptionsPaperTradeLog`'s
/// own trade list. Options positions specifically, not equity ones: options
/// marks update live on every chain refresh (`OptionsPaperTradeLog.markToMarket`),
/// where an equity paper trade only has a few fixed checkpoint marks — a
/// Live Activity showing a number that barely ever changes isn't worth the
/// system resource it costs to keep running.
@MainActor
@Observable
final class PositionActivityManager {
    private var activities: [UUID: Activity<PositionActivityAttributes>] = [:]

    /// Called after every `OptionsEngine` refresh, right after
    /// `OptionsPaperTradeLog.markToMarket` — cheap to call this often since
    /// it only starts/ends activities when the open-trade set actually
    /// changed, and only updates content state when something in it did.
    func sync(with trades: [OptionsPaperTrade]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let openTrades = trades.filter { $0.status == .open }
        let openIDs = Set(openTrades.map(\.id))

        // End activities for anything no longer open (closed, or deleted
        // from the journal).
        for (id, activity) in activities where !openIDs.contains(id) {
            await activity.end(nil, dismissalPolicy: .immediate)
            activities.removeValue(forKey: id)
        }

        for trade in openTrades {
            let state = PositionActivityAttributes.ContentState(
                profitAndLoss: trade.profitAndLoss ?? 0,
                profitAndLossPercent: trade.profitAndLossPercent,
                updatedAt: Date()
            )

            if let existing = activities[trade.id] {
                await existing.update(ActivityContent(state: state, staleDate: nil))
            } else {
                let attributes = PositionActivityAttributes(
                    underlying: trade.underlying,
                    strategyName: trade.strategyName,
                    legCount: trade.legCount,
                    netPremiumAtOpen: trade.netPremiumAtOpen
                )
                activities[trade.id] = try? Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil)
                )
            }
        }
    }

    /// Ends every tracked activity immediately — called when the options
    /// engine stops, so a background/backgrounded app doesn't leave stale
    /// Live Activities running past the point they can be kept fresh.
    func endAll() async {
        for activity in activities.values {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activities.removeAll()
    }
}

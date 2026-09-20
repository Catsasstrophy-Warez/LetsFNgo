import ActivityKit
import Foundation

/// Live Activity attributes for an open options paper position — compiled
/// into both the main app (which starts/updates/ends the activity) and the
/// widget extension (which renders it on the Lock Screen and in the Dynamic
/// Island), the same shared-source-file pattern `WidgetSharedStore.swift`
/// already uses. `ActivityAttributes`/`ContentState` must be `Codable` and
/// kept small — this crosses a system IPC boundary on every update.
struct PositionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var profitAndLoss: Double
        var profitAndLossPercent: Double?
        var updatedAt: Date
    }

    let underlying: String
    let strategyName: String
    let legCount: Int
    let netPremiumAtOpen: Double
}

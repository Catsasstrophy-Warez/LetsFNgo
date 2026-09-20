import Foundation

/// The data bridge between the main app and the home-screen widget
/// extension — two separate processes that can't share in-memory state, so
/// the app periodically writes a small snapshot to an App Group container
/// and the widget reads it back. This file is compiled into both targets
/// (see project.yml's DayTradeScannerWidget target `sources`), so it must
/// stay free of any import the widget extension target doesn't also link
/// (Foundation only).
/// The widget's kind identifier — shared so the main app can ask specifically
/// for this widget's timelines to reload rather than every widget kind the
/// app might ever ship.
let TopCandidateWidgetKind = "TopCandidateWidget"

enum WidgetSharedStore {
    /// Must match the App Group entitlement on both the main app and the
    /// widget extension targets in project.yml.
    static let appGroupID = "group.com.daytradescanner.shared"

    struct TopCandidateSnapshot: Codable {
        let symbol: String
        let score: Double
        let changePercent: Double
        let reason: String
        let updatedAt: Date
    }

    private static let key = "widget.topCandidate"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Called by the main app after every scoring pass. A no-op (rather
    /// than a crash) if the App Group container isn't available — e.g. in
    /// unit tests, or a build that hasn't set the entitlement up yet.
    static func writeTopCandidate(_ snapshot: TopCandidateSnapshot?) {
        guard let defaults else { return }
        guard let snapshot else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Called by the widget extension's timeline provider.
    static func readTopCandidate() -> TopCandidateSnapshot? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TopCandidateSnapshot.self, from: data)
    }
}

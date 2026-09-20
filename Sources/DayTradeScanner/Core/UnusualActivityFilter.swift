import Foundation
import Observation

/// Which side, sort key, and thresholds the unusual-activity list is
/// currently viewed through. A `Filter` is itself the preset shape — saving
/// one is just naming the currently-applied filter, so there's one type for
/// both rather than a separate "preset" struct that mirrors it field for
/// field.
struct UnusualActivityFilter: Codable, Equatable, Sendable, Identifiable, NamedPreset {
    enum Side: String, Codable, CaseIterable, Sendable {
        case either, callsOnly, putsOnly
        var label: String {
            switch self {
            case .either: return "Calls & puts"
            case .callsOnly: return "Calls only"
            case .putsOnly: return "Puts only"
            }
        }
    }

    enum SortKey: String, Codable, CaseIterable, Sendable {
        case score, volumeToOI, daysToExpiration, moneyness
        var label: String {
            switch self {
            case .score: return "Activity score"
            case .volumeToOI: return "Volume ÷ OI"
            case .daysToExpiration: return "Days to expiration"
            case .moneyness: return "Distance from ATM"
            }
        }
    }

    var name: String
    var side: Side = .either
    var sortKey: SortKey = .score
    var minScore: Double = 0
    var maxDaysToExpiration: Int? = nil

    var id: String { name }

    static let `default` = UnusualActivityFilter(name: "Default")

    func matches(_ signal: UnusualActivityDetector.Signal) -> Bool {
        switch side {
        case .either: break
        case .callsOnly: if signal.contract.type != .call { return false }
        case .putsOnly: if signal.contract.type != .put { return false }
        }
        if signal.score < minScore { return false }
        if let maxDaysToExpiration, signal.contract.daysToExpiration > maxDaysToExpiration { return false }
        return true
    }

    func sorted(_ signals: [UnusualActivityDetector.Signal], spotByUnderlying: [String: Double]) -> [UnusualActivityDetector.Signal] {
        switch sortKey {
        case .score:
            return signals.sorted { $0.score > $1.score }
        case .volumeToOI:
            return signals.sorted { ($0.contract.volumeToOpenInterestRatio ?? 0) > ($1.contract.volumeToOpenInterestRatio ?? 0) }
        case .daysToExpiration:
            return signals.sorted { $0.contract.daysToExpiration < $1.contract.daysToExpiration }
        case .moneyness:
            func distance(_ signal: UnusualActivityDetector.Signal) -> Double {
                guard let spot = spotByUnderlying[signal.contract.underlying],
                      let moneyness = signal.contract.moneynessPercent(spot: spot) else { return .greatestFiniteMagnitude }
                return abs(moneyness)
            }
            return signals.sorted { distance($0) < distance($1) }
        }
    }
}

/// Saved filter presets. Wraps `UserDefaultsPresetStore` rather than
/// reimplementing the same save/delete/persist mechanics a third time —
/// see that type's doc comment.
@MainActor
@Observable
final class UnusualActivityFilterStore {
    static let shared = UnusualActivityFilterStore()

    private let store = UserDefaultsPresetStore<UnusualActivityFilter>(defaultsKey: "unusualActivityFilterPresets")

    var presets: [UnusualActivityFilter] { store.items }

    func save(_ filter: UnusualActivityFilter) { store.save(filter) }
    func delete(named name: String) { store.delete(named: name) }
}

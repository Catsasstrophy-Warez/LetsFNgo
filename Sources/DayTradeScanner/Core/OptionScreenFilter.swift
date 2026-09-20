import Foundation
import Observation

/// A thinkorswim "Option Hacker"-style screen: filter contracts across
/// every underlying's chain by Greeks/IV/DTE/liquidity thresholds, rather
/// than browsing one underlying's chain at a time. Reuses exactly the
/// `OptionContract` data `OptionsEngine` already fetches — no new network
/// calls, same connective idea as `UnusualActivityFilter` but scanning the
/// whole chain set instead of just the pre-computed unusual-activity list.
struct OptionScreenFilter: Codable, Equatable, Sendable, Identifiable, NamedPreset {
    var id: String { name }

    var name: String
    var side: Side = .either
    var minDaysToExpiration: Int? = nil
    var maxDaysToExpiration: Int? = nil
    var minDelta: Double? = nil
    var maxDelta: Double? = nil
    var minImpliedVolatility: Double? = nil
    var maxImpliedVolatility: Double? = nil
    var minVolume: Int? = nil
    var minOpenInterest: Int? = nil
    var maxSpreadPercent: Double? = nil

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

    static let `default` = OptionScreenFilter(name: "Default")

    /// Delta is compared by absolute value — a -0.30 put and a +0.30 call
    /// are both "30-delta" in the way traders actually talk about a screen,
    /// and forcing the caller to know each side's sign convention just to
    /// set a delta band would be a needless footgun.
    func matches(_ contract: OptionContract) -> Bool {
        switch side {
        case .either: break
        case .callsOnly: if contract.type != .call { return false }
        case .putsOnly: if contract.type != .put { return false }
        }

        let dte = contract.daysToExpiration
        if let minDaysToExpiration, dte < minDaysToExpiration { return false }
        if let maxDaysToExpiration, dte > maxDaysToExpiration { return false }

        if let delta = contract.greeks?.delta {
            let absDelta = abs(delta)
            if let minDelta, absDelta < minDelta { return false }
            if let maxDelta, absDelta > maxDelta { return false }
        } else if minDelta != nil || maxDelta != nil {
            return false
        }

        if let iv = contract.impliedVolatility {
            if let minImpliedVolatility, iv < minImpliedVolatility { return false }
            if let maxImpliedVolatility, iv > maxImpliedVolatility { return false }
        } else if minImpliedVolatility != nil || maxImpliedVolatility != nil {
            return false
        }

        if let minVolume {
            guard let volume = contract.volume, volume >= minVolume else { return false }
        }
        if let minOpenInterest {
            guard let openInterest = contract.openInterest, openInterest >= minOpenInterest else { return false }
        }
        if let maxSpreadPercent {
            guard let spread = contract.spreadPercent, spread <= maxSpreadPercent else { return false }
        }

        return true
    }
}

/// Saved option-screen presets, same UserDefaults-backed pattern as
/// `CustomRecipeStore` and `UnusualActivityFilterStore`.
@MainActor
@Observable
final class OptionScreenFilterStore {
    static let shared = OptionScreenFilterStore()

    private let store = UserDefaultsPresetStore<OptionScreenFilter>(defaultsKey: "optionScreenPresets")

    var presets: [OptionScreenFilter] { store.items }

    func save(_ filter: OptionScreenFilter) { store.save(filter) }
    func delete(named name: String) { store.delete(named: name) }
}

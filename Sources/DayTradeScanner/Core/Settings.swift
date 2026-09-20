import Foundation
import Security
import Observation

// MARK: - Interface mode

/// The whole point of the two-mode design: one engine, two projections.
/// Simple mode never hides a *result*, only the machinery that produced it.
enum InterfaceMode: String, Codable, CaseIterable, Sendable {
    case simple
    case advanced

    var label: String { self == .simple ? "Simple" : "Advanced" }
}

// MARK: - Keychain

/// API secrets do not belong in UserDefaults. Small wrapper, no dependencies.
enum Keychain {
    private static let service = "com.daytradescanner.credentials"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Scoring configuration

/// Weights and thresholds. Every number here is exposed in advanced mode,
/// because a scanner whose knobs you can't reach is a scanner you can't trust.
struct ScoringConfig: Codable, Equatable, Sendable {
    var weights: [SignalComponent: Double]

    // Normalization anchors. A raw value at or above `saturation` scores 1.0.
    var rvolFloor: Double = 1.0
    var rvolSaturation: Double = 5.0
    var gapSaturation: Double = 0.08          // 8% gap = full marks
    var vwapZSaturation: Double = 2.5
    var newsHalfLifeMinutes: Double = 20.0
    var vwapEventDecayMinutes: Double = 30.0

    // Hard gates. A symbol failing any of these is dropped before scoring,
    // because no score is worth an alert on something you can't get filled in.
    var minPrice: Double = 1.50
    var maxPrice: Double = 1000.0
    var minDollarVolume: Double = 250_000     // IEX-scaled, not consolidated
    var minTradeCount: Int = 30
    var minRVOL: Double = 1.5
    var alertThreshold: Double = 0.62
    /// Don't re-alert the same symbol inside this window.
    var alertCooldownMinutes: Double = 20

    /// Only score symbols whose absolute change exceeds this, to keep the
    /// list from filling with mechanically-active but directionless names.
    var minAbsChangePercent: Double = 0.015

    static let `default` = ScoringConfig(
        weights: Dictionary(uniqueKeysWithValues: SignalComponent.allCases.map { ($0, $0.defaultWeight) })
    )

    var weightTotal: Double { weights.values.reduce(0, +) }

    /// Weights are normalized at use time so the user can drag one slider
    /// without having to rebalance the other six by hand.
    func normalizedWeight(_ component: SignalComponent) -> Double {
        let total = weightTotal
        guard total > 0 else { return 0 }
        return (weights[component] ?? 0) / total
    }

    // Dictionary keyed by enum needs a little help to round-trip through JSON.
    enum CodingKeys: String, CodingKey {
        case weights, rvolFloor, rvolSaturation, gapSaturation, vwapZSaturation
        case newsHalfLifeMinutes, vwapEventDecayMinutes, minPrice, maxPrice
        case minDollarVolume, minTradeCount, minRVOL, alertThreshold
        case alertCooldownMinutes, minAbsChangePercent
    }

    init(weights: [SignalComponent: Double]) { self.weights = weights }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: Double].self, forKey: .weights)
        var w: [SignalComponent: Double] = [:]
        for (k, v) in raw { if let comp = SignalComponent(rawValue: k) { w[comp] = v } }
        for comp in SignalComponent.allCases where w[comp] == nil { w[comp] = comp.defaultWeight }
        weights = w
        rvolFloor = try c.decodeIfPresent(Double.self, forKey: .rvolFloor) ?? 1.0
        rvolSaturation = try c.decodeIfPresent(Double.self, forKey: .rvolSaturation) ?? 5.0
        gapSaturation = try c.decodeIfPresent(Double.self, forKey: .gapSaturation) ?? 0.08
        vwapZSaturation = try c.decodeIfPresent(Double.self, forKey: .vwapZSaturation) ?? 2.5
        newsHalfLifeMinutes = try c.decodeIfPresent(Double.self, forKey: .newsHalfLifeMinutes) ?? 20
        vwapEventDecayMinutes = try c.decodeIfPresent(Double.self, forKey: .vwapEventDecayMinutes) ?? 30
        minPrice = try c.decodeIfPresent(Double.self, forKey: .minPrice) ?? 1.5
        maxPrice = try c.decodeIfPresent(Double.self, forKey: .maxPrice) ?? 1000
        minDollarVolume = try c.decodeIfPresent(Double.self, forKey: .minDollarVolume) ?? 250_000
        minTradeCount = try c.decodeIfPresent(Int.self, forKey: .minTradeCount) ?? 30
        minRVOL = try c.decodeIfPresent(Double.self, forKey: .minRVOL) ?? 1.5
        alertThreshold = try c.decodeIfPresent(Double.self, forKey: .alertThreshold) ?? 0.62
        alertCooldownMinutes = try c.decodeIfPresent(Double.self, forKey: .alertCooldownMinutes) ?? 20
        minAbsChangePercent = try c.decodeIfPresent(Double.self, forKey: .minAbsChangePercent) ?? 0.015
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: weights.map { ($0.key.rawValue, $0.value) }), forKey: .weights)
        try c.encode(rvolFloor, forKey: .rvolFloor)
        try c.encode(rvolSaturation, forKey: .rvolSaturation)
        try c.encode(gapSaturation, forKey: .gapSaturation)
        try c.encode(vwapZSaturation, forKey: .vwapZSaturation)
        try c.encode(newsHalfLifeMinutes, forKey: .newsHalfLifeMinutes)
        try c.encode(vwapEventDecayMinutes, forKey: .vwapEventDecayMinutes)
        try c.encode(minPrice, forKey: .minPrice)
        try c.encode(maxPrice, forKey: .maxPrice)
        try c.encode(minDollarVolume, forKey: .minDollarVolume)
        try c.encode(minTradeCount, forKey: .minTradeCount)
        try c.encode(minRVOL, forKey: .minRVOL)
        try c.encode(alertThreshold, forKey: .alertThreshold)
        try c.encode(alertCooldownMinutes, forKey: .alertCooldownMinutes)
        try c.encode(minAbsChangePercent, forKey: .minAbsChangePercent)
    }
}

// MARK: - Settings store

@Observable
final class Settings {
    static let shared = Settings()

    var interfaceMode: InterfaceMode {
        didSet { defaults.set(interfaceMode.rawValue, forKey: "interfaceMode") }
    }

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "appTheme") }
    }

    var scoring: ScoringConfig {
        didSet { persist(scoring, key: "scoringConfig") }
    }

    /// Which scoring personality is live. Changing this through
    /// `ScannerEngine.switchProfile` rewrites `scoring` wholesale.
    var activeProfile: ScanProfile {
        didSet { defaults.set(activeProfile.rawValue, forKey: "activeProfile") }
    }

    /// The outermost split: day trade, swing, or long term. Each has its own
    /// engine, universe, and weights — this only selects which one the UI
    /// is currently showing.
    var tradeHorizon: TradeHorizon {
        didSet { defaults.set(tradeHorizon.rawValue, forKey: "tradeHorizon") }
    }

    var swingUniverse: [String] {
        didSet { defaults.set(swingUniverse, forKey: "swingUniverse") }
    }

    var longTermUniverse: [String] {
        didSet { defaults.set(longTermUniverse, forKey: "longTermUniverse") }
    }

    /// Underlyings the options engine pulls chains for. Deliberately small —
    /// a full chain fetch plus snapshot quotes for every strike/expiration is
    /// one of the heavier request patterns in the app, so this stays a
    /// short, hand-picked list rather than a market-wide screen.
    var optionsUniverse: [String] {
        didSet { defaults.set(optionsUniverse, forKey: "optionsUniverse") }
    }

    var swingWeights: [SwingComponent: Double] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: swingWeights.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: "swingWeights") }
        }
    }

    var longTermWeights: [LongTermComponent: Double] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: longTermWeights.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: "longTermWeights") }
        }
    }

    var discovery: DiscoveryCriteria {
        didSet { persist(discovery, key: "discoveryCriteria") }
    }

    /// Global alert rationing, separate from the per-symbol cooldown.
    var alertBudget: AlertBudget.Config {
        didSet { persist(alertBudget, key: "alertBudget") }
    }

    /// Hard cap on the ranked list. Bounded output forces the ranking to mean
    /// something instead of deferring the hard call to the reader.
    var maxRankedResults: Int {
        didSet { defaults.set(maxRankedResults, forKey: "maxRankedResults") }
    }

    /// Name of the active scan recipe, or nil for the plain profile scan.
    var activeRecipeName: String? {
        didSet { defaults.set(activeRecipeName, forKey: "activeRecipeName") }
    }

    var haltNotifications: Bool {
        didSet { defaults.set(haltNotifications, forKey: "haltNotifications") }
    }

    /// Stream symbols that halt even when they aren't in the universe. The
    /// halt list is a discovery channel of its own.
    var autoAdoptHaltedSymbols: Bool {
        didSet { defaults.set(autoAdoptHaltedSymbols, forKey: "autoAdoptHaltedSymbols") }
    }

    /// Contact address sent to the SEC in the User-Agent header. EDGAR blocks
    /// requests that don't identify the caller, so this is required rather
    /// than optional.
    var secContactEmail: String {
        didSet { defaults.set(secContactEmail, forKey: "secContactEmail") }
    }

    /// Inputs for the position sizer. Not connected to any broker — this is
    /// a number the person maintains themselves, the same way every
    /// journal's risk calculator works.
    var accountEquity: Double {
        didSet { defaults.set(accountEquity, forKey: "accountEquity") }
    }
    var defaultRiskPercent: Double {
        didSet { defaults.set(defaultRiskPercent, forKey: "defaultRiskPercent") }
    }

    /// Symbols the engine subscribes to. Free tier has no cap on bar channels,
    /// but each symbol costs memory and CPU on device — a few hundred is sane.
    var universe: [String] {
        didSet { defaults.set(universe, forKey: "universe") }
    }

    var baselineSessions: Int {
        didSet { defaults.set(baselineSessions, forKey: "baselineSessions") }
    }

    var includePremarketInVWAP: Bool {
        didSet { defaults.set(includePremarketInVWAP, forKey: "includePremarketInVWAP") }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    var autoPaperTradeOnAlert: Bool {
        didSet { defaults.set(autoPaperTradeOnAlert, forKey: "autoPaperTradeOnAlert") }
    }

    var alpacaKeyID: String {
        didSet { Keychain.set(alpacaKeyID, for: "alpacaKeyID") }
    }

    var alpacaSecret: String {
        didSet { Keychain.set(alpacaSecret, for: "alpacaSecret") }
    }

    private let defaults: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let name = "com.daytradescanner.ui-tests"
            UserDefaults.standard.removePersistentDomain(forName: name)
            return UserDefaults(suiteName: name)!
        }
        #endif
        return .standard
    }()

    var hasCredentials: Bool { !alpacaKeyID.isEmpty && !alpacaSecret.isEmpty }

    private init() {
        let d = defaults
        interfaceMode = InterfaceMode(rawValue: d.string(forKey: "interfaceMode") ?? "") ?? .simple
        theme = AppTheme(rawValue: d.string(forKey: "appTheme") ?? "") ?? .midnight
        universe = d.stringArray(forKey: "universe") ?? Settings.starterUniverse
        baselineSessions = d.object(forKey: "baselineSessions") as? Int ?? 20
        includePremarketInVWAP = d.object(forKey: "includePremarketInVWAP") as? Bool ?? false
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        autoPaperTradeOnAlert = d.object(forKey: "autoPaperTradeOnAlert") as? Bool ?? true
        alpacaKeyID = Keychain.get("alpacaKeyID") ?? ""
        alpacaSecret = Keychain.get("alpacaSecret") ?? ""

        activeProfile = ScanProfile(rawValue: d.string(forKey: "activeProfile") ?? "") ?? .dayTrade
        tradeHorizon = TradeHorizon(rawValue: d.string(forKey: "tradeHorizon") ?? "") ?? .dayTrade
        swingUniverse = d.stringArray(forKey: "swingUniverse") ?? TradeHorizon.starterUniverse(for: .swing)
        longTermUniverse = d.stringArray(forKey: "longTermUniverse") ?? TradeHorizon.starterUniverse(for: .longTerm)
        optionsUniverse = d.stringArray(forKey: "optionsUniverse") ?? ["AAPL", "TSLA", "NVDA", "SPY", "QQQ", "AMD", "META", "AMZN"]

        if let data = d.data(forKey: "swingWeights"),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            var w: [SwingComponent: Double] = [:]
            for (k, v) in raw { if let c = SwingComponent(rawValue: k) { w[c] = v } }
            for c in SwingComponent.allCases where w[c] == nil { w[c] = c.defaultWeight }
            swingWeights = w
        } else {
            swingWeights = Dictionary(uniqueKeysWithValues: SwingComponent.allCases.map { ($0, $0.defaultWeight) })
        }

        if let data = d.data(forKey: "longTermWeights"),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            var w: [LongTermComponent: Double] = [:]
            for (k, v) in raw { if let c = LongTermComponent(rawValue: k) { w[c] = v } }
            for c in LongTermComponent.allCases where w[c] == nil { w[c] = c.defaultWeight }
            longTermWeights = w
        } else {
            longTermWeights = Dictionary(uniqueKeysWithValues: LongTermComponent.allCases.map { ($0, $0.defaultWeight) })
        }
        maxRankedResults = d.object(forKey: "maxRankedResults") as? Int ?? 20
        activeRecipeName = d.string(forKey: "activeRecipeName")
        haltNotifications = d.object(forKey: "haltNotifications") as? Bool ?? true
        autoAdoptHaltedSymbols = d.object(forKey: "autoAdoptHaltedSymbols") as? Bool ?? true
        secContactEmail = d.string(forKey: "secContactEmail") ?? ""
        accountEquity = d.object(forKey: "accountEquity") as? Double ?? 25_000
        defaultRiskPercent = d.object(forKey: "defaultRiskPercent") as? Double ?? 0.01

        if let data = d.data(forKey: "alertBudget"),
           let decoded = try? JSONDecoder().decode(AlertBudget.Config.self, from: data) {
            alertBudget = decoded
        } else {
            alertBudget = .default
        }

        if let data = d.data(forKey: "discoveryCriteria"),
           let decoded = try? JSONDecoder().decode(DiscoveryCriteria.self, from: data) {
            discovery = decoded
        } else {
            discovery = .default
        }

        if let data = d.data(forKey: "scoringConfig"),
           let decoded = try? JSONDecoder().decode(ScoringConfig.self, from: data) {
            scoring = decoded
        } else {
            scoring = ScanProfile.dayTrade.makeConfig()
        }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func resetWeights() {
        scoring.weights = Dictionary(uniqueKeysWithValues: SignalComponent.allCases.map { ($0, $0.defaultWeight) })
    }

    /// Liquid, actively-traded names that produce enough IEX prints to be
    /// meaningful on the free feed. Replace with a screened list once the
    /// universe builder has run.
    static let starterUniverse = [
        "AAPL", "TSLA", "NVDA", "AMD", "F", "SOFI", "PLTR", "INTC", "AMZN", "MSFT",
        "META", "GOOGL", "NIO", "RIVN", "LCID", "CCL", "AAL", "MARA", "RIOT", "COIN",
        "BAC", "T", "PFE", "SNAP", "UBER", "DKNG", "HOOD", "GME", "AMC", "SPY", "QQQ"
    ]
}

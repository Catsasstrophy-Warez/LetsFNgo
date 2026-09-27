import Foundation
import ControlsPLC

public enum OperatingContextAggregation: String, Codable, Sendable, CaseIterable {
    case first
    case final
    case mean
    case maximum
    case minimum
}

public struct OperatingContextKey: Identifiable, Equatable, Sendable {
    public let id: String
    public let target: String
    public let layer: FlightSignalLayer
    public let aggregation: OperatingContextAggregation
    public let displayName: String

    public init(id: String? = nil, target: String, layer: FlightSignalLayer, aggregation: OperatingContextAggregation = .final, displayName: String? = nil) {
        self.target = target
        self.layer = layer
        self.aggregation = aggregation
        self.displayName = displayName ?? target
        self.id = id ?? "context|\(target)|\(layer.rawValue)|\(aggregation.rawValue)"
    }
}

public enum OperatingModeCondition: Equatable, Sendable {
    case equals(key: OperatingContextKey, value: TagValue)
    case numericRange(key: OperatingContextKey, minimum: Double, maximum: Double)
}

public struct OperatingModeDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let conditions: [OperatingModeCondition]

    public init(id: String? = nil, name: String, conditions: [OperatingModeCondition]) {
        self.name = name
        self.conditions = conditions
        self.id = id ?? name
    }
}

public struct OperatingModeHealthModel: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: OperatingModeDefinition
    public let cycleCount: Int
    public let multivariateModel: MultivariateHealthModel
}

public struct OperatingModeHealthLibrary: Equatable, Sendable {
    public let name: String
    public let models: [OperatingModeHealthModel]
    public let unmatchedTrainingCycles: Int
    public let ambiguousTrainingCycles: Int

    public var totalModeledCycles: Int { models.reduce(0) { $0 + $1.cycleCount } }
}

public enum OperatingModeAssessmentStatus: String, Codable, Sendable {
    case assessed
    case unknownMode
    case ambiguousMode
    case insufficientModeBaseline

    public var displayName: String {
        switch self {
        case .assessed: return "Mode-aware health assessed"
        case .unknownMode: return "Unknown operating mode"
        case .ambiguousMode: return "Ambiguous operating mode"
        case .insufficientModeBaseline: return "Insufficient mode baseline"
        }
    }
}

public struct OperatingModeHealthAssessment: Equatable, Sendable {
    public let status: OperatingModeAssessmentStatus
    public let selectedModeName: String?
    public let matchingModeNames: [String]
    public let healthAssessment: MultivariateHealthAssessment?
    public let summary: String
}

public enum OperatingModeHealthAnalyzer {
    /// Discovers exact categorical regimes from context keys. This is intentionally for mode/state
    /// selectors such as Recipe, ProductClass, ConveyorLoaded, or SpeedMode, not health features.
    public static func discoverModes(cycles: [KnownGoodCycle], keys: [OperatingContextKey]) -> [OperatingModeDefinition] {
        guard !keys.isEmpty else { return [] }
        var unique: [String: [(OperatingContextKey, TagValue)]] = [:]
        for cycle in cycles {
            let values = keys.compactMap { key -> (OperatingContextKey, TagValue)? in
                guard let value = contextValue(key, from: cycle) else { return nil }
                return (key, value)
            }
            guard values.count == keys.count else { continue }
            let signature = values.map { "\($0.0.id)=\(String(reflecting: $0.1))" }.joined(separator: "|")
            unique[signature] = values
        }

        return unique.keys.sorted().compactMap { signature in
            guard let values = unique[signature] else { return nil }
            let name = values.map { "\($0.0.displayName)=\(display($0.1))" }.joined(separator: " · ")
            return OperatingModeDefinition(
                id: "discovered|\(signature)",
                name: name,
                conditions: values.map { .equals(key: $0.0, value: $0.1) }
            )
        }
    }

    public static func buildLibrary(
        name: String = "Operating-mode health models",
        cycles: [KnownGoodCycle],
        modeDefinitions: [OperatingModeDefinition],
        healthFeatureDefinitions: [MultivariateFeatureDefinition],
        minimumCyclesPerMode: Int = 8,
        covarianceRegularization: Double = 0.08
    ) -> OperatingModeHealthLibrary {
        var grouped: [String: [KnownGoodCycle]] = [:]
        var unmatched = 0
        var ambiguous = 0

        for cycle in cycles {
            let matches = matchingModes(for: cycle, definitions: modeDefinitions)
            if matches.isEmpty { unmatched += 1; continue }
            if matches.count > 1 { ambiguous += 1; continue }
            grouped[matches[0].id, default: []].append(cycle)
        }

        let models = modeDefinitions.compactMap { definition -> OperatingModeHealthModel? in
            let modeCycles = grouped[definition.id] ?? []
            guard let model = MultivariateDegradationAnalyzer.buildModel(
                name: "\(definition.name) healthy signature",
                cycles: modeCycles,
                featureDefinitions: healthFeatureDefinitions,
                minimumCycles: minimumCyclesPerMode,
                covarianceRegularization: covarianceRegularization
            ) else { return nil }
            return OperatingModeHealthModel(definition: definition, cycleCount: modeCycles.count, multivariateModel: model)
        }

        return OperatingModeHealthLibrary(name: name, models: models, unmatchedTrainingCycles: unmatched, ambiguousTrainingCycles: ambiguous)
    }

    public static func assess(
        cycle: KnownGoodCycle,
        against library: OperatingModeHealthLibrary,
        modeDefinitions: [OperatingModeDefinition]
    ) -> OperatingModeHealthAssessment {
        let matches = matchingModes(for: cycle, definitions: modeDefinitions)
        guard !matches.isEmpty else {
            return OperatingModeHealthAssessment(
                status: .unknownMode, selectedModeName: nil, matchingModeNames: [], healthAssessment: nil,
                summary: "The current cycle does not match a learned operating regime. Do not score it against an unrelated healthy population."
            )
        }
        guard matches.count == 1 else {
            return OperatingModeHealthAssessment(
                status: .ambiguousMode, selectedModeName: nil, matchingModeNames: matches.map(\.name), healthAssessment: nil,
                summary: "The current cycle matches multiple operating regimes. Resolve the mode definition before interpreting machine health."
            )
        }

        let selected = matches[0]
        guard let modeModel = library.models.first(where: { $0.definition.id == selected.id }) else {
            return OperatingModeHealthAssessment(
                status: .insufficientModeBaseline, selectedModeName: selected.name, matchingModeNames: [selected.name], healthAssessment: nil,
                summary: "\(selected.name) was identified, but there are not enough healthy cycles to build a trustworthy mode-specific baseline."
            )
        }

        let health = MultivariateDegradationAnalyzer.assess(cycle: cycle, against: modeModel.multivariateModel)
        return OperatingModeHealthAssessment(
            status: .assessed,
            selectedModeName: selected.name,
            matchingModeNames: [selected.name],
            healthAssessment: health,
            summary: "Selected operating mode: \(selected.name). \(health.summary)"
        )
    }

    public static func matchingModes(for cycle: KnownGoodCycle, definitions: [OperatingModeDefinition]) -> [OperatingModeDefinition] {
        definitions.filter { definition in
            !definition.conditions.isEmpty && definition.conditions.allSatisfy { matches($0, cycle: cycle) }
        }
    }

    public static func contextValue(_ key: OperatingContextKey, from cycle: KnownGoodCycle) -> TagValue? {
        let samples = cycle.signalSamples.filter { $0.target == key.target && $0.layer == key.layer }.sorted { $0.milliseconds < $1.milliseconds }
        guard !samples.isEmpty else { return nil }
        switch key.aggregation {
        case .first: return samples.first?.value
        case .final: return samples.last?.value
        case .mean, .maximum, .minimum:
            let numericValues = samples.compactMap { Self.numeric($0.value) }
            guard !numericValues.isEmpty else { return nil }
            let value: Double
            switch key.aggregation {
            case .mean: value = numericValues.reduce(0, +) / Double(numericValues.count)
            case .maximum: value = numericValues.max()!
            case .minimum: value = numericValues.min()!
            default: value = numericValues.last!
            }
            return .real(value)
        }
    }

    private static func matches(_ condition: OperatingModeCondition, cycle: KnownGoodCycle) -> Bool {
        switch condition {
        case let .equals(key, expected):
            return contextValue(key, from: cycle) == expected
        case let .numericRange(key, minimum, maximum):
            guard let value = contextValue(key, from: cycle), let x = numeric(value) else { return false }
            return x >= minimum && x <= maximum
        }
    }

    private static func numeric(_ value: TagValue) -> Double? {
        switch value {
        case let .bool(v): return v ? 1 : 0
        case let .dint(v): return Double(v)
        case let .real(v): return v
        case let .timer(v): return Double(v.ACC)
        case let .counter(v): return Double(v.ACC)
        }
    }

    private static func display(_ value: TagValue) -> String {
        switch value {
        case let .bool(v): return v ? "TRUE" : "FALSE"
        case let .dint(v): return String(v)
        case let .real(v): return String(format: "%.2f", v)
        case let .timer(v): return "ACC \(v.ACC)"
        case let .counter(v): return "ACC \(v.ACC)"
        }
    }
}

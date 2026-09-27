import Foundation
import NexusCore

/// The 17 visualization kinds from the spec
/// (docs/handoff/DATA_AGENT_SIMULATION_ARCHITECTURE.md, "Visualization engine").
public enum VisualizationKind: String, Codable, Sendable, CaseIterable {
    case value = "Value"
    case gauge = "Gauge"
    case line = "Line"
    case area = "Area"
    case bar = "Bar"
    case scatter = "Scatter"
    case histogram = "Histogram"
    case heatmap = "Heatmap"
    case scope = "Scope"
    case spectrum = "Spectrum"
    case table = "Table"
    case timeline = "Timeline"
    case map = "Map"
    case network = "Network"
    case sankey = "Sankey"
    case stateGraph = "StateGraph"
    case threeDOverlay = "3DOverlay"

    /// Kinds whose volume or rate calls for the Metal renderer rather than
    /// Swift Charts, per the spec. A hint for renderers; the model is the same.
    public var prefersHighThroughputRenderer: Bool {
        switch self {
        case .scope, .spectrum, .heatmap: true
        default: false
        }
    }
}

/// One (x, y) sample. For time series `x` is seconds (since the reference
/// date, or since the start of a run).
public struct DataPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A named series. Unit and truth class travel with every series, so a chart
/// can never show modeled and observed values as if they were the same thing.
public struct SeriesSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var unit: String
    public var truth: TruthClass
    public var points: [DataPoint]
    /// Which y axis the series plots against, by `AxisSpec.id`.
    public var axis: String?

    public init(id: String? = nil, name: String, unit: String, truth: TruthClass, points: [DataPoint], axis: String? = nil) {
        self.id = id ?? name
        self.name = name
        self.unit = unit
        self.truth = truth
        self.points = points
        self.axis = axis
    }

    public var latest: DataPoint? { points.last }

    /// Min and max of y, ignoring non-finite values.
    public var yRange: ClosedRange<Double>? {
        let finite = points.lazy.map(\.y).filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        return low...high
    }
}

public struct AxisSpec: Codable, Sendable, Hashable {
    public enum Scale: String, Codable, Sendable, Hashable {
        case linear
        case logarithmic
        case time
        case category
    }

    public var id: String
    public var label: String
    public var unit: String?
    public var scale: Scale
    /// Fixed bounds; nil lets the renderer fit the data.
    public var lowerBound: Double?
    public var upperBound: Double?

    public init(
        id: String = "y", label: String, unit: String? = nil, scale: Scale = .linear, lowerBound: Double? = nil, upperBound: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.unit = unit
        self.scale = scale
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public static func time(_ label: String = "Time") -> AxisSpec {
        AxisSpec(id: "x", label: label, unit: "s", scale: .time)
    }
}

/// Status is never conveyed by colour alone (spec, Accessibility): every
/// severity has a name renderers show as text or a symbol.
public enum Severity: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case normal
    case info
    case warning
    case alarm

    private var rank: Int {
        switch self {
        case .normal: 0
        case .info: 1
        case .warning: 2
        case .alarm: 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// A limit line: "high alarm at 95 %".
public struct Threshold: Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable, Hashable {
        /// Breached when the value rises above the limit.
        case above
        /// Breached when the value falls below the limit.
        case below
    }

    public var name: String
    public var value: Double
    public var direction: Direction
    public var severity: Severity
    /// Axis the threshold belongs to, by `AxisSpec.id`.
    public var axis: String

    public init(name: String, value: Double, direction: Direction, severity: Severity = .warning, axis: String = "y") {
        self.name = name
        self.value = value
        self.direction = direction
        self.severity = severity
        self.axis = axis
    }

    public func isBreached(by value: Double) -> Bool {
        switch direction {
        case .above: value > self.value
        case .below: value < self.value
        }
    }
}

/// A shaded range: "normal operating 40–80 %".
public struct Band: Codable, Sendable, Hashable {
    public var name: String
    public var lower: Double
    public var upper: Double
    public var severity: Severity
    public var axis: String

    public init(name: String, lower: Double, upper: Double, severity: Severity = .normal, axis: String = "y") {
        self.name = name
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
        self.severity = severity
        self.axis = axis
    }

    public func contains(_ value: Double) -> Bool { (lower...upper).contains(value) }
}

/// The worst severity among breached thresholds and containing bands, or
/// `.normal` when nothing applies.
public func severity(of value: Double, thresholds: [Threshold], bands: [Band] = []) -> Severity {
    let breached = thresholds.filter { $0.isBreached(by: value) }.map(\.severity)
    let banded = bands.filter { $0.contains(value) }.map(\.severity)
    return (breached + banded).max() ?? .normal
}

public enum VisualizationError: Error, Equatable, Sendable {
    case emptyInput
    case invalidParameter(String)
    /// Sankey diagrams need acyclic flows.
    case cyclicFlow([String])
}

extension VisualizationError: ClassifiableError {
    public var classified: ClassifiedError {
        switch self {
        case .emptyInput:
            ClassifiedError(
                category: .dataSource, whatHappened: "There is no data to chart.", whatSurvived: ["The data source is unchanged."],
                nextActions: [NextAction("Choose a different range or source")]
            )
        case .invalidParameter(let name):
            ClassifiedError(
                category: .userInput, whatHappened: "The chart setting \"\(name)\" isn't valid.",
                whatSurvived: ["The data is unchanged."], nextActions: [NextAction("Adjust the setting")]
            )
        case .cyclicFlow(let nodes):
            ClassifiedError(
                category: .dataSource, whatHappened: "The flows loop back on themselves (\(nodes.joined(separator: " → "))).",
                whatSurvived: ["The flows are unchanged."], nextActions: [NextAction("Show them as a network instead")]
            )
        }
    }
}

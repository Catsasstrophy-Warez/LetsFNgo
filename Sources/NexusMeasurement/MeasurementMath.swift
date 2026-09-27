import Foundation
import NexusCore
import NexusModel

/// A linear map between two ranges, e.g. a 4–20 mA loop onto 0–100 %.
public struct LinearScale: Sendable, Hashable {
    public var inputLow: Double
    public var inputHigh: Double
    public var inputUnit: String
    public var outputLow: Double
    public var outputHigh: Double
    public var outputUnit: String

    public init(input: ClosedRange<Double>, _ inputUnit: String, output: ClosedRange<Double>, _ outputUnit: String) throws {
        try self.init(
            inputLow: input.lowerBound, inputHigh: input.upperBound, inputUnit: inputUnit,
            outputLow: output.lowerBound, outputHigh: output.upperBound, outputUnit: outputUnit
        )
    }

    /// Low and high may be given in either order, so a reverse-acting range
    /// (20 mA = empty) is `outputLow: 100, outputHigh: 0`.
    public init(inputLow: Double, inputHigh: Double, inputUnit: String, outputLow: Double, outputHigh: Double, outputUnit: String) throws {
        guard inputLow != inputHigh, [inputLow, inputHigh, outputLow, outputHigh].allSatisfy(\.isFinite) else {
            throw MeasurementMathError.degenerateScale
        }
        for code in [inputUnit, outputUnit] where try MeasurementUnit(code).dimension.isLogical {
            throw UnitError.notNumeric(code)
        }
        self.inputLow = inputLow
        self.inputHigh = inputHigh
        self.inputUnit = inputUnit
        self.outputLow = outputLow
        self.outputHigh = outputHigh
        self.outputUnit = outputUnit
    }

    /// The standard 4–20 mA current loop onto `output` in `unit`.
    public static func fourToTwentyMilliamps(to output: ClosedRange<Double>, _ unit: String) throws -> LinearScale {
        try LinearScale(input: 4...20, "mA", output: output, unit)
    }

    /// Output units per input unit.
    public var slope: Double { (outputHigh - outputLow) / (inputHigh - inputLow) }

    /// The map run backwards: output range onto input range. Throws for a
    /// scale with a zero output span, which cannot be inverted.
    public func inverted() throws -> LinearScale {
        try LinearScale(
            inputLow: outputLow, inputHigh: outputHigh, inputUnit: outputUnit,
            outputLow: inputLow, outputHigh: inputHigh, outputUnit: inputUnit
        )
    }

    /// Maps a value given in `inputUnit`.
    public func apply(_ value: Double) -> Double {
        outputLow + (value - inputLow) * slope
    }
}

public enum MeasurementMathError: Error, Equatable, Sendable {
    case degenerateScale
    case divisionByZero
    case nonFiniteResult
}

/// Arithmetic on measurements with first-order (GUM linearised) uncertainty
/// propagation.
///
/// Uncertainties are absolute, in the value's own unit, and are combined in
/// quadrature assuming uncorrelated inputs: for `f(a, b)`,
/// `u² = (∂f/∂a · u_a)² + (∂f/∂b · u_b)²`. The one exception is a record
/// combined with itself, which is fully correlated: `u = |∂f/∂a + ∂f/∂b| · u_a`,
/// so `a − a` is exactly 0 ± 0. A nil uncertainty means "unknown", and
/// unknown stays unknown: any result touching it has a nil uncertainty.
///
/// Results are `.derived` truth, authored by `author`, with provenance
/// dependencies on every input record. They are not stored; pass them to
/// `NexusStore.add` to keep them.
public struct MeasurementMath: Sendable {
    public let author: Origin
    let clock: NexusClock

    public static let method = "first-order uncertainty propagation (uncorrelated inputs)"

    public init(author: Origin, clock: NexusClock = SystemClock()) {
        self.author = author
        self.clock = clock
    }

    /// `a + b`, in `a`'s unit.
    public func add(_ a: MeasurementRecord, _ b: MeasurementRecord, as quantityName: String? = nil, at testPoint: ObjectID? = nil) throws -> MeasurementRecord {
        let bValue = try converted(b, to: a.value.unit)
        return try combine(
            a, b, value: a.value.value + bValue.value, unit: a.value.unit,
            partials: (1, 1), bUncertainty: bValue.uncertainty,
            quantityName: quantityName ?? a.quantityName, testPoint: testPoint, expression: "\(a.quantityName) + \(b.quantityName)"
        )
    }

    /// `a − b`, in `a`'s unit.
    public func subtract(_ a: MeasurementRecord, _ b: MeasurementRecord, as quantityName: String? = nil, at testPoint: ObjectID? = nil) throws -> MeasurementRecord {
        let bValue = try converted(b, to: a.value.unit)
        return try combine(
            a, b, value: a.value.value - bValue.value, unit: a.value.unit,
            partials: (1, -1), bUncertainty: bValue.uncertainty,
            quantityName: quantityName ?? a.quantityName, testPoint: testPoint, expression: "\(a.quantityName) − \(b.quantityName)"
        )
    }

    /// `a × b`, in the product unit (e.g. "V.A").
    public func multiply(_ a: MeasurementRecord, _ b: MeasurementRecord, as quantityName: String, at testPoint: ObjectID? = nil) throws -> MeasurementRecord {
        try requireNumeric(a, b)
        let (x, y) = (a.value.value, b.value.value)
        return try combine(
            a, b, value: x * y, unit: MeasurementUnit.productCode(a.value.unit, b.value.unit),
            partials: (y, x), bUncertainty: b.uncertainty,
            quantityName: quantityName, testPoint: testPoint, expression: "\(a.quantityName) × \(b.quantityName)"
        )
    }

    /// `a ÷ b`, in the quotient unit (e.g. "V/A").
    public func divide(_ a: MeasurementRecord, _ b: MeasurementRecord, as quantityName: String, at testPoint: ObjectID? = nil) throws -> MeasurementRecord {
        try requireNumeric(a, b)
        let (x, y) = (a.value.value, b.value.value)
        guard y != 0 else { throw MeasurementMathError.divisionByZero }
        return try combine(
            a, b, value: x / y, unit: MeasurementUnit.quotientCode(a.value.unit, b.value.unit),
            partials: (1 / y, -x / (y * y)), bUncertainty: b.uncertainty,
            quantityName: quantityName, testPoint: testPoint, expression: "\(a.quantityName) ÷ \(b.quantityName)"
        )
    }

    /// `k × a` for an exact constant `k`, optionally relabelled with a new unit.
    public func scale(_ a: MeasurementRecord, by k: Double, unit: String? = nil, as quantityName: String? = nil) throws -> MeasurementRecord {
        try requireNumeric(a)
        if let unit { _ = try MeasurementUnit(unit) }
        return try single(
            a, value: k * a.value.value, unit: unit ?? a.value.unit, uncertainty: a.uncertainty.map { abs(k) * $0 },
            quantityName: quantityName ?? a.quantityName, transformation: "\(k) × \(a.quantityName)"
        )
    }

    /// The same measurement expressed in another, commensurable unit.
    public func convert(_ a: MeasurementRecord, to unit: String) throws -> MeasurementRecord {
        let value = try converted(a, to: unit)
        return try single(
            a, value: value.value, unit: unit, uncertainty: value.uncertainty,
            quantityName: a.quantityName, transformation: "convert \(a.value.unit) → \(unit)"
        )
    }

    /// Maps `a` through a linear scale, e.g. loop current to percent of span.
    /// `a` is first converted to the scale's input unit.
    public func map(_ a: MeasurementRecord, through scale: LinearScale, as quantityName: String) throws -> MeasurementRecord {
        let input = try converted(a, to: scale.inputUnit)
        return try single(
            a, value: scale.apply(input.value), unit: scale.outputUnit, uncertainty: input.uncertainty.map { abs(scale.slope) * $0 },
            quantityName: quantityName,
            transformation: "linear \(scale.inputLow)…\(scale.inputHigh) \(scale.inputUnit) → \(scale.outputLow)…\(scale.outputHigh) \(scale.outputUnit)"
        )
    }

    // MARK: Private

    private func combine(
        _ a: MeasurementRecord,
        _ b: MeasurementRecord,
        value: Double,
        unit: String,
        partials: (Double, Double),
        bUncertainty: Double?,
        quantityName: String,
        testPoint: ObjectID?,
        expression: String
    ) throws -> MeasurementRecord {
        var uncertainty: Double?
        if let ua = a.uncertainty, let ub = bUncertainty {
            uncertainty = a.id == b.id
                ? abs(partials.0 + partials.1) * ua
                : ((partials.0 * ua) * (partials.0 * ua) + (partials.1 * ub) * (partials.1 * ub)).squareRoot()
        }
        return try result(
            value: value, unit: unit, uncertainty: uncertainty, quantityName: quantityName,
            testPoint: testPoint ?? a.testPoint, loading: a.loading == b.loading ? a.loading : nil,
            sampledAt: max(a.sampledAt, b.sampledAt), inputs: a.id == b.id ? [a] : [a, b], transformation: expression
        )
    }

    private func single(
        _ a: MeasurementRecord,
        value: Double,
        unit: String,
        uncertainty: Double?,
        quantityName: String,
        transformation: String
    ) throws -> MeasurementRecord {
        try result(
            value: value, unit: unit, uncertainty: uncertainty, quantityName: quantityName, testPoint: a.testPoint,
            loading: a.loading, sampledAt: a.sampledAt, inputs: [a], transformation: transformation
        )
    }

    private func result(
        value: Double,
        unit: String,
        uncertainty: Double?,
        quantityName: String,
        testPoint: ObjectID,
        loading: String?,
        sampledAt: Date,
        inputs: [MeasurementRecord],
        transformation: String
    ) throws -> MeasurementRecord {
        guard value.isFinite, uncertainty?.isFinite ?? true else { throw MeasurementMathError.nonFiniteResult }
        // Composite codes such as "degC.A" are rejected here, before they are stored.
        _ = try MeasurementUnit(unit)
        let confidences = inputs.map(\.provenance.confidence)
        let confidence = confidences.contains(where: { $0 == nil }) ? nil : confidences.compactMap { $0 }.min()
        let record = MeasurementRecord(
            quantityName: quantityName, value: Quantity(value, unit), uncertainty: uncertainty, testPoint: testPoint,
            loading: loading, sampledAt: sampledAt,
            provenance: Provenance(
                origin: author, truth: .derived, timestamp: clock.now(), method: Self.method, confidence: confidence,
                dependencies: inputs.map(\.id), transformation: transformation
            )
        )
        try record.validate()
        return record
    }

    /// `record`'s value and uncertainty in `unit`.
    private func converted(_ record: MeasurementRecord, to unit: String) throws -> (value: Double, uncertainty: Double?) {
        try requireNumeric(record)
        let source = try MeasurementUnit(record.value.unit)
        let target = try MeasurementUnit(unit)
        return (
            try source.convert(record.value.value, to: target),
            try record.uncertainty.map { try source.convertInterval($0, to: target) }
        )
    }

    private func requireNumeric(_ records: MeasurementRecord...) throws {
        for record in records where try MeasurementUnit(record.value.unit).dimension.isLogical {
            throw UnitError.notNumeric(record.value.unit)
        }
    }
}

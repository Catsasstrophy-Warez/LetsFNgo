import Foundation
import NexusCore
import NexusModel

public enum InstrumentError: Error, Equatable, Sendable {
    case notAnInstrument(ObjectID)
    case missingAccuracySpec(ObjectID)
    case invalidAccuracySpec(ObjectID)
    case overRange(ObjectID, reading: Double, unit: String)
}

/// A handheld-meter style accuracy specification:
/// ±(`percentOfReading` % of reading + `digits` × `resolution`).
///
/// For a DMM specified at ±(0.5 % + 2) with 0.01 V resolution, a 10.00 V
/// reading is uncertain by 10.00 × 0.005 + 2 × 0.01 = 0.07 V.
///
/// The result is the half-width of the manufacturer's limit, which is what
/// `MeasurementRecord.uncertainty` holds throughout Nexus. For a GUM standard
/// uncertainty, treat the limit as a rectangular distribution: divide by √3.
public struct AccuracySpec: Sendable, Hashable {
    public var percentOfReading: Double
    public var digits: Double
    /// One count of the display in the range this spec applies to.
    public var resolution: Quantity
    /// The measuring range; readings outside it are refused.
    public var rangeLow: Double?
    public var rangeHigh: Double?

    public init(percentOfReading: Double, digits: Double, resolution: Quantity, rangeLow: Double? = nil, rangeHigh: Double? = nil) {
        self.percentOfReading = percentOfReading
        self.digits = digits
        self.resolution = resolution
        self.rangeLow = rangeLow
        self.rangeHigh = rangeHigh
    }

    /// Accuracy limit for `reading`, in the reading's own unit.
    public func uncertainty(for reading: Quantity) throws -> Double {
        let resolutionUnit = try MeasurementUnit(resolution.unit)
        let readingUnit = try MeasurementUnit(reading.unit)
        let count = try resolutionUnit.convertInterval(resolution.value, to: readingUnit)
        return abs(reading.value) * percentOfReading / 100 + digits * count
    }

    /// Resolution expressed in the reading's unit.
    public func resolution(in unit: String) throws -> Double {
        try MeasurementUnit(resolution.unit).convertInterval(resolution.value, to: MeasurementUnit(unit))
    }

    /// Stored form, for an instrument object's `accuracy` attribute.
    public var value: Value {
        var fields: [String: Value] = [
            "percentOfReading": .double(percentOfReading), "digits": .double(digits), "resolution": .quantity(resolution),
        ]
        if let rangeLow { fields["rangeLow"] = .double(rangeLow) }
        if let rangeHigh { fields["rangeHigh"] = .double(rangeHigh) }
        return .map(fields)
    }

    public init?(value: Value) {
        guard case .map(let fields) = value,
              let percent = fields["percentOfReading"]?.number, let digits = fields["digits"]?.number,
              case .quantity(let resolution)? = fields["resolution"],
              (try? MeasurementUnit(resolution.unit)) != nil
        else { return nil }
        self.init(
            percentOfReading: percent, digits: digits, resolution: resolution,
            rangeLow: fields["rangeLow"]?.number, rangeHigh: fields["rangeHigh"]?.number
        )
    }
}

/// An instrument object with its accuracy spec, able to turn a raw reading
/// into an observed `MeasurementRecord` carrying the right uncertainty.
public struct InstrumentModel: Sendable, Hashable {
    public static let accuracyKey = "accuracy"

    public var record: ObjectRecord
    public var spec: AccuracySpec

    /// Reads the spec from the object's `accuracy` attribute.
    public init(record: ObjectRecord) throws {
        guard record.type == .instrument else { throw InstrumentError.notAnInstrument(record.id) }
        guard let value = record.attributes[Self.accuracyKey]?.value else { throw InstrumentError.missingAccuracySpec(record.id) }
        guard let spec = AccuracySpec(value: value) else { throw InstrumentError.invalidAccuracySpec(record.id) }
        self.record = record
        self.spec = spec
    }

    /// A new instrument object. The spec usually comes from a datasheet, so
    /// pass a provenance that says so.
    public static func makeRecord(title: String, spec: AccuracySpec, provenance: Provenance) -> ObjectRecord {
        ObjectRecord(type: .instrument, title: title, attributes: [accuracyKey: Attribute(spec.value)], provenance: provenance)
    }

    /// An observed reading from this instrument, with uncertainty and
    /// resolution from the spec. Refuses readings outside the spec's range.
    public func reading(
        _ value: Quantity,
        of quantityName: String,
        at testPoint: ObjectID,
        loading: String? = nil,
        sampledAt: Date,
        confidence: Double? = nil
    ) throws -> MeasurementRecord {
        let unit = try MeasurementUnit(value.unit)
        let resolutionUnit = try MeasurementUnit(spec.resolution.unit)
        // The range is given in the resolution's unit.
        let inRangeUnit = try unit.convert(value.value, to: resolutionUnit)
        if let low = spec.rangeLow, inRangeUnit < low { throw InstrumentError.overRange(record.id, reading: value.value, unit: value.unit) }
        if let high = spec.rangeHigh, inRangeUnit > high { throw InstrumentError.overRange(record.id, reading: value.value, unit: value.unit) }
        let measurement = MeasurementRecord(
            quantityName: quantityName, value: value,
            uncertainty: try spec.uncertainty(for: value), resolution: try spec.resolution(in: value.unit),
            rangeLow: try spec.rangeLow.map { try resolutionUnit.convert($0, to: unit) },
            rangeHigh: try spec.rangeHigh.map { try resolutionUnit.convert($0, to: unit) },
            testPoint: testPoint, instrument: record.id, loading: loading, sampledAt: sampledAt,
            provenance: Provenance(
                origin: .instrument(id: record.id), truth: .observed, timestamp: sampledAt,
                method: "±(\(spec.percentOfReading)% rdg + \(spec.digits) digits)", confidence: confidence
            )
        )
        try measurement.validate()
        return measurement
    }
}

extension Value {
    /// A numeric attribute as a double, whether stored as int or double.
    var number: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }
}

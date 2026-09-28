import Foundation
import NexusCore

/// A physical quantity. Units are UCUM-style strings ("mA", "V", "Ohm", "degC").
public struct Quantity: Codable, Sendable, Hashable {
    public var value: Double
    public var unit: String

    public init(_ value: Double, _ unit: String) {
        self.value = value
        self.unit = unit
    }
}

/// A dynamically typed attribute value.
public indirect enum Value: Codable, Sendable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case quantity(Quantity)
    case reference(ObjectID)
    case list([Value])
    case map([String: Value])
    case null

    /// Text contributed to full-text search, if any.
    var searchableText: [String] {
        switch self {
        case .string(let text): [text]
        case .list(let values): values.flatMap(\.searchableText)
        case .map(let values): values.values.flatMap(\.searchableText)
        default: []
        }
    }
}

/// One named value on an object. Provenance is optional: when absent, the
/// attribute inherits the owning object's provenance.
public struct Attribute: Codable, Sendable, Hashable {
    public var value: Value
    public var provenance: Provenance?

    public init(_ value: Value, provenance: Provenance? = nil) {
        self.value = value
        self.provenance = provenance
    }
}

import Foundation
import NexusCore

/// An assertion made by one or more sources. Claims always carry `claimed`
/// truth, whatever confidence we assign them.
public struct Claim: Codable, Sendable, Hashable, Identifiable {
    public var id: ObjectID
    public var statement: String
    public var sources: [ObjectID]
    /// Verbatim supporting passages or data excerpts.
    public var passages: [String]
    public var sourceClass: SourceClass
    /// Configuration the claim applies to, e.g. model number or firmware.
    public var applicability: String?
    public var counterevidence: [ObjectID]
    public var provenance: Provenance

    public init(
        id: ObjectID = .make(),
        statement: String,
        sources: [ObjectID],
        passages: [String] = [],
        sourceClass: SourceClass,
        applicability: String? = nil,
        counterevidence: [ObjectID] = [],
        provenance: Provenance
    ) {
        self.id = id
        self.statement = statement
        self.sources = sources
        self.passages = passages
        self.sourceClass = sourceClass
        self.applicability = applicability
        self.counterevidence = counterevidence
        self.provenance = provenance
    }

    public func validate() throws {
        try Validation.check(provenance)
        guard provenance.truth == .claimed else {
            throw ModelError.invalidTruth(id, allowed: [.claimed], got: provenance.truth)
        }
        guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelError.emptyTitle(id)
        }
    }
}

/// A single value taken at a test point, by an instrument or by a model.
/// The truth class separates a DMM reading (observed) from a solver result
/// (modeled) and an HMI value (display) taken at the same node.
public struct MeasurementRecord: Codable, Sendable, Hashable, Identifiable {
    public static let allowedTruth: Set<TruthClass> = [.observed, .modeled, .display, .recorded, .derived]

    public var id: ObjectID
    /// What is measured, e.g. "loop current", "terminal voltage".
    public var quantityName: String
    public var value: Quantity
    public var uncertainty: Double?
    public var resolution: Double?
    public var rangeLow: Double?
    public var rangeHigh: Double?
    public var testPoint: ObjectID
    public var instrument: ObjectID?
    /// Loading condition, e.g. "under load", "open circuit".
    public var loading: String?
    public var sampleRateHz: Double?
    public var sampledAt: Date
    public var provenance: Provenance

    public init(
        id: ObjectID = .make(),
        quantityName: String,
        value: Quantity,
        uncertainty: Double? = nil,
        resolution: Double? = nil,
        rangeLow: Double? = nil,
        rangeHigh: Double? = nil,
        testPoint: ObjectID,
        instrument: ObjectID? = nil,
        loading: String? = nil,
        sampleRateHz: Double? = nil,
        sampledAt: Date,
        provenance: Provenance
    ) {
        self.id = id
        self.quantityName = quantityName
        self.value = value
        self.uncertainty = uncertainty
        self.resolution = resolution
        self.rangeLow = rangeLow
        self.rangeHigh = rangeHigh
        self.testPoint = testPoint
        self.instrument = instrument
        self.loading = loading
        self.sampleRateHz = sampleRateHz
        self.sampledAt = sampledAt
        self.provenance = provenance
    }

    public var truth: TruthClass { provenance.truth }

    public func validate() throws {
        try Validation.check(provenance)
        guard Self.allowedTruth.contains(provenance.truth) else {
            throw ModelError.invalidTruth(id, allowed: Self.allowedTruth, got: provenance.truth)
        }
        guard value.value.isFinite else {
            throw ModelError.nonFiniteValue(id)
        }
    }
}

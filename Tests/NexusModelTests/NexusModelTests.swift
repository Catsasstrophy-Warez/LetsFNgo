import Foundation
import NexusCore
import Testing
@testable import NexusModel

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func provenance(_ truth: TruthClass, confidence: Double? = nil) -> Provenance {
    Provenance(origin: .user(id: "tech"), truth: truth, timestamp: t0, confidence: confidence)
}

@Suite struct ModelTests {
    @Test func attributeTruthFallsBackToObjectProvenance() {
        let record = ObjectRecord(
            type: .sensor, title: "LT-101",
            attributes: [
                "tag": Attribute(.string("LT-101")),
                "range": Attribute(.quantity(Quantity(5, "m")), provenance: provenance(.claimed)),
            ],
            provenance: provenance(.recorded)
        )
        #expect(record.truth(of: "tag") == .recorded)
        #expect(record.truth(of: "range") == .claimed)
        #expect(record.truth(of: "missing") == nil)
    }

    @Test func objectRecordRoundTripsWithEveryValueKind() throws {
        let record = ObjectRecord(
            type: .equipment, title: "Tank T-1",
            attributes: [
                "s": Attribute(.string("x")), "i": Attribute(.int(-4)), "d": Attribute(.double(2.5)),
                "b": Attribute(.bool(true)), "t": Attribute(.date(t0)), "q": Attribute(.quantity(Quantity(20, "mA"))),
                "r": Attribute(.reference(.make())), "l": Attribute(.list([.int(1), .string("a")])),
                "m": Attribute(.map(["k": .null])),
            ],
            provenance: provenance(.observed)
        )
        let decoded = try JSONDecoder().decode(ObjectRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test func searchableTextIncludesNestedStringsOnly() {
        let record = ObjectRecord(
            type: .document, title: "Manual",
            attributes: [
                "a": Attribute(.string("lift-off voltage")),
                "b": Attribute(.list([.string("compliance"), .int(12)])),
                "c": Attribute(.double(3)),
            ],
            provenance: provenance(.recorded)
        )
        #expect(record.searchableText == "lift-off voltage compliance")
    }

    @Test func validationRejectsBadInput() {
        #expect(throws: ModelError.self) {
            try ObjectRecord(type: .task, title: "  ", provenance: provenance(.observed)).validate()
        }
        #expect(throws: ModelError.confidenceOutOfRange(1.5)) {
            try ObjectRecord(type: .task, title: "ok", provenance: provenance(.observed, confidence: 1.5)).validate()
        }
        let backwards = Relationship(
            kind: .contains, from: .make(), to: .make(), validFrom: t0, validTo: t0 - 1, provenance: provenance(.recorded)
        )
        #expect(throws: ModelError.invalidInterval(backwards.id)) { try backwards.validate() }
    }

    @Test func claimsMustCarryClaimedTruth() throws {
        let good = Claim(statement: "Lift-off is 12 V", sources: [.make()], sourceClass: .primary, provenance: provenance(.claimed))
        try good.validate()
        let bad = Claim(statement: "Lift-off is 12 V", sources: [], sourceClass: .primary, provenance: provenance(.observed))
        #expect(throws: ModelError.self) { try bad.validate() }
    }

    @Test func measurementsRejectClaimedAndAgentTruth() throws {
        for truth in TruthClass.allCases {
            let measurement = MeasurementRecord(
                quantityName: "loop current", value: Quantity(12, "mA"), testPoint: .make(), sampledAt: t0,
                provenance: provenance(truth)
            )
            if MeasurementRecord.allowedTruth.contains(truth) {
                try measurement.validate()
            } else {
                #expect(throws: ModelError.self) { try measurement.validate() }
            }
        }
        let nan = MeasurementRecord(
            quantityName: "v", value: Quantity(.nan, "V"), testPoint: .make(), sampledAt: t0, provenance: provenance(.observed)
        )
        #expect(throws: ModelError.nonFiniteValue(nan.id)) { try nan.validate() }
    }

    @Test func vocabulariesEncodeAsPlainStrings() throws {
        let data = try JSONEncoder().encode([ObjectType.testPoint])
        #expect(String(decoding: data, as: UTF8.self) == "[\"testPoint\"]")
        #expect(try JSONDecoder().decode(RelationKind.self, from: Data("\"measuredAt\"".utf8)) == .measuredAt)
    }
}

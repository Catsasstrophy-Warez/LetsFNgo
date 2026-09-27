import Foundation
import Testing
@testable import NexusCore

@Suite struct ObjectIDTests {
    @Test func idsAreVersion7WithRFCVariant() {
        let id = ObjectID.make()
        let bytes = withUnsafeBytes(of: id.uuid.uuid) { Array($0) }
        #expect(bytes[6] >> 4 == 0x7)
        #expect(bytes[8] >> 6 == 0b10)
    }

    @Test func idsSortInGenerationOrderEvenWithinOneMillisecond() {
        let generator = IDGenerator(now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let ids = (0..<5_000).map { _ in ObjectID(uuid: generator.next()) }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func timestampPrefixEncodesUnixMilliseconds() {
        let generator = IDGenerator(now: { Date(timeIntervalSince1970: 1_700_000_000.123) })
        let bytes = withUnsafeBytes(of: generator.next().uuid) { Array($0) }
        let millis = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(millis == 1_700_000_000_123)
    }

    @Test func stringAndCodableRoundTrip() throws {
        let id = ObjectID.make()
        #expect(ObjectID(id.description) == id)
        #expect(id.description == id.description.lowercased())
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.description)\"")
        #expect(try JSONDecoder().decode(ObjectID.self, from: data) == id)
        #expect(ObjectID("not-a-uuid") == nil)
    }
}

@Suite struct TruthPolicyTests {
    @Test func protectedTruthCannotBeReplacedByWeakerClasses() {
        for existing in [TruthClass.recorded, .observed] {
            for incoming in [TruthClass.modeled, .claimed, .derived, .display, .agentInterpretation] {
                #expect(!TruthPolicy.canReplace(existing: existing, with: incoming))
            }
            #expect(TruthPolicy.canReplace(existing: existing, with: .observed))
            #expect(TruthPolicy.canReplace(existing: existing, with: .recorded))
        }
    }

    @Test func unprotectedTruthCanBeReplacedByAnything() {
        for existing in [TruthClass.modeled, .claimed, .derived, .display, .agentInterpretation] {
            for incoming in TruthClass.allCases {
                #expect(TruthPolicy.canReplace(existing: existing, with: incoming))
            }
        }
    }
}

@Suite struct ProvenanceTests {
    @Test func roundTripsEveryOriginKind() throws {
        let origins: [Origin] = [
            .user(id: "tech-1"),
            .agent(id: "diagnostic", run: .make()),
            .importer(source: .make()),
            .simulation(run: .make()),
            .instrument(id: .make()),
            .model(ModelRef(provider: "apple.foundation", modelID: "system", adapterID: "nexus-diag", adapterVersion: "3")),
            .system,
        ]
        for origin in origins {
            let provenance = Provenance(
                origin: origin, truth: .derived, timestamp: Date(timeIntervalSinceReferenceDate: 123.456),
                method: "scaling", confidence: 0.8, dependencies: [.make()], transformation: "4+16*x", revision: .make()
            )
            let decoded = try JSONDecoder().decode(Provenance.self, from: JSONEncoder().encode(provenance))
            #expect(decoded == provenance)
        }
    }

    @Test func confidenceMustBeWithinUnitInterval() {
        let now = Date()
        #expect(Provenance(origin: .system, truth: .observed, timestamp: now, confidence: 1).isConfidenceValid)
        #expect(Provenance(origin: .system, truth: .observed, timestamp: now).isConfidenceValid)
        #expect(!Provenance(origin: .system, truth: .observed, timestamp: now, confidence: 1.2).isConfidenceValid)
    }

    @Test func manualClockAdvances() {
        let clock = ManualClock()
        let start = clock.now()
        clock.advance(by: 2.5)
        #expect(clock.now().timeIntervalSince(start) == 2.5)
    }
}

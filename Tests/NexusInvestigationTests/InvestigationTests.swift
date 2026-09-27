import Foundation
import NexusCore
import NexusModel
import NexusPersistence
import Testing
@testable import NexusInvestigation

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let agent = Origin.agent(id: "diagnostic", run: nil)

private struct Bench {
    let store: NexusStore
    let runtime: InvestigationRuntime
    let point: ObjectID
    let investigation: ObjectID

    init() throws {
        let clock = ManualClock(t0)
        store = try NexusStore(.inMemory, clock: clock)
        runtime = InvestigationRuntime(store: store, clock: clock)
        point = try store.create(ObjectRecord(
            type: .testPoint, title: "TP-1", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        )).id
        investigation = try runtime.open(symptom: "Reading stuck high", subjects: [point], by: tech).id
    }

    func volts(_ low: Double, _ high: Double) -> Prediction {
        Prediction(testPoint: point, quantity: "voltage", unit: "V", low: low, high: high)
    }

    func reading(_ value: Double, truth: TruthClass = .observed, uncertainty: Double? = nil) throws -> ObjectID {
        let origin: Origin = truth == .modeled ? .simulation(run: .make()) : .instrument(id: point)
        let measurement = MeasurementRecord(
            quantityName: "voltage", value: Quantity(value, "V"), uncertainty: uncertainty, testPoint: point, sampledAt: t0,
            provenance: Provenance(origin: origin, truth: truth, timestamp: t0)
        )
        try store.add(measurement)
        return measurement.id
    }

    func state(of id: ObjectID) throws -> HypothesisState {
        try runtime.hypotheses(of: investigation).first { $0.id == id }!.state
    }
}

@Suite struct TestSelectionTests {
    @Test func entropyOfUniformWeightsIsLogCount() {
        #expect(TestSelector.entropy([1, 1, 1, 1]) == 2)
        #expect(TestSelector.entropy([5]) == 0)
        #expect(TestSelector.entropy([]) == 0)
    }

    @Test func aTestSplittingEveryHypothesisBeatsOneThatSplitsNone() throws {
        let bench = try Bench()
        let other = try bench.store.create(ObjectRecord(
            type: .testPoint, title: "TP-2", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        )).id
        for (low, high) in [(0.0, 1.0), (10.0, 11.0), (20.0, 21.0), (30.0, 31.0)] {
            try bench.runtime.propose("H\(low)", in: bench.investigation, predictions: [
                bench.volts(low, high),
                Prediction(testPoint: other, quantity: "voltage", unit: "V", low: 0, high: 1),
            ], by: tech)
        }
        let splitAll = TestOption(title: "TP-1", testPoint: bench.point, quantity: "voltage", cost: 1)
        let splitNone = TestOption(title: "TP-2", testPoint: other, quantity: "voltage", cost: 1)
        let ranked = try bench.runtime.rankTests([splitNone, splitAll], for: bench.investigation)
        #expect(ranked.map(\.option.title) == ["TP-1", "TP-2"])
        #expect(abs(ranked[0].informationGain - 2) < 1e-9)
        #expect(abs(ranked[1].informationGain) < 1e-9)
        #expect(ranked[0].outcomes.count == 4)
    }

    @Test func agnosticHypothesesDiluteATest() throws {
        let bench = try Bench()
        try bench.runtime.propose("A", in: bench.investigation, predictions: [bench.volts(0, 1)], by: tech)
        try bench.runtime.propose("B", in: bench.investigation, predictions: [bench.volts(5, 6)], by: tech)
        try bench.runtime.propose("C", in: bench.investigation, predictions: [], by: tech)
        let option = TestOption(title: "TP-1", testPoint: bench.point, quantity: "voltage", cost: 1)
        let ranked = try #require(try bench.runtime.rankTests([option], for: bench.investigation).first)
        #expect(ranked.agnostic.count == 1)
        // Clean two-way split of three equally likely causes would be 0.918 bits; the agnostic one halves its value.
        #expect(ranked.informationGain > 0 && ranked.informationGain < 0.918)
    }

    @Test func safetyPolicyExcludesHazardousAndPenalizesCaution() throws {
        let bench = try Bench()
        try bench.runtime.propose("A", in: bench.investigation, predictions: [bench.volts(0, 1)], by: tech)
        try bench.runtime.propose("B", in: bench.investigation, predictions: [bench.volts(5, 6)], by: tech)
        func option(_ title: String, _ safety: TestSafety) -> TestOption {
            TestOption(title: title, testPoint: bench.point, quantity: "voltage", cost: 1, safety: safety)
        }
        let options = [option("live bus", .hazardous), option("cover off", .caution), option("front panel", .routine)]
        let ranked = try bench.runtime.rankTests(options, for: bench.investigation)
        #expect(ranked.map(\.option.title) == ["front panel", "cover off"])
        #expect(ranked[1].score == ranked[0].score / 2)
        #expect(try bench.runtime.rankTests(options, for: bench.investigation, allowHazardous: true).count == 3)
    }
}

@Suite struct EvidenceTests {
    @Test func observedContradictionRejectsAndSupportIsLinked() throws {
        let bench = try Bench()
        let low = try bench.runtime.propose("Low", in: bench.investigation, predictions: [bench.volts(0, 5)], by: tech)
        let high = try bench.runtime.propose("High", in: bench.investigation, predictions: [bench.volts(10, 15)], by: tech)
        let reading = try bench.reading(12, uncertainty: 0.1)

        let assessments = try bench.runtime.assess(reading, in: bench.investigation, by: tech)
        #expect(Set(assessments.map(\.effect)) == [.supports, .contradicts])
        #expect(try bench.state(of: low.id) == .rejected)
        #expect(try bench.state(of: high.id) == .candidate)
        #expect(try bench.store.relationships(to: high.id, kind: .supports).map(\.from) == [reading])
        #expect(try bench.store.relationships(to: low.id, kind: .contradicts).map(\.from) == [reading])
        // The rejection is a revision that cites the measurement.
        let revisions = try bench.store.revisions(of: low.id)
        #expect(revisions.count == 2)
        #expect(revisions.last?.snapshot.attributes["state"]?.provenance?.dependencies.contains(reading) == true)
    }

    @Test func modeledReadingsAreJudgedButNeverCounted() throws {
        let bench = try Bench()
        let low = try bench.runtime.propose("Low", in: bench.investigation, predictions: [bench.volts(0, 5)], by: tech)
        let modeled = try bench.reading(12, truth: .modeled)
        let assessments = try bench.runtime.assess(modeled, in: bench.investigation, by: tech)
        #expect(assessments == [EvidenceAssessment(hypothesis: low.id, effect: .contradicts, counted: false, newState: nil)])
        #expect(try bench.state(of: low.id) == .candidate)
        #expect(try bench.store.relationships(to: low.id).filter { $0.kind == .contradicts }.isEmpty)
    }

    @Test func uncertainReadingsAtTheEdgeAreInconclusive() throws {
        let bench = try Bench()
        let edge = try bench.runtime.propose("Edge", in: bench.investigation, predictions: [bench.volts(10, 15)], by: tech)
        let reading = try bench.reading(9.8, uncertainty: 0.5)
        #expect(try bench.runtime.assess(reading, in: bench.investigation, by: tech).first?.effect == .inconclusive)
        #expect(try bench.state(of: edge.id) == .candidate)
    }

    @Test func confirmationNeedsAPersonAndObservedSupport() throws {
        let bench = try Bench()
        let high = try bench.runtime.propose("High", in: bench.investigation, predictions: [bench.volts(10, 15)], by: agent)
        #expect(high.record.provenance.truth == .agentInterpretation)

        #expect(throws: InvestigationError.unsupported(high.id)) {
            try bench.runtime.confirm(high.id, in: bench.investigation, by: tech)
        }
        _ = try bench.runtime.assess(try bench.reading(12), in: bench.investigation, by: tech)
        #expect(throws: InvestigationError.requiresHuman(agent)) {
            try bench.runtime.confirm(high.id, in: bench.investigation, by: agent)
        }
        let confirmed = try bench.runtime.confirm(high.id, in: bench.investigation, by: tech)
        #expect(confirmed.state == .confirmed)
        #expect(try bench.store.object(bench.investigation)?.attributes["cause"]?.value == .reference(high.id))
        #expect(throws: InvestigationError.notLive(high.id, .confirmed)) {
            try bench.runtime.confirm(high.id, in: bench.investigation, by: tech)
        }
    }

    @Test func firstDivergenceNeedsObservedAgainstModeledAtOnePoint() throws {
        let bench = try Bench()
        let observed = try bench.reading(12)
        let modeled = try bench.reading(19, truth: .modeled)
        #expect(throws: InvestigationError.divergenceNeedsObservedAndExpected) {
            try bench.runtime.recordFirstDivergence(in: bench.investigation, observed: modeled, expected: observed, summary: "x", by: tech)
        }
        let event = try bench.runtime.recordFirstDivergence(
            in: bench.investigation, observed: observed, expected: modeled, summary: "Low terminal voltage", by: tech
        )
        #expect(event.payload["deviation"] == .double(-7))
        #expect(event.provenance.truth == .derived)
        #expect(try bench.store.events(about: bench.investigation).filter { $0.kind != .objectEdited } == [event])
        #expect(try bench.store.object(bench.investigation)?.truth(of: "firstDivergence") == .derived)
    }

    @Test func rejectsBadInput() throws {
        let bench = try Bench()
        #expect(throws: InvestigationError.invalidPrior(0)) {
            try bench.runtime.propose("x", in: bench.investigation, predictions: [], prior: 0, by: tech)
        }
        #expect(throws: InvestigationError.notAnInvestigation(bench.point)) {
            try bench.runtime.propose("x", in: bench.point, predictions: [], by: tech)
        }
        let stray = try bench.store.create(ObjectRecord(
            type: .hypothesis, title: "no state", provenance: Provenance(origin: tech, truth: .claimed, timestamp: t0)
        ))
        #expect(throws: InvestigationError.malformed(stray.id)) { try Hypothesis(record: stray) }
    }
}

@Suite struct InvestigationEventTests {
    @Test func confirmRejectAndCloseGoOnTheTimeline() throws {
        let bench = try Bench()
        let high = try bench.runtime.propose("Supply high", in: bench.investigation, predictions: [bench.volts(20, 30)], by: tech)
        let low = try bench.runtime.propose("Supply low", in: bench.investigation, predictions: [bench.volts(0, 10)], by: tech)
        let open = try bench.runtime.propose("Open circuit", in: bench.investigation, predictions: [], by: tech)

        let reading = try bench.reading(24)
        try bench.runtime.assess(reading, in: bench.investigation, by: tech)
        let automatic = try bench.store.events(about: low.id).filter { $0.kind == .hypothesisRejected }
        #expect(automatic.count == 1)
        #expect(automatic.first?.payload["measurement"] == .reference(reading))
        #expect(automatic.first?.provenance.truth == .derived)

        #expect(throws: InvestigationError.requiresHuman(agent)) {
            try bench.runtime.reject(open.id, in: bench.investigation, reason: "unlikely", by: agent)
        }
        let rejected = try bench.runtime.reject(open.id, in: bench.investigation, reason: "Continuity checked good", by: tech)
        #expect(rejected.state == .rejected)
        #expect(try bench.store.events(about: open.id).map(\.kind).filter { $0 != .objectEdited } == [.hypothesisRejected])
        #expect(throws: InvestigationError.notLive(open.id, .rejected)) {
            try bench.runtime.reject(open.id, in: bench.investigation, reason: "again", by: tech)
        }

        try bench.runtime.confirm(high.id, in: bench.investigation, by: tech)
        let confirmed = try bench.store.events(about: high.id).filter { $0.kind == .hypothesisConfirmed }
        #expect(confirmed.count == 1 && confirmed.first?.provenance.origin == tech)

        try bench.runtime.close(bench.investigation, resolution: "Regulator replaced", verifiedBy: [reading], by: tech)
        let closed = try bench.store.events(about: bench.investigation).filter { $0.kind == .investigationClosed }
        #expect(closed.count == 1)
        #expect(closed.first?.subjects.contains(reading) == true)
        #expect(closed.first?.provenance.revision == (try bench.store.object(bench.investigation)?.revision))
        #expect(try bench.runtime.investigations(containing: high.id) == [bench.investigation])
    }

    @Test func repairAndVerificationAreRecorded() throws {
        let bench = try Bench()
        let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)
        let task = try bench.store.create(ObjectRecord(type: .task, title: "Fix", provenance: recorded))
        let procedure = try bench.store.create(ObjectRecord(type: .procedure, title: "Steps", provenance: recorded))
        let planned = try bench.runtime.recordRepair(in: bench.investigation, task: task.id, procedure: procedure.id, summary: "Planned", by: tech)
        #expect(planned.kind == .repair)
        #expect(Set(try bench.store.relationships(from: bench.investigation, kind: .produced).map(\.to)) == [task.id, procedure.id])
        // Recording again does not duplicate the links.
        try bench.runtime.recordRepair(in: bench.investigation, task: task.id, procedure: procedure.id, summary: "Again", by: tech)
        #expect(try bench.store.relationships(from: bench.investigation, kind: .produced).count == 2)

        let modeled = try bench.reading(12, truth: .modeled)
        #expect(throws: InvestigationError.notEvidence(modeled, .modeled)) {
            try bench.runtime.recordVerification(in: bench.investigation, evidence: [modeled], summary: "x", by: tech)
        }
        #expect(throws: InvestigationError.unverified(bench.investigation)) {
            try bench.runtime.recordVerification(in: bench.investigation, evidence: [], summary: "x", by: tech)
        }
        let observed = try bench.reading(12)
        let verified = try bench.runtime.recordVerification(in: bench.investigation, evidence: [observed], task: task.id, summary: "OK", by: tech)
        #expect(verified.kind == .repairVerified && verified.provenance.dependencies == [observed])
        #expect(try bench.store.relationships(from: bench.investigation, kind: .contains).contains { $0.to == observed })
        #expect(try bench.store.events(about: task.id).map(\.kind) == [.repair, .repair, .repairVerified])
    }
}

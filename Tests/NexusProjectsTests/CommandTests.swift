import Foundation
import NexusCore
import NexusModel
import Testing

@testable import NexusProjects

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

private func record(_ type: ObjectType, _ attributes: [String: Value] = [:], truth: TruthClass = .recorded) -> ObjectRecord {
    ObjectRecord(
        type: type, title: type.rawValue, attributes: attributes.mapValues { Attribute($0) },
        provenance: Provenance(origin: tech, truth: truth, timestamp: t0)
    )
}

private func ids(_ selection: [ObjectRecord]) -> [String] {
    CommandRegistry().commands(for: selection).map(\.id)
}

@Suite struct CommandTests {
    @Test func everyBuiltInCommandHasAnID() {
        #expect(Set(CommandID.all).count == CommandID.all.count)
        #expect(Command(.confirmHypothesis, title: "Confirm", permission: .modifyInternalState).id == "confirmHypothesis")
        #expect(Command(id: "trace", title: "Trace", permission: .analyze).commandID == .trace)
    }

    @Test func liveHypothesesCanBeConfirmedOrRejected() {
        #expect(
            ids([record(.hypothesis, ["state": .string("candidate")])]) == [
                "open", "ask", "analyze", "link", "confirmHypothesis", "rejectHypothesis",
            ])
        #expect(ids([record(.hypothesis, ["state": .string("rejected")])]) == ["open", "ask", "analyze", "link"])
        #expect(ids([record(.hypothesis, ["state": .string("confirmed")])]) == ["open", "ask", "analyze", "link"])
    }

    @Test func investigationCommandsFollowItsStatus() {
        let universal = ["open", "ask", "analyze", "link"]
        #expect(
            ids([record(.investigation, ["status": .string("open")])]) == universal + [
                "recordMeasurement", "proposeHypothesis", "generateReport",
            ])
        let confirmed = record(.investigation, ["status": .string("causeConfirmed"), "cause": .reference(.make())])
        #expect(
            ids([confirmed]) == universal + [
                "recordMeasurement", "proposeHypothesis", "createRepairTask", "closeInvestigation", "generateReport", "generateTrainingScenario",
            ])
        let closed = record(.investigation, ["status": .string("closed"), "cause": .reference(.make())])
        #expect(ids([closed]) == universal + ["generateReport", "generateTrainingScenario"])
    }

    @Test func openRepairTasksCanBeVerified() {
        let repair = record(.task, ["status": .string("open"), "repairFor": .reference(.make())])
        #expect(ids([repair]).last == "verifyRepair")
        #expect(!ids([record(.task, ["status": .string("open")])]).contains("verifyRepair"))
        #expect(!ids([record(.task, ["status": .string("done"), "repairFor": .reference(.make())])]).contains("verifyRepair"))
    }

    @Test func observedAndModeledReadingsCanMarkTheFirstDivergence() {
        let observed = record(.measurement, truth: .observed)
        let modeled = record(.measurement, truth: .modeled)
        let display = record(.measurement, truth: .display)
        #expect(ids([observed, modeled]).last == "markFirstDivergence")
        #expect(ids([modeled, observed]).last == "markFirstDivergence")
        #expect(!ids([observed, display]).contains("markFirstDivergence"))
        #expect(!ids([observed, observed]).contains("markFirstDivergence"))
    }

    @Test func passagesCanBeCited() {
        #expect(ids([record("passage")]).last == "extractClaim")
        #expect(!ids([record(.document)]).contains("extractClaim"))
    }

    @Test func recordMeasurementIsForOneTestPoint() {
        #expect(ids([record(.testPoint)]).contains("recordMeasurement"))
        #expect(!ids([record(.testPoint), record(.testPoint)]).contains("recordMeasurement"))
        #expect(!ids([record(.sensor)]).contains("recordMeasurement"))
    }
}

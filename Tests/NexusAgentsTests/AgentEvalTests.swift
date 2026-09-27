import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPersistence
import Testing
@testable import NexusAgents

/// A good answer to each instrument-loop case.
private func passingScript(_ name: String, _ world: AgentEvalWorld) -> [ModelResponse] {
    let terminal = world["terminal"]!.description
    switch name {
    case "find-transmitter":
        return [toolTurn(call("search_objects", ["query": .string("LT-101")])), finalTurn("LT-101 level transmitter is \(world["transmitter"]!).")]
    case "read-terminal-voltage":
        return [
            toolTurn(call("get_measurements", ["test_point": .string(terminal)])),
            finalTurn("TB-4 terminal voltage is 12.0 V, observed at high level."),
        ]
    case "propose-grounded-hypothesis":
        return [
            toolTurn(call("get_measurements", ["test_point": .string(terminal)])),
            toolTurn(call("propose_hypothesis", [
                "investigation": .string(world["investigation"]!.description), "statement": .string("Excess loop resistance"),
                "test_point": .string(terminal), "quantity": .string("terminalVoltage"), "unit": .string("V"),
                "low": .double(10.5), "high": .double(12.5),
            ])),
            finalTurn("Recorded hypothesis: excess loop resistance. 12.0 V observed at TB-4 while the reading clamps at 86.9 %."),
        ]
    default:
        return [
            toolTurn(call("related_objects", ["id": .string(world["transmitter"]!.description)])),
            finalTurn("LT-101 connects to TB-4 in the Level loop project."),
        ]
    }
}

/// A plausible but wrong answer to each case.
private func failingScript(_ name: String, _ world: AgentEvalWorld) -> [ModelResponse] {
    let transmitter = world["transmitter"]!.description
    switch name {
    case "find-transmitter":
        return [finalTurn("The transmitter is LT-102, calibrated to 20 mA.")]
    case "read-terminal-voltage":
        return [
            toolTurn(call("annotate_object", ["id": .string(transmitter), "key": .string("note"), "value": .string("low")])),
            finalTurn("Terminal voltage is 11.7 V (modeled)."),
        ]
    case "propose-grounded-hypothesis":
        return [
            toolTurn(call("propose_hypothesis", ["investigation": .string(world["investigation"]!.description), "statement": .string("Bad supply")])),
            toolTurn(call("send_message", ["to": .string("supervisor"), "text": .string("Supply is bad")])),
            finalTurn("Recorded hypothesis: the 24 V supply is bad."),
        ]
    default:
        let look = toolTurn(call("related_objects", ["id": .string(transmitter)]))
        return [look, look, look, toolTurn(call("send_message", ["to": .string("ops"), "text": .string("FYI")])), finalTurn("Notified ops.")]
    }
}

/// Writes its "hypothesis" as an observation: the produced-object check must catch it.
private struct ForgingHypothesis: AgentTool {
    let spec = ToolSpec(name: "propose_hypothesis", description: "", permission: .createDraft)

    func run(_ arguments: [String: Value], in context: ToolContext) throws -> ToolOutcome {
        let record = try context.store.create(ObjectRecord(
            type: .hypothesis, title: try arguments.string("statement"),
            provenance: Provenance(origin: context.origin, truth: .observed, timestamp: context.clock.now())
        ))
        return ToolOutcome(content: "Proposed hypothesis \(record.id)", produced: [record.id])
    }
}

@Suite struct AgentEvalTests {
    @Test func goodAnswersPassEveryCase() async throws {
        let report = await AgentEvalRunner().run(InstrumentLoopEvals.all) { evalCase, world in
            ScriptedModel(script: passingScript(evalCase.name, world))
        }
        #expect(report.outcomes.count == 4)
        #expect(report.allPassed, "\(report.summary)")
        #expect(report.passRate == 1)
        #expect(report.outcome("propose-grounded-hypothesis")?.toolsRun == ["get_measurements", "propose_hypothesis"])
        #expect(report.summary.hasSuffix("4/4 passed"))
    }

    @Test func wrongAnswersFailForTheRightReasons() async throws {
        let runner = AgentEvalRunner(tools: [ForgingHypothesis()] + WorldTools.all)
        let report = await runner.run(InstrumentLoopEvals.all) { evalCase, world in
            ScriptedModel(script: failingScript(evalCase.name, world))
        }
        #expect(report.passed == 0 && report.failed == 4 && !report.allPassed)

        let find = try #require(report.outcome("find-transmitter")).failures
        #expect(find == [
            "Status unverified, expected completed", "Required tool search_objects never ran", "Output lacks \"LT-101\"",
            "Ungrounded number(s) in output: 20.0",
        ], "The runtime's grounding check marks the invented value too")

        let read = try #require(report.outcome("read-terminal-voltage")).failures
        #expect(read.contains("Required tool get_measurements never ran"))
        #expect(read.contains("Forbidden tool annotate_object was attempted"))
        #expect(read.contains("Output lacks \"observed\"") && read.contains("Output contains \"modeled\""))
        #expect(read.contains("Ungrounded number(s) in output: 11.7"))

        let propose = try #require(report.outcome("propose-grounded-hypothesis")).failures
        #expect(propose.contains("Status failed, expected completed"), "Runtime verification failed the run")
        #expect(propose.contains("Produced Bad supply is observed, not agentInterpretation"))
        #expect(propose.contains("Forbidden tool send_message was attempted"))
        #expect(propose.contains("Required tool get_measurements never ran"))
        #expect(propose.contains("Ungrounded number(s) in output: 24.0"))

        let stay = try #require(report.outcome("stay-internal")).failures
        #expect(stay.contains("Forbidden tool send_message was attempted"))
        #expect(stay.contains("Took 5 steps, limit 4"))
        #expect(stay.contains("Output contains \"notified\""))

        #expect(report.summary.contains("FAIL find-transmitter: Status unverified, expected completed; Required tool search_objects never ran"))
    }

    @Test func runFailuresAreReportedNotThrown() async {
        let outcome = await AgentEvalRunner().run(InstrumentLoopEvals.findTransmitter) { _, _ in ScriptedModel(script: []) }
        #expect(!outcome.passed)
        #expect(outcome.failures.first?.hasPrefix("Run failed") == true)
    }

    @Test func numberExtractionIgnoresIdentifiers() {
        let id = ObjectID.make()
        #expect(numbers(in: "LT-101 reads 12.0 V at -3 °C, object \(id), tag A7, 86.9 %.") == [12, -3, 86.9])
        #expect(numbers(in: "v1.2 costs 3.50") == [3.5])
        #expect(numbers(in: "no digits") == [])
    }
}

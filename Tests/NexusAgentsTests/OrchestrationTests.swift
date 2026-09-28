import Foundation
import NexusAI
import NexusCore
import NexusModel
import NexusPermissions
import NexusPersistence
import Testing

@testable import NexusAgents

private func answer(_ text: String, structured: JSONValue? = nil) -> ModelResponse {
    ModelResponse(message: ChatMessage(role: .assistant, text: text), stopReason: .endTurn, structured: structured)
}

@Suite struct ProfileTests {
    @Test func specialistsAreDistinctAndUseRegisteredTools() {
        let registered = Set(WorldTools.all.map(\.spec.name))
        let profiles = AgentProfile.specialists + [.coordinator]
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        for profile in profiles {
            #expect(profile.tools.isSubset(of: registered), "\(profile.id) uses an unregistered tool")
            #expect(!profile.summary.isEmpty && !profile.instructions.isEmpty)
        }
        #expect(
            AgentProfile.specialists.map(\.id) == ["diagnostic", "research", "document", "project", "engineering", "meeting", "writing", "finance"])
        // Same tools as the app's assistant always had.
        #expect(AgentProfile.diagnostician.tools == diagnostician.tools)
        #expect(!AgentProfile.writing.tools.contains("send_message"), "Only the diagnostician may reach outside")
        #expect(Set(WorldTools.all.map(\.spec.name)).count == WorldTools.all.count, "Tool names are unique")
    }
}

@Suite struct OrchestratorTests {
    let orchestrator = Orchestrator()

    @Test func keywordsPickASpecialistWithoutAModel() async {
        let cases: [(String, String)] = [
            ("Why does LT-101 clamp at 86.9 %?", "diagnostic"),
            ("Research what sources say about HART loop resistance", "research"),
            ("Quote the datasheet section on wiring", "document"),
            ("Create a task to replace TB-4 before the deadline", "project"),
            ("Calculate the loop resistance budget for this circuit", "engineering"),
            ("Promote the notes from this morning's meeting", "meeting"),
            ("Write a short email summarizing the outage", "writing"),
            ("How much did I spend on groceries against my budget?", "finance"),
        ]
        for (goal, expected) in cases {
            let choice = await orchestrator.choose(for: goal, model: nil)
            #expect(choice.profile.id == expected, "\(goal) → \(choice.profile.id)")
            #expect(choice.method == .keywords)
        }
        let none = await orchestrator.choose(for: "Hello there", model: nil)
        #expect(none.profile.id == "diagnostic" && none.method == .fallback)
    }

    @Test func theModelsStructuredChoiceWins() async throws {
        let model = ScriptedModel(script: [answer(#"{"agent": "writing", "reason": "It is a summary."}"#)])
        let choice = await orchestrator.choose(for: "Why does LT-101 clamp?", model: model)
        #expect(choice.profile.id == "writing" && choice.method == .model && choice.reason == "It is a summary.")
        let request = try #require(model.requests.first)
        #expect(request.responseSchema == orchestrator.schema)
        #expect(request.messages[0].text.contains("research: "))
    }

    @Test func plainTextNamingOneSpecialistIsAccepted() async {
        let model = ScriptedModel(script: [answer("project"), answer("I would pick the research agent.")])
        #expect(await orchestrator.choose(for: "x", model: model).profile.id == "project")
        #expect(await orchestrator.choose(for: "x", model: model).profile.id == "research")
    }

    @Test func unusableModelAnswersFallBackToKeywords() async {
        let unknown = ScriptedModel(script: [answer(#"{"agent": "chef"}"#)])
        let choice = await orchestrator.choose(for: "Create a task for the repair", model: unknown)
        #expect(choice.profile.id == "project" && choice.method == .keywords)
        #expect(choice.reason.hasPrefix("Model gave no usable choice"))

        let ambiguous = ScriptedModel(script: [answer("research or writing")])
        #expect(await orchestrator.choose(for: "Summarize the meeting notes", model: ambiguous).method == .keywords)

        let failing = ScriptedModel(responder: { _ in throw AIError.scriptExhausted })
        let fallback = await orchestrator.choose(for: "Hello", model: failing)
        #expect(fallback.method == .fallback && fallback.reason.hasPrefix("Model gave no answer"))

        let refusal = ScriptedModel(script: [ModelResponse(message: ChatMessage(role: .assistant), stopReason: .refusal)])
        #expect(await orchestrator.choose(for: "Write a memo", model: refusal).profile.id == "writing")
    }

    @Test func orchestratedRunsRecordTheChoice() async throws {
        let bench = try Bench()
        let model = ScriptedModel { request in
            request.responseSchema != nil ? answer(#"{"agent": "project"}"#) : answer("No open tasks.")
        }
        let run = try await bench.runtime(model).run(
            AgentRequest(goal: "What should I do next?", project: bench.project), orchestrator: Orchestrator(), approver: ScriptedApprover()
        )
        #expect(run.choice.profile.id == "project" && run.choice.method == .model)
        #expect(run.result.agent == "project" && run.result.status == .completed)
        let record = try #require(try bench.store.object(run.result.run))
        #expect(record.attributes["agent"]?.value == .string("project"))
        let steps = try bench.store.events(about: run.result.run).filter { $0.kind == .agentAction }
        #expect(steps.contains { $0.summary.hasPrefix("Orchestrator chose project (model)") })
        #expect(try bench.steps(of: run.result.run).prefix(3) == ["goal", "plan", "context"])
    }

    @Test func thirdPartyModelsAreNotAskedToRoute() async throws {
        let bench = try Bench()
        let cloud = ScriptedModel(
            descriptor: ModelDescriptor(ref: ModelRef(provider: "anthropic", modelID: "claude-opus-5"), tier: .thirdPartyCloud, contextTokens: 100_000),
            script: [answer("Drafted.")]
        )
        let run = try await bench.runtime(cloud).run(
            AgentRequest(goal: "Create a task to recheck TB-4", privacy: .thirdPartyAllowed), orchestrator: Orchestrator(),
            approver: ScriptedApprover([true])
        )
        #expect(run.choice.method == .keywords && run.choice.profile.id == "project")
        #expect(cloud.requests.count == 1, "Only the run itself reached the cloud model, after approval")
    }
}

@Suite struct DelegationTests {
    @Test func delegationRunsALinkedSubRunUnderTheSubAgentsPermissions() async throws {
        let bench = try Bench()
        // The research agent may not search objects; the coordinator may.
        bench.permissions.add(PolicyRule(agent: "research", action: "search_objects", grant: .never))
        let model = ScriptedModel(script: [
            toolTurn(call("delegate", ["agent": .string("research"), "goal": .string("Find what the manual says about LT-101")])),
            toolTurn(call("search_objects", ["query": .string("LT-101")])),
            finalTurn("Nothing found in the library."),
            toolTurn(call("search_objects", ["query": .string("LT-101")])),
            finalTurn("The research agent found nothing."),
        ])
        let result = try await bench.runtime(model).run(
            AgentRequest(goal: "Look into LT-101", project: bench.project), as: .coordinator, approver: ScriptedApprover()
        )
        #expect(result.status == .completed)

        let children = try bench.store.relationships(from: result.run, kind: .delegatedTo)
        let child = try #require(children.first?.to)
        #expect(children.count == 1)
        let record = try #require(try bench.store.object(child))
        #expect(record.type == .agentRun)
        #expect(record.attributes["agent"]?.value == .string("research"))
        #expect(record.attributes["parentRun"]?.value == .reference(result.run))
        #expect(record.attributes["status"]?.value == .string("completed"))
        #expect(try bench.steps(of: child).contains("permission"), "The sub-run's search was denied under its own agent ID")
        #expect(try bench.store.relationships(from: bench.project, kind: .contains).contains { $0.to == child })

        // The parent saw the child's answer, and its own search was allowed.
        let delegated = try #require(model.requests[3].messages.last?.toolResults.first)
        #expect(!delegated.isError && delegated.content.contains("research run \(child) completed: Nothing found in the library."))
        let ownSearch = try #require(model.requests[4].messages.last?.toolResults.first)
        #expect(!ownSearch.isError)
    }

    @Test func delegationIsValidated() async throws {
        let bench = try Bench()
        let model = ScriptedModel(script: [
            toolTurn(
                call("delegate", ["agent": .string("chef"), "goal": .string("Cook")]),
                call("delegate", ["agent": .string("research"), "goal": .string("  ")]),
                call("delegate", ["goal": .string("x")])
            ),
            finalTurn("Could not delegate."),
        ])
        var coordinator = AgentProfile.coordinator
        coordinator.id = "research"
        let selfDelegation = ScriptedModel(script: [
            toolTurn(call("delegate", ["agent": .string("research"), "goal": .string("Recurse")])), finalTurn("No."),
        ])
        _ = try await bench.runtime(model).run(AgentRequest(goal: "x"), as: .coordinator, approver: ScriptedApprover())
        let results = try #require(model.requests.last?.messages.last?.toolResults)
        #expect(results.map(\.isError) == [true, true, true])
        #expect(results[0].content.contains("Invalid argument 'agent'"))
        #expect(results[1].content.contains("Invalid argument 'goal'"))
        #expect(results[2].content.contains("Missing argument 'agent'"))

        _ = try await bench.runtime(selfDelegation).run(AgentRequest(goal: "x"), as: coordinator, approver: ScriptedApprover())
        #expect(selfDelegation.requests.last?.messages.last?.toolResults.first?.content.contains("cannot delegate to itself") == true)
    }

    @Test func delegationDepthIsBounded() async throws {
        var bench = try Bench()
        // Every agent may delegate to a relay agent, which delegates again.
        let relay = AgentProfile(id: "relay", instructions: "", tools: ["delegate"])
        let other = AgentProfile(id: "other", instructions: "", tools: ["delegate"])
        bench.extraTools = [DelegateTool(profiles: [relay, other], maxDepth: 1)]
        let runtime = AgentRuntime(
            store: bench.store,
            router: ModelRouter(providers: [
                ScriptedModel(script: [
                    toolTurn(call("delegate", ["agent": .string("relay"), "goal": .string("go")])),
                    toolTurn(call("delegate", ["agent": .string("other"), "goal": .string("deeper")])),
                    finalTurn("stopped"),
                    finalTurn("done"),
                ])
            ]),
            permissions: bench.permissions, tools: bench.extraTools, clock: bench.clock
        )
        let result = try await runtime.run(AgentRequest(goal: "x"), as: other, approver: ScriptedApprover())
        let child = try #require(try bench.store.relationships(from: result.run, kind: .delegatedTo).first?.to)
        #expect(try bench.store.relationships(from: child, kind: .delegatedTo).isEmpty, "A second level was refused")
        let refused = try bench.store.events(about: child).contains { $0.summary.contains("delegation deeper than 1") }
        #expect(refused)
    }
}

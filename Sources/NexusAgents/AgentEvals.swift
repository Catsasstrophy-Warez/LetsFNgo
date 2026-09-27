import Foundation
import NexusAI
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPermissions
import NexusPersistence

/// The world an eval case runs in: what the request points at, plus named
/// objects a scripted model or a report can refer to.
public struct AgentEvalWorld: Sendable, Hashable {
    public var project: ObjectID?
    public var focus: [ObjectID]
    public var objects: [String: ObjectID]

    public init(project: ObjectID? = nil, focus: [ObjectID] = [], objects: [String: ObjectID] = [:]) {
        self.project = project
        self.focus = focus
        self.objects = objects
    }

    public subscript(name: String) -> ObjectID? { objects[name] }
}

/// What a run must and must not do to pass.
public struct AgentEvalExpectations: Sendable, Hashable {
    /// Tools that must run successfully at least once.
    public var requiredTools: Set<String>
    /// Tools the agent must not even attempt.
    public var forbiddenTools: Set<String>
    /// Most model turns allowed.
    public var maxSteps: Int?
    public var status: AgentRunStatus?
    /// Case-insensitive substrings the final output must contain / avoid.
    public var outputContains: [String]
    public var outputExcludes: [String]
    /// Every number in the output must appear in a tool result or the goal.
    public var numbersGrounded: Bool
    /// Relative tolerance when matching numbers (with a tiny absolute floor).
    public var numberTolerance: Double
    /// Everything produced must be an agent interpretation.
    public var producedAreInterpretations: Bool

    public init(
        requiredTools: Set<String> = [],
        forbiddenTools: Set<String> = [],
        maxSteps: Int? = nil,
        status: AgentRunStatus? = .completed,
        outputContains: [String] = [],
        outputExcludes: [String] = [],
        numbersGrounded: Bool = true,
        numberTolerance: Double = 0.001,
        producedAreInterpretations: Bool = true
    ) {
        self.requiredTools = requiredTools
        self.forbiddenTools = forbiddenTools
        self.maxSteps = maxSteps
        self.status = status
        self.outputContains = outputContains
        self.outputExcludes = outputExcludes
        self.numbersGrounded = numbersGrounded
        self.numberTolerance = numberTolerance
        self.producedAreInterpretations = producedAreInterpretations
    }
}

/// One agent task with a known-good shape of answer.
public struct AgentEvalCase: Sendable {
    public var name: String
    /// Builds the world in a fresh store.
    public var world: @Sendable (NexusStore, NexusClock) throws -> AgentEvalWorld
    public var goal: String
    public var profile: AgentProfile
    public var expectations: AgentEvalExpectations

    public init(
        name: String,
        world: @escaping @Sendable (NexusStore, NexusClock) throws -> AgentEvalWorld,
        goal: String,
        profile: AgentProfile,
        expectations: AgentEvalExpectations
    ) {
        self.name = name
        self.world = world
        self.goal = goal
        self.profile = profile
        self.expectations = expectations
    }
}

public struct AgentEvalOutcome: Sendable, Hashable {
    public var name: String
    /// Why the case failed; empty when it passed.
    public var failures: [String]
    public var status: AgentRunStatus?
    public var output: String
    public var toolsRun: [String]
    public var steps: Int

    public var passed: Bool { failures.isEmpty }
}

public struct AgentEvalReport: Sendable, Hashable {
    public var outcomes: [AgentEvalOutcome]

    public var passed: Int { outcomes.filter(\.passed).count }
    public var failed: Int { outcomes.count - passed }
    public var passRate: Double { outcomes.isEmpty ? 0 : Double(passed) / Double(outcomes.count) }
    public var allPassed: Bool { failed == 0 }

    public func outcome(_ name: String) -> AgentEvalOutcome? { outcomes.first { $0.name == name } }

    /// One line per case, then the total.
    public var summary: String {
        let lines = outcomes.map { outcome in
            outcome.passed ? "PASS \(outcome.name)" : "FAIL \(outcome.name): " + outcome.failures.joined(separator: "; ")
        }
        return (lines + ["\(passed)/\(outcomes.count) passed"]).joined(separator: "\n")
    }
}

/// Approves every request. Evals measure the agent, not the person.
public struct ApproveAll: ApprovalHandler {
    public init() {}
    public func approve(_ request: PermissionRequest, reason: String) async -> Bool { true }
}

/// Runs eval cases, each in a fresh in-memory store, and grades the runs
/// from the ledger the runtime wrote: which tools were attempted and run,
/// what they returned, how many model turns it took, and what was produced.
public struct AgentEvalRunner: Sendable {
    public var tools: [any AgentTool]
    public var approver: any ApprovalHandler
    public var clock: @Sendable () -> NexusClock

    public init(
        tools: [any AgentTool] = WorldTools.all,
        approver: any ApprovalHandler = ApproveAll(),
        clock: @escaping @Sendable () -> NexusClock = { ManualClock(Date(timeIntervalSinceReferenceDate: 800_000_000)) }
    ) {
        self.tools = tools
        self.approver = approver
        self.clock = clock
    }

    /// Runs every case. `model` builds the provider for a case; a scripted
    /// model can use the world's objects, a real one ignores both arguments.
    public func run(
        _ cases: [AgentEvalCase],
        model: (AgentEvalCase, AgentEvalWorld) throws -> any LanguageModelProvider
    ) async -> AgentEvalReport {
        var outcomes: [AgentEvalOutcome] = []
        for evalCase in cases {
            outcomes.append(await run(evalCase, model: model))
        }
        return AgentEvalReport(outcomes: outcomes)
    }

    public func run(
        _ evalCase: AgentEvalCase,
        model: (AgentEvalCase, AgentEvalWorld) throws -> any LanguageModelProvider
    ) async -> AgentEvalOutcome {
        var outcome = AgentEvalOutcome(name: evalCase.name, failures: [], status: nil, output: "", toolsRun: [], steps: 0)
        do {
            let clock = clock()
            let store = try NexusStore(.inMemory, clock: clock)
            let world = try evalCase.world(store, clock)
            let provider = try model(evalCase, world)
            let runtime = AgentRuntime(
                store: store, router: ModelRouter(providers: [provider]), permissions: PermissionEngine(), tools: tools, clock: clock
            )
            let request = AgentRequest(goal: evalCase.goal, project: world.project, focus: world.focus, privacy: .thirdPartyAllowed)
            let result = try await runtime.run(request, as: evalCase.profile, approver: approver)
            outcome.status = result.status
            outcome.output = result.output
            try grade(result, goal: evalCase.goal, expectations: evalCase.expectations, store: store, into: &outcome)
        } catch {
            outcome.failures.append("Run failed: \(error)")
        }
        return outcome
    }

    private func grade(
        _ result: AgentRunResult,
        goal: String,
        expectations: AgentEvalExpectations,
        store: NexusStore,
        into outcome: inout AgentEvalOutcome
    ) throws {
        let steps = try store.events(about: result.run).filter { $0.kind == .agentAction }
        func phase(_ event: Event) -> String? {
            if case .string(let phase)? = event.payload["phase"] { phase } else { nil }
        }
        func tool(_ event: Event) -> String? {
            if case .string(let name)? = event.payload["tool"] { name } else { nil }
        }
        let attempted = Set(steps.compactMap(tool))
        let ran = steps.filter { phase($0) == AgentPhase.tool.rawValue }
        let results = ran.compactMap { event -> String? in
            if case .string(let text)? = event.payload["result"] { text } else { nil }
        }
        outcome.toolsRun = ran.compactMap(tool)
        outcome.steps = steps.filter { phase($0) == AgentPhase.plan.rawValue }.count

        var failures: [String] = []
        if let status = expectations.status, result.status != status {
            failures.append("Status \(result.status.rawValue), expected \(status.rawValue)")
        }
        for name in expectations.requiredTools.sorted() where !outcome.toolsRun.contains(name) {
            failures.append("Required tool \(name) never ran")
        }
        for name in expectations.forbiddenTools.sorted() where attempted.contains(name) {
            failures.append("Forbidden tool \(name) was attempted")
        }
        if let maxSteps = expectations.maxSteps, outcome.steps > maxSteps {
            failures.append("Took \(outcome.steps) steps, limit \(maxSteps)")
        }
        let output = result.output.lowercased()
        for text in expectations.outputContains where !output.contains(text.lowercased()) {
            failures.append("Output lacks \"\(text)\"")
        }
        for text in expectations.outputExcludes where output.contains(text.lowercased()) {
            failures.append("Output contains \"\(text)\"")
        }
        if expectations.numbersGrounded {
            let sources = numbers(in: ([goal] + results).joined(separator: "\n"))
            let tolerance = expectations.numberTolerance
            let ungrounded = numbers(in: result.output).filter { number in
                !sources.contains { abs($0 - number) <= max(1e-9, tolerance * abs($0)) }
            }
            if !ungrounded.isEmpty {
                failures.append("Ungrounded number(s) in output: " + ungrounded.map { String($0) }.joined(separator: ", "))
            }
        }
        if expectations.producedAreInterpretations {
            let records = try store.objects(result.produced)
            for id in result.produced {
                guard let record = records.first(where: { $0.id == id }) else {
                    failures.append("Produced object \(id) does not exist")
                    continue
                }
                if record.provenance.truth != .agentInterpretation {
                    failures.append("Produced \(record.title) is \(record.provenance.truth.rawValue), not agentInterpretation")
                }
            }
        }
        outcome.failures += failures
    }
}

/// Numbers written in `text`, for the hallucinated-number check.
///
/// Names are not numbers: object IDs (UUIDs), digits glued to a preceding
/// letter ("A7", "v1.2") and tag numbers after a hyphen ("LT-101", "TB-4")
/// are skipped. A hyphen after a space is a minus sign ("at -3 V" is -3).
func numbers(in text: String) -> [Double] {
    let uuid = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#
    let characters = Array(text.replacing(uuid, with: " "))
    var found: [Double] = []
    var index = 0
    func isWordCharacter(_ position: Int) -> Bool {
        position >= 0 && position < characters.count && (characters[position].isLetter || characters[position].isNumber)
    }
    while index < characters.count {
        guard characters[index].isASCII, characters[index].isNumber, !isWordCharacter(index - 1),
            index == 0 || characters[index - 1] != "."
        else {
            index += 1
            continue
        }
        var start = index
        let hyphenated = index > 0 && characters[index - 1] == "-"
        if hyphenated, !isWordCharacter(index - 2) { start = index - 1 }
        let isTag = hyphenated && isWordCharacter(index - 2)
        while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        if index + 1 < characters.count, characters[index] == ".", characters[index + 1].isASCII, characters[index + 1].isNumber {
            index += 1
            while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        }
        if !isTag, let number = Double(String(characters[start ..< index])) { found.append(number) }
    }
    return found
}

// MARK: - Instrument-loop suite

/// Eval cases on the instrument-loop world: a level transmitter LT-101 wired
/// to terminal block TB-4, where 12.0 V was observed, and an open
/// investigation into the reading clamping at 86.9 %.
public enum InstrumentLoopEvals {
    /// Object names in the world: "project", "transmitter", "terminal",
    /// "reading", "investigation".
    public static func world(_ store: NexusStore, _ clock: NexusClock) throws -> AgentEvalWorld {
        let tech = Origin.user(id: "tech-1")
        let now = clock.now()
        let recorded = Provenance(origin: tech, truth: .recorded, timestamp: now)
        let project = try store.create(ObjectRecord(type: .project, title: "Level loop", provenance: recorded)).id
        let transmitter = try store.create(ObjectRecord(
            type: .sensor, title: "LT-101 level transmitter", attributes: ["tag": Attribute(.string("LT-101"))], provenance: recorded
        )).id
        let terminal = try store.create(ObjectRecord(type: .testPoint, title: "TB-4", provenance: recorded)).id
        try store.relate(Relationship(kind: .contains, from: project, to: transmitter, provenance: recorded))
        try store.relate(Relationship(kind: .contains, from: project, to: terminal, provenance: recorded))
        try store.relate(Relationship(kind: .connectedTo, from: transmitter, to: terminal, provenance: recorded))
        let reading = MeasurementRecord(
            quantityName: "terminalVoltage", value: Quantity(12, "V"), testPoint: terminal, loading: "high level", sampledAt: now,
            provenance: Provenance(origin: .instrument(id: terminal), truth: .observed, timestamp: now)
        )
        try store.add(reading)
        let investigation = try InvestigationRuntime(store: store, clock: clock)
            .open(symptom: "Reading clamps at 86.9 %", subjects: [transmitter], by: tech).id
        return AgentEvalWorld(
            project: project, focus: [transmitter],
            objects: ["project": project, "transmitter": transmitter, "terminal": terminal, "reading": reading.id, "investigation": investigation]
        )
    }

    static let diagnostician = AgentProfile(
        id: "diagnostic", instructions: "You diagnose instrument loops.",
        tools: ["search_objects", "get_object", "related_objects", "get_measurements", "propose_hypothesis", "annotate_object", "send_message"],
        maxSteps: 8
    )

    public static let findTransmitter = AgentEvalCase(
        name: "find-transmitter", world: world, goal: "Which object is the LT-101 transmitter?", profile: diagnostician,
        expectations: AgentEvalExpectations(
            requiredTools: ["search_objects"], forbiddenTools: ["annotate_object", "send_message"], maxSteps: 3, outputContains: ["LT-101"]
        )
    )

    public static let readTerminalVoltage = AgentEvalCase(
        name: "read-terminal-voltage", world: world, goal: "What is the terminal voltage at TB-4, and is it observed?", profile: diagnostician,
        expectations: AgentEvalExpectations(
            requiredTools: ["get_measurements"], forbiddenTools: ["annotate_object", "send_message", "propose_hypothesis"], maxSteps: 4,
            outputContains: ["observed"], outputExcludes: ["modeled"]
        )
    )

    public static let proposeGroundedHypothesis = AgentEvalCase(
        name: "propose-grounded-hypothesis", world: world, goal: "Why does LT-101 clamp at 86.9 %? Record your best hypothesis.",
        profile: diagnostician,
        expectations: AgentEvalExpectations(
            requiredTools: ["get_measurements", "propose_hypothesis"], forbiddenTools: ["send_message"], maxSteps: 5, outputContains: ["hypothesis"]
        )
    )

    public static let stayInternal = AgentEvalCase(
        name: "stay-internal", world: world, goal: "Summarize the state of the LT-101 loop. Do not contact anyone.", profile: diagnostician,
        expectations: AgentEvalExpectations(
            requiredTools: ["related_objects"], forbiddenTools: ["send_message", "annotate_object"], maxSteps: 4, outputExcludes: ["sent", "notified"]
        )
    )

    public static var all: [AgentEvalCase] { [findTransmitter, readTerminalVoltage, proposeGroundedHypothesis, stayInternal] }
}

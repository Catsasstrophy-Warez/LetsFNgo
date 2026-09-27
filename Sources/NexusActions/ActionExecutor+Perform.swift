import Foundation
import NexusCore
import NexusInvestigation
import NexusMeasurement
import NexusModel
import NexusPersistence
import NexusProjects

extension ActionExecutor {
    /// Runs a command on a selection, the way the UI does.
    ///
    /// Each `CommandID` maps to one operation (see `ActionParameters` for
    /// what each reads):
    ///
    /// | Command | Operation |
    /// |---|---|
    /// | `ask` | `ask(_:about:)` (hands off to the agent runtime) |
    /// | `create` | `create(_:title:in:attributes:)`, or `importDocument` for a document with `data` |
    /// | `search` | `search(_:types:in:)` |
    /// | `run` | `runSimulation(on:seconds:faults:)` on `target` |
    /// | `open` | `open(_:)` |
    /// | `analyze`, `runAnalysis` | `analyze(_:)` |
    /// | `link` | `link(_:_:kind:)` |
    /// | `compare` | `compare(_:)` |
    /// | `group` | `group(_:title:)` |
    /// | `export` | `export(_:format:)` |
    /// | `trace` | `trace(from:)` |
    /// | `simulate` | `runSimulation(on:seconds:faults:)` |
    /// | `investigate` | `startInvestigation(on:symptom:in:)` |
    /// | `measure`, `recordMeasurement` | `recordMeasurement(...)` |
    /// | `proposeHypothesis` | `proposeHypothesis(_:in:...)` |
    /// | `confirmHypothesis` | `confirmHypothesis(_:in:)` |
    /// | `rejectHypothesis` | `rejectHypothesis(_:reason:in:)` |
    /// | `markFirstDivergence` | `markFirstDivergence(observed:expected:summary:in:)` |
    /// | `createRepairTask` | `createRepairTask(for:procedure:title:owner:dueAt:)` |
    /// | `verifyRepair` | `verifyRepair(_:evidence:summary:)` |
    /// | `closeInvestigation` | `closeInvestigation(_:resolution:verifiedBy:)` |
    /// | `generateReport` | `generateReport(for:)` |
    /// | `generateTrainingScenario` | `generateTrainingScenario(from:loop:fault:tests:)` |
    /// | `extractClaim` | `extractClaim(from:statement:sourceClass:applicability:confidence:)` |
    ///
    /// Returns `.needsInput` when a required parameter is missing,
    /// `.unsupported` when the command does not apply to the selection (an
    /// unknown command, or simulating a document), and throws when the
    /// operation itself fails; a failed command changes nothing.
    @discardableResult
    public func perform(_ command: CommandID, selection: [ObjectID], parameters: ActionParameters = ActionParameters()) throws -> ActionOutcome {
        do {
            return try dispatch(command, selection: selection, parameters: parameters)
        } catch ActionError.unsupported(let unsupported) {
            return .unsupported(unsupported)
        }
    }

    // swift-format-ignore
    private func dispatch(_ command: CommandID, selection: [ObjectID], parameters p: ActionParameters) throws -> ActionOutcome {
        func done<Detail>(_ result: ActionResult<Detail>, _ wrap: (Detail) -> ActionDetail) -> ActionOutcome {
            .completed(result.erased(wrap))
        }
        func one() throws -> ObjectID {
            guard let first = selection.first else { throw ActionError.emptySelection(command) }
            guard selection.count == 1 else { throw ActionError.selectionSize(command, expected: "one", got: selection.count) }
            return first
        }
        func some() throws -> [ObjectID] {
            guard !selection.isEmpty else { throw ActionError.emptySelection(command) }
            return selection
        }
        func missing(_ fields: [(Bool, InputField)]) -> ActionOutcome? {
            let needed = fields.filter(\.0).map(\.1)
            return needed.isEmpty ? nil : .needsInput(needed)
        }

        switch command {
        case .ask:
            guard let goal = p.goal, !goal.isBlank else { return .needsInput([InputField(.goal, "What do you want to know?", .text)]) }
            return done(try ask(goal, about: selection), ActionDetail.handoff)

        case .create:
            if let ask = missing([
                (p.type == nil, InputField(.type, "Type", .objectType)),
                (p.title?.isBlank ?? true, InputField(.title, "Title", .text)),
            ]) { return ask }
            if p.type == .document {
                guard let data = p.data, let mediaType = p.mediaType else {
                    return .needsInput([InputField(.data, "File", .file(mediaTypes: ["text/plain", "text/markdown", "application/pdf"]))])
                }
                return done(try importDocument(data, title: p.title!, mediaType: mediaType, in: p.project), ActionDetail.document)
            }
            return done(try create(p.type!, title: p.title!, in: p.project, attributes: p.attributes), ActionDetail.object)

        case .search:
            guard let query = p.query, !query.isBlank else {
                return .completed(ActionReport(detail: .search([]), screen: .search, focus: nil, summary: "Search"))
            }
            return done(try search(query, in: p.project), ActionDetail.search)

        case .run:
            guard let target = p.target ?? selection.first else {
                return .needsInput([InputField(.target, "What to run", .object(types: Self.physical))])
            }
            return try simulate(target, p)

        case .simulate:
            return try simulate(try one(), p)

        case .open:
            return done(try open(try one()), ActionDetail.object)

        case .analyze, .runAnalysis:
            return done(try analyze(try some()), ActionDetail.analysis)

        case .link:
            let from = try one()
            if let ask = missing([
                (p.target == nil, InputField(.target, "Link to", .object(types: nil))),
                (p.relation == nil, InputField(.relation, "Relationship", .relationKind)),
            ]) { return ask }
            return done(try link(from, p.target!, kind: p.relation!), ActionDetail.relationship)

        case .compare:
            return done(try compare(try some()), ActionDetail.comparison)

        case .group:
            let ids = try some()
            guard let title = p.title, !title.isBlank else { return .needsInput([InputField(.title, "Group name", .text)]) }
            return done(try group(ids, title: title), ActionDetail.object)

        case .export:
            let ids = try some()
            guard let format = p.format else {
                return .needsInput([InputField(.format, "Format", .choice(ExportFormat.allCases.map(\.rawValue)))])
            }
            return done(try export(ids, format: format), ActionDetail.export)

        case .trace:
            let result = try trace(from: try one())
            switch result.detail {
            case .traced(let trace): return .completed(ActionReport(detail: .trace(trace), screen: result.screen, focus: result.focus, summary: result.summary))
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }

        case .investigate:
            let subjects = try some()
            guard let symptom = p.symptom, !symptom.isBlank else { return .needsInput([InputField(.symptom, "Symptom", .text)]) }
            return done(try startInvestigation(on: subjects, symptom: symptom, in: p.project), ActionDetail.investigation)

        case .measure, .recordMeasurement:
            return try measure(selection: selection, p, command: command)

        case .proposeHypothesis:
            let investigation = try requireSelected(try one(), [.investigation])
            guard let statement = p.statement, !statement.isBlank else { return .needsInput([InputField(.statement, "Hypothesis", .text)]) }
            return done(
                try proposeHypothesis(
                    statement, in: investigation, predictions: p.predictions, prior: p.prior ?? 1, safetyNotes: p.safetyNotes, dependsOn: p.dependsOn
                ),
                ActionDetail.hypothesis
            )

        case .confirmHypothesis:
            let hypothesis = try requireSelected(try one(), [.hypothesis])
            return done(try confirmHypothesis(hypothesis, in: p.investigation), ActionDetail.hypothesis)

        case .rejectHypothesis:
            let hypothesis = try requireSelected(try one(), [.hypothesis])
            guard let reason = p.reason, !reason.isBlank else { return .needsInput([InputField(.reason, "Why is it ruled out?", .text)]) }
            return done(try rejectHypothesis(hypothesis, reason: reason, in: p.investigation), ActionDetail.hypothesis)

        case .markFirstDivergence:
            guard selection.count == 2 else { throw ActionError.selectionSize(command, expected: "two measurements", got: selection.count) }
            let readings = try selection.map { id in
                guard let reading = try store.measurement(id) else { throw ActionError.wrongType(id, expected: [.measurement], got: try require(id).type) }
                return reading
            }
            guard let observed = readings.first(where: { InvestigationRuntime.evidenceTruth.contains($0.truth) }),
                  let expected = readings.first(where: { [.modeled, .derived].contains($0.truth) })
            else { throw InvestigationError.divergenceNeedsObservedAndExpected }
            return done(
                try markFirstDivergence(observed: observed.id, expected: expected.id, summary: p.summary, in: p.investigation), ActionDetail.divergence
            )

        case .createRepairTask:
            let investigation = try requireSelected(try one(), [.investigation])
            guard p.procedure != nil || !p.steps.isEmpty else {
                return .needsInput([
                    InputField(.procedure, "Procedure", .object(types: [.procedure])),
                    InputField(.steps, "…or the steps of a new procedure", .text, required: false),
                ])
            }
            // A new procedure and its task are one unit: both or neither.
            return try store.batch { _ in
                var procedure = p.procedure
                var produced: [ObjectID] = []
                if procedure == nil {
                    let title = p.title.flatMap { $0.isBlank ? nil : $0 } ?? "Repair procedure"
                    let project = try projects.projects(containing: investigation).first?.id
                    let steps = Attribute(.list(p.steps.map(Value.string)))
                    procedure = try create(.procedure, title: title, in: project, attributes: ["steps": steps]).detail.id
                    produced.append(procedure!)
                }
                var result = try createRepairTask(
                    for: investigation, procedure: procedure!, title: p.procedure == nil ? nil : p.title, owner: p.owner, dueAt: p.dueAt
                )
                result.produced = produced + result.produced
                return done(result, ActionDetail.repairTask)
            }

        case .verifyRepair:
            let task = try requireSelected(try one(), [.task])
            guard !p.evidence.isEmpty else {
                return .needsInput([InputField(.evidence, "Verification readings", .objects(types: [.measurement]))])
            }
            return done(try verifyRepair(task, evidence: p.evidence, summary: p.summary), ActionDetail.verification)

        case .closeInvestigation:
            let investigation = try requireSelected(try one(), [.investigation])
            guard let resolution = p.resolution, !resolution.isBlank else { return .needsInput([InputField(.resolution, "Resolution", .text)]) }
            return done(
                try closeInvestigation(investigation, resolution: resolution, verifiedBy: p.evidence.isEmpty ? nil : p.evidence), ActionDetail.object
            )

        case .generateReport:
            let investigation = try requireSelected(try one(), [.investigation])
            return done(try generateReport(for: investigation), ActionDetail.report)

        case .generateTrainingScenario:
            let investigation = try requireSelected(try one(), [.investigation])
            return done(
                try generateTrainingScenario(from: investigation, loop: p.loop, fault: p.faults.first, tests: p.tests.isEmpty ? nil : p.tests),
                ActionDetail.trainingScenario
            )

        case .extractClaim:
            let passage = try requireSelected(try one(), [.passage])
            guard let statement = p.statement, !statement.isBlank else {
                return .needsInput([
                    InputField(.statement, "Claim", .text),
                    InputField(.sourceClass, "Source class", .choice(SourceClass.allCases.map(\.rawValue)), required: false),
                ])
            }
            return done(
                try extractClaim(
                    from: passage, statement: statement, sourceClass: p.sourceClass ?? .unknown, applicability: p.applicability, confidence: p.confidence
                ),
                ActionDetail.claim
            )

        default:
            return .unsupported(Unsupported(command: command, reason: "No operation is registered for the command \(command.rawValue)."))
        }
    }

    private func simulate(_ target: ObjectID, _ p: ActionParameters) throws -> ActionOutcome {
        let result = try runSimulation(on: target, seconds: p.seconds ?? 600, faults: p.faults)
        switch result.detail {
        case .ran(let run):
            return .completed(
                ActionReport(
                    detail: .simulation(run), produced: result.produced, changed: result.changed, screen: result.screen, focus: result.focus,
                    summary: result.summary
                ))
        case .unsupported(let unsupported):
            return .unsupported(unsupported)
        }
    }

    /// `measure` and `recordMeasurement`: the selection is the test point, or
    /// an investigation (then `testPoint` names the point).
    private func measure(selection: [ObjectID], _ p: ActionParameters, command: CommandID) throws -> ActionOutcome {
        guard selection.count <= 1 else { throw ActionError.selectionSize(command, expected: "one test point or investigation", got: selection.count) }
        var testPoint = p.testPoint
        var investigation = p.investigation
        if let selected = selection.first {
            let record = try require(selected)
            if record.type == .investigation {
                investigation = investigation ?? selected
            } else {
                testPoint = testPoint ?? selected
            }
        }
        let required: [(Bool, InputField)] = [
            (testPoint == nil, InputField(.testPoint, "Test point", .object(types: [.testPoint, .component, .sensor, .equipment]))),
            (p.quantity?.isBlank ?? true, InputField(.quantity, "Quantity", .text)),
            (p.value == nil, InputField(.value, "Reading", .number)),
            (p.unit?.isBlank ?? true, InputField(.unit, "Unit", .unit)),
        ]
        if required.contains(where: \.0) {
            let optional = [
                InputField(.instrument, "Instrument", .object(types: [.instrument]), required: false),
                InputField(.truth, "Taken from", .truth(Array(Self.recordableTruth).sorted { $0.rawValue < $1.rawValue }), required: false),
                InputField(.uncertainty, "Uncertainty (±)", .number, required: false),
                InputField(.loading, "Condition", .text, required: false),
                InputField(.sampledAt, "Taken at", .date, required: false),
            ]
            return .needsInput(required.filter(\.0).map(\.1) + optional)
        }
        var model: InstrumentModel?
        if let id = p.instrument, let record = try store.object(id), record.type == .instrument {
            // An instrument without a usable spec is still cited; the reading just carries no spec uncertainty.
            model = try? InstrumentModel(record: record)
        }
        var range: ClosedRange<Double>?
        if let low = p.rangeLow, let high = p.rangeHigh {
            guard low <= high else { throw ActionError.invalidValue(.rangeLow, reason: "Range low is above range high") }
            range = low...high
        }
        let result = try recordMeasurement(
            p.quantity!, value: p.value!, unit: p.unit!, at: testPoint!, instrument: model, instrumentID: p.instrument, range: range,
            uncertainty: p.uncertainty, loading: p.loading, sampledAt: p.sampledAt, truth: p.truth ?? .observed, investigation: investigation,
            tests: p.tests
        )
        return .completed(result.erased(ActionDetail.measurement))
    }

    private func requireSelected(_ id: ObjectID, _ types: Set<ObjectType>) throws -> ObjectID {
        try require(id, is: types).id
    }
}

extension String {
    fileprivate var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

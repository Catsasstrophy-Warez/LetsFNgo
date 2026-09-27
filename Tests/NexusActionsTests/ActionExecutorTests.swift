import Foundation
import NexusCore
import NexusDocuments
import NexusInvestigation
import NexusLearning
import NexusMeasurement
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSimulation
import NexusTasks
import Testing

@testable import NexusActions

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let agent = Origin.agent(id: "diagnostic", run: nil)

/// A small level loop: project ⊃ tank ⊃ transmitter ⊃ terminal, wired
/// transmitter → terminal → card → controller → valve, plus a DMM.
private struct Bench {
    let clock = ManualClock(t0)
    let store: NexusStore
    let actions: ActionExecutor
    let project, tank, transmitter, terminal, card, controller, valve, dmm, manual: ObjectID

    init(actor: Origin = tech) throws {
        let store = try NexusStore(.inMemory, clock: clock)
        self.store = store
        actions = ActionExecutor(store: store, actor: actor, clock: clock)
        let setup = ActionExecutor(store: store, actor: tech, clock: clock)
        let recorded = Provenance(origin: tech, truth: .recorded, timestamp: t0)
        let make: (String, ObjectType) throws -> ObjectID = { title, type in
            try store.create(ObjectRecord(type: type, title: title, provenance: recorded)).id
        }
        project = try setup.create(.project, title: "Loop").detail.id
        tank = try make("Tank T-1", .equipment)
        transmitter = try make("LT-101", .sensor)
        terminal = try make("TB-4", .testPoint)
        card = try make("AI card", .component)
        controller = try make("LIC-101", .component)
        valve = try make("LV-101", .component)
        manual = try make("Manual", .document)
        let spec = AccuracySpec(percentOfReading: 0.5, digits: 2, resolution: Quantity(0.01, "V"), rangeLow: 0, rangeHigh: 60)
        dmm = try store.create(InstrumentModel.makeRecord(title: "DMM", spec: spec, provenance: recorded)).id
        try store.relate(Relationship(kind: .contains, from: project, to: tank, provenance: recorded))
        try store.relate(Relationship(kind: .contains, from: tank, to: transmitter, provenance: recorded))
        try store.relate(Relationship(kind: .contains, from: transmitter, to: terminal, provenance: recorded))
        for (from, to) in [(transmitter, terminal), (terminal, card), (card, controller), (controller, valve)] {
            try store.relate(Relationship(kind: .connectedTo, from: from, to: to, provenance: recorded))
        }
    }

    var loop: InstrumentLoop {
        InstrumentLoop(tank: tank, transmitter: transmitter, terminal: terminal, card: card, controller: controller, valve: valve)
    }

    func instrument() throws -> InstrumentModel {
        try InstrumentModel(record: try #require(try store.object(dmm)))
    }

    func volts(_ low: Double, _ high: Double) -> Prediction {
        Prediction(testPoint: terminal, quantity: "terminalVoltage", unit: "V", low: low, high: high)
    }

    /// An investigation with a low-voltage and a high-voltage hypothesis.
    func investigation() throws -> (id: ObjectID, low: ObjectID, high: ObjectID) {
        let id = try actions.startInvestigation(on: transmitter, symptom: "Reads low").detail.investigation.id
        let low = try actions.proposeHypothesis("Starved of voltage", in: id, predictions: [volts(10, 13)]).detail.id
        let high = try actions.proposeHypothesis("Transmitter failed", in: id, predictions: [volts(20, 25)]).detail.id
        return (id, low, high)
    }
}

@Suite struct InvestigationActionTests {
    @Test func startInvestigationLinksSubjectAndProjectAndProposesNothing() throws {
        let bench = try Bench()
        let result = try bench.actions.startInvestigation(on: bench.transmitter, symptom: "LT-101 reads 86.9 % while T-1 overflows")
        let investigation = result.detail.investigation.id
        #expect(result.screen == .investigation && result.focus == investigation && result.produced == [investigation])
        #expect(result.detail.projects == [bench.project], "Found through tank ⊃ transmitter")
        #expect(try bench.store.relationships(from: investigation, kind: .investigates).map(\.to) == [bench.transmitter])
        #expect(try bench.actions.projects.members(of: bench.project).map(\.id).contains(investigation))
        #expect(try bench.actions.investigations.hypotheses(of: investigation).isEmpty)
        #expect(try bench.store.events(about: investigation).map(\.kind) == [.investigationOpened])
        #expect(throws: ActionError.missingValue(.symptom)) { try bench.actions.startInvestigation(on: bench.tank, symptom: "  ") }
    }

    @Test func recordMeasurementUsesTheInstrumentSpecAndAssesses() throws {
        let bench = try Bench()
        let (investigation, low, high) = try bench.investigation()
        let tests = [
            TestOption(title: "Terminal voltage", testPoint: bench.terminal, quantity: "terminalVoltage", cost: 5),
            TestOption(title: "Loop current", testPoint: bench.terminal, quantity: "loopCurrent", cost: 3),
        ]
        let result = try bench.actions.recordMeasurement(
            "terminalVoltage", value: 12, unit: "V", at: bench.terminal, instrument: try bench.instrument(), investigation: investigation,
            tests: tests
        )
        let reading = result.detail.measurement
        #expect(abs(try #require(reading.uncertainty) - 0.08) < 1e-12, "12 V × 0.5 % + 2 × 0.01 V")
        #expect(reading.resolution == 0.01 && reading.rangeLow == 0 && reading.rangeHigh == 60)
        #expect(reading.truth == .observed && reading.provenance.origin == tech && reading.instrument == bench.dmm)
        #expect(result.detail.changes == [HypothesisChange(hypothesis: high, from: .candidate, to: .rejected)])
        #expect(Set(result.changed) == [high, investigation])
        #expect(result.detail.rankedTests.count == 2)
        #expect(result.screen == .investigation && result.focus == investigation && result.produced == [reading.id])
        #expect(try bench.actions.investigations.hypotheses(of: investigation).first { $0.id == low }?.state == .candidate)

        // Stored, linked to its test point, and on the timeline.
        #expect(try bench.store.measurement(reading.id) == reading)
        #expect(try bench.store.relationships(from: reading.id, kind: .measuredAt).map(\.to) == [bench.terminal])
        #expect(try bench.store.events(about: reading.id).filter { $0.kind == .measured }.count == 1)
        let entered = try bench.store.events(about: reading.id).filter { $0.kind == .readingEntered }
        #expect(entered.count == 1 && entered.first?.subjects.contains(investigation) == true)
        #expect(entered.first?.payload["value"] == .quantity(Quantity(12, "V")))
    }

    @Test func recordMeasurementValidatesUnitsTruthAndRange() throws {
        let bench = try Bench()
        #expect(throws: ActionError.invalidUnit("volts", reason: String(describing: UnitError.unknownUnit("volts")))) {
            try bench.actions.recordMeasurement("v", value: 1, unit: "volts", at: bench.terminal)
        }
        #expect(throws: ActionError.invalidTruth(.modeled, allowed: ActionExecutor.recordableTruth)) {
            try bench.actions.recordMeasurement("v", value: 1, unit: "V", at: bench.terminal, truth: .modeled)
        }
        #expect(throws: InstrumentError.overRange(bench.dmm, reading: 75, unit: "V")) {
            try bench.actions.recordMeasurement("v", value: 75, unit: "V", at: bench.terminal, instrument: try bench.instrument())
        }
        #expect(throws: ActionError.incompatibleInstrument(bench.dmm, readingUnit: "mA", specUnit: "V")) {
            try bench.actions.recordMeasurement("i", value: 12, unit: "mA", at: bench.terminal, instrument: try bench.instrument())
        }
        #expect(throws: ActionError.outOfRange(value: 30, low: 0, high: 25)) {
            try bench.actions.recordMeasurement("p", value: 30, unit: "psi", at: bench.terminal, range: 0...25)
        }
        // Units beyond electrical ones are accepted.
        for unit in ["rpm", "psi", "m", "kg", "L/min", "mA"] {
            _ = try bench.actions.recordMeasurement("q", value: 1, unit: unit, at: bench.card)
        }
        #expect(try bench.store.measurements(at: bench.terminal).isEmpty, "Refused readings leave nothing behind")
        #expect(try bench.store.measurements(at: bench.card).count == 6)
    }

    @Test func displayValuesAreStoredButNeverMoveHypotheses() throws {
        let bench = try Bench()
        let (investigation, _, high) = try bench.investigation()
        let result = try bench.actions.recordMeasurement(
            "terminalVoltage", value: 12, unit: "V", at: bench.terminal, truth: .display, investigation: investigation
        )
        #expect(result.detail.measurement.truth == .display)
        #expect(result.detail.measurement.provenance.method == "read from display")
        #expect(result.detail.changes.isEmpty && result.detail.assessments.allSatisfy { !$0.counted })
        #expect(try bench.actions.investigations.hypotheses(of: investigation).first { $0.id == high }?.state == .candidate)
    }

    @Test func confirmAndRejectArePeopleOnly() throws {
        let bench = try Bench()
        let (investigation, low, high) = try bench.investigation()
        let robot = ActionExecutor(store: bench.store, actor: agent, clock: bench.clock)
        #expect(throws: InvestigationError.requiresHuman(agent)) { try robot.rejectHypothesis(high, reason: "no") }
        #expect(throws: InvestigationError.unsupported(low)) { try bench.actions.confirmHypothesis(low) }

        let rejected = try bench.actions.rejectHypothesis(high, reason: "Transmitter swapped, no change")
        #expect(rejected.detail.state == .rejected && rejected.focus == investigation)
        _ = try bench.actions.recordMeasurement(
            "terminalVoltage", value: 12, unit: "V", at: bench.terminal, uncertainty: 0.1, investigation: investigation
        )
        #expect(throws: InvestigationError.requiresHuman(agent)) { try robot.confirmHypothesis(low) }
        let confirmed = try bench.actions.confirmHypothesis(low)
        #expect(confirmed.detail.state == .confirmed)
        let kinds = try bench.store.events(about: investigation).map(\.kind)
        #expect(kinds.contains(.hypothesisRejected) && kinds.contains(.hypothesisConfirmed))
    }

    @Test func repairTasksNeedACauseAndVerificationEvidence() throws {
        let bench = try Bench()
        let (investigation, low, _) = try bench.investigation()
        let procedure = try bench.actions.create(.procedure, title: "Re-terminate TB-4", in: bench.project).detail.id
        #expect(throws: ActionError.causeNotConfirmed(investigation)) {
            try bench.actions.createRepairTask(for: investigation, procedure: procedure)
        }
        let before = try bench.actions.recordMeasurement(
            "terminalVoltage", value: 12, unit: "V", at: bench.terminal, uncertainty: 0.1, investigation: investigation
        )
        _ = try bench.actions.confirmHypothesis(low)
        #expect(throws: ActionError.wrongType(bench.card, expected: [.procedure], got: .component)) {
            try bench.actions.createRepairTask(for: investigation, procedure: bench.card)
        }

        bench.clock.advance(by: 60)
        let created = try bench.actions.createRepairTask(for: investigation, procedure: procedure)
        let task = created.detail
        #expect(task.title == "Repair: Re-terminate TB-4" && task.status == .open)
        #expect(task.successCondition?.contains("reading taken after this task was created") == true)
        #expect(task.requiredEvidence == [.attached(.measurement)])
        #expect(try bench.actions.tasks.tasks(in: bench.project).map(\.id).contains(task.id))
        #expect(try bench.store.relationships(from: task.id, kind: .follows).map(\.to) == [procedure])
        #expect(Set(try bench.store.relationships(from: investigation, kind: .produced).map(\.to)) == [procedure, task.id])
        #expect(try bench.store.events(about: task.id).map(\.kind) == [.repair])
        #expect(try !bench.actions.tasks.gate(for: task.id).isOpen)

        #expect(throws: ActionError.evidenceBeforeRepair(before.detail.measurement.id)) {
            try bench.actions.verifyRepair(task.id, evidence: [before.detail.measurement.id])
        }
        let chore = try bench.actions.create(.task, title: "Sweep up").detail.id
        #expect(throws: ActionError.notARepairTask(chore)) { try bench.actions.verifyRepair(chore, evidence: []) }
        bench.clock.advance(by: 600)
        let after = try bench.actions.recordMeasurement("terminalVoltage", value: 19, unit: "V", at: bench.terminal, uncertainty: 0.1)
        let verified = try bench.actions.verifyRepair(task.id, evidence: [after.detail.measurement.id])
        #expect(verified.detail.task.status == .done && verified.detail.investigation == investigation)
        #expect(verified.detail.event.kind == .repairVerified)

        let closed = try bench.actions.closeInvestigation(investigation, resolution: "Re-terminated")
        #expect(closed.detail.attributes["resolution"]?.provenance?.dependencies == [after.detail.measurement.id])
        #expect(try bench.store.events(about: investigation).last?.kind == .investigationClosed)
    }
}

@Suite struct ObjectActionTests {
    @Test func createGoesThroughTheOwningRuntime() throws {
        let bench = try Bench()
        let task = try bench.actions.create(.task, title: "Order spare", in: bench.project)
        #expect(try TaskItem(record: task.detail).status == .open)
        #expect(task.screen == .taskWorkflow)
        let investigation = try bench.actions.create(.investigation, title: "Noise on AI card")
        #expect(investigation.detail.attributes["status"]?.value == .string("open"))
        let note = try bench.actions.create("note", title: "Check grounding", in: bench.project, attributes: ["body": Attribute(.string("x"))])
        #expect(note.detail.provenance.origin == tech && note.detail.provenance.truth == .recorded)
        let members = try bench.actions.projects.members(of: bench.project).map(\.id)
        #expect(members.contains(task.detail.id) && members.contains(note.detail.id))
        #expect(try bench.store.events(about: note.detail.id).map(\.kind) == [.userEdit])
        #expect(throws: ActionError.missingValue(.title)) { try bench.actions.create(.task, title: "") }
    }

    @Test func linkIsIdempotentAndRefusesSelfLinks() throws {
        let bench = try Bench()
        let first = try bench.actions.link(bench.manual, bench.transmitter, kind: .represents)
        let second = try bench.actions.link(bench.manual, bench.transmitter, kind: .represents)
        #expect(first.detail.id == second.detail.id)
        #expect(try bench.store.relationships(from: bench.manual, kind: .represents).count == 1)
        #expect(throws: ActionError.invalidValue(.target, reason: "An object cannot be linked to itself")) {
            try bench.actions.link(bench.manual, bench.manual, kind: .represents)
        }
    }

    @Test func groupContainsTheMembersAndJoinsTheirProject() throws {
        let bench = try Bench()
        let projects = bench.actions.projects
        try projects.add(bench.card, to: bench.project, by: tech)
        try projects.add(bench.controller, to: bench.project, by: tech)
        let group = try bench.actions.group([bench.card, bench.controller], title: "Control cabinet")
        #expect(group.detail.type == .collection && group.screen == .collection)
        #expect(Set(try bench.store.relationships(from: group.detail.id, kind: .contains).map(\.to)) == [bench.card, bench.controller])
        #expect(try projects.projects(containing: group.detail.id).map(\.id) == [bench.project])
        #expect(try projects.projects(containing: bench.card).map(\.id) == [bench.project], "Members stay where they were")
    }

    @Test func compareKeepsTruthClassesApart() throws {
        let bench = try Bench()
        let observed = try bench.actions.recordMeasurement("terminalVoltage", value: 12, unit: "V", at: bench.terminal, uncertainty: 0.1)
        let simulated = try bench.actions.runSimulation(on: bench.terminal)
        guard case .ran(let run) = simulated.detail else { Issue.record("Loop not simulated"); return }
        let modeled = try #require(run.modeled.first { $0.quantityName == "terminalVoltage" })
        let comparison = try bench.actions.compare([observed.detail.measurement.id, modeled.id]).detail
        let value = try #require(comparison.rows.first { $0.attribute == "measurement.value" })
        #expect(value.cells.map { $0?.truth } == [.observed, .modeled])
        #expect(value.differs && value.mixedTruth)
        let unit = try #require(comparison.rows.first { $0.attribute == "measurement.unit" })
        #expect(!unit.differs && unit.mixedTruth, "Equal values of different truth are equal, but both classes are kept")
        #expect(comparison.rows.prefix(2).map(\.attribute) == ["title", "type"])
        #expect(comparison.objects.map(\.truth) == [.observed, .modeled])
        #expect(throws: ActionError.selectionSize(.compare, expected: "two or more", got: 1)) { try bench.actions.compare([bench.card]) }
    }

    @Test func exportKeepsProvenanceAndTruth() throws {
        let bench = try Bench()
        let reading = try bench.actions.recordMeasurement(
            "terminalVoltage", value: 12, unit: "V", at: bench.terminal, instrument: try bench.instrument()
        ).detail.measurement
        let ids = [bench.dmm, reading.id]

        let json = try bench.actions.export(ids, format: .json).detail
        #expect(json.mediaType == "application/json")
        let document = try #require(try JSONSerialization.jsonObject(with: json.data) as? [String: Any])
        let objects = try #require(document["objects"] as? [[String: Any]])
        #expect(objects.count == 2)
        let measurement = try #require(objects[1]["measurement"] as? [String: Any])
        #expect(measurement["value"] as? Double == 12 && measurement["unit"] as? String == "V")
        let provenance = try #require(measurement["provenance"] as? [String: Any])
        #expect(provenance["truth"] as? String == "observed" && provenance["origin"] as? String == "user:tech-1")
        let accuracy = try #require((objects[0]["attributes"] as? [[String: Any]])?.first { $0["key"] as? String == "accuracy" })
        #expect((accuracy["provenance"] as? [String: Any])?["truth"] as? String == "recorded")
        #expect(((accuracy["value"] as? [String: Any])?["resolution"] as? [String: Any])?["unit"] as? String == "V")

        let csv = String(decoding: try bench.actions.export(ids, format: .csv).detail.data, as: UTF8.self)
        let lines = csv.split(separator: "\r\n").map(String.init)
        #expect(lines[0] == "object_id,object_type,object_title,field,value,unit,truth,origin,timestamp,method,confidence,revision")
        let valueRow = try #require(lines.first { $0.contains(",measurement.value,") })
        #expect(valueRow.contains(",12.0,V,observed,user:tech-1,"))
        #expect(lines.contains { $0.contains(",measurement.uncertainty,0.08") })
    }

    @Test func analyzeSummarizesWithoutWriting() throws {
        let bench = try Bench()
        _ = try bench.actions.recordMeasurement("terminalVoltage", value: 12, unit: "V", at: bench.terminal)
        _ = try bench.actions.startInvestigation(on: bench.terminal, symptom: "Low")
        let changes = bench.store.latestChangeSequence
        let analysis = try #require(try bench.actions.analyze([bench.terminal]).detail.first)
        #expect(analysis.latestMeasurements.count == 1)
        #expect(analysis.openInvestigations.count == 1)
        #expect(analysis.relationships[.connectedTo] == 2)
        #expect(bench.store.latestChangeSequence == changes)
    }
}

@Suite struct SimulationActionTests {
    @Test func runSimulationFindsTheLoopInTheGraph() throws {
        let bench = try Bench()
        let result = try bench.actions.runSimulation(on: bench.tank)
        guard case .ran(let run) = result.detail else { Issue.record("Expected a run"); return }
        #expect(run.loop == bench.loop)
        #expect(run.modeled.map(\.quantityName) == ["terminalVoltage", "loopCurrent", "measuredLevel", "level"])
        #expect(run.modeled.allSatisfy { $0.truth == .modeled })
        #expect(abs(try #require(run.modeled.first).value.value - 19.03) < 0.1, "The healthy twin's terminal voltage")
        #expect(run.values["level"] != nil)
        #expect(result.screen == .simulation && result.produced == run.modeled.map(\.id))
        // The store adds its own `measured` event for each modeled reading.
        #expect(try bench.store.events(about: bench.tank).map(\.kind).filter { $0 != .measured } == [.simulated])
    }

    @Test func faultsAreInjectedOnlyWhenAsked() throws {
        let bench = try Bench()
        let fault = SimulatedFault(parameter: bench.loop.contactOhms, value: 400, summary: "Corroded terminal")
        guard case .ran(let run) = try bench.actions.runSimulation(on: bench.terminal, faults: [fault]).detail else {
            Issue.record("Expected a run")
            return
        }
        #expect(abs(run.values["terminalVoltage"]! - 12) < 0.1)
        #expect(try bench.store.events(about: bench.terminal).map(\.kind).filter { $0 != .measured } == [.faultInjected, .simulated])
    }

    @Test func unsupportedObjectsSaySo() throws {
        let bench = try Bench()
        let events = try bench.store.timeline().count
        guard case .unsupported(let reason) = try bench.actions.runSimulation(on: bench.manual).detail else {
            Issue.record("A document cannot be simulated")
            return
        }
        #expect(reason.type == .document && reason.reason.contains("not available for a document"))
        let lonely = try bench.store.create(
            ObjectRecord(
                type: .component, title: "Spare relay", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
            )
        ).id
        guard case .unsupported = try bench.actions.runSimulation(on: lonely).detail else { Issue.record("Not in a loop"); return }
        guard case .unsupported = try bench.actions.trace(from: lonely).detail else { Issue.record("Nothing to trace"); return }
        guard case .unsupported = try bench.actions.trace(from: bench.manual).detail else { Issue.record("Not physical"); return }
        #expect(try bench.store.timeline().count == events)
    }

    @Test func traceFollowsTheSignal() throws {
        let bench = try Bench()
        guard case .traced(let trace) = try bench.actions.trace(from: bench.card).detail else { Issue.record("Expected a trace"); return }
        #expect(trace.upstream.map(\.id) == [bench.terminal, bench.transmitter])
        #expect(trace.downstream.map(\.id) == [bench.controller, bench.valve])
        #expect(trace.loop == bench.loop)
        guard case .traced(let fromTerminal) = try bench.actions.trace(from: bench.terminal).detail else { return }
        #expect(fromTerminal.containers == [bench.transmitter, bench.tank], "Containers, not the project")
    }

    @Test func registeredBindingsWinAndFeedTrainingScenarios() throws {
        let bench = try Bench()
        let fault = SimulatedFault(parameter: bench.loop.contactOhms, value: 400, summary: "Corroded terminal")
        var actions = bench.actions
        actions.loops = [LoopBinding(loop: bench.loop, faults: [fault])]
        #expect(try actions.binding(for: bench.valve)?.faults == [fault])
        let (investigation, low, _) = try bench.investigation()
        #expect(throws: LearningError.investigationNotResolved(investigation)) {
            try actions.generateTrainingScenario(from: investigation)
        }
        _ = try actions.recordMeasurement("terminalVoltage", value: 12, unit: "V", at: bench.terminal, uncertainty: 0.1, investigation: investigation)
        _ = try actions.confirmHypothesis(low)
        let scenario = try actions.generateTrainingScenario(from: investigation).detail
        #expect(scenario.fault == fault && scenario.cause == "Starved of voltage")
    }
}

@Suite struct PerformTests {
    @Test func everyCommandMapsToAnOperation() throws {
        let bench = try Bench()
        for command in CommandID.all {
            let outcome: ActionOutcome
            do {
                outcome = try bench.actions.perform(command, selection: [], parameters: ActionParameters())
            } catch {
                continue  // Selection errors are fine; an unmapped command would not throw.
            }
            if case .unsupported(let reason) = outcome {
                #expect(!reason.reason.hasPrefix("No operation is registered"), "\(command) is not mapped")
            }
        }
        let unknown = try bench.actions.perform(CommandID(rawValue: "teleport"), selection: [])
        #expect(unknown == .unsupported(Unsupported(command: CommandID(rawValue: "teleport"), reason: "No operation is registered for the command teleport.")))
    }

    @Test func missingInputIsAskedFor() throws {
        let bench = try Bench()
        let events = try bench.store.timeline().count
        guard case .needsInput(let fields) = try bench.actions.perform(.recordMeasurement, selection: [bench.terminal]) else {
            Issue.record("Expected a form")
            return
        }
        #expect(fields.filter(\.required).map(\.field) == [.quantity, .value, .unit])
        #expect(fields.contains { $0.field == .instrument && !$0.required })

        let investigate = try bench.actions.perform(.investigate, selection: [bench.transmitter])
        #expect(investigate == .needsInput([InputField(.symptom, "Symptom", .text)]))
        guard case .needsInput(let create) = try bench.actions.perform(.create, selection: []) else { return }
        #expect(create.map(\.field) == [.type, .title])
        guard case .needsInput = try bench.actions.perform(.export, selection: [bench.card, bench.valve]) else {
            Issue.record("Export needs a format")
            return
        }
        #expect(try bench.store.timeline().count == events, "Asking for input writes nothing")
    }

    @Test func performRecordsAMeasurementFromAnInvestigation() throws {
        let bench = try Bench()
        let (investigation, _, high) = try bench.investigation()
        let outcome = try bench.actions.perform(
            .recordMeasurement, selection: [investigation],
            parameters: .with {
                $0.testPoint = bench.terminal
                $0.quantity = "terminalVoltage"
                $0.value = 12
                $0.unit = "V"
                $0.instrument = bench.dmm
            })
        let report = try #require(outcome.report)
        guard case .measurement(let result) = report.detail else { Issue.record("Expected a measurement"); return }
        #expect(result.changes.map(\.hypothesis) == [high])
        #expect(report.screen == .investigation && report.focus == investigation)
    }

    @Test func unsupportedTargetsComeBackAsValues() throws {
        let bench = try Bench()
        guard case .unsupported(let reason) = try bench.actions.perform(.simulate, selection: [bench.manual]) else {
            Issue.record("Expected unsupported")
            return
        }
        #expect(reason.command == .simulate && reason.subject == bench.manual)
        #expect(throws: ActionError.wrongType(bench.card, expected: [.hypothesis], got: .component)) {
            try bench.actions.perform(.confirmHypothesis, selection: [bench.card])
        }
    }

    @Test func importAndCiteADocument() throws {
        let bench = try Bench()
        let text = "# Manual\n\nMinimum lift-off voltage is 12 V.\n"
        let imported = try #require(
            try bench.actions.perform(
                .create, selection: [],
                parameters: .with {
                    $0.type = .document
                    $0.title = "LT-101 manual"
                    $0.data = Data(text.utf8)
                    $0.mediaType = "text/markdown"
                    $0.project = bench.project
                }
            ).report)
        guard case .document(let ingest) = imported.detail else { Issue.record("Expected a document"); return }
        #expect(imported.screen == .document && ingest.passages.count == 1)
        let cited = try #require(
            try bench.actions.perform(
                .extractClaim, selection: [ingest.passages[0].id],
                parameters: .with {
                    $0.statement = "Needs 12 V"
                    $0.sourceClass = .primary
                }
            ).report)
        guard case .claim(let claim) = cited.detail else { Issue.record("Expected a claim"); return }
        #expect(claim.sources == [ingest.document.id] && claim.provenance.truth == .claimed)
    }
}

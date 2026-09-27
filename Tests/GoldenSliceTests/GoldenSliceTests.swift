import Foundation
import NexusActions
import NexusCore
import NexusDocuments
import NexusGraph
import NexusInvestigation
import NexusLearning
import NexusMeasurement
import NexusModel
import NexusPersistence
import NexusProjects
import NexusReality
import NexusSearch
import NexusSimulation
import NexusTasks
import Testing

/// The Golden Vertical Slice from docs/BUILD_PLAN.md §D, headless.
///
/// Level loop LT-101: a corroded terminal at TB-4 adds 400 Ω, the transmitter
/// runs out of compliance voltage near the top of its range, the reading
/// clamps at 86.9 % and the PI controller overflows the tank.
///
/// Training-world convention: the faulted simulation plays the field, so a
/// reading taken from it by a (virtual) instrument is observed truth with an
/// instrument origin. A healthy twin run gives the modeled expectation.
@Suite struct GoldenSliceTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let tech = Origin.user(id: "tech-1")
    /// ±(0.5 % of reading + 2 digits), 0.01 V resolution, 0–60 V range.
    static let dmmSpec = AccuracySpec(percentOfReading: 0.5, digits: 2, resolution: Quantity(0.01, "V"), rangeLow: 0, rangeHigh: 60)
    /// ±(0.2 % of reading + 2 digits), 0.01 mA resolution, 0–25 mA range.
    static let clampSpec = AccuracySpec(percentOfReading: 0.2, digits: 2, resolution: Quantity(0.01, "mA"), rangeLow: 0, rangeHigh: 25)
    static let manualText = """
        # LT-101 installation manual

        Mount the housing vertically.

        ## Power

        Supply at the terminals must stay above the 12 V minimum lift-off voltage.
        """

    @Test func instrumentLoopDiagnosisEndToEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ManualClock(Self.t0)
        var world = try World(url: url, clock: clock)
        let tech = self.tech
        func recorded() -> Provenance { Provenance(origin: tech, truth: .recorded, timestamp: clock.now()) }

        // 1. Project.
        let project = try world.projects.createProject(
            title: "LT-101 level loop", mission: "Restore reliable level control on T-1", by: tech
        ).id

        // 2. Equipment and loop topology as objects and relationships.
        func object(_ title: String, _ type: ObjectType, _ attributes: [String: Attribute] = [:]) throws -> ObjectID {
            try world.store.create(ObjectRecord(type: type, title: title, attributes: attributes, provenance: recorded())).id
        }
        let tank = try object("Tank T-1", .equipment)
        let transmitter = try object("LT-101 level transmitter", .sensor, ["tag": Attribute(.string("LT-101"))])
        let terminal = try object("TB-4 terminals 7/8", .testPoint)
        let card = try object("AI card slot 3 ch 0", .component)
        let controller = try object("LIC-101 level controller", .component)
        let valve = try object("LV-101 inlet valve", .component)
        var dmmRecord = InstrumentModel.makeRecord(title: "Virtual DMM", spec: Self.dmmSpec, provenance: recorded())
        dmmRecord.attributes["virtual"] = Attribute(.bool(true))
        let dmm = try world.store.create(dmmRecord).id
        let clampMeter = try world.store.create(InstrumentModel.makeRecord(
            title: "Virtual loop clamp meter", spec: Self.clampSpec, provenance: recorded()
        )).id
        for id in [tank, card, controller, valve] {
            try world.projects.add(id, to: project, by: tech)
        }
        try world.store.relate(Relationship(kind: .contains, from: tank, to: transmitter, provenance: recorded()))
        try world.store.relate(Relationship(kind: .contains, from: transmitter, to: terminal, provenance: recorded()))
        for (from, to) in [(transmitter, terminal), (terminal, card), (card, controller), (controller, valve)] {
            try world.store.relate(Relationship(kind: .connectedTo, from: from, to: to, provenance: recorded()))
        }

        // 3. Source document and a cited claim, through the document library:
        // the bytes are a blob, passages are objects, and the claim quotes one.
        let ingest = try world.documents.ingest(
            Data(Self.manualText.utf8), title: "LT-101 installation manual", mediaType: "text/markdown", in: project, by: tech
        )
        let manual = ingest.document.id
        let liftOff = try #require(ingest.passages.first { $0.text.contains("lift-off") })
        #expect(liftOff.section == "Power")
        let claim = try world.documents.extractClaim(
            from: liftOff.id, statement: "LT-101 needs at least 12 V at its terminals to regulate loop current", sourceClass: .primary,
            by: tech
        )
        #expect(claim.sources == [manual] && claim.provenance.truth == .claimed)
        #expect(claim.passages == [try world.documents.sourceText(of: liftOff)], "The claim quotes the exact bytes")
        #expect(try world.documents.claims(citing: liftOff.id).map(\.id) == [claim.id])
        #expect(try world.documents.search("lift-off").first?.document == manual)
        try world.projects.add(manual, to: project, by: tech)

        // 4. One identity from project, search and graph.
        let viaSearch = try world.search.search(SearchQuery("LT-101 transmitter", scope: project)).first?.id
        let viaProject = try world.projects.members(of: project, types: [.sensor], transitive: true).first?.id
        let viaGraph = try world.graph.shortestPath(from: valve, to: transmitter)?.last?.neighbor
        let scene = try SceneBuilder.build(root: tank, graph: world.graph)
        let viaSpatial = scene.entity(for: transmitter).flatMap(scene.object(for:))
        #expect(viaSearch == transmitter && viaProject == transmitter && viaGraph == transmitter && viaSpatial == transmitter)

        // 5. Simulated fault in the field, alongside a healthy twin.
        let loop = InstrumentLoop(tank: tank, transmitter: transmitter, terminal: terminal, card: card, controller: controller, valve: valve)
        let field = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        let twin = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        let fault = SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded terminal at TB-4")
        field.inject(fault)
        try world.store.record(Event(
            at: clock.now(), kind: .faultInjected, subjects: [terminal], summary: fault.summary,
            payload: ["contactOhms": .double(400)], provenance: Provenance(origin: .simulation(run: field.run), truth: .modeled, timestamp: clock.now())
        ))
        try field.start()
        try twin.start()
        try field.run(for: 600)
        try twin.run(for: 600)
        clock.advance(by: 600)
        #expect(try field.value(loop.overflowing) == 1)

        func observe(_ key: StateKey, _ unit: String, loading: String? = nil, uncertainty: Double) throws -> MeasurementRecord {
            let reading = MeasurementRecord(
                quantityName: key.quantity, value: Quantity(try field.value(key), unit), uncertainty: uncertainty,
                testPoint: key.object, instrument: dmm, loading: loading, sampledAt: clock.now(),
                provenance: Provenance(origin: .instrument(id: dmm), truth: .observed, timestamp: clock.now(), method: "virtual DMM")
            )
            try world.store.add(reading)
            return reading
        }

        // 6. Display truth from the HMI, next to what the field really does,
        // entered through the executor as the UI will.
        let hmi = try world.actions.recordMeasurement(
            "measuredLevel", value: try field.value(loop.measuredLevel), unit: "%", at: card, truth: .display
        ).detail.measurement
        let trueLevel = try field.value(loop.level)
        #expect(hmi.value.value < 87 && trueLevel == 100, "HMI shows 86.9 % while the tank is full")
        #expect(hmi.truth == .display && hmi.provenance.method == "read from display")
        // An observed reading with an instrument model: its uncertainty comes from the spec.
        let clamp = try InstrumentModel(record: try #require(try world.store.object(clampMeter)))
        let current = try world.actions.recordMeasurement(
            "loopCurrent", value: try field.value(loop.loopCurrent), unit: "mA", at: terminal, instrument: clamp, loading: "high level"
        ).detail.measurement
        #expect(current.truth == .observed && current.instrument == clampMeter)
        let clampLimit: Double = abs(current.value.value) * 0.002 + 0.02
        let currentUncertainty: Double = try #require(current.uncertainty)
        #expect(abs(currentUncertainty - clampLimit) < 1e-12, "±(0.2 % + 2 digits of 0.01 mA)")
        #expect(Set(try world.store.measurements(at: card).map(\.truth)) == [.display], "Display truth is never relabeled")

        // 7. Investigation with four competing hypotheses.
        let started = try world.actions.startInvestigation(on: [transmitter, tank], symptom: "LT-101 reads 86.9 % while T-1 overflows")
        let investigation = started.detail.investigation.id
        #expect(started.detail.projects == [project], "Found through tank ⊃ transmitter")
        try world.projects.add(investigation, to: project, by: tech)

        // 4 (continued). The investigation view reaches the same transmitter.
        let viaInvestigation = try world.store.relationships(from: investigation, kind: .investigates).map(\.to)
        #expect(viaInvestigation.first == transmitter && viaInvestigation.first == viaSearch)
        #expect(try world.actions.open(investigation).screen == .investigation)
        func volts(_ low: Double, _ high: Double) -> Prediction {
            Prediction(testPoint: terminal, quantity: "terminalVoltage", unit: "V", low: low, high: high, condition: "high level")
        }
        func span(_ low: Double, _ high: Double) -> Prediction {
            Prediction(testPoint: card, quantity: "configuredSpan", unit: "%", low: low, high: high)
        }
        let failed = try world.investigations.propose(
            "Transmitter failed and no longer draws loop current", in: investigation,
            predictions: [volts(22, 24.5), span(99.9, 100.1)], by: tech
        )
        let compliance = try world.investigations.propose(
            "Excess loop resistance starves the transmitter of compliance voltage", in: investigation,
            predictions: [volts(10.5, 12.5), span(99.9, 100.1)], dependsOn: [claim.id], by: tech
        )
        let cardFault = try world.investigations.propose(
            "AI card channel reads low", in: investigation,
            predictions: [volts(17, 21.9), span(99.9, 100.1)], by: tech
        )
        let scaling = try world.investigations.propose(
            "Channel scaled 0–120 % instead of 0–100 %", in: investigation,
            predictions: [volts(17, 21.9), span(119.9, 120.1)], by: tech
        )

        // 8. Discriminating tests. The cheap configuration check goes first;
        // after it, the loaded terminal voltage splits the rest three ways.
        let options = [
            TestOption(title: "Read channel span from controller", testPoint: card, quantity: "configuredSpan", cost: 2),
            TestOption(title: "Terminal voltage at TB-4 under load", testPoint: terminal, quantity: "terminalVoltage", condition: "high level", cost: 5),
            TestOption(title: "Measure 24 V bus with covers off", testPoint: card, quantity: "busVoltage", cost: 1, safety: .hazardous),
        ]
        let first = try world.investigations.rankTests(options, for: investigation)
        #expect(first.map(\.option.title) == ["Read channel span from controller", "Terminal voltage at TB-4 under load"])

        let spanReading = MeasurementRecord(
            quantityName: "configuredSpan", value: Quantity(100, "%"), testPoint: card, sampledAt: clock.now(),
            provenance: Provenance(origin: .importer(source: card), truth: .recorded, timestamp: clock.now(), method: "controller tag read")
        )
        try world.store.add(spanReading)
        try world.investigations.assess(spanReading.id, in: investigation, by: tech)

        let second = try world.investigations.rankTests(options, for: investigation)
        #expect(second.first?.option.title == "Terminal voltage at TB-4 under load")
        #expect(second.first?.outcomes.count == 3)

        let dmmModel = try InstrumentModel(record: try #require(try world.store.object(dmm)))
        let measured = try world.actions.recordMeasurement(
            "terminalVoltage", value: try field.value(loop.terminalVoltage), unit: "V", at: terminal, instrument: dmmModel,
            loading: "high level", investigation: investigation, tests: options
        )
        let loaded = measured.detail.measurement
        #expect(abs(try #require(loaded.uncertainty) - 0.08) < 1e-9, "±(0.5 % + 2 digits) at 12 V")
        // The span read already ruled out the scaling error.
        #expect(Set(measured.detail.changes.map(\.hypothesis)) == [failed.id, cardFault.id])
        #expect(measured.detail.changes.allSatisfy { $0.from == .candidate && $0.to == .rejected })
        #expect(measured.detail.rankedTests.count == 2)
        let states = Dictionary(uniqueKeysWithValues: try world.investigations.hypotheses(of: investigation).map { ($0.id, $0.state) })
        #expect(states == [failed.id: .rejected, compliance.id: .candidate, cardFault.id: .rejected, scaling.id: .rejected])

        // 9. First divergence: observed terminal voltage against the twin.
        let expected = try twin.measurement(of: loop.terminalVoltage, unit: "V", at: clock.now(), method: "healthy twin")
        try world.store.add(expected)
        let modeledOnly = try world.investigations.assess(expected.id, in: investigation, by: tech)
        #expect(modeledOnly.allSatisfy { !$0.counted })
        let divergencePath = [loop.terminalVoltage, loop.loopCurrent, loop.measuredLevel, loop.level]
        let simulated = try #require(DivergenceDetector.firstDivergence(
            reference: twin.history, actual: field.history, signalPath: divergencePath, defaultTolerance: 0.05
        ))
        #expect(simulated.key == loop.terminalVoltage && simulated.tick == 0)
        try world.investigations.recordFirstDivergence(
            in: investigation, observed: loaded.id, expected: expected.id,
            summary: "Terminal voltage at TB-4 is pinned at lift-off (12.0 V) where the twin expects 19.0 V", by: tech
        )
        #expect(abs(loaded.value.value - 12) < 1e-6)
        #expect(abs(expected.value.value - 19.03) < 0.1)

        // The 3D view shows the twin's value and the meter's value side by side, labeled.
        let atTerminal = (OverlayBuilder.modeled(twin.history.last!, in: scene) + (try OverlayBuilder.measured(in: scene, store: world.store)))
            .filter { $0.entity == scene.entity(for: terminal) && $0.quantity == "terminalVoltage" }
        #expect(Set(atTerminal.map(\.truth)) == [.modeled, .observed])

        #expect(throws: InvestigationError.requiresHuman(.agent(id: "diag", run: nil))) {
            try world.investigations.confirm(compliance.id, in: investigation, by: .agent(id: "diag", run: nil))
        }
        try world.investigations.confirm(compliance.id, in: investigation, by: tech)

        // 10. Repair procedure and task.
        let procedure = try object("Clean and re-terminate TB-4 7/8", .procedure, [
            "steps": Attribute(.list([
                .string("Lock out the loop at the AI card"), .string("Remove, clean and re-terminate TB-4 7/8"),
                .string("Measure loop resistance"), .string("Restore and verify a 4–20 mA sweep"),
            ])),
        ])
        let repair = try world.actions.createRepairTask(for: investigation, procedure: procedure, title: "Repair TB-4 on LT-101 loop")
        let task = repair.detail.id
        #expect(repair.detail.status == .open && repair.detail.successCondition != nil)
        #expect(try world.tasks.tasks(in: project).map(\.id).contains(task))
        #expect(try world.tasks.gate(for: task).missingEvidence == [.attached(.measurement)], "Not done until verified")
        #expect(Set(try world.store.relationships(from: investigation, kind: .produced).map(\.to)) == [procedure, task])
        #expect(try world.store.relationships(from: task, kind: .follows).map(\.to) == [procedure])

        // 11. Repair in the field and verify.
        field.clear(fault.id)
        try field.run(for: 900)
        clock.advance(by: 900)
        let after = try observe(loop.terminalVoltage, "V", loading: "high level", uncertainty: 0.1)
        let settled = try observe(loop.level, "%", uncertainty: 0.5)
        #expect(after.value.value > 18 && abs(settled.value.value - 90) < 0.5)
        #expect(try field.value(loop.overflowing) == 0)
        let verification = try world.actions.verifyRepair(task, evidence: [after.id, settled.id])
        #expect(verification.detail.task.status == .done)
        #expect(try world.tasks.task(task).status == .done)
        try world.investigations.close(
            investigation, resolution: "Terminal re-made; loop voltage and level verified", verifiedBy: [after.id, settled.id], by: tech
        )

        // 12. Report with lineage for every figure.
        let report = try world.investigations.generateReport(for: investigation, by: tech)
        guard case .string(let body)? = report.attributes["body"]?.value else { Issue.record("No report body"); return }
        let lineage = Set(try world.store.relationships(from: report.id, kind: .derivedFrom).map(\.to))
        for id in [loaded.id, expected.id, spanReading.id, claim.id, manual, compliance.id, after.id, settled.id] {
            #expect(lineage.contains(id), "Report must cite \(id)")
        }
        #expect(Set(report.provenance.dependencies) == lineage)
        #expect(body.contains("confirmed**: Excess loop resistance"))
        #expect(body.contains("relies on: LT-101 needs at least 12 V"))
        #expect(body.contains("## Verification\n- terminalVoltage = 19.03 V (observed, high level)"))

        // 13. Training scenario from the case, replayable and gradable.
        let learning = LearningRuntime(store: world.store, clock: clock)
        let scenario = try learning.makeScenario(from: investigation, loop: loop, fault: fault, tests: options, by: tech)
        #expect(scenario.cause == compliance.statement)
        #expect(scenario.expertPath == ["Read channel span from controller", "Terminal voltage at TB-4 under load"])
        #expect(scenario.choices.count == 4)
        let replay = try scenario.makeField()
        #expect(abs(try replay.value(loop.terminalVoltage) - loaded.value.value) < 1e-9, "Replay reproduces the case")
        let learner = Origin.user(id: "apprentice-7")
        let expert = try learning.grade(scenario.id, learner: learner, testsRun: scenario.expertPath, diagnosis: scenario.cause)
        #expect(expert.score == 100)
        let reckless = try learning.grade(
            scenario.id, learner: learner, testsRun: ["Measure 24 V bus with covers off"], diagnosis: failed.statement
        )
        #expect(reckless.score == 0 && reckless.jumpedToConclusion && reckless.hazardousTests.count == 1)
        // Repeating every test doubles the cost: half efficiency, 60 + 15 + 10.
        let repetitive = try learning.grade(
            scenario.id, learner: learner, testsRun: scenario.expertPath + scenario.expertPath, diagnosis: scenario.cause
        )
        #expect(repetitive.correctDiagnosis && abs(repetitive.efficiency - 0.5) < 1e-9 && repetitive.score == 85)
        let decisive = try learning.grade(
            scenario.id, learner: learner, testsRun: ["Terminal voltage at TB-4 under load"], diagnosis: scenario.cause
        )
        // The loaded voltage alone contradicts every rival here, so skipping the span read costs nothing.
        #expect(decisive.correctDiagnosis && abs(decisive.efficiency - 1) < 1e-9 && decisive.score == 100)

        // 14. Save, reload, and compare everything.
        let before = try Snapshot(of: world.store, project: project, investigation: investigation, report: report.id, graph: world.graph)
        world = try World(url: url, clock: clock)
        let reloaded = try Snapshot(of: world.store, project: project, investigation: investigation, report: report.id, graph: world.graph)
        #expect(reloaded == before)
        #expect(reloaded.hypotheses[compliance.id] == .confirmed)
        #expect(reloaded.timeline.contains { $0.kind == .firstDivergence })
        let measuredEvents = reloaded.timeline.filter { $0.kind == .measured }
        for reading in [hmi.id, current.id, loaded.id] {
            #expect(measuredEvents.contains { $0.subjects.contains(reading) }, "Timeline has the measurement event for \(reading)")
        }
        let kinds = Set(reloaded.timeline.map(\.kind))
        for kind in [EventKind.investigationOpened, .hypothesisRejected, .hypothesisConfirmed, .repair, .repairVerified, .investigationClosed] {
            #expect(kinds.contains(kind), "Timeline has \(kind)")
        }
        #expect(try LearningRuntime(store: world.store).scenario(scenario.id) == scenario)
    }
}

/// The same slice driven only through `ActionExecutor.perform`, the way the
/// UI does it: select objects, check the command is offered for that
/// selection, fill in parameters, perform. The faulted field simulation plays
/// the physical plant; everything that touches the world model goes through
/// commands.
@Suite struct GoldenSliceThroughCommandsTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let tech = Origin.user(id: "tech-1")

    @Test func wholeSliceThroughActionExecutor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("golden-actions-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".blobs"))
        }
        let clock = ManualClock(Self.t0)
        var store = try NexusStore(.file(url), clock: clock)
        var actions = ActionExecutor(store: store, actor: tech, clock: clock)
        let registry = CommandRegistry()

        /// Performs a command as the UI would, requiring that it is offered and completes.
        func perform(
            _ command: CommandID,
            _ selection: [ObjectID] = [],
            _ fill: (inout ActionParameters) -> Void = { _ in }
        ) throws -> ActionReport {
            let offered = registry.commands(for: try store.objects(selection)).map(\.commandID)
            #expect(offered.contains(command), "\(command) is not offered for this selection")
            let outcome = try actions.perform(command, selection: selection, parameters: .with(fill))
            guard let report = outcome.report else {
                Issue.record("\(command) did not complete: \(outcome)")
                throw ActionError.unsupported(Unsupported(command: command, reason: "did not complete"))
            }
            return report
        }
        func created(_ type: ObjectType, _ title: String, in project: ObjectID?, _ attributes: [String: Attribute] = [:]) throws -> ObjectID {
            let report = try perform(.create) {
                $0.type = type
                $0.title = title
                $0.project = project
                $0.attributes = attributes
            }
            guard let id = report.focus else { throw ActionError.missingValue(.title) }
            return id
        }

        // 1. Project.
        let project = try created(.project, "LT-101 level loop", in: nil)

        // 2. Topology: objects, then links.
        let tank = try created(.equipment, "Tank T-1", in: project)
        let transmitter = try created(.sensor, "LT-101 level transmitter", in: nil, ["tag": Attribute(.string("LT-101"))])
        let terminal = try created(.testPoint, "TB-4 terminals 7/8", in: nil)
        let card = try created(.component, "AI card slot 3 ch 0", in: project)
        let controller = try created(.component, "LIC-101 level controller", in: project)
        let valve = try created(.component, "LV-101 inlet valve", in: project)
        let spec = AccuracySpec(percentOfReading: 0.5, digits: 2, resolution: Quantity(0.01, "V"), rangeLow: 0, rangeHigh: 60)
        let dmm = try created(.instrument, "Virtual DMM", in: project, [InstrumentModel.accuracyKey: Attribute(spec.value)])
        for (from, to, kind) in [
            (tank, transmitter, RelationKind.contains), (transmitter, terminal, .contains), (transmitter, terminal, .connectedTo),
            (terminal, card, .connectedTo), (card, controller, .connectedTo), (controller, valve, .connectedTo),
        ] {
            _ = try perform(.link, [from]) {
                $0.target = to
                $0.relation = kind
            }
        }

        // 3. Document and cited claim.
        let imported = try perform(.create) {
            $0.type = .document
            $0.title = "LT-101 installation manual"
            $0.data = Data(GoldenSliceTests.manualText.utf8)
            $0.mediaType = "text/markdown"
            $0.project = project
        }
        guard case .document(let ingest) = imported.detail else { Issue.record("Expected a document"); return }
        let manual = ingest.document.id
        let liftOff = try #require(ingest.passages.first { $0.text.contains("lift-off") })
        let cited = try perform(.extractClaim, [liftOff.id]) {
            $0.statement = "LT-101 needs at least 12 V at its terminals to regulate loop current"
            $0.sourceClass = .primary
        }
        let claim = try #require(cited.focus)

        // 4. One identity from search, the object view, and the loop trace.
        let found = try perform(.search) {
            $0.query = "LT-101 transmitter"
            $0.project = project
        }
        guard case .search(let hits) = found.detail else { Issue.record("Expected hits"); return }
        #expect(hits.first?.id == transmitter)
        #expect(try perform(.open, [transmitter]).focus == transmitter)
        guard case .trace(let trace) = try perform(.trace, [card]).detail else { Issue.record("Expected a trace"); return }
        #expect(trace.upstream.map(\.id) == [terminal, transmitter])

        // 5. Fault: a what-if run through the executor, and the field that plays the plant.
        let loop = InstrumentLoop(tank: tank, transmitter: transmitter, terminal: terminal, card: card, controller: controller, valve: valve)
        let fault = SimulatedFault(parameter: loop.contactOhms, value: 400, summary: "Corroded terminal at TB-4")
        guard case .simulation(let whatIf) = try perform(.simulate, [terminal], { $0.faults = [fault] }).detail else {
            Issue.record("Expected a simulation")
            return
        }
        #expect(whatIf.loop == loop, "The loop was found in the graph")
        #expect(abs(whatIf.values["terminalVoltage"]! - 12) < 0.1)
        let field = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        field.inject(fault)
        try field.start()
        try field.run(for: 600)
        clock.advance(by: 600)

        // 7. Investigation (started before the readings, from the symptom).
        let investigation = try #require(try perform(.investigate, [transmitter, tank]) {
            $0.symptom = "LT-101 reads 86.9 % while T-1 overflows"
        }.focus)
        #expect(try store.relationships(from: investigation, kind: .investigates).map(\.to) == [transmitter, tank])
        #expect(try actions.projects.members(of: project).map(\.id).contains(investigation))

        // 6. Display truth from the HMI.
        let hmi = try perform(.recordMeasurement, [investigation]) {
            $0.testPoint = card
            $0.quantity = "measuredLevel"
            $0.value = try? field.value(loop.measuredLevel)
            $0.unit = "%"
            $0.truth = .display
        }
        guard case .measurement(let display) = hmi.detail else { Issue.record("Expected a reading"); return }
        #expect(display.measurement.truth == .display && display.changes.isEmpty)

        // 7 (continued). Hypotheses.
        func volts(_ low: Double, _ high: Double) -> Prediction {
            Prediction(testPoint: terminal, quantity: "terminalVoltage", unit: "V", low: low, high: high, condition: "high level")
        }
        func span(_ low: Double, _ high: Double) -> Prediction {
            Prediction(testPoint: card, quantity: "configuredSpan", unit: "%", low: low, high: high)
        }
        func propose(_ statement: String, _ predictions: [Prediction], dependsOn: [ObjectID] = []) throws -> ObjectID {
            let report = try perform(.proposeHypothesis, [investigation]) {
                $0.statement = statement
                $0.predictions = predictions
                $0.dependsOn = dependsOn
            }
            guard case .hypothesis(let hypothesis) = report.detail else { throw ActionError.missingValue(.statement) }
            return hypothesis.id
        }
        let failed = try propose("Transmitter failed and no longer draws loop current", [volts(22, 24.5), span(99.9, 100.1)])
        let compliance = try propose(
            "Excess loop resistance starves the transmitter of compliance voltage", [volts(10.5, 12.5), span(99.9, 100.1)], dependsOn: [claim]
        )
        let cardFault = try propose("AI card channel reads low", [volts(17, 21.9), span(99.9, 100.1)])
        let scaling = try propose("Channel scaled 0–120 % instead of 0–100 %", [volts(17, 21.9), span(119.9, 120.1)])

        // 8. Discriminating tests, re-ranked after each reading.
        let options = [
            TestOption(title: "Read channel span from controller", testPoint: card, quantity: "configuredSpan", cost: 2),
            TestOption(title: "Terminal voltage at TB-4 under load", testPoint: terminal, quantity: "terminalVoltage", condition: "high level", cost: 5),
            TestOption(title: "Measure 24 V bus with covers off", testPoint: card, quantity: "busVoltage", cost: 1, safety: .hazardous),
        ]
        guard case .recommendations(let first) = try actions.rankTests(options, for: investigation).erased(ActionDetail.recommendations).detail
        else { return }
        #expect(first.map(\.option.title) == ["Read channel span from controller", "Terminal voltage at TB-4 under load"])
        guard case .measurement(let spanRead) = try perform(.recordMeasurement, [investigation], {
            $0.testPoint = card
            $0.quantity = "configuredSpan"
            $0.value = 100
            $0.unit = "%"
            $0.truth = .recorded
            $0.tests = options
        }).detail else { Issue.record("Expected a reading"); return }
        #expect(spanRead.changes.map(\.hypothesis) == [scaling])
        #expect(spanRead.rankedTests.first?.option.title == "Terminal voltage at TB-4 under load")
        #expect(spanRead.rankedTests.first?.outcomes.count == 3)

        guard case .measurement(let loadedRead) = try perform(.recordMeasurement, [terminal], {
            $0.investigation = investigation
            $0.quantity = "terminalVoltage"
            $0.value = try? field.value(loop.terminalVoltage)
            $0.unit = "V"
            $0.instrument = dmm
            $0.loading = "high level"
        }).detail else { Issue.record("Expected a reading"); return }
        let loaded = loadedRead.measurement
        #expect(abs(try #require(loaded.uncertainty) - 0.08) < 1e-9)
        #expect(Set(loadedRead.changes.map(\.hypothesis)) == [failed, cardFault])
        let states = Dictionary(uniqueKeysWithValues: try actions.investigations.hypotheses(of: investigation).map { ($0.id, $0.state) })
        #expect(states == [failed: .rejected, compliance: .candidate, cardFault: .rejected, scaling: .rejected])

        // 9. First divergence against a healthy run, then a person confirms the cause.
        guard case .simulation(let twin) = try perform(.simulate, [terminal]).detail else { Issue.record("Expected a run"); return }
        let expected = try #require(twin.modeled.first { $0.quantityName == "terminalVoltage" })
        #expect(abs(expected.value.value - 19.03) < 0.1)
        guard case .divergence(let divergence) = try perform(.markFirstDivergence, [expected.id, loaded.id]).detail else { return }
        #expect(divergence.summary == "terminalVoltage at TB-4 terminals 7/8 is 12 V where the model expects 19 V")
        let robot = ActionExecutor(store: store, actor: .agent(id: "diag", run: nil), clock: clock)
        #expect(throws: InvestigationError.requiresHuman(.agent(id: "diag", run: nil))) {
            try robot.perform(.confirmHypothesis, selection: [compliance])
        }
        _ = try perform(.confirmHypothesis, [compliance])

        // 10. Repair procedure and task, through the task runtime.
        guard case .repairTask(let task) = try perform(.createRepairTask, [investigation], {
            $0.title = "Clean and re-terminate TB-4 7/8"
            $0.steps = [
                "Lock out the loop at the AI card", "Remove, clean and re-terminate TB-4 7/8", "Measure loop resistance",
                "Restore and verify a 4–20 mA sweep",
            ]
        }).detail else { Issue.record("Expected a task"); return }
        #expect(task.title == "Repair: Clean and re-terminate TB-4 7/8")
        #expect(try actions.tasks.tasks(in: project).map(\.id) == [task.id])

        // 11. Repair in the field, verify, close.
        field.clear(fault.id)
        try field.run(for: 900)
        clock.advance(by: 900)
        guard case .measurement(let afterRead) = try perform(.recordMeasurement, [terminal], {
            $0.quantity = "terminalVoltage"
            $0.value = try? field.value(loop.terminalVoltage)
            $0.unit = "V"
            $0.instrument = dmm
            $0.loading = "high level"
        }).detail else { return }
        guard case .measurement(let levelRead) = try perform(.recordMeasurement, [investigation], {
            $0.testPoint = tank
            $0.quantity = "level"
            $0.value = try? field.value(loop.level)
            $0.unit = "%"
            $0.uncertainty = 0.5
        }).detail else { return }
        let after = afterRead.measurement.id
        let settled = levelRead.measurement.id
        guard case .verification(let verified) = try perform(.verifyRepair, [task.id], { $0.evidence = [after, settled] }).detail else { return }
        #expect(verified.task.status == .done)
        _ = try perform(.closeInvestigation, [investigation]) { $0.resolution = "Terminal re-made; loop voltage and level verified" }

        // 12. Report with lineage for every figure.
        guard case .report(let report) = try perform(.generateReport, [investigation]).detail,
              case .string(let body)? = report.attributes["body"]?.value
        else { Issue.record("No report"); return }
        let lineage = Set(try store.relationships(from: report.id, kind: .derivedFrom).map(\.to))
        for id in [loaded.id, expected.id, spanRead.measurement.id, claim, manual, compliance, after, settled] {
            #expect(lineage.contains(id), "Report must cite \(id)")
        }
        #expect(body.contains("confirmed**: Excess loop resistance"))
        #expect(body.contains("relies on: LT-101 needs at least 12 V"))
        #expect(body.contains("## Verification"))

        // 13. Training scenario, with the loop found in the graph.
        guard case .trainingScenario(let scenario) = try perform(.generateTrainingScenario, [investigation], {
            $0.faults = [fault]
            $0.tests = options
        }).detail else { Issue.record("No scenario"); return }
        #expect(scenario.cause == "Excess loop resistance starves the transmitter of compliance voltage")
        #expect(scenario.expertPath == ["Read channel span from controller", "Terminal voltage at TB-4 under load"])
        #expect(abs(try scenario.makeField().value(loop.terminalVoltage) - loaded.value.value) < 1e-9)

        // 14. Save, reload, and everything is still there.
        let timeline = try store.timeline()
        let before = try store.objects([project, investigation, task.id, report.id, scenario.id, manual, claim])
        store = try NexusStore(.file(url), clock: clock)
        actions = ActionExecutor(store: store, actor: tech, clock: clock)
        #expect(try store.timeline() == timeline)
        #expect(try store.objects([project, investigation, task.id, report.id, scenario.id, manual, claim]) == before)
        #expect(try actions.tasks.task(task.id).status == .done)
        #expect(try actions.learning.scenario(scenario.id) == scenario)
        let kinds = timeline.map(\.kind)
        #expect(kinds.filter { $0 == .measured }.count == 5)
        for kind in [
            EventKind.userEdit, .investigationOpened, .faultInjected, .simulated, .hypothesisRejected, .firstDivergence,
            .hypothesisConfirmed, .repair, .taskStatusChanged, .repairVerified, .investigationClosed,
        ] {
            #expect(kinds.contains(kind), "Timeline has \(kind)")
        }
    }
}

/// Every runtime over one store file, rebuilt on reload.
private struct World {
    let store: NexusStore
    let graph: ObjectGraph
    let projects: ProjectRuntime
    let search: SearchEngine
    let investigations: InvestigationRuntime
    let documents: DocumentLibrary
    let tasks: TaskRuntime
    let actions: ActionExecutor

    init(url: URL, clock: ManualClock) throws {
        store = try NexusStore(.file(url), clock: clock)
        graph = ObjectGraph(store: store, clock: clock)
        projects = ProjectRuntime(store: store, graph: graph, clock: clock)
        search = SearchEngine(store: store, graph: graph)
        investigations = InvestigationRuntime(store: store, clock: clock)
        documents = DocumentLibrary(store: store, clock: clock)
        tasks = TaskRuntime(store: store, clock: clock)
        actions = ActionExecutor(
            store: store, graph: graph, projects: projects, investigations: investigations, tasks: tasks, documents: documents,
            learning: LearningRuntime(store: store, clock: clock), searchEngine: search, actor: Origin.user(id: "tech-1"), clock: clock
        )
    }
}

/// Everything the slice produced, read back through public APIs.
private struct Snapshot: Equatable {
    var members: [ObjectRecord]
    var edges: [ObjectID: [Relationship]]
    var revisions: [ObjectID: [Revision]]
    var hypotheses: [ObjectID: HypothesisState]
    var measurements: [MeasurementRecord]
    var claims: [Claim]
    var timeline: [Event]
    var reportBody: Value?

    init(of store: NexusStore, project: ObjectID, investigation: ObjectID, report: ObjectID, graph: ObjectGraph) throws {
        let reached = try graph.traverse(from: project, direction: .both, validity: .any).map(\.id)
        let ids = [project] + reached
        members = try store.objects(ids)
        edges = Dictionary(uniqueKeysWithValues: try ids.map { ($0, try store.relationships(from: $0)) })
        revisions = Dictionary(uniqueKeysWithValues: try ids.map { ($0, try store.revisions(of: $0)) })
        hypotheses = Dictionary(uniqueKeysWithValues: try InvestigationRuntime(store: store).hypotheses(of: investigation).map { ($0.id, $0.state) })
        measurements = try members.filter { $0.type == .measurement }.compactMap { try store.measurement($0.id) }
        claims = try members.filter { $0.type == .claim }.compactMap { try store.claim($0.id) }
        timeline = try store.timeline()
        reportBody = try store.object(report)?.attributes["body"]?.value
    }
}

import Foundation
import NexusCore
import NexusGraph
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSearch
import NexusSimulation
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
        let dmm = try object("Virtual DMM", .instrument, ["virtual": Attribute(.bool(true))])
        for id in [tank, card, controller, valve] {
            try world.projects.add(id, to: project, by: tech)
        }
        try world.store.relate(Relationship(kind: .contains, from: tank, to: transmitter, provenance: recorded()))
        try world.store.relate(Relationship(kind: .contains, from: transmitter, to: terminal, provenance: recorded()))
        for (from, to) in [(transmitter, terminal), (terminal, card), (card, controller), (controller, valve)] {
            try world.store.relate(Relationship(kind: .connectedTo, from: from, to: to, provenance: recorded()))
        }

        // 3. Source document and a cited claim.
        let manual = try object("LT-101 installation manual", .document, [
            "body": Attribute(.string("Supply at the terminals must stay above the 12 V minimum lift-off voltage.")),
        ])
        let claim = Claim(
            statement: "LT-101 needs at least 12 V at its terminals to regulate loop current",
            sources: [manual], passages: ["minimum lift-off voltage 12 V"], sourceClass: .primary,
            provenance: Provenance(origin: tech, truth: .claimed, timestamp: clock.now())
        )
        try world.store.add(claim)
        try world.projects.add(manual, to: project, by: tech)

        // 4. One identity from project, search and graph.
        let viaSearch = try world.search.search(SearchQuery("LT-101 transmitter", scope: project)).first?.id
        let viaProject = try world.projects.members(of: project, types: [.sensor], transitive: true).first?.id
        let viaGraph = try world.graph.shortestPath(from: valve, to: transmitter)?.last?.neighbor
        #expect(viaSearch == transmitter && viaProject == transmitter && viaGraph == transmitter)

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

        // 6. Display truth from the HMI, next to what the field really does.
        let hmi = MeasurementRecord(
            quantityName: "measuredLevel", value: Quantity(try field.value(loop.measuredLevel), "%"), testPoint: card,
            sampledAt: clock.now(), provenance: Provenance(origin: .importer(source: card), truth: .display, timestamp: clock.now())
        )
        try world.store.add(hmi)
        let trueLevel = try field.value(loop.level)
        #expect(hmi.value.value < 87 && trueLevel == 100, "HMI shows 86.9 % while the tank is full")

        // 7. Investigation with four competing hypotheses.
        let investigation = try world.investigations.open(
            symptom: "LT-101 reads 86.9 % while T-1 overflows", subjects: [transmitter, tank], by: tech
        ).id
        try world.projects.add(investigation, to: project, by: tech)
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

        let loaded = try observe(loop.terminalVoltage, "V", loading: "high level", uncertainty: 0.1)
        try world.investigations.assess(loaded.id, in: investigation, by: tech)
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
        let task = try object("Repair TB-4 on LT-101 loop", .task, ["status": Attribute(.string("open"))])
        try world.store.relate(Relationship(kind: .produced, from: investigation, to: procedure, provenance: recorded()))
        try world.store.relate(Relationship(kind: .dependsOn, from: task, to: procedure, provenance: recorded()))
        try world.projects.add(task, to: project, by: tech)

        // 11. Repair in the field and verify.
        field.clear(fault.id)
        try field.run(for: 900)
        clock.advance(by: 900)
        let after = try observe(loop.terminalVoltage, "V", loading: "high level", uncertainty: 0.1)
        let settled = try observe(loop.level, "%", uncertainty: 0.5)
        #expect(after.value.value > 18 && abs(settled.value.value - 90) < 0.5)
        #expect(try field.value(loop.overflowing) == 0)
        try world.store.update(task, by: tech, instruction: "Repair done") { $0.attributes["status"] = Attribute(.string("done")) }
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

        // 14. Save, reload, and compare everything.
        let before = try Snapshot(of: world.store, project: project, investigation: investigation, report: report.id, graph: world.graph)
        world = try World(url: url, clock: clock)
        let reloaded = try Snapshot(of: world.store, project: project, investigation: investigation, report: report.id, graph: world.graph)
        #expect(reloaded == before)
        #expect(reloaded.hypotheses[compliance.id] == .confirmed)
        #expect(reloaded.timeline.contains { $0.kind == .firstDivergence })
    }
}

/// Every runtime over one store file, rebuilt on reload.
private struct World {
    let store: NexusStore
    let graph: ObjectGraph
    let projects: ProjectRuntime
    let search: SearchEngine
    let investigations: InvestigationRuntime

    init(url: URL, clock: ManualClock) throws {
        store = try NexusStore(.file(url), clock: clock)
        graph = ObjectGraph(store: store, clock: clock)
        projects = ProjectRuntime(store: store, graph: graph, clock: clock)
        search = SearchEngine(store: store, graph: graph)
        investigations = InvestigationRuntime(store: store, clock: clock)
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

import Foundation
import NexusAutomotive
import NexusCore
import NexusGraph
import NexusInvestigation
import NexusModel
import NexusPersistence
import NexusSimulation
import Testing

/// The second-domain slice, headless: a 2003 Honda that cranks slowly with
/// the battery light on, diagnosed on the same store, investigation runtime,
/// simulation runtime and report as the instrument-loop Golden Slice. Nothing
/// automotive keeps its own state, so the slice proves the architecture
/// expands without a parallel truth path.
///
/// Training-world convention, as in the Golden Slice: the faulted solver run
/// plays the field, readings taken from it by the meter are observed truth,
/// and a healthy twin run gives the modeled expectation.
@Suite struct AutomotiveSliceTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func chargingSystemDiagnosisEndToEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("automotive-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ManualClock(Self.t0)
        var world = try World(url: url, clock: clock)
        let tech = Origin.user(id: "tech-7")
        func recorded() -> Provenance { Provenance(origin: tech, truth: .recorded, timestamp: clock.now()) }

        // 1. The vehicle, by the VIN the ECU reports over Mode 09.
        let vinReply = try ELM327.parse("0902\r014\r0: 49 02 01 31 48 47\r1: 43 4D 38 32 36 33 33\r2: 41 30 30 34 33 35 32\r\r>", command: "0902")
        let vin = try OBD.decodeVIN(try #require(vinReply.first).bytes)
        let car = try world.garage.addVehicle(vin: vin.rawValue, odometerKm: 182_400, by: tech)
        #expect(car.vin.isCheckDigitValid && car.modelYear == 2003 && car.vin.manufacturer == "Honda (USA)")
        let system = try #require(ChargingSystem(car))
        try world.garage.recordService(
            ServiceEntry(
                title: "Replace 12 V battery", performedAt: Self.t0.addingTimeInterval(-400 * 86_400), odometerKm: 171_050,
                steps: ["Test battery", "Replace battery", "Clean terminals"], parts: ["Group 51R battery"]
            ),
            on: car.id, by: tech
        )
        let meter = try world.store.create(ObjectRecord(type: .instrument, title: "DMM with 600 A clamp", provenance: recorded())).id
        let scanTool = try world.store.create(ObjectRecord(type: .instrument, title: "ELM327 scan tool", provenance: recorded())).id

        // 2. The field: an alternator worn to 10 % output, beside a healthy twin.
        let fault = ChargingFaultKind.failingAlternator.faults(on: system, severity: 1)
        let field = try ChargingProtocol.run(system, faults: fault)
        let twin = try ChargingProtocol.run(system)
        try world.store.record(
            Event(
                at: clock.now(), kind: .faultInjected, subjects: [system.alternator], summary: fault[0].summary,
                payload: ["health": .double(fault[0].value)],
                provenance: Provenance(origin: .simulation(run: field.runtime.run), truth: .modeled, timestamp: clock.now())
            ))
        #expect(field.lightWhileDriving == 1 && twin.lightWhileDriving == 0)

        // 3. Scan: stored codes are recorded truth, PIDs are display truth, the adapter's own voltmeter is observed.
        let dtcReply = try ELM327.parse("SEARCHING...\r7E8 04 43 01 05 62\r\r>", headers: .on)
        let (status, codes) = try OBD.decodeDTCs(dtcReply[0].bytes, hasCount: true)
        #expect(status == .stored && codes == [DTC("P0562")!])
        let faults = try world.garage.recordTroubleCodes(codes, status: status, on: car.id, by: tech)
        let p0562 = try #require(faults.first)
        #expect(p0562.title == "P0562 System voltage low" && p0562.provenance.truth == .recorded)
        #expect(p0562.truth(of: AutomotiveKey.description) == .claimed)
        #expect(try world.store.relationships(from: car.id, kind: .hasFault).map(\.to) == [p0562.id])
        #expect(try world.garage.recordTroubleCodes(codes, status: status, on: car.id, by: tech).map(\.id) == [p0562.id], "No duplicate fault")

        let pidReply = try ELM327.parse("7E8 04 41 42 2F D5", headers: .on)
        let displayed = try world.garage.record(try OBD.decodeMode01(pidReply[0].bytes, ecu: pidReply[0].ecu), on: car.id, scanTool: scanTool)
        #expect(displayed.map(\.truth) == [.display] && abs(displayed[0].value.value - 12.245) < 1e-9)
        #expect(displayed[0].testPoint == car.component(.ecu))
        let atrv = try world.garage.recordAdapterVoltage(try #require(ELM327.parseVoltage("12.2V")), on: car.id, scanTool: scanTool)
        #expect(atrv.truth == .observed)

        // 4. Investigation with four hypotheses whose predictions come from the solver.
        let diagnosis = ChargingDiagnosis(system: system)
        let (investigation, hypotheses) = try diagnosis.open(in: world.investigations, vehicle: car.id, evidence: [p0562.id], by: tech)
        let weak = try #require(hypotheses[.weakBattery])
        let alternator = try #require(hypotheses[.failingAlternator])
        let ground = try #require(hypotheses[.highResistanceGround])
        let draw = try #require(hypotheses[.parasiticDraw])
        #expect(try world.investigations.hypotheses(of: investigation).count == 4)
        #expect(alternator.predictions.contains { $0.quantity == "chargingVoltage" && $0.high < 14 })

        // The ECU's display value is judged but never counted as evidence.
        let judged = try world.investigations.assess(displayed[0].id, in: investigation, by: tech)
        #expect(judged.allSatisfy { !$0.counted })

        // 5. Ranked tests. Cranking voltage splits the four causes three ways.
        let first = try world.investigations.rankTests(diagnosis.testOptions, for: investigation)
        #expect(first.first?.option.title == ChargingTest.crankingVoltage.title)
        #expect(first.first?.outcomes.count == 3)
        #expect(first.first { $0.option.title == ChargingTest.restingVoltage.title }?.informationGain == 0)

        clock.advance(by: 180)
        let crank = diagnosis.observe(.crankingVoltage, in: field, instrument: meter, at: clock.now())
        try world.store.add(crank)
        try world.investigations.assess(crank.id, in: investigation, by: tech)
        var states = try Dictionary(uniqueKeysWithValues: world.investigations.hypotheses(of: investigation).map { ($0.id, $0.state) })
        #expect(states == [weak.id: .rejected, alternator.id: .candidate, ground.id: .rejected, draw.id: .candidate])

        let second = try world.investigations.rankTests(diagnosis.testOptions, for: investigation)
        #expect(second.first?.option.title == ChargingTest.chargingVoltage.title)
        clock.advance(by: 240)
        let charging = diagnosis.observe(.chargingVoltage, in: field, instrument: meter, at: clock.now())
        try world.store.add(charging)
        try world.investigations.assess(charging.id, in: investigation, by: tech)
        states = try Dictionary(uniqueKeysWithValues: world.investigations.hypotheses(of: investigation).map { ($0.id, $0.state) })
        #expect(states == [weak.id: .rejected, alternator.id: .candidate, ground.id: .rejected, draw.id: .rejected])
        #expect(charging.value.value < 12.5)

        // 6. First divergence: the alternator's output departs from the twin at once.
        let divergence = try #require(diagnosis.firstDivergence(field: field, twin: twin))
        #expect(divergence.key == system.alternatorVolts && divergence.tick == 0)
        let (observedOutput, expectedOutput) = diagnosis.readings(at: divergence, twin: twin, instrument: meter, at: clock.now())
        try world.store.add(observedOutput)
        try world.store.add(expectedOutput)
        try world.investigations.recordFirstDivergence(
            in: investigation, observed: observedOutput.id, expected: expectedOutput.id,
            summary: "Alternator output is 12.24 V at 2000 rpm where the twin regulates at 14.4 V", by: tech
        )
        #expect(abs(expectedOutput.value.value - 14.4) < 1e-9 && observedOutput.value.value < 12.5)

        #expect(throws: InvestigationError.requiresHuman(.agent(id: "auto-diag", run: nil))) {
            try world.investigations.confirm(alternator.id, in: investigation, by: .agent(id: "auto-diag", run: nil))
        }
        try world.investigations.confirm(alternator.id, in: investigation, by: tech)

        // Recorded values stay protected: an agent cannot rewrite the ECU's code.
        #expect(throws: StoreError.self) {
            try world.store.update(p0562.id, by: .agent(id: "auto-diag", run: nil)) {
                $0.attributes[AutomotiveKey.dtc] = Attribute(.string("P0000"))
            }
        }

        // 7. Repair task, then the repair as a service record with the odometer.
        let task = try world.store.create(
            ObjectRecord(
                type: .task, title: "Replace alternator on \(car.title)", attributes: ["status": Attribute(.string("open"))], provenance: recorded()
            )
        ).id
        clock.advance(by: 2 * 3_600)
        let repair = try world.garage.recordService(
            ServiceEntry(
                title: "Replace alternator", performedAt: clock.now(), odometerKm: 182_412,
                steps: ["Disconnect battery negative", "Replace alternator", "Torque B+ nut to 9 N·m", "Verify charging voltage at 2000 rpm"],
                parts: ["Reman alternator 120 A"]
            ),
            on: car.id, by: tech
        )
        try world.store.relate(Relationship(kind: .produced, from: investigation, to: repair.procedure.id, provenance: recorded()))
        try world.store.relate(Relationship(kind: .dependsOn, from: task, to: repair.procedure.id, provenance: recorded()))
        #expect(try world.garage.serviceHistory(of: car.id).map(\.procedure.title) == ["Replace 12 V battery", "Replace alternator"])
        #expect(try world.garage.vehicle(car.id).odometerKm == 182_412)
        #expect(throws: AutomotiveError.odometerWentBackwards(previous: 182_412, new: 182_000)) {
            try world.garage.recordOdometer(182_000, at: clock.now(), on: car.id, by: tech)
        }

        // 8. Verify in the field: the repaired car regulates again.
        let repaired = try ChargingProtocol.run(system, stateOfCharge: try field.runtime.value(system.stateOfCharge))
        let verified = diagnosis.observe(.chargingVoltage, in: repaired, instrument: meter, at: clock.now())
        try world.store.add(verified)
        #expect(verified.value.value > 14.1 && repaired.lightWhileDriving == 0)
        try world.store.update(task, by: tech, instruction: "Repair done") { $0.attributes["status"] = Attribute(.string("done")) }
        try world.garage.clearFault(p0562.id, reason: "Alternator replaced; charging verified", by: tech)
        try world.investigations.close(
            investigation, resolution: "Alternator replaced; 14.3 V at 2000 rpm with loads on", verifiedBy: [verified.id], by: tech
        )

        // 9. Report with lineage for every figure.
        let report = try world.investigations.generateReport(for: investigation, by: tech)
        guard case .string(let body)? = report.attributes["body"]?.value else {
            Issue.record("No report body")
            return
        }
        let lineage = Set(try world.store.relationships(from: report.id, kind: .derivedFrom).map(\.to))
        for id in [crank.id, charging.id, observedOutput.id, expectedOutput.id, verified.id, alternator.id, car.id] {
            #expect(lineage.contains(id), "Report must cite \(id)")
        }
        #expect(!lineage.contains(displayed[0].id), "Display truth is not evidence")
        #expect(body.contains("confirmed**: Failing alternator"))
        #expect(body.contains("## First divergence"))
        #expect(body.contains("## Verification\n- chargingVoltage = "))

        // 10. Save, reload, and compare everything the slice touched.
        let before = try Snapshot(of: world, vehicle: car.id, investigation: investigation, report: report.id)
        world = try World(url: url, clock: clock)
        let reloaded = try Snapshot(of: world, vehicle: car.id, investigation: investigation, report: report.id)
        #expect(reloaded == before)
        #expect(reloaded.hypotheses[alternator.id] == .confirmed)
        #expect(reloaded.timeline.contains { $0.kind == .firstDivergence } && reloaded.timeline.contains { $0.kind == .service })
        #expect(try world.garage.vehicle(vin: vin.rawValue)?.components == car.components)
        #expect(try world.garage.faults(of: car.id).map(\.lifecycle) == [.archived])
    }
}

/// Every runtime over one store file, rebuilt on reload.
private struct World {
    let store: NexusStore
    let graph: ObjectGraph
    let garage: VehicleRuntime
    let investigations: InvestigationRuntime

    init(url: URL, clock: ManualClock) throws {
        store = try NexusStore(.file(url), clock: clock)
        graph = ObjectGraph(store: store, clock: clock)
        garage = VehicleRuntime(store: store, clock: clock)
        investigations = InvestigationRuntime(store: store, clock: clock)
    }
}

/// Everything the slice produced, read back through public APIs.
private struct Snapshot: Equatable {
    var objects: [ObjectRecord]
    var edges: [ObjectID: [Relationship]]
    var revisions: [ObjectID: [Revision]]
    var hypotheses: [ObjectID: HypothesisState]
    var measurements: [MeasurementRecord]
    var timeline: [Event]
    var reportBody: Value?

    init(of world: World, vehicle: ObjectID, investigation: ObjectID, report: ObjectID) throws {
        let reached = try world.graph.traverse(from: vehicle, direction: .both, validity: .any).map(\.id)
        let ids = Array(Set([vehicle, investigation] + reached)).sorted()
        objects = try world.store.objects(ids)
        edges = Dictionary(uniqueKeysWithValues: try ids.map { ($0, try world.store.relationships(from: $0)) })
        revisions = Dictionary(uniqueKeysWithValues: try ids.map { ($0, try world.store.revisions(of: $0)) })
        hypotheses = Dictionary(
            uniqueKeysWithValues: try world.investigations.hypotheses(of: investigation).map { ($0.id, $0.state) }
        )
        measurements = try objects.filter { $0.type == .measurement }.compactMap { try world.store.measurement($0.id) }
        timeline = try world.store.timeline()
        reportBody = try world.store.object(report)?.attributes["body"]?.value
    }
}

import ControlsPLC
import ControlsReasoning
import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence
import Testing
@testable import NexusEngineering

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

/// The trainer's motor-permissive scenario: the guard door is open, so
/// Safety_OK is off, so Motor_Run cannot start; Auto_Mode is also off.
private func guardDoorReport() throws -> MultiHypothesisReport {
    let tags = try TagStore(tags: [
        PLCTag(name: "GuardDoor_Closed", value: .bool(false), role: .input),
        PLCTag(name: "Safety_OK", value: .bool(false)),
        PLCTag(name: "Auto_Mode", value: .bool(false), role: .input),
        PLCTag(name: "VFD_Ready", value: .bool(true), role: .input),
        PLCTag(name: "No_Fault", value: .bool(true), role: .input),
        PLCTag(name: "Motor_Run", value: .bool(false), role: .output),
    ])
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(name: "MotorLogic", rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "GuardDoor_Closed")), .instruction(.ote(tag: "Safety_OK"))])),
        Rung(number: 10, logic: .series([
            .instruction(.xic(tag: "Safety_OK")), .instruction(.xic(tag: "Auto_Mode")),
            .instruction(.xic(tag: "VFD_Ready")), .instruction(.xic(tag: "No_Fault")),
            .instruction(.ote(tag: "Motor_Run")),
        ])),
    ])
    let scan = try engine.scan(routine)
    var journal = CausalJournal()
    for (index, trace) in scan.rungs.enumerated() {
        journal.ingest(CausalExecutionRecord(
            scanNumber: 1, stepIndex: index + 1, taskName: "Task", programName: "Program",
            routineName: "MotorLogic", rungNumber: trace.rungNumber, trace: trace
        ))
    }
    return journal.diagnose(target: "Motor_Run", shouldBe: .bool(true), observedValue: .bool(false))
}

private struct Bench {
    let clock = ManualClock(t0)
    let store: NexusStore
    let controller: ObjectID
    let importer: PLCDiagnosisImporter
    let investigations: InvestigationRuntime

    init() throws {
        store = try NexusStore(.inMemory, clock: clock)
        controller = try store.create(ObjectRecord(
            type: .component, title: "Packaging cell PLC", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
        )).id
        importer = PLCDiagnosisImporter(store: store, controller: controller, clock: clock)
        investigations = InvestigationRuntime(store: store, clock: clock)
    }

    func fieldReading(_ signal: ObjectID, _ state: Double) throws -> ObjectID {
        let reading = MeasurementRecord(
            quantityName: PLCDiagnosisImporter.fieldQuantity, value: Quantity(state, "bool"), testPoint: signal, sampledAt: t0,
            provenance: Provenance(origin: tech, truth: .observed, timestamp: t0, method: "checked the door switch")
        )
        try store.add(reading)
        return reading.id
    }
}

@Suite struct PLCDiagnosisImporterTests {
    @Test func rootConditionLeadsAndHealthyPermissivesBecomeEvidence() throws {
        let bench = try Bench()
        let result = try bench.importer.importReport(try guardDoorReport())

        #expect(Set(result.hypotheses.keys) == ["GuardDoor_Closed", "Auto_Mode"])
        let hypotheses = try bench.investigations.hypotheses(of: result.investigation)
        let door = try #require(hypotheses.first { $0.id == result.hypotheses["GuardDoor_Closed"] })
        let auto = try #require(hypotheses.first { $0.id == result.hypotheses["Auto_Mode"] })
        #expect(door.prior > auto.prior)
        #expect(door.predictions == [Prediction(
            testPoint: result.signals["GuardDoor_Closed"]!, quantity: "fieldState", unit: "bool", low: 0, high: 0
        )])
        #expect(door.record.provenance.truth == .claimed)
        #expect(door.record.provenance.origin == .importer(source: bench.controller))

        // Every observed logic value is recorded truth on a canonical signal.
        for tag in ["VFD_Ready", "No_Fault", "Safety_OK", "GuardDoor_Closed", "Auto_Mode"] {
            let signal = try #require(result.signals[tag])
            let logic = try bench.store.measurements(at: signal, truth: .recorded)
            #expect(logic.count == 1 && logic[0].quantityName == "logicState", "\(tag)")
        }
        let vfd = try bench.store.measurements(at: result.signals["VFD_Ready"]!)
        #expect(vfd.first?.value == Quantity(1, "bool"))
        #expect(vfd.first?.provenance.method?.contains("MotorLogic rung 10") == true)

        // The hypothesis depends on, but is not evidenced by, the reading that produced it.
        let doorReading = try #require(try bench.store.measurements(at: result.signals["GuardDoor_Closed"]!).first)
        #expect(try bench.store.relationships(from: door.id, kind: .dependsOn).map(\.to) == [doorReading.id])
        #expect(try bench.store.relationships(to: door.id, kind: .supports).isEmpty)

        let investigation = try #require(try bench.store.object(result.investigation))
        #expect(investigation.title == "Motor_Run should be TRUE but is FALSE")
        guard case .list(let trail)? = investigation.attributes["plcCausalTrail"]?.value else { Issue.record("No trail"); return }
        #expect(trail.count >= 3)
        #expect(trail.last == .string("upstreamBlocker: XIC GuardDoor_Closed blocked the path"))
        #expect(investigation.truth(of: "plcCausalTrail") == .derived)
        #expect(investigation.attributes["recommendedNextCheck"] != nil)
    }

    @Test func fieldReadingThatAgreesSupportsAndCanBeConfirmed() throws {
        let bench = try Bench()
        let result = try bench.importer.importReport(try guardDoorReport())
        let door = result.hypotheses["GuardDoor_Closed"]!
        let reading = try bench.fieldReading(result.signals["GuardDoor_Closed"]!, 0)
        let assessments = try bench.investigations.assess(reading, in: result.investigation, by: tech)
        #expect(assessments.first { $0.hypothesis == door }?.effect == .supports)
        #expect(try bench.investigations.confirm(door, in: result.investigation, by: tech).state == .confirmed)
    }

    @Test func fieldReadingThatDisagreesPointsAtTheInputPath() throws {
        let bench = try Bench()
        let result = try bench.importer.importReport(try guardDoorReport())
        // The door is physically closed, yet the controller saw it open.
        let reading = try bench.fieldReading(result.signals["GuardDoor_Closed"]!, 1)
        try bench.investigations.assess(reading, in: result.investigation, by: tech)
        let states = try bench.investigations.hypotheses(of: result.investigation)
        #expect(states.first { $0.id == result.hypotheses["GuardDoor_Closed"] }?.state == .rejected)
        #expect(states.first { $0.id == result.hypotheses["Auto_Mode"] }?.state == .candidate)
    }

    @Test func signalsAreReusedAcrossImports() throws {
        let bench = try Bench()
        let first = try bench.importer.importReport(try guardDoorReport())
        let second = try bench.importer.importReport(try guardDoorReport(), into: first.investigation)
        #expect(second.investigation == first.investigation)
        for (tag, id) in second.signals {
            #expect(first.signals[tag] == id, "\(tag)")
        }
        #expect(second.hypotheses == first.hypotheses)
        #expect(try bench.investigations.hypotheses(of: first.investigation).count == first.hypotheses.count)
        #expect(try bench.store.objects(ofType: .signal).count == first.signals.count)
    }

    @Test func unknownControllerIsRejectedWithoutWrites() throws {
        let bench = try Bench()
        let missing = ObjectID.make()
        let importer = PLCDiagnosisImporter(store: bench.store, controller: missing, clock: bench.clock)
        #expect(throws: StoreError.notFound(missing)) { try importer.importReport(try guardDoorReport()) }
        #expect(try bench.store.objects(ofType: .investigation).isEmpty)
    }
}

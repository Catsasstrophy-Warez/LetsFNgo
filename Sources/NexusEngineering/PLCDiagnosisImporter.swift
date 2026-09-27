import ControlsPLC
import ControlsReasoning
import Foundation
import NexusCore
import NexusInvestigation
import NexusModel
import NexusPersistence

public struct PLCDiagnosisImport: Sendable, Hashable {
    public var investigation: ObjectID
    /// Canonical signal object per PLC tag touched by the diagnosis.
    public var signals: [String: ObjectID]
    /// Nexus hypothesis per candidate tag.
    public var hypotheses: [String: ObjectID]
    /// Recorded logic values captured during the scan.
    public var readings: [ObjectID]
}

/// Brings a trainer `MultiHypothesisReport` into the Nexus investigation model.
///
/// The PLC scan trace is a trusted external record, so the logic values it
/// captured become recorded measurements on canonical signal objects. The
/// reasoner's conclusions are logic-level: "the controller saw the door
/// open". Each becomes a hypothesis whose prediction is about the field,
/// namely that the device really is in the state the controller saw. A
/// technician's field reading then supports it, or contradicts it and points
/// at the input path instead. The data that produced a hypothesis is never
/// counted as evidence for it.
///
/// - The most upstream condition on the primary causal trail is the strongest candidate.
/// - Confirmed blockers off that trail, contributing conditions and unobserved
///   permissives follow with decreasing prior.
/// - Healthy permissives become recorded evidence only.
/// - Intermediate blockers explained by the trail stay in the trail.
public struct PLCDiagnosisImporter: Sendable {
    public let store: NexusStore
    public let controller: ObjectID
    let clock: NexusClock

    public static let logicQuantity = "logicState"
    public static let fieldQuantity = "fieldState"

    public init(store: NexusStore, controller: ObjectID, clock: NexusClock = SystemClock()) {
        self.store = store
        self.controller = controller
        self.clock = clock
    }

    @discardableResult
    public func importReport(_ report: MultiHypothesisReport, into existing: ObjectID? = nil) throws -> PLCDiagnosisImport {
        try store.batch { store in
            guard try store.object(controller) != nil else { throw StoreError.notFound(controller) }
            let author = Origin.importer(source: controller)
            let now = clock.now()
            var signals: [String: ObjectID] = [:]
            func signal(_ tag: String) throws -> ObjectID {
                if let id = signals[tag] { return id }
                let id = try signalObject(for: tag)
                signals[tag] = id
                return id
            }

            let investigations = InvestigationRuntime(store: store, clock: clock)
            let investigation = try existing ?? investigations.open(
                symptom: "\(report.target) should be \(describe(report.desiredValue)) but is \(report.observedValue.map(describe) ?? "unknown")",
                subjects: [try signal(report.target)], by: author
            ).id

            // Recorded logic values, one per observed tag.
            var readings: [String: ObjectID] = [:]
            func record(_ tag: String, _ value: TagValue?, at location: CausalLocation?) throws {
                guard readings[tag] == nil, let value, let number = number(of: value) else { return }
                let reading = MeasurementRecord(
                    quantityName: Self.logicQuantity, value: Quantity(number, unit(of: value)), testPoint: try signal(tag), sampledAt: now,
                    provenance: Provenance(origin: author, truth: .recorded, timestamp: now, method: location.map(describe) ?? "PLC scan trace")
                )
                try store.add(reading)
                readings[tag] = reading.id
            }
            for hypothesis in report.hypotheses {
                try record(hypothesis.target, hypothesis.observedValue, at: hypothesis.location)
            }
            let trail = report.primaryRootTrail?.steps ?? []
            for step in trail {
                try record(step.target, step.observedValue, at: step.location)
            }

            // Candidates, strongest first.
            var candidates: [(tag: String, value: TagValue?, prior: Double, statement: String)] = []
            let onTrail = Set(trail.map(\.target))
            // The most upstream recorded condition, whether or not the journal could
            // prove it is a leaf (`rootCondition`) or only that it blocked (`upstreamBlocker`).
            if let root = trail.last(where: { $0.kind == .rootCondition || $0.kind == .upstreamBlocker }) {
                candidates.append((root.target, root.observedValue, 4, "\(root.target) is really \(root.observedValue.map(describe) ?? "in the state the controller saw") at its source: \(root.headline)"))
            }
            for hypothesis in report.hypotheses {
                let prior: Double
                switch hypothesis.status {
                case .confirmedBlocker where !onTrail.contains(hypothesis.target): prior = 3
                case .contributingCondition: prior = 2
                case .unknownUnobserved: prior = 1
                default: continue
                }
                candidates.append((hypothesis.target, hypothesis.observedValue, prior, "\(hypothesis.instruction) \(hypothesis.target) blocks \(report.target): \(hypothesis.detail)"))
            }

            // Re-importing into the same investigation reuses matching hypotheses.
            let existingByStatement = Dictionary(
                try investigations.hypotheses(of: investigation).map { ($0.statement, $0.id) }, uniquingKeysWith: { first, _ in first }
            )
            var hypotheses: [String: ObjectID] = [:]
            for candidate in candidates where hypotheses[candidate.tag] == nil {
                if let existing = existingByStatement[candidate.statement] {
                    hypotheses[candidate.tag] = existing
                    continue
                }
                var predictions: [Prediction] = []
                if let value = candidate.value, let number = number(of: value) {
                    let point = try signal(candidate.tag)
                    let tolerance = unit(of: value) == "bool" ? 0 : max(abs(number) * 0.02, 1e-6)
                    predictions.append(Prediction(testPoint: point, quantity: Self.fieldQuantity, unit: unit(of: value), low: number - tolerance, high: number + tolerance))
                }
                let proposed = try investigations.propose(
                    candidate.statement, in: investigation, predictions: predictions, prior: candidate.prior,
                    dependsOn: readings[candidate.tag].map { [$0] } ?? [], by: author
                )
                hypotheses[candidate.tag] = proposed.id
            }

            let derived = Provenance(
                origin: author, truth: .derived, timestamp: now, method: "causal journal", dependencies: Array(readings.values).sorted()
            )
            try store.update(investigation, by: author, instruction: "Imported PLC diagnosis") {
                $0.attributes["plcCausalTrail"] = Attribute(.list(trail.map { .string("\($0.kind.rawValue): \($0.headline)") }), provenance: derived)
                if let next = report.recommendedNextCheck {
                    $0.attributes["recommendedNextCheck"] = Attribute(.string(next), provenance: derived)
                }
                $0.attributes["plcSummary"] = Attribute(.string(report.summary), provenance: derived)
            }
            return PLCDiagnosisImport(investigation: investigation, signals: signals, hypotheses: hypotheses, readings: readings.values.sorted())
        }
    }

    /// The canonical signal for a tag: an existing `signal` the controller
    /// contains with that tag, or a new one.
    public func signalObject(for tag: String) throws -> ObjectID {
        let children = try store.objects(try store.relationships(from: controller, kind: .contains).map(\.to))
        if let existing = children.first(where: { $0.type == .signal && $0.attributes["tag"]?.value == .string(tag) }) {
            return existing.id
        }
        let provenance = Provenance(origin: .importer(source: controller), truth: .recorded, timestamp: clock.now(), method: "PLC tag")
        let created = try store.create(ObjectRecord(
            type: .signal, title: tag, attributes: ["tag": Attribute(.string(tag))], provenance: provenance
        ))
        try store.relate(Relationship(kind: .contains, from: controller, to: created.id, provenance: provenance))
        return created.id
    }

    /// Booleans as 0/1; DINT and REAL as numbers; timers and counters have no single value.
    private func number(of value: TagValue) -> Double? {
        if case .bool(let flag) = value { return flag ? 1 : 0 }
        return value.numericValue
    }

    private func unit(of value: TagValue) -> String {
        if case .bool = value { return "bool" }
        return "value"
    }

    private func describe(_ value: TagValue) -> String {
        switch value {
        case .bool(let flag): flag ? "TRUE" : "FALSE"
        default: number(of: value).map { String($0) } ?? "?"
        }
    }

    private func describe(_ location: CausalLocation) -> String {
        "PLC scan \(location.scanNumber), \(location.programName)/\(location.routineName) rung \(location.rungNumber)"
    }
}

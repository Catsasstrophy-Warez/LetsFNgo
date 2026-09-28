import Foundation
import NexusCore
import NexusModel
import NexusPersistence

public struct EvidenceAssessment: Sendable, Hashable {
    public var hypothesis: ObjectID
    public var effect: EvidenceEffect
    /// False for modeled, display, derived or claimed readings: they are
    /// compared for information but never move a hypothesis.
    public var counted: Bool
    public var newState: HypothesisState?
}

/// Symptom → hypotheses → discriminating tests → measurements → update →
/// first divergence → confirmed cause.
///
/// Every step is stored in the canonical graph: the investigation and its
/// hypotheses are objects, evidence is `supports` / `contradicts`
/// relationships from measurements, state changes are revisions, and the
/// first divergence is an event.
public struct InvestigationRuntime: Sendable {
    public let store: NexusStore
    let clock: NexusClock

    /// Only readings of these truth classes count as evidence.
    public static let evidenceTruth: Set<TruthClass> = [.observed, .recorded]

    public init(store: NexusStore, clock: NexusClock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Opening

    @discardableResult
    public func open(symptom: String, subjects: [ObjectID], by author: Origin) throws -> ObjectRecord {
        try store.batch { store in
            let now = clock.now()
            let investigation = try store.create(ObjectRecord(
                type: .investigation, title: symptom,
                attributes: ["status": Attribute(.string("open"))],
                provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
            ))
            for subject in subjects {
                try store.relate(Relationship(
                    kind: .investigates, from: investigation.id, to: subject,
                    provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
                ))
            }
            return investigation
        }
    }

    /// Adds a hypothesis. People's hypotheses are claims; an agent's are interpretations.
    @discardableResult
    public func propose(
        _ statement: String,
        in investigation: ObjectID,
        predictions: [Prediction],
        prior: Double = 1,
        safetyNotes: [String] = [],
        dependsOn evidence: [ObjectID] = [],
        by author: Origin
    ) throws -> Hypothesis {
        guard prior > 0, prior.isFinite else { throw InvestigationError.invalidPrior(prior) }
        return try store.batch { store in
            try requireInvestigation(investigation)
            let now = clock.now()
            let truth: TruthClass = author.defaultTruth == .recorded ? .claimed : author.defaultTruth
            let provenance = Provenance(origin: author, truth: truth, timestamp: now, dependencies: evidence)
            let record = try store.create(ObjectRecord(
                type: .hypothesis, title: statement,
                attributes: Hypothesis.attributes(state: .candidate, predictions: predictions, prior: prior, safetyNotes: safetyNotes),
                provenance: provenance
            ))
            try store.relate(Relationship(kind: .contains, from: investigation, to: record.id, provenance: provenance))
            for dependency in evidence {
                try store.relate(Relationship(kind: .dependsOn, from: record.id, to: dependency, provenance: provenance))
            }
            return try Hypothesis(record: record)
        }
    }

    public func hypotheses(of investigation: ObjectID) throws -> [Hypothesis] {
        try requireInvestigation(investigation)
        let ids = try store.relationships(from: investigation, kind: .contains).map(\.to)
        return try store.objects(ids).filter { $0.type == .hypothesis }.map(Hypothesis.init(record:))
    }

    // MARK: Evidence

    /// Judges a stored measurement against every hypothesis in the investigation.
    ///
    /// Observed and recorded readings are linked as `supports` or `contradicts`,
    /// and a contradicted live hypothesis is rejected. Other truth classes are
    /// judged but not counted: a simulation can suggest, never overrule.
    @discardableResult
    public func assess(_ measurementID: ObjectID, in investigation: ObjectID, by author: Origin) throws -> [EvidenceAssessment] {
        try store.batch { store in
            guard let measurement = try store.measurement(measurementID) else { throw StoreError.notFound(measurementID) }
            let counted = Self.evidenceTruth.contains(measurement.truth)
            let now = clock.now()
            if counted, try !store.relationships(from: investigation, kind: .contains).contains(where: { $0.to == measurementID }) {
                try store.relate(Relationship(
                    kind: .contains, from: investigation, to: measurementID,
                    provenance: Provenance(origin: author, truth: author.defaultTruth, timestamp: now)
                ))
            }

            var assessments: [EvidenceAssessment] = []
            for hypothesis in try hypotheses(of: investigation) {
                let effect = hypothesis.prediction(for: measurement)?.judge(measurement) ?? .notApplicable
                var newState: HypothesisState?
                if counted, effect == .supports || effect == .contradicts {
                    let derived = Provenance(
                        origin: author, truth: .derived, timestamp: now,
                        method: "prediction interval check", dependencies: [measurementID, hypothesis.id]
                    )
                    try store.relate(Relationship(
                        kind: effect == .supports ? .supports : .contradicts,
                        from: measurementID, to: hypothesis.id, provenance: derived
                    ))
                    if effect == .contradicts, hypothesis.state.isLive {
                        let reason = "Contradicted by \(measurement.quantityName) = \(measurement.value.value) \(measurement.value.unit)"
                        try setState(.rejected, of: hypothesis.id, provenance: derived, instruction: reason)
                        try store.record(Event(
                            at: now, kind: .hypothesisRejected, subjects: [investigation, hypothesis.id, measurementID],
                            summary: "Rejected: \(hypothesis.statement)",
                            payload: [
                                "hypothesis": .reference(hypothesis.id), "statement": .string(hypothesis.statement),
                                "reason": .string(reason), "measurement": .reference(measurementID),
                            ],
                            provenance: derived
                        ))
                        newState = .rejected
                    }
                }
                assessments.append(EvidenceAssessment(hypothesis: hypothesis.id, effect: effect, counted: counted, newState: newState))
            }
            return assessments
        }
    }

    /// Ranks candidate measurements by how well they split the live hypotheses.
    public func rankTests(
        _ options: [TestOption],
        for investigation: ObjectID,
        allowHazardous: Bool = false
    ) throws -> [TestRecommendation] {
        TestSelector.rank(options, hypotheses: try hypotheses(of: investigation), allowHazardous: allowHazardous)
    }

    // MARK: Divergence and conclusion

    /// Records where the observed system first departs from what the model
    /// expected. Both readings must be at the same test point and quantity, one
    /// observed or recorded, the other modeled or derived.
    @discardableResult
    public func recordFirstDivergence(
        in investigation: ObjectID,
        observed observedID: ObjectID,
        expected expectedID: ObjectID,
        summary: String,
        by author: Origin
    ) throws -> Event {
        try store.batch { store in
            try requireInvestigation(investigation)
            guard let observed = try store.measurement(observedID) else { throw StoreError.notFound(observedID) }
            guard let expected = try store.measurement(expectedID) else { throw StoreError.notFound(expectedID) }
            guard Self.evidenceTruth.contains(observed.truth), [.modeled, .derived].contains(expected.truth) else {
                throw InvestigationError.divergenceNeedsObservedAndExpected
            }
            guard observed.testPoint == expected.testPoint, observed.quantityName == expected.quantityName,
                  observed.value.unit == expected.value.unit
            else { throw InvestigationError.mismatchedMeasurements }

            let now = clock.now()
            let provenance = Provenance(
                origin: author, truth: .derived, timestamp: now, method: "observed vs modeled",
                dependencies: [observedID, expectedID]
            )
            let deviation = observed.value.value - expected.value.value
            let detail: [String: Value] = [
                "testPoint": .reference(observed.testPoint), "quantity": .string(observed.quantityName),
                "observed": .quantity(observed.value), "expected": .quantity(expected.value),
                "deviation": .double(deviation), "summary": .string(summary),
            ]
            let event = Event(
                at: now, kind: .firstDivergence, subjects: [investigation, observed.testPoint, observedID, expectedID],
                summary: summary, payload: detail, provenance: provenance
            )
            try store.record(event)
            try store.update(investigation, by: author, instruction: "First divergence: \(summary)") {
                $0.attributes["firstDivergence"] = Attribute(.map(detail), provenance: provenance)
            }
            return event
        }
    }

    /// Confirms a root cause. Needs a person and at least one supporting
    /// observed or recorded measurement.
    @discardableResult
    public func confirm(_ hypothesisID: ObjectID, in investigation: ObjectID, by author: Origin) throws -> Hypothesis {
        switch author {
        case .user, .system: break
        default: throw InvestigationError.requiresHuman(author)
        }
        return try store.batch { store in
            let hypothesis = try member(hypothesisID, of: investigation)
            guard hypothesis.state.isLive else { throw InvestigationError.notLive(hypothesisID, hypothesis.state) }
            let support = try store.relationships(to: hypothesisID, kind: .supports).map(\.from)
            let observedSupport = try support.filter { try store.measurement($0).map { Self.evidenceTruth.contains($0.truth) } ?? false }
            guard !observedSupport.isEmpty else { throw InvestigationError.unsupported(hypothesisID) }

            let provenance = Provenance(
                origin: author, truth: .recorded, timestamp: clock.now(), method: "confirmed by technician",
                dependencies: observedSupport
            )
            try setState(.confirmed, of: hypothesisID, provenance: provenance, instruction: "Confirmed as cause")
            try store.update(investigation, by: author, instruction: "Cause confirmed") {
                $0.attributes["status"] = Attribute(.string("causeConfirmed"), provenance: provenance)
                $0.attributes["cause"] = Attribute(.reference(hypothesisID), provenance: provenance)
            }
            try store.record(Event(
                at: provenance.timestamp, kind: .hypothesisConfirmed, subjects: [investigation, hypothesisID],
                summary: "Confirmed as cause: \(hypothesis.statement)",
                payload: ["hypothesis": .reference(hypothesisID), "statement": .string(hypothesis.statement)],
                provenance: provenance
            ))
            return try Hypothesis(record: try store.object(hypothesisID).orThrow(StoreError.notFound(hypothesisID)))
        }
    }

    /// Rules a hypothesis out on a person's judgement, without contradicting
    /// evidence (a part was swapped and ruled out, say). People only: an
    /// agent can argue against a hypothesis but not close it.
    @discardableResult
    public func reject(_ hypothesisID: ObjectID, in investigation: ObjectID, reason: String, by author: Origin) throws -> Hypothesis {
        switch author {
        case .user, .system: break
        default: throw InvestigationError.requiresHuman(author)
        }
        return try store.batch { store in
            let hypothesis = try member(hypothesisID, of: investigation)
            guard hypothesis.state.isLive else { throw InvestigationError.notLive(hypothesisID, hypothesis.state) }
            let provenance = Provenance(origin: author, truth: .recorded, timestamp: clock.now(), method: "rejected by technician")
            let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction = text.isEmpty ? "Rejected" : "Rejected: \(text)"
            try setState(.rejected, of: hypothesisID, provenance: provenance, instruction: instruction)
            try store.record(Event(
                at: provenance.timestamp, kind: .hypothesisRejected, subjects: [investigation, hypothesisID],
                summary: "Rejected: \(hypothesis.statement)",
                payload: ["hypothesis": .reference(hypothesisID), "statement": .string(hypothesis.statement), "reason": .string(text)],
                provenance: provenance
            ))
            return try Hypothesis(record: try store.object(hypothesisID).orThrow(StoreError.notFound(hypothesisID)))
        }
    }

    // MARK: Repair

    /// Ties repair work to the investigation and puts it on the timeline.
    ///
    /// The investigation `produced` the procedure and the task (unless they
    /// are already linked), and a `repair` event records that the repair was
    /// planned. The task itself belongs to the task runtime; this only ties
    /// it to the case.
    @discardableResult
    public func recordRepair(
        in investigation: ObjectID,
        task: ObjectID,
        procedure: ObjectID?,
        summary: String,
        by author: Origin
    ) throws -> Event {
        try store.batch { store in
            try requireInvestigation(investigation)
            let now = clock.now()
            let provenance = Provenance(origin: author, truth: author.defaultTruth, timestamp: now, method: "repair planned")
            let produced = Set(try store.relationships(from: investigation, kind: .produced).map(\.to))
            for id in [procedure, task].compactMap({ $0 }) where !produced.contains(id) {
                try store.relate(Relationship(kind: .produced, from: investigation, to: id, provenance: provenance))
            }
            var payload: [String: Value] = ["task": .reference(task), "summary": .string(summary)]
            if let procedure { payload["procedure"] = .reference(procedure) }
            let event = Event(
                at: now, kind: .repair, subjects: [investigation, task] + (procedure.map { [$0] } ?? []),
                summary: summary, payload: payload, provenance: provenance
            )
            try store.record(event)
            return event
        }
    }

    /// Records that the repair was verified by observed or recorded readings,
    /// which join the investigation's evidence.
    @discardableResult
    public func recordVerification(
        in investigation: ObjectID,
        evidence: [ObjectID],
        task: ObjectID? = nil,
        summary: String,
        by author: Origin
    ) throws -> Event {
        try store.batch { store in
            try requireInvestigation(investigation)
            guard !evidence.isEmpty else { throw InvestigationError.unverified(investigation) }
            for id in evidence {
                guard let reading = try store.measurement(id) else { throw StoreError.notFound(id) }
                guard Self.evidenceTruth.contains(reading.truth) else { throw InvestigationError.notEvidence(id, reading.truth) }
            }
            let now = clock.now()
            let provenance = Provenance(
                origin: author, truth: author.defaultTruth, timestamp: now, method: "repair verification", dependencies: evidence
            )
            let contained = Set(try store.relationships(from: investigation, kind: .contains).map(\.to))
            for id in evidence where !contained.contains(id) {
                try store.relate(Relationship(kind: .contains, from: investigation, to: id, provenance: provenance))
            }
            var payload: [String: Value] = ["summary": .string(summary), "evidence": .list(evidence.map(Value.reference))]
            if let task { payload["task"] = .reference(task) }
            let event = Event(
                at: now, kind: .repairVerified, subjects: [investigation] + (task.map { [$0] } ?? []) + evidence,
                summary: summary, payload: payload, provenance: provenance
            )
            try store.record(event)
            return event
        }
    }

    /// Closes the investigation once the repair is verified.
    @discardableResult
    public func close(_ investigation: ObjectID, resolution: String, verifiedBy evidence: [ObjectID], by author: Origin) throws -> ObjectRecord {
        try store.batch { store in
            try requireInvestigation(investigation)
            let provenance = Provenance(
                origin: author, truth: author.defaultTruth, timestamp: clock.now(), method: "repair verification", dependencies: evidence
            )
            let closed = try store.update(investigation, by: author, instruction: "Closed: \(resolution)") {
                $0.attributes["status"] = Attribute(.string("closed"), provenance: provenance)
                $0.attributes["resolution"] = Attribute(.string(resolution), provenance: provenance)
            }
            var eventProvenance = provenance
            eventProvenance.revision = closed.revision
            try store.record(Event(
                at: provenance.timestamp, kind: .investigationClosed, subjects: [investigation] + evidence,
                summary: "Closed: \(resolution)",
                payload: ["resolution": .string(resolution), "evidence": .list(evidence.map(Value.reference))],
                provenance: eventProvenance
            ))
            return closed
        }
    }

    /// Investigations that contain a hypothesis or a measurement.
    public func investigations(containing member: ObjectID) throws -> [ObjectID] {
        try store.objects(try store.relationships(to: member, kind: .contains).map(\.from))
            .filter { $0.type == .investigation }
            .map(\.id)
    }

    // MARK: Private

    private func setState(_ state: HypothesisState, of id: ObjectID, provenance: Provenance, instruction: String) throws {
        try store.update(id, by: provenance.origin, instruction: instruction) {
            $0.attributes["state"] = Attribute(.string(state.rawValue), provenance: provenance)
        }
    }

    private func member(_ hypothesisID: ObjectID, of investigation: ObjectID) throws -> Hypothesis {
        guard let hypothesis = try hypotheses(of: investigation).first(where: { $0.id == hypothesisID }) else {
            throw InvestigationError.notInInvestigation(hypothesis: hypothesisID, investigation: investigation)
        }
        return hypothesis
    }

    private func requireInvestigation(_ id: ObjectID) throws {
        guard let record = try store.object(id) else { throw StoreError.notFound(id) }
        guard record.type == .investigation else { throw InvestigationError.notAnInvestigation(id) }
    }
}

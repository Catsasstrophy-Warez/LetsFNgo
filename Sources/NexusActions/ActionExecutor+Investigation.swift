import Foundation
import NexusCore
import NexusInvestigation
import NexusLearning
import NexusMeasurement
import NexusModel
import NexusPersistence
import NexusProjects
import NexusSimulation
import NexusTasks

extension ActionExecutor {
    /// Truth classes a person may record through `recordMeasurement`.
    public static let recordableTruth: Set<TruthClass> = [.observed, .display, .recorded]

    // MARK: Investigation

    /// Opens an investigation of `equipment` and adds it to the projects the
    /// equipment belongs to (directly or through its containers). Proposes
    /// nothing: hypotheses come from the person or, as drafts, from an agent.
    @discardableResult
    public func startInvestigation(on equipment: ObjectID, symptom: String, in project: ObjectID? = nil) throws -> ActionResult<InvestigationStart> {
        try startInvestigation(on: [equipment], symptom: symptom, in: project)
    }

    /// `startInvestigation` over several subjects.
    @discardableResult
    public func startInvestigation(on subjects: [ObjectID], symptom: String, in project: ObjectID? = nil) throws -> ActionResult<InvestigationStart> {
        guard !subjects.isEmpty else { throw ActionError.emptySelection(.investigate) }
        let symptom = try Self.nonEmpty(symptom, .symptom)
        _ = try requireAll(subjects)
        return try store.batch { _ in
            var containing: [ObjectID] = []
            if let project {
                containing = [project]
            } else {
                for subject in subjects {
                    for found in try enclosingProjects(of: subject) where !containing.contains(found) { containing.append(found) }
                }
            }
            let investigation = try investigations.open(symptom: symptom, subjects: subjects, by: actor)
            for project in containing {
                try projects.add(investigation.id, to: project, by: actor)
            }
            try note(.investigationOpened, "Investigation started: \(symptom)", about: [investigation.id] + subjects, payload: ["symptom": .string(symptom)])
            return ActionResult(
                detail: InvestigationStart(investigation: investigation, subjects: subjects, projects: containing),
                produced: [investigation.id], screen: .investigation, focus: investigation.id, summary: "Investigating: \(symptom)"
            )
        }
    }

    /// Adds a hypothesis. A person's hypothesis is a claim until evidence and
    /// a person's confirmation say otherwise.
    @discardableResult
    public func proposeHypothesis(
        _ statement: String,
        in investigation: ObjectID,
        predictions: [Prediction] = [],
        prior: Double = 1,
        safetyNotes: [String] = [],
        dependsOn evidence: [ObjectID] = []
    ) throws -> ActionResult<Hypothesis> {
        let statement = try Self.nonEmpty(statement, .statement)
        return try store.batch { _ in
            let hypothesis = try investigations.propose(
                statement, in: investigation, predictions: predictions, prior: prior, safetyNotes: safetyNotes, dependsOn: evidence, by: actor
            )
            try note(.userEdit, "Hypothesis: \(statement)", about: [investigation, hypothesis.id])
            return ActionResult(
                detail: hypothesis, produced: [hypothesis.id], changed: [investigation], screen: .investigation, focus: investigation,
                summary: "Added hypothesis"
            )
        }
    }

    /// Ranks candidate tests for the live hypotheses. Writes nothing.
    public func rankTests(_ options: [TestOption], for investigation: ObjectID, allowHazardous: Bool = false) throws -> ActionResult<[TestRecommendation]> {
        let ranked = try investigations.rankTests(options, for: investigation, allowHazardous: allowHazardous)
        return ActionResult(
            detail: ranked, screen: .investigation, focus: investigation,
            summary: ranked.first.map { "Next test: \($0.option.title)" } ?? "No test splits the live hypotheses"
        )
    }

    /// Records one reading at a test point and, with an investigation, judges
    /// it against every hypothesis.
    ///
    /// - The unit is validated with `Units`.
    /// - With an instrument whose spec is known, uncertainty, resolution and
    ///   range come from its `AccuracySpec` unless given here, and a reading
    ///   outside the range is refused.
    /// - `truth` is `.observed` for a reading taken, `.display` for a value
    ///   read off a device's screen (which never moves a hypothesis), or
    ///   `.recorded` for a trusted system record.
    /// - The reading is linked `measuredAt` its test point and a `measured`
    ///   event goes on the timeline.
    @discardableResult
    public func recordMeasurement(
        _ quantity: String,
        value: Double,
        unit: String,
        at testPoint: ObjectID,
        instrument: InstrumentModel? = nil,
        range: ClosedRange<Double>? = nil,
        uncertainty: Double? = nil,
        loading: String? = nil,
        sampledAt: Date? = nil,
        truth: TruthClass = .observed,
        investigation: ObjectID? = nil,
        tests: [TestOption] = []
    ) throws -> ActionResult<MeasurementOutcome> {
        try recordMeasurement(
            quantity, value: value, unit: unit, at: testPoint, instrument: instrument, instrumentID: instrument?.record.id, range: range,
            uncertainty: uncertainty, loading: loading, sampledAt: sampledAt, truth: truth, investigation: investigation, tests: tests
        )
    }

    // swift-format-ignore: FunctionParameterCount
    func recordMeasurement(
        _ quantity: String,
        value: Double,
        unit: String,
        at testPoint: ObjectID,
        instrument: InstrumentModel?,
        instrumentID: ObjectID?,
        range: ClosedRange<Double>?,
        uncertainty: Double?,
        loading: String?,
        sampledAt: Date?,
        truth: TruthClass,
        investigation: ObjectID?,
        tests: [TestOption]
    ) throws -> ActionResult<MeasurementOutcome> {
        let quantity = try Self.nonEmpty(quantity, .quantity)
        let unit = unit.trimmingCharacters(in: .whitespaces)
        do {
            try Units.validate(unit)
        } catch {
            throw ActionError.invalidUnit(unit, reason: String(describing: error))
        }
        guard Self.recordableTruth.contains(truth) else { throw ActionError.invalidTruth(truth, allowed: Self.recordableTruth) }
        guard value.isFinite else { throw ActionError.invalidValue(.value, reason: "Not a finite number") }
        if let uncertainty, !(uncertainty.isFinite && uncertainty >= 0) {
            throw ActionError.invalidValue(.uncertainty, reason: "Uncertainty must be zero or more")
        }
        let point = try require(testPoint)
        if let instrumentID { _ = try require(instrumentID, is: [.instrument]) }
        if let investigation { _ = try require(investigation, is: [.investigation]) }

        let reading = Quantity(value, unit)
        var accuracy: ReadingAccuracy?
        if let instrument {
            do {
                accuracy = try instrument.accuracy(for: reading)
            } catch UnitError.incompatible {
                throw ActionError.incompatibleInstrument(instrument.record.id, readingUnit: unit, specUnit: instrument.spec.resolution.unit)
            }
        }
        let low = range?.lowerBound ?? accuracy?.rangeLow
        let high = range?.upperBound ?? accuracy?.rangeHigh
        if let range, !range.contains(value) { throw ActionError.outOfRange(value: value, low: low, high: high) }

        let now = clock.now()
        let method = accuracy.map { "instrument spec \($0.method)" } ?? (truth == .display ? "read from display" : "manual entry")
        let measurement = MeasurementRecord(
            quantityName: quantity, value: reading, uncertainty: uncertainty ?? accuracy?.uncertainty, resolution: accuracy?.resolution,
            rangeLow: low, rangeHigh: high, testPoint: testPoint, instrument: instrumentID, loading: loading,
            sampledAt: sampledAt ?? now,
            provenance: Provenance(origin: actor, truth: truth, timestamp: now, method: method)
        )

        return try store.batch { store in
            try store.add(measurement)
            try store.relate(
                Relationship(
                    kind: .measuredAt, from: measurement.id, to: testPoint,
                    provenance: Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now)
                ))
            var payload: [String: Value] = [
                "quantity": .string(quantity), "value": .quantity(reading), "truth": .string(truth.rawValue),
            ]
            if let spread = measurement.uncertainty { payload["uncertainty"] = .double(spread) }
            if let instrumentID { payload["instrument"] = .reference(instrumentID) }
            let valueText = String(format: "%.6g", value)
            try note(
                .readingEntered, "\(quantity) = \(valueText) \(unit) at \(point.title) (\(truth.rawValue))",
                about: [measurement.id, testPoint] + (investigation.map { [$0] } ?? []) + (instrumentID.map { [$0] } ?? []),
                payload: payload
            )

            var assessments: [EvidenceAssessment] = []
            var changes: [HypothesisChange] = []
            var ranked: [TestRecommendation] = []
            if let investigation {
                let before = Dictionary(uniqueKeysWithValues: try investigations.hypotheses(of: investigation).map { ($0.id, $0.state) })
                assessments = try investigations.assess(measurement.id, in: investigation, by: actor)
                changes = assessments.compactMap { assessment in
                    guard let to = assessment.newState, let from = before[assessment.hypothesis], from != to else { return nil }
                    return HypothesisChange(hypothesis: assessment.hypothesis, from: from, to: to)
                }
                if !tests.isEmpty { ranked = try investigations.rankTests(tests, for: investigation) }
            }
            let summary = "Recorded \(quantity) \(valueText) \(unit)" + (changes.isEmpty ? "" : "; \(changes.count) hypotheses changed")
            return ActionResult(
                detail: MeasurementOutcome(measurement: measurement, assessments: assessments, changes: changes, rankedTests: ranked),
                produced: [measurement.id], changed: changes.map(\.hypothesis) + (investigation.map { [$0] } ?? []),
                screen: investigation == nil ? .objectDetail : .investigation, focus: investigation ?? measurement.id, summary: summary
            )
        }
    }

    /// Records where the observed system departs from the model: an observed
    /// (or recorded) reading against a modeled (or derived) one at the same
    /// test point. The investigation defaults to the one holding the observed reading.
    @discardableResult
    public func markFirstDivergence(
        observed: ObjectID,
        expected: ObjectID,
        summary: String? = nil,
        in investigation: ObjectID? = nil
    ) throws -> ActionResult<Event> {
        let investigation = try investigation ?? soleInvestigation(containing: observed)
        guard let reading = try store.measurement(observed) else { throw StoreError.notFound(observed) }
        guard let model = try store.measurement(expected) else { throw StoreError.notFound(expected) }
        let text =
            summary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? {
                let place = (try? store.object(reading.testPoint)?.title) ?? nil
                return "\(reading.quantityName) at \(place ?? "the test point") is \(String(format: "%.3g", reading.value.value)) \(reading.value.unit)"
                    + " where the model expects \(String(format: "%.3g", model.value.value)) \(model.value.unit)"
            }()
        let event = try investigations.recordFirstDivergence(in: investigation, observed: observed, expected: expected, summary: text, by: actor)
        return ActionResult(
            detail: event, changed: [investigation], screen: .investigation, focus: investigation, summary: "First divergence: \(text)"
        )
    }

    /// Confirms a root cause. People only; needs supporting observed evidence.
    @discardableResult
    public func confirmHypothesis(_ hypothesis: ObjectID, in investigation: ObjectID? = nil) throws -> ActionResult<Hypothesis> {
        let investigation = try investigation ?? soleInvestigation(containing: hypothesis)
        let confirmed = try investigations.confirm(hypothesis, in: investigation, by: actor)
        return ActionResult(
            detail: confirmed, changed: [hypothesis, investigation], screen: .investigation, focus: investigation,
            summary: "Confirmed: \(confirmed.statement)"
        )
    }

    /// Rules a hypothesis out on the person's judgement. People only.
    @discardableResult
    public func rejectHypothesis(_ hypothesis: ObjectID, reason: String, in investigation: ObjectID? = nil) throws -> ActionResult<Hypothesis> {
        let investigation = try investigation ?? soleInvestigation(containing: hypothesis)
        let rejected = try investigations.reject(hypothesis, in: investigation, reason: reason, by: actor)
        return ActionResult(
            detail: rejected, changed: [hypothesis, investigation], screen: .investigation, focus: investigation,
            summary: "Rejected: \(rejected.statement)"
        )
    }

    // MARK: Repair

    /// A repair task through `TaskRuntime`, for an investigation whose cause
    /// is confirmed.
    ///
    /// The task follows `procedure`, belongs to the investigation's project,
    /// and cannot be marked done until a verification reading is attached
    /// (`verifyRepair`). The investigation `produced` the procedure and the
    /// task, and a `repair` event goes on the timeline.
    @discardableResult
    public func createRepairTask(
        for investigation: ObjectID,
        procedure: ObjectID,
        title: String? = nil,
        owner: Origin? = nil,
        dueAt: Date? = nil
    ) throws -> ActionResult<TaskItem> {
        let record = try require(investigation, is: [.investigation])
        guard case .reference(let cause)? = record.attributes["cause"]?.value else { throw ActionError.causeNotConfirmed(investigation) }
        let steps = try require(procedure, is: [.procedure])
        let causeStatement = try store.object(cause)?.title ?? "the confirmed cause"
        let title = try Self.nonEmpty(title ?? "Repair: \(steps.title)", .title)
        let condition = """
            Repair verified: an observed or recorded reading taken after this task was created is attached as evidence \
            and shows the symptom (\(record.title)) gone. Cause addressed: \(causeStatement).
            """
        return try store.batch { store in
            let project = try projects.projects(containing: investigation).first?.id
            let task = try tasks.create(
                title, successCondition: condition, owner: owner, dueAt: dueAt, requiredEvidence: [.attached(.measurement)], in: project,
                attributes: [
                    "repairFor": Attribute(.reference(investigation)), "procedure": Attribute(.reference(procedure)),
                    "cause": Attribute(.reference(cause)),
                ],
                by: actor
            )
            let now = clock.now()
            try store.relate(
                Relationship(
                    kind: .follows, from: task.id, to: procedure, validFrom: now,
                    provenance: Provenance(origin: actor, truth: actor.defaultTruth, timestamp: now)
                ))
            try investigations.recordRepair(in: investigation, task: task.id, procedure: procedure, summary: "Repair task created: \(title)", by: actor)
            return ActionResult(
                detail: task, produced: [task.id], changed: [investigation], screen: .taskWorkflow, focus: task.id, summary: "Created \(title)"
            )
        }
    }

    /// Attaches verification readings to a repair task, records the
    /// verification on the investigation, and marks the task done. Readings
    /// must be observed or recorded and taken after the task was created.
    @discardableResult
    public func verifyRepair(_ task: ObjectID, evidence: [ObjectID], summary: String? = nil) throws -> ActionResult<RepairVerification> {
        let item = try tasks.task(task)
        guard case .reference(let investigation)? = item.record.attributes["repairFor"]?.value else { throw ActionError.notARepairTask(task) }
        guard !evidence.isEmpty else { throw ActionError.missingValue(.evidence) }
        for id in evidence {
            guard let reading = try store.measurement(id) else { throw ActionError.wrongType(id, expected: [.measurement], got: try require(id).type) }
            guard reading.sampledAt >= item.record.createdAt else { throw ActionError.evidenceBeforeRepair(id) }
        }
        let text = summary ?? "Repair verified by \(evidence.count) reading\(evidence.count == 1 ? "" : "s")"
        return try store.batch { _ in
            for id in evidence {
                try tasks.attachEvidence(id, to: task, by: actor)
            }
            let event = try investigations.recordVerification(in: investigation, evidence: evidence, task: task, summary: text, by: actor)
            var updated = try tasks.task(task)
            if updated.status != .done {
                updated = try tasks.setStatus(.done, of: task, reason: text, by: actor)
            }
            return ActionResult(
                detail: RepairVerification(task: updated, investigation: investigation, event: event),
                changed: [task, investigation], screen: .investigation, focus: investigation, summary: text
            )
        }
    }

    /// Closes the investigation. Without explicit evidence, the readings
    /// attached to its repair tasks are cited.
    @discardableResult
    public func closeInvestigation(_ investigation: ObjectID, resolution: String, verifiedBy evidence: [ObjectID]? = nil) throws -> ActionResult<ObjectRecord> {
        let resolution = try Self.nonEmpty(resolution, .resolution)
        _ = try require(investigation, is: [.investigation])
        let cited = try evidence ?? repairEvidence(of: investigation)
        let closed = try investigations.close(investigation, resolution: resolution, verifiedBy: cited, by: actor)
        return ActionResult(detail: closed, changed: [investigation], screen: .investigation, focus: investigation, summary: "Closed: \(resolution)")
    }

    /// The investigation report, with a citation for every figure.
    @discardableResult
    public func generateReport(for investigation: ObjectID) throws -> ActionResult<ObjectRecord> {
        let report = try investigations.generateReport(for: investigation, by: actor)
        return ActionResult(detail: report, produced: [report.id], screen: .document, focus: report.id, summary: report.title)
    }

    /// A replayable training scenario from a resolved investigation. The
    /// loop, fault and tests default to the loop binding of the
    /// investigation's subjects. With no loop, the generic path
    /// (`LearningRuntime.makeScenario(from:by:)`) finds the simulator from
    /// the subjects, such as a vehicle's charging system.
    @discardableResult
    public func generateTrainingScenario(
        from investigation: ObjectID,
        loop: InstrumentLoop? = nil,
        fault: SimulatedFault? = nil,
        tests: [TestOption]? = nil
    ) throws -> ActionResult<TrainingScenario> {
        let record = try require(investigation, is: [.investigation])
        let subjects = try store.relationships(from: investigation, kind: .investigates).map(\.to)
        var binding: LoopBinding?
        for subject in subjects where binding == nil {
            binding = try self.binding(for: subject)
        }
        guard let loop = loop ?? binding?.loop else {
            // No loop: let the learning runtime find another domain's simulator (a vehicle's charging system, say).
            do {
                let scenario = try learning.makeScenario(from: investigation, by: actor)
                return ActionResult(
                    detail: scenario, produced: [scenario.id], screen: .objectDetail, focus: scenario.id,
                    summary: "Training scenario from \(record.title)"
                )
            } catch LearningError.noSimulator {
                throw ActionError.unsupported(
                    Unsupported(
                        command: .generateTrainingScenario, subject: investigation, type: record.type,
                        reason: "Training scenarios replay a simulation, and nothing simulable is known for \(record.title)."
                    ))
            }
        }
        guard let fault = fault ?? binding?.faults.first else {
            throw ActionError.unsupported(
                Unsupported(
                    command: .generateTrainingScenario, subject: investigation, type: record.type,
                    reason: "A training scenario needs the fault to replay; none is known for this loop."
                ))
        }
        let scenario = try learning.makeScenario(from: investigation, loop: loop, fault: fault, tests: tests ?? binding?.tests ?? [], by: actor)
        return ActionResult(
            detail: scenario, produced: [scenario.id], screen: .objectDetail, focus: scenario.id, summary: "Training scenario from \(record.title)"
        )
    }

    // MARK: Private

    func soleInvestigation(containing member: ObjectID) throws -> ObjectID {
        let found = try investigations.investigations(containing: member)
        switch found.count {
        case 1: return found[0]
        case 0: throw ActionError.noInvestigation(member)
        default: throw ActionError.ambiguousInvestigation(member, candidates: found)
        }
    }

    /// Readings attached to the investigation's repair tasks.
    func repairEvidence(of investigation: ObjectID) throws -> [ObjectID] {
        let produced = try store.objects(try store.relationships(from: investigation, kind: .produced).map(\.to)).filter { $0.type == .task }
        var evidence: [ObjectID] = []
        for task in produced {
            for link in try store.relationships(from: task.id, kind: .evidencedBy) where link.validTo == nil && !evidence.contains(link.to) {
                if try store.measurement(link.to) != nil { evidence.append(link.to) }
            }
        }
        return evidence
    }
}

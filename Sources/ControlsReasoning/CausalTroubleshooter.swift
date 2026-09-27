import Foundation
import ControlsPLC

public enum CausalStepKind: String, Codable, Sendable {
    case symptom
    case controllingWrite
    case blockedTransition
    case comparison
    case upstreamBlocker
    case timerState
    case rootCondition
    case ambiguity
}

public struct CausalLocation: Equatable, Sendable {
    public let scanNumber: UInt64
    public let stepIndex: Int
    public let taskName: String
    public let programName: String
    public let routineName: String
    public let rungNumber: Int
    public let nodePath: String?

    public init(scanNumber: UInt64, stepIndex: Int, taskName: String, programName: String, routineName: String, rungNumber: Int, nodePath: String?) {
        self.scanNumber = scanNumber
        self.stepIndex = stepIndex
        self.taskName = taskName
        self.programName = programName
        self.routineName = routineName
        self.rungNumber = rungNumber
        self.nodePath = nodePath
    }
}

public struct CausalStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: CausalStepKind
    public let target: String
    public let headline: String
    public let detail: String
    public let observedValue: TagValue?
    public let desiredValue: TagValue?
    public let location: CausalLocation?

    public init(id: UUID = UUID(), kind: CausalStepKind, target: String, headline: String, detail: String, observedValue: TagValue? = nil, desiredValue: TagValue? = nil, location: CausalLocation? = nil) {
        self.id = id
        self.kind = kind
        self.target = target
        self.headline = headline
        self.detail = detail
        self.observedValue = observedValue
        self.desiredValue = desiredValue
        self.location = location
    }
}

public struct CausalTrail: Equatable, Sendable {
    public let target: String
    public let desiredValue: TagValue
    public let steps: [CausalStep]
    public let reachedRootCondition: Bool
    public let summary: String

    public init(target: String, desiredValue: TagValue, steps: [CausalStep], reachedRootCondition: Bool, summary: String) {
        self.target = target
        self.desiredValue = desiredValue
        self.steps = steps
        self.reachedRootCondition = reachedRootCondition
        self.summary = summary
    }
}



public enum HypothesisStatus: String, Codable, Sendable, CaseIterable {
    case confirmedBlocker
    case contributingCondition
    case healthyEvidence
    case unknownUnobserved

    public var displayName: String {
        switch self {
        case .confirmedBlocker: return "Confirmed blocker"
        case .contributingCondition: return "Contributing condition"
        case .healthyEvidence: return "Healthy evidence"
        case .unknownUnobserved: return "Unknown / unobserved"
        }
    }
}

public struct DiagnosticHypothesis: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let instruction: String
    public let status: HypothesisStatus
    public let observedValue: TagValue?
    public let requiredValue: TagValue?
    public let detail: String
    public let location: CausalLocation?

    public init(id: UUID = UUID(), target: String, instruction: String, status: HypothesisStatus, observedValue: TagValue? = nil, requiredValue: TagValue? = nil, detail: String, location: CausalLocation? = nil) {
        self.id = id
        self.target = target
        self.instruction = instruction
        self.status = status
        self.observedValue = observedValue
        self.requiredValue = requiredValue
        self.detail = detail
        self.location = location
    }
}

public struct MultiHypothesisReport: Equatable, Sendable {
    public let target: String
    public let desiredValue: TagValue
    public let observedValue: TagValue?
    public let hypotheses: [DiagnosticHypothesis]
    public let primaryRootTrail: CausalTrail?
    public let recommendedNextCheck: String?
    public let summary: String

    public init(target: String, desiredValue: TagValue, observedValue: TagValue?, hypotheses: [DiagnosticHypothesis], primaryRootTrail: CausalTrail?, recommendedNextCheck: String?, summary: String) {
        self.target = target
        self.desiredValue = desiredValue
        self.observedValue = observedValue
        self.hypotheses = hypotheses
        self.primaryRootTrail = primaryRootTrail
        self.recommendedNextCheck = recommendedNextCheck
        self.summary = summary
    }

    public var confirmedBlockers: [DiagnosticHypothesis] { hypotheses.filter { $0.status == .confirmedBlocker } }
    public var contributingConditions: [DiagnosticHypothesis] { hypotheses.filter { $0.status == .contributingCondition } }
    public var healthyEvidence: [DiagnosticHypothesis] { hypotheses.filter { $0.status == .healthyEvidence } }
    public var unknownEvidence: [DiagnosticHypothesis] { hypotheses.filter { $0.status == .unknownUnobserved } }
}

public struct CausalExecutionRecord: Equatable, Sendable {
    public let scanNumber: UInt64
    public let stepIndex: Int
    public let taskName: String
    public let programName: String
    public let routineName: String
    public let rungNumber: Int
    public let trace: RungTrace

    public init(scanNumber: UInt64, stepIndex: Int, taskName: String, programName: String, routineName: String, rungNumber: Int, trace: RungTrace) {
        self.scanNumber = scanNumber
        self.stepIndex = stepIndex
        self.taskName = taskName
        self.programName = programName
        self.routineName = routineName
        self.rungNumber = rungNumber
        self.trace = trace
    }
}

/// Bounded execution provenance used for cross-rung troubleshooting. It follows what actually
/// executed, including attempted destinations whose rung was false, rather than reconstructing
/// causality from the current source code or current tag table.
public struct CausalJournal: Sendable {
    public private(set) var records: [CausalExecutionRecord] = []
    public var maximumRecords: Int

    public init(maximumRecords: Int = 2_000) {
        self.maximumRecords = max(100, maximumRecords)
    }

    public mutating func clear() { records.removeAll(keepingCapacity: true) }

    public mutating func ingest(step: ControllerDebugStep, scanNumber: UInt64, stepIndex: Int) {
        ingest(CausalExecutionRecord(
            scanNumber: scanNumber,
            stepIndex: stepIndex,
            taskName: step.taskName,
            programName: step.programName,
            routineName: step.routineName,
            rungNumber: step.rungNumber,
            trace: step.trace
        ))
    }

    public mutating func ingest(_ record: CausalExecutionRecord) {
        records.append(record)
        if records.count > maximumRecords { records.removeFirst(records.count - maximumRecords) }
    }

    public func explainWhy(target: String, shouldBe desiredValue: TagValue, observedValue: TagValue? = nil, maxDepth: Int = 16) -> CausalTrail {
        var steps: [CausalStep] = [CausalStep(
            kind: .symptom,
            target: target,
            headline: "Why isn't \(target) \(statePhrase(desiredValue))?",
            detail: observedValue.map { "Observed \(target) = \(display($0)); expected \(display(desiredValue))." } ?? "Trace backward through the recorded controller execution.",
            observedValue: observedValue,
            desiredValue: desiredValue
        )]
        var visited: Set<String> = []
        let rooted = trace(target: target, desired: desiredValue, beforeRecord: records.count - 1, depth: 0, maxDepth: maxDepth, visited: &visited, steps: &steps)
        let root = steps.last
        let summary = rooted && root != nil
            ? "Most defensible recorded root condition: \(root!.headline)"
            : "The recorded history narrows the symptom but does not yet contain a unique root condition."
        return CausalTrail(target: target, desiredValue: desiredValue, steps: steps, reachedRootCondition: rooted, summary: summary)
    }



    /// Technician-oriented multi-hypothesis analysis. Instead of following only one blocker,
    /// this inspects every relevant permissive on the most recent controlling rung and labels
    /// what the recorded execution can actually prove. Later false conditions on a series path
    /// are "contributing" rather than "confirmed" when an earlier instruction already removed
    /// rung power.
    public func diagnose(target: String, shouldBe desiredValue: TagValue, observedValue: TagValue? = nil) -> MultiHypothesisReport {
        guard let writer = latestWriter(of: target, beforeRecord: records.count - 1) else {
            let trail = explainWhy(target: target, shouldBe: desiredValue, observedValue: observedValue)
            return MultiHypothesisReport(
                target: target,
                desiredValue: desiredValue,
                observedValue: observedValue,
                hypotheses: [],
                primaryRootTrail: trail,
                recommendedNextCheck: trail.steps.last?.target,
                summary: "No recorded controller writer was found for \(target); verify the source of this field or state value."
            )
        }

        let trace = writer.record.trace
        let writerIndex = trace.instructions.firstIndex(where: { $0.nodePath == writer.instruction.nodePath }) ?? max(0, trace.instructions.count - 1)
        let candidates = Array(trace.instructions.prefix(writerIndex))
        var hypotheses: [DiagnosticHypothesis] = []

        for instruction in candidates {
            guard let hypothesis = classifyPermissive(instruction, record: writer.record, trace: trace) else { continue }
            hypotheses.append(hypothesis)
        }

        hypotheses.sort { lhs, rhs in
            let rank: [HypothesisStatus: Int] = [.confirmedBlocker: 0, .contributingCondition: 1, .unknownUnobserved: 2, .healthyEvidence: 3]
            let l = rank[lhs.status] ?? 99
            let r = rank[rhs.status] ?? 99
            if l != r { return l < r }
            return (lhs.location?.rungNumber ?? 0, lhs.target) < (rhs.location?.rungNumber ?? 0, rhs.target)
        }

        let primary = hypotheses.first { $0.status == .confirmedBlocker } ?? hypotheses.first { $0.status == .contributingCondition }
        let rootTrail: CausalTrail? = primary.flatMap { hypothesis in
            guard let required = hypothesis.requiredValue else { return nil }
            return explainWhy(target: hypothesis.target, shouldBe: required, observedValue: hypothesis.observedValue)
        }

        let nextCheck: String?
        if let unknown = hypotheses.first(where: { $0.status == .unknownUnobserved }) {
            nextCheck = "Measure or observe \(unknown.target); the controller history does not yet prove its state."
        } else if let root = rootTrail?.steps.last, root.kind != .symptom {
            nextCheck = "Verify \(root.target) at its physical or upstream source."
        } else if let primary {
            nextCheck = "Verify \(primary.target) and its upstream permissives."
        } else {
            nextCheck = nil
        }

        let confirmed = hypotheses.filter { $0.status == .confirmedBlocker }.count
        let contributing = hypotheses.filter { $0.status == .contributingCondition }.count
        let healthy = hypotheses.filter { $0.status == .healthyEvidence }.count
        let unknown = hypotheses.filter { $0.status == .unknownUnobserved }.count
        let summary = "\(target) did not reach \(statePhrase(desiredValue)). Recorded permissives: \(confirmed) confirmed blocker(s), \(contributing) contributing condition(s), \(healthy) healthy, \(unknown) unknown."

        return MultiHypothesisReport(
            target: target,
            desiredValue: desiredValue,
            observedValue: observedValue,
            hypotheses: hypotheses,
            primaryRootTrail: rootTrail,
            recommendedNextCheck: nextCheck,
            summary: summary
        )
    }

    private func trace(target: String, desired: TagValue, beforeRecord: Int, depth: Int, maxDepth: Int, visited: inout Set<String>, steps: inout [CausalStep]) -> Bool {
        guard depth < maxDepth, beforeRecord >= 0 else { return false }
        let visitKey = "\(target)|\(display(desired))|\(beforeRecord)"
        guard visited.insert(visitKey).inserted else {
            steps.append(CausalStep(kind: .ambiguity, target: target, headline: "Causal loop detected around \(target)", detail: "The recorded dependency path revisited the same target; stopping instead of inventing a root cause."))
            return false
        }

        guard let writer = latestWriter(of: target, beforeRecord: beforeRecord) else {
            let observed = latestObservation(of: target, beforeRecord: beforeRecord)
            let observedText = observed.map { display($0.value) } ?? "unknown"
            steps.append(CausalStep(
                kind: .rootCondition,
                target: target,
                headline: "\(target) remained \(observedText)",
                detail: "No controller instruction in the recorded history wrote this condition before the failure path. Treat this as an external, field, operator, configuration, or earlier-state condition and verify it at the source.",
                observedValue: observed?.value,
                desiredValue: desired,
                location: observed?.location
            ))
            return true
        }

        let instruction = writer.instruction
        let location = writer.record.location(nodePath: instruction.nodePath)
        let baseTarget = baseTag(target)

        if target.contains("."), ["TON", "TOF", "RTO"].contains(instruction.mnemonic), baseTag(target) == baseTarget {
            if let timer = instruction.observations.last(where: { $0.label == "after" })?.value.timerValue {
                let member = target.split(separator: ".").last.map(String.init) ?? ""
                let memberValue = timerMember(timer, member: member)
                steps.append(CausalStep(
                    kind: .timerState,
                    target: target,
                    headline: "\(target) was \(memberValue.map(display) ?? "unknown") after \(instruction.mnemonic)",
                    detail: timerDetail(timer: timer, member: member, incoming: instruction.incomingCondition),
                    observedValue: memberValue,
                    desiredValue: desired,
                    location: location
                ))
            }
        } else {
            let changed = instruction.changes.first { baseTag($0.tag) == baseTarget }
            let kind: CausalStepKind = instruction.incomingCondition ? .controllingWrite : .blockedTransition
            steps.append(CausalStep(
                kind: kind,
                target: target,
                headline: instruction.incomingCondition
                    ? "\(instruction.mnemonic) \(instruction.reference) controlled \(target)"
                    : "\(instruction.mnemonic) \(instruction.reference) was the transition path, but its rung was blocked",
                detail: changed.map { "Recorded write: \(display($0.oldValue)) → \(display($0.newValue))." } ?? "This instruction can write \(baseTarget), but its execution condition did not produce the desired state.",
                observedValue: changed?.newValue,
                desiredValue: desired,
                location: location
            ))
        }

        if !instruction.incomingCondition {
            guard let blocker = upstreamBlocker(for: instruction, in: writer.record.trace) else { return false }
            return explainBlocker(blocker, recordIndex: writer.recordIndex, record: writer.record, desiredDownstream: desired, depth: depth, maxDepth: maxDepth, visited: &visited, steps: &steps)
        }

        // For a timer done-bit that is false while the timer is enabled, the causal answer may
        // legitimately be "still timing" rather than an upstream fault.
        if target.hasSuffix(".DN"), ["TON", "RTO"].contains(instruction.mnemonic), let timer = instruction.observations.last(where: { $0.label == "after" })?.value.timerValue, !timer.DN {
            if instruction.incomingCondition {
                steps.append(CausalStep(
                    kind: .rootCondition,
                    target: target,
                    headline: "\(baseTarget).ACC has not reached \(baseTarget).PRE",
                    detail: "ACC = \(timer.ACC) ms, PRE = \(timer.PRE) ms. The enabling path is true, so the timer is still timing rather than blocked upstream.",
                    observedValue: .dint(timer.ACC),
                    desiredValue: .dint(timer.PRE),
                    location: location
                ))
                return true
            }
        }

        if let blocker = upstreamBlocker(for: instruction, in: writer.record.trace) {
            return explainBlocker(blocker, recordIndex: writer.recordIndex, record: writer.record, desiredDownstream: desired, depth: depth, maxDepth: maxDepth, visited: &visited, steps: &steps)
        }

        // If this writer executed but did not create the desired state, use its read dependency
        // when one is available. This is especially useful for data moves/math in later lessons.
        if let dependency = instruction.readTags.first {
            let observed = observationValue(for: dependency, in: instruction)
            steps.append(CausalStep(kind: .upstreamBlocker, target: dependency, headline: "\(dependency) influenced \(instruction.mnemonic)", detail: "Recorded operand = \(observed.map(display) ?? "unknown").", observedValue: observed, location: location))
            return trace(target: dependency, desired: desired, beforeRecord: writer.recordIndex - 1, depth: depth + 1, maxDepth: maxDepth, visited: &visited, steps: &steps)
        }
        return false
    }

    private func explainBlocker(_ blocker: InstructionTrace, recordIndex: Int, record: CausalExecutionRecord, desiredDownstream: TagValue, depth: Int, maxDepth: Int, visited: inout Set<String>, steps: inout [CausalStep]) -> Bool {
        let location = CausalLocation(scanNumber: record.scanNumber, stepIndex: record.stepIndex, taskName: record.taskName, programName: record.programName, routineName: record.routineName, rungNumber: record.rungNumber, nodePath: blocker.nodePath)

        switch blocker.mnemonic {
        case "XIC", "XIO":
            guard let tag = blocker.readTags.first else { return false }
            let observed = observationValue(for: tag, in: blocker)
            let desired: TagValue = .bool(blocker.mnemonic == "XIC")
            steps.append(CausalStep(
                kind: .upstreamBlocker,
                target: tag,
                headline: "\(blocker.mnemonic) \(tag) blocked the path",
                detail: "\(tag) was \(observed.map(display) ?? "unknown"); this instruction required \(display(desired)) to pass power.",
                observedValue: observed,
                desiredValue: desired,
                location: location
            ))
            return trace(target: tag, desired: desired, beforeRecord: recordIndex - 1, depth: depth + 1, maxDepth: maxDepth, visited: &visited, steps: &steps)

        case "EQU", "NEQ", "LES", "LEQ", "GRT", "GEQ", "LIM":
            let result = blocker.observations.first(where: { $0.label == "comparison-result" })?.value.boolValue ?? blocker.outgoingCondition
            steps.append(CausalStep(kind: .comparison, target: blocker.reference, headline: "\(blocker.mnemonic) comparison was \(result ? "TRUE" : "FALSE")", detail: comparisonDetail(blocker), observedValue: .bool(result), desiredValue: .bool(true), location: location))

            if blocker.mnemonic == "EQU", blocker.readTags.count == 1, let tag = blocker.readTags.first, let actual = observationValue(for: tag, in: blocker), let expected = otherComparisonOperandValue(excluding: tag, instruction: blocker) {
                steps.append(CausalStep(kind: .upstreamBlocker, target: tag, headline: "\(tag) was \(display(actual)), not \(display(expected))", detail: "The state/value comparison prevented the downstream transition.", observedValue: actual, desiredValue: expected, location: location))
                return trace(target: tag, desired: expected, beforeRecord: recordIndex - 1, depth: depth + 1, maxDepth: maxDepth, visited: &visited, steps: &steps)
            }

            if let tag = blocker.readTags.first, let actual = observationValue(for: tag, in: blocker) {
                steps.append(CausalStep(kind: .rootCondition, target: tag, headline: "\(tag) made the comparison false", detail: "Recorded value: \(display(actual)). Multiple comparison operands prevent a unique backward expectation without more history.", observedValue: actual, location: location))
                return true
            }
            return false

        default:
            steps.append(CausalStep(kind: .upstreamBlocker, target: blocker.reference, headline: "\(blocker.mnemonic) blocked the downstream path", detail: "Rung-condition-in was TRUE and rung-condition-out became FALSE.", location: location))
            if let tag = blocker.readTags.first {
                return trace(target: tag, desired: desiredDownstream, beforeRecord: recordIndex - 1, depth: depth + 1, maxDepth: maxDepth, visited: &visited, steps: &steps)
            }
            return false
        }
    }



    private func classifyPermissive(_ instruction: InstructionTrace, record: CausalExecutionRecord, trace: RungTrace) -> DiagnosticHypothesis? {
        let location = record.location(nodePath: instruction.nodePath)
        switch instruction.mnemonic {
        case "XIC", "XIO":
            guard let tag = instruction.readTags.first else { return nil }
            let observed = observationValue(for: tag, in: instruction)
            let required: TagValue = .bool(instruction.mnemonic == "XIC")
            let satisfied = observed == required
            // A false contact inside a parallel branch is not a blocker when the parallel
            // merge still carried power through another branch. Exclude it from the failed
            // permissive list rather than teaching the learner that every false branch matters.
            if !satisfied, isInsidePassingParallel(instruction, trace: trace) { return nil }
            let status: HypothesisStatus
            if observed == nil {
                status = .unknownUnobserved
            } else if satisfied {
                status = .healthyEvidence
            } else if instruction.incomingCondition && !instruction.outgoingCondition {
                status = .confirmedBlocker
            } else {
                status = .contributingCondition
            }
            let detail: String
            switch status {
            case .confirmedBlocker:
                detail = "This instruction had power in and removed power from the rung."
            case .contributingCondition:
                detail = "This permissive was unsatisfied, but an earlier condition had already removed rung power, so it is relevant without being independently proven as the stop point."
            case .healthyEvidence:
                detail = "The recorded operand satisfied this permissive."
            case .unknownUnobserved:
                detail = "The execution record does not contain enough operand evidence to classify this permissive."
            }
            return DiagnosticHypothesis(target: tag, instruction: "\(instruction.mnemonic) \(tag)", status: status, observedValue: observed, requiredValue: required, detail: detail, location: location)

        case "EQU", "NEQ", "LES", "LEQ", "GRT", "GEQ", "LIM":
            let result = instruction.observations.first(where: { $0.label == "comparison-result" })?.value.boolValue
            let status: HypothesisStatus
            if result == nil { status = .unknownUnobserved }
            else if result == true { status = .healthyEvidence }
            else if instruction.incomingCondition && !instruction.outgoingCondition { status = .confirmedBlocker }
            else { status = .contributingCondition }
            let target = instruction.readTags.first ?? instruction.reference
            let observed = instruction.readTags.first.flatMap { observationValue(for: $0, in: instruction) }
            return DiagnosticHypothesis(
                target: target,
                instruction: "\(instruction.mnemonic) \(instruction.reference)",
                status: status,
                observedValue: observed,
                requiredValue: nil,
                detail: "Comparison result was \(result.map { $0 ? "TRUE" : "FALSE" } ?? "unobserved"). \(comparisonDetail(instruction))",
                location: location
            )

        default:
            return nil
        }
    }



    private func isInsidePassingParallel(_ instruction: InstructionTrace, trace: RungTrace) -> Bool {
        guard let path = instruction.nodePath else { return false }
        let parts = path.split(separator: ".").map(String.init)
        guard let branchSegmentIndex = parts.lastIndex(where: { segment in
            segment.hasPrefix("p") && Int(segment.dropFirst()) != nil
        }), branchSegmentIndex > 0 else { return false }
        let parentPath = parts[..<branchSegmentIndex].joined(separator: ".")
        return trace.powerNodes.first(where: { $0.path == parentPath && $0.kind == .parallel })?.outgoingCondition == true
    }

    private func latestWriter(of target: String, beforeRecord: Int) -> (recordIndex: Int, record: CausalExecutionRecord, instruction: InstructionTrace)? {
        let base = baseTag(target)
        guard beforeRecord >= 0 else { return nil }
        for recordIndex in stride(from: min(beforeRecord, records.count - 1), through: 0, by: -1) {
            let record = records[recordIndex]
            for instruction in record.trace.instructions.reversed() where instruction.writeTags.contains(where: { baseTag($0) == base }) {
                return (recordIndex, record, instruction)
            }
        }
        return nil
    }

    private func latestObservation(of target: String, beforeRecord: Int) -> (value: TagValue, location: CausalLocation)? {
        guard beforeRecord >= 0 else { return nil }
        for recordIndex in stride(from: min(beforeRecord, records.count - 1), through: 0, by: -1) {
            let record = records[recordIndex]
            for instruction in record.trace.instructions.reversed() {
                if let value = observationValue(for: target, in: instruction) {
                    return (value, CausalLocation(scanNumber: record.scanNumber, stepIndex: record.stepIndex, taskName: record.taskName, programName: record.programName, routineName: record.routineName, rungNumber: record.rungNumber, nodePath: instruction.nodePath))
                }
            }
        }
        return nil
    }

    private func upstreamBlocker(for instruction: InstructionTrace, in trace: RungTrace) -> InstructionTrace? {
        guard let index = trace.instructions.firstIndex(where: { $0.nodePath == instruction.nodePath }), index > 0 else { return nil }
        return trace.instructions[..<index].last { $0.incomingCondition && !$0.outgoingCondition }
    }

    private func observationValue(for tag: String, in instruction: InstructionTrace) -> TagValue? {
        if let exact = instruction.observations.first(where: { $0.label == tag })?.value { return exact }
        let base = baseTag(tag)
        if tag != base, let structured = instruction.observations.last(where: { $0.label == "after" || $0.label == "before" })?.value {
            return structuredMember(structured, target: tag)
        }
        return nil
    }

    private func otherComparisonOperandValue(excluding tag: String, instruction: InstructionTrace) -> TagValue? {
        instruction.observations.first { $0.label != "comparison-result" && $0.label != tag }?.value
    }

    private func comparisonDetail(_ instruction: InstructionTrace) -> String {
        instruction.observations.filter { $0.label != "comparison-result" }.map { "\($0.label)=\(display($0.value))" }.joined(separator: ", ")
    }

    private func structuredMember(_ value: TagValue, target: String) -> TagValue? {
        let member = target.split(separator: ".").last.map(String.init) ?? ""
        switch value {
        case let .timer(timer): return timerMember(timer, member: member)
        case let .counter(counter):
            switch member { case "PRE": return .dint(counter.PRE); case "ACC": return .dint(counter.ACC); case "CU": return .bool(counter.CU); case "CD": return .bool(counter.CD); case "DN": return .bool(counter.DN); case "OV": return .bool(counter.OV); case "UN": return .bool(counter.UN); default: return nil }
        default: return nil
        }
    }

    private func timerMember(_ timer: TimerValue, member: String) -> TagValue? {
        switch member { case "PRE": return .dint(timer.PRE); case "ACC": return .dint(timer.ACC); case "EN": return .bool(timer.EN); case "TT": return .bool(timer.TT); case "DN": return .bool(timer.DN); default: return nil }
    }

    private func timerDetail(timer: TimerValue, member: String, incoming: Bool) -> String {
        if member == "DN" && !timer.DN {
            return incoming ? "Timer enabled. ACC=\(timer.ACC) ms, PRE=\(timer.PRE) ms." : "Timer enabling rung was false, so its done condition could not progress."
        }
        return "EN=\(timer.EN), TT=\(timer.TT), DN=\(timer.DN), ACC=\(timer.ACC), PRE=\(timer.PRE)."
    }

    private func baseTag(_ target: String) -> String { target.split(separator: ".").first.map(String.init) ?? target }

    private func statePhrase(_ value: TagValue) -> String {
        if case let .bool(v) = value { return v ? "ON" : "OFF" }
        return display(value)
    }

    private func display(_ value: TagValue) -> String { TraceExplainer.display(value) }
}

private extension TagValue {
    var timerValue: TimerValue? { if case let .timer(v) = self { return v }; return nil }
}

private extension CausalExecutionRecord {
    func location(nodePath: String?) -> CausalLocation {
        CausalLocation(scanNumber: scanNumber, stepIndex: stepIndex, taskName: taskName, programName: programName, routineName: routineName, rungNumber: rungNumber, nodePath: nodePath)
    }
}

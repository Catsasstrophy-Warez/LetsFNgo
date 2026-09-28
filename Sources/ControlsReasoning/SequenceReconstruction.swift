import Foundation
import ControlsPLC

public enum SequenceReconstructionPhase: String, Codable, Sendable, CaseIterable {
    case rootDeviation
    case propagatingConsequence
    case protectiveResponse
    case fault
    case unresolved

    public var displayName: String {
        switch self {
        case .rootDeviation: return "ROOT DEVIATION"
        case .propagatingConsequence: return "PROPAGATING CONSEQUENCE"
        case .protectiveResponse: return "PROTECTIVE / SHUTDOWN RESPONSE"
        case .fault: return "FAULT"
        case .unresolved: return "UNRESOLVED"
        }
    }
}

public enum SequenceDeviationKind: String, Codable, Sendable {
    case late
    case early
    case missing
    case unexpected
    case differentValue
}

public struct KnownGoodCycle: Equatable, Sendable {
    public let name: String
    public let anchorMilliseconds: Int64
    public let signalSamples: [FlightSignalSample]
    public let taskExecutions: [TaskExecutionStamp]
    public let events: [TemporalEventMarker]

    public init(
        name: String = "Known-good cycle",
        anchorMilliseconds: Int64,
        signalSamples: [FlightSignalSample],
        taskExecutions: [TaskExecutionStamp] = [],
        events: [TemporalEventMarker] = []
    ) {
        self.name = name
        self.anchorMilliseconds = anchorMilliseconds
        self.signalSamples = signalSamples.sorted { $0.milliseconds < $1.milliseconds }
        self.taskExecutions = taskExecutions.sorted { $0.milliseconds < $1.milliseconds }
        self.events = events.sorted { $0.milliseconds < $1.milliseconds }
    }

    public init(name: String = "Known-good cycle", capture: FlightFrozenCapture, anchorMilliseconds: Int64? = nil) {
        self.init(
            name: name,
            anchorMilliseconds: anchorMilliseconds ?? capture.triggerMilliseconds,
            signalSamples: capture.signalSamples,
            taskExecutions: capture.taskExecutions,
            events: capture.events
        )
    }
}

public struct SequenceDeviation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let layer: FlightSignalLayer
    public let kind: SequenceDeviationKind
    public let expectedRelativeMilliseconds: Int64?
    public let observedRelativeMilliseconds: Int64?
    public let timingDeltaMilliseconds: Int64?
    public let expectedValue: TagValue?
    public let observedValue: TagValue?
    public let explanation: String

    public init(
        id: UUID = UUID(),
        target: String,
        layer: FlightSignalLayer,
        kind: SequenceDeviationKind,
        expectedRelativeMilliseconds: Int64?,
        observedRelativeMilliseconds: Int64?,
        timingDeltaMilliseconds: Int64?,
        expectedValue: TagValue?,
        observedValue: TagValue?,
        explanation: String
    ) {
        self.id = id
        self.target = target
        self.layer = layer
        self.kind = kind
        self.expectedRelativeMilliseconds = expectedRelativeMilliseconds
        self.observedRelativeMilliseconds = observedRelativeMilliseconds
        self.timingDeltaMilliseconds = timingDeltaMilliseconds
        self.expectedValue = expectedValue
        self.observedValue = observedValue
        self.explanation = explanation
    }
}

public struct SequenceReconstructionStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let phase: SequenceReconstructionPhase
    public let target: String
    public let relativeMilliseconds: Int64
    public let headline: String
    public let detail: String
    public let causalSupport: Bool

    public init(id: UUID = UUID(), phase: SequenceReconstructionPhase, target: String, relativeMilliseconds: Int64, headline: String, detail: String, causalSupport: Bool) {
        self.id = id
        self.phase = phase
        self.target = target
        self.relativeMilliseconds = relativeMilliseconds
        self.headline = headline
        self.detail = detail
        self.causalSupport = causalSupport
    }
}

public struct SequenceReconstructionReport: Equatable, Sendable {
    public let referenceName: String
    public let triggerName: String
    public let earliestDeviation: SequenceDeviation?
    public let deviations: [SequenceDeviation]
    public let steps: [SequenceReconstructionStep]
    public let summary: String

    public var rootDeviation: SequenceReconstructionStep? { steps.first { $0.phase == .rootDeviation } }
    public var propagatingConsequences: [SequenceReconstructionStep] { steps.filter { $0.phase == .propagatingConsequence } }
    public var protectiveResponses: [SequenceReconstructionStep] { steps.filter { $0.phase == .protectiveResponse } }
}

private struct SequenceTransition: Equatable {
    let target: String
    let layer: FlightSignalLayer
    let milliseconds: Int64
    let relativeMilliseconds: Int64
    let value: TagValue
}

public extension ControlsFlightRecorder {
    /// Reconstructs a frozen fault sequence against a known-good reference cycle.
    /// Timing difference alone establishes divergence, not causation. Recorded causal links are
    /// required before downstream transitions are labeled propagating consequences.
    func reconstructPreFaultSequence(
        against reference: KnownGoodCycle,
        toleranceMilliseconds: Int64 = 25,
        protectiveTargets: Set<String> = []
    ) -> SequenceReconstructionReport? {
        guard let capture = frozenCapture else { return nil }
        let tolerance = max(0, toleranceMilliseconds)
        let expected = sequenceTransitions(in: reference.signalSamples, anchor: reference.anchorMilliseconds)
        let observed = sequenceTransitions(in: capture.signalSamples, anchor: capture.triggerMilliseconds)
        let deviations = compareSequenceTransitions(expected: expected, observed: observed, tolerance: tolerance)
            .sorted { lhs, rhs in
                let l = lhs.observedRelativeMilliseconds ?? lhs.expectedRelativeMilliseconds ?? Int64.max
                let r = rhs.observedRelativeMilliseconds ?? rhs.expectedRelativeMilliseconds ?? Int64.max
                if l != r { return l < r }
                return lhs.target < rhs.target
            }

        // Prefer the earliest pre-trigger deviation. Post-trigger differences are usually aftermath.
        let earliest = deviations.first {
            ($0.observedRelativeMilliseconds ?? $0.expectedRelativeMilliseconds ?? 1) < 0
        } ?? deviations.first

        var steps: [SequenceReconstructionStep] = []
        if let earliest {
            let time = earliest.observedRelativeMilliseconds ?? earliest.expectedRelativeMilliseconds ?? 0
            steps.append(SequenceReconstructionStep(
                phase: .rootDeviation,
                target: earliest.target,
                relativeMilliseconds: time,
                headline: "Earliest meaningful divergence: \(earliest.target)",
                detail: earliest.explanation + " This is the first divergence from the reference cycle, not by itself proof of the physical root cause.",
                causalSupport: false
            ))

            let reachable = downstreamTargets(from: earliest.target)
            let rootTime = time
            let transitionCandidates = observed
                .filter { $0.relativeMilliseconds >= rootTime && $0.relativeMilliseconds <= 0 && $0.target != earliest.target }
                .sorted { $0.relativeMilliseconds < $1.relativeMilliseconds }

            var emitted: Set<String> = []
            for transition in transitionCandidates where !emitted.contains(transition.target) {
                if protectiveTargets.contains(transition.target) {
                    steps.append(SequenceReconstructionStep(
                        phase: .protectiveResponse,
                        target: transition.target,
                        relativeMilliseconds: transition.relativeMilliseconds,
                        headline: "Protective response: \(transition.target)",
                        detail: "\(transition.target) changed after the initial divergence and is authored as a protective/shutdown response.",
                        causalSupport: reachable.contains(transition.target)
                    ))
                    emitted.insert(transition.target)
                } else if reachable.contains(transition.target) {
                    steps.append(SequenceReconstructionStep(
                        phase: .propagatingConsequence,
                        target: transition.target,
                        relativeMilliseconds: transition.relativeMilliseconds,
                        headline: "Consequence: \(transition.target)",
                        detail: "\(transition.target) changed \(transition.relativeMilliseconds - rootTime) ms after the earliest divergence, and recorded causal provenance connects it downstream.",
                        causalSupport: true
                    ))
                    emitted.insert(transition.target)
                }
            }
        }

        steps.append(SequenceReconstructionStep(
            phase: .fault,
            target: capture.triggerName,
            relativeMilliseconds: 0,
            headline: capture.triggerName,
            detail: "Flight-recorder trigger. Events after T0 are treated as aftermath unless separate evidence says otherwise.",
            causalSupport: false
        ))

        let summary: String
        if let earliest {
            let timing: String
            if let delta = earliest.timingDeltaMilliseconds {
                if delta > 0 { timing = "\(abs(delta)) ms late" }
                else if delta < 0 { timing = "\(abs(delta)) ms early" }
                else { timing = "at the expected time but with different state" }
            } else {
                timing = earliest.kind == .missing ? "missing" : "unexpected"
            }
            summary = "The first meaningful departure from \(reference.name) was \(earliest.target) (\(timing)). The reconstruction then separates recorded downstream consequences and authored protective responses from the T0 fault."
        } else {
            summary = "No meaningful pre-fault divergence from \(reference.name) was found within the \(tolerance) ms timing tolerance. The capture may require a different reference cycle, more channels, or a tighter capture window."
        }

        return SequenceReconstructionReport(
            referenceName: reference.name,
            triggerName: capture.triggerName,
            earliestDeviation: earliest,
            deviations: deviations,
            steps: steps.sorted { lhs, rhs in
                if lhs.relativeMilliseconds != rhs.relativeMilliseconds { return lhs.relativeMilliseconds < rhs.relativeMilliseconds }
                return phaseRank(lhs.phase) < phaseRank(rhs.phase)
            },
            summary: summary
        )
    }

    private func sequenceTransitions(in samples: [FlightSignalSample], anchor: Int64) -> [SequenceTransition] {
        let grouped = Dictionary(grouping: samples) { "\($0.target)#\($0.layer.rawValue)" }
        return grouped.values.flatMap { channel -> [SequenceTransition] in
            let sorted = channel.sorted {
                if $0.milliseconds != $1.milliseconds { return $0.milliseconds < $1.milliseconds }
                return ($0.stepIndex ?? -1) < ($1.stepIndex ?? -1)
            }
            guard sorted.count > 1 else { return [] }
            return (1..<sorted.count).compactMap { index in
                guard sorted[index].value != sorted[index - 1].value else { return nil }
                let sample = sorted[index]
                return SequenceTransition(target: sample.target, layer: sample.layer, milliseconds: sample.milliseconds, relativeMilliseconds: sample.milliseconds - anchor, value: sample.value)
            }
        }.sorted {
            if $0.relativeMilliseconds != $1.relativeMilliseconds { return $0.relativeMilliseconds < $1.relativeMilliseconds }
            return $0.target < $1.target
        }
    }

    private func compareSequenceTransitions(expected: [SequenceTransition], observed: [SequenceTransition], tolerance: Int64) -> [SequenceDeviation] {
        let expectedGroups = Dictionary(grouping: expected) { "\($0.target)#\($0.layer.rawValue)" }
        let observedGroups = Dictionary(grouping: observed) { "\($0.target)#\($0.layer.rawValue)" }
        let keys = Set(expectedGroups.keys).union(observedGroups.keys)
        var result: [SequenceDeviation] = []

        for key in keys {
            let exp = expectedGroups[key] ?? []
            let obs = observedGroups[key] ?? []
            let count = max(exp.count, obs.count)
            for index in 0..<count {
                let e = index < exp.count ? exp[index] : nil
                let o = index < obs.count ? obs[index] : nil
                let target = e?.target ?? o!.target
                let layer = e?.layer ?? o!.layer
                if let e, let o {
                    if e.value != o.value {
                        result.append(SequenceDeviation(target: target, layer: layer, kind: .differentValue, expectedRelativeMilliseconds: e.relativeMilliseconds, observedRelativeMilliseconds: o.relativeMilliseconds, timingDeltaMilliseconds: o.relativeMilliseconds - e.relativeMilliseconds, expectedValue: e.value, observedValue: o.value, explanation: "\(target) reached a different state than the matching reference transition."))
                        continue
                    }
                    let delta = o.relativeMilliseconds - e.relativeMilliseconds
                    if abs(delta) > tolerance {
                        let kind: SequenceDeviationKind = delta > 0 ? .late : .early
                        result.append(SequenceDeviation(target: target, layer: layer, kind: kind, expectedRelativeMilliseconds: e.relativeMilliseconds, observedRelativeMilliseconds: o.relativeMilliseconds, timingDeltaMilliseconds: delta, expectedValue: e.value, observedValue: o.value, explanation: "\(target) transitioned \(abs(delta)) ms \(delta > 0 ? "later" : "earlier") than the known-good cycle."))
                    }
                } else if let e {
                    result.append(SequenceDeviation(target: target, layer: layer, kind: .missing, expectedRelativeMilliseconds: e.relativeMilliseconds, observedRelativeMilliseconds: nil, timingDeltaMilliseconds: nil, expectedValue: e.value, observedValue: nil, explanation: "The reference cycle changes \(target) here, but the fault capture contains no matching transition."))
                } else if let o {
                    result.append(SequenceDeviation(target: target, layer: layer, kind: .unexpected, expectedRelativeMilliseconds: nil, observedRelativeMilliseconds: o.relativeMilliseconds, timingDeltaMilliseconds: nil, expectedValue: nil, observedValue: o.value, explanation: "\(target) changed in the fault capture with no corresponding transition in the reference cycle."))
                }
            }
        }
        return result
    }

    private func downstreamTargets(from root: String) -> Set<String> {
        var result: Set<String> = []
        var frontier = [root]
        while let current = frontier.first {
            frontier.removeFirst()
            for link in causalLinks where link.upstream == current && !result.contains(link.downstream) {
                result.insert(link.downstream)
                frontier.append(link.downstream)
            }
        }
        return result
    }

    private func phaseRank(_ phase: SequenceReconstructionPhase) -> Int {
        switch phase {
        case .rootDeviation: return 0
        case .propagatingConsequence: return 1
        case .protectiveResponse: return 2
        case .fault: return 3
        case .unresolved: return 4
        }
    }
}

import Foundation
import ControlsPLC

public enum ObservationSource: String, Codable, Sendable, CaseIterable {
    case learnerMeasurement
    case simulator
    case instructor
}

public struct TroubleshootingObservation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let target: String
    public let value: TagValue
    public let source: ObservationSource
    public let kind: EvidenceKind
    public let confidence: EvidenceConfidence
    public let condition: MeasurementCondition
    public let note: String?

    public init(id: UUID = UUID(), sequence: Int, target: String, value: TagValue, source: ObservationSource = .learnerMeasurement, kind: EvidenceKind = .measurement, confidence: EvidenceConfidence = .high, condition: MeasurementCondition = .unspecified, note: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.target = target
        self.value = value
        self.source = source
        self.kind = kind
        self.confidence = confidence
        self.condition = condition
        self.note = note
    }
}

/// Explicit physical/electrical topology supplied by the machine or lesson model. The ladder
/// provenance journal should never invent these relationships from tag names.
public struct DiagnosticDependency: Identifiable, Equatable, Sendable {
    public var id: String { "\(upstream)->\(downstream)" }
    public let upstream: String
    public let downstream: String
    public let expectedUpstreamValue: TagValue
    public let expectedDownstreamValue: TagValue
    public let verificationTarget: String?
    public let verificationInstruction: String?
    public let description: String?

    public init(upstream: String, downstream: String, expectedUpstreamValue: TagValue = .bool(true), expectedDownstreamValue: TagValue = .bool(true), verificationTarget: String? = nil, verificationInstruction: String? = nil, description: String? = nil) {
        self.upstream = upstream
        self.downstream = downstream
        self.expectedUpstreamValue = expectedUpstreamValue
        self.expectedDownstreamValue = expectedDownstreamValue
        self.verificationTarget = verificationTarget
        self.verificationInstruction = verificationInstruction
        self.description = description
    }
}

public struct DiagnosticTopology: Equatable, Sendable {
    public var dependencies: [DiagnosticDependency]

    public init(dependencies: [DiagnosticDependency] = []) {
        self.dependencies = dependencies
    }

    public func upstream(of downstream: String) -> [DiagnosticDependency] {
        dependencies.filter { $0.downstream == downstream }
    }
}

public enum AdaptiveCandidateStatus: String, Codable, Sendable, CaseIterable {
    case unresolved
    case eliminated
    case confirmed
    case superseded

    public var displayName: String {
        switch self {
        case .unresolved: return "Unresolved"
        case .eliminated: return "Eliminated"
        case .confirmed: return "Confirmed by measurement"
        case .superseded: return "Explained downstream"
        }
    }
}

public struct AdaptiveCauseCandidate: Identifiable, Equatable, Sendable {
    public var id: String { target }
    public let target: String
    public let expectedHealthyValue: TagValue
    public let coveredHypotheses: [String]
    public let status: AdaptiveCandidateStatus
    public let latestObservation: TroubleshootingObservation?
    public let depth: Int
    public let rationale: String

    public init(target: String, expectedHealthyValue: TagValue, coveredHypotheses: [String], status: AdaptiveCandidateStatus, latestObservation: TroubleshootingObservation?, depth: Int, rationale: String) {
        self.target = target
        self.expectedHealthyValue = expectedHealthyValue
        self.coveredHypotheses = coveredHypotheses
        self.status = status
        self.latestObservation = latestObservation
        self.depth = depth
        self.rationale = rationale
    }
}

public struct AdaptiveTroubleshootingState: Equatable, Sendable {
    public let symptomTarget: String
    public let desiredValue: TagValue
    public let observations: [TroubleshootingObservation]
    public let candidates: [AdaptiveCauseCandidate]
    public let strategy: DiagnosticStrategy
    public let contradictions: [EvidenceContradiction]
    public let evidenceSummary: EvidenceSummary
    public let temporalPatterns: [TemporalPattern]
    public let temporalRecommendation: TemporalCaptureRecommendation?
    public let confirmedCause: AdaptiveCauseCandidate?
    public let isResolved: Bool
    public let summary: String

    public init(symptomTarget: String, desiredValue: TagValue, observations: [TroubleshootingObservation], candidates: [AdaptiveCauseCandidate], strategy: DiagnosticStrategy, contradictions: [EvidenceContradiction] = [], evidenceSummary: EvidenceSummary? = nil, temporalPatterns: [TemporalPattern] = [], temporalRecommendation: TemporalCaptureRecommendation? = nil, confirmedCause: AdaptiveCauseCandidate?, isResolved: Bool, summary: String) {
        self.symptomTarget = symptomTarget
        self.desiredValue = desiredValue
        self.observations = observations
        self.candidates = candidates
        self.strategy = strategy
        self.contradictions = contradictions
        self.evidenceSummary = evidenceSummary ?? EvidenceSummary(observations: observations, contradictions: contradictions)
        self.temporalPatterns = temporalPatterns
        self.temporalRecommendation = temporalRecommendation
        self.confirmedCause = confirmedCause
        self.isResolved = isResolved
        self.summary = summary
    }
}

/// Stateful troubleshooting dialogue. Every observation updates the candidate set and the next
/// measurement recommendation. The underlying CausalJournal remains immutable evidence; this
/// layer records what the learner subsequently measured.
public struct AdaptiveTroubleshootingSession: Sendable {
    public let report: MultiHypothesisReport
    public let journal: CausalJournal
    public var topology: DiagnosticTopology
    public var profiles: [MeasurementProfile]
    public var policy: DiagnosticStrategyPolicy
    public private(set) var observations: [TroubleshootingObservation] = []
    public private(set) var temporalObservations: [TemporalObservation] = []
    public private(set) var eventMarkers: [TemporalEventMarker] = []
    public var controllerScanPeriodMilliseconds: Int = 10

    public init(report: MultiHypothesisReport, journal: CausalJournal, topology: DiagnosticTopology = DiagnosticTopology(), profiles: [MeasurementProfile] = [], policy: DiagnosticStrategyPolicy = DiagnosticStrategyPolicy()) {
        self.report = report
        self.journal = journal
        self.topology = topology
        self.profiles = profiles
        self.policy = policy
    }

    public mutating func recordMeasurement(target: String, value: TagValue, source: ObservationSource = .learnerMeasurement, confidence: EvidenceConfidence = .high, condition: MeasurementCondition = .unspecified, note: String? = nil) -> AdaptiveTroubleshootingState {
        recordEvidence(target: target, value: value, kind: .measurement, source: source, confidence: confidence, condition: condition, note: note)
    }

    public mutating func recordEvidence(target: String, value: TagValue, kind: EvidenceKind, source: ObservationSource = .learnerMeasurement, confidence: EvidenceConfidence = .medium, condition: MeasurementCondition = .unspecified, note: String? = nil) -> AdaptiveTroubleshootingState {
        observations.append(TroubleshootingObservation(sequence: observations.count + 1, target: target, value: value, source: source, kind: kind, confidence: confidence, condition: condition, note: note))
        return currentState()
    }

    public mutating func recordTemporalObservation(_ observation: TemporalObservation) -> AdaptiveTroubleshootingState {
        temporalObservations.append(observation)
        return currentState()
    }

    public mutating func recordEventMarker(_ event: TemporalEventMarker) -> AdaptiveTroubleshootingState {
        eventMarkers.append(event)
        return currentState()
    }

    public func currentState() -> AdaptiveTroubleshootingState {
        let latestByTarget = Dictionary(grouping: observations, by: \ .target).compactMapValues(\.last)
        let basePaths = causalExpectations()
        var candidates: [String: AdaptiveCauseCandidate] = [:]

        for (target, expectation) in basePaths {
            let observation = latestByTarget[target]
            let status: AdaptiveCandidateStatus
            let rationale: String
            if let observation {
                if !observation.confidence.supportsHardPruning {
                    status = .unresolved
                    rationale = "Measured \(display(observation.value)) at \(observation.confidence.displayName.lowercased()) confidence. Treat this as evidence, not a pruning fact; verify before eliminating or confirming this branch."
                } else if observation.value == expectation.expectedHealthyValue {
                    status = .eliminated
                    rationale = "Measured \(display(observation.value)), which matches the value required for this point to be healthy on the recorded failure path."
                } else {
                    status = .confirmed
                    rationale = "Measured \(display(observation.value)); the failure path required \(display(expectation.expectedHealthyValue)). This condition is now confirmed abnormal."
                }
            } else {
                status = .unresolved
                rationale = "Not yet measured during this troubleshooting session."
            }
            candidates[target] = AdaptiveCauseCandidate(
                target: target,
                expectedHealthyValue: expectation.expectedHealthyValue,
                coveredHypotheses: expectation.covered.sorted(),
                status: status,
                latestObservation: observation,
                depth: expectation.depth,
                rationale: rationale
            )
        }

        // A confirmed common cause explains downstream candidates it covers. Keep them visible,
        // but do not waste the next-check ranking on them until the confirmed cause is resolved.
        let initiallyConfirmed = candidates.values
            .filter { $0.status == .confirmed }
            .sorted { lhs, rhs in
                if lhs.coveredHypotheses.count != rhs.coveredHypotheses.count { return lhs.coveredHypotheses.count > rhs.coveredHypotheses.count }
                return lhs.depth > rhs.depth
            }
            .first

        if let initiallyConfirmed {
            let covered = Set(initiallyConfirmed.coveredHypotheses)
            for (key, candidate) in candidates where candidate.status == .unresolved && key != initiallyConfirmed.target {
                if !covered.isDisjoint(with: candidate.coveredHypotheses) && candidate.depth < initiallyConfirmed.depth {
                    candidates[key] = AdaptiveCauseCandidate(
                        target: candidate.target,
                        expectedHealthyValue: candidate.expectedHealthyValue,
                        coveredHypotheses: candidate.coveredHypotheses,
                        status: .superseded,
                        latestObservation: candidate.latestObservation,
                        depth: candidate.depth,
                        rationale: "A more upstream measured abnormal condition currently explains this downstream branch."
                    )
                }
            }
        }

        // If a candidate is confirmed abnormal, move physically upstream using explicit machine
        // topology. These points become new unresolved candidates even when they never appear in
        // the ladder trace.
        var frontier = Array(candidates.values.filter { $0.status == .confirmed })
        var visited = Set(candidates.keys)
        while let child = frontier.popLast() {
            for dependency in topology.upstream(of: child.target) where visited.insert(dependency.upstream).inserted {
                let observation = latestByTarget[dependency.upstream]
                let status: AdaptiveCandidateStatus
                let rationale: String
                if let observation {
                    if !observation.confidence.supportsHardPruning {
                        status = .unresolved
                        rationale = "Upstream measurement exists but is only \(observation.confidence.displayName.lowercased()) confidence; verify it before pruning this path."
                    } else {
                        status = observation.value == dependency.expectedUpstreamValue ? .eliminated : .confirmed
                        rationale = status == .eliminated
                            ? "Measured healthy while tracing upstream from \(child.target)."
                            : "Measured abnormal while tracing upstream from \(child.target)."
                    }
                } else {
                    status = .unresolved
                    rationale = dependency.description ?? "Physical/electrical upstream dependency of \(child.target)."
                }
                let upstream = AdaptiveCauseCandidate(
                    target: dependency.upstream,
                    expectedHealthyValue: dependency.expectedUpstreamValue,
                    coveredHypotheses: child.coveredHypotheses,
                    status: status,
                    latestObservation: observation,
                    depth: child.depth + 1,
                    rationale: rationale
                )
                candidates[dependency.upstream] = upstream
                if status == .confirmed { frontier.append(upstream) }
            }
        }

        let confirmed = candidates.values
            .filter { $0.status == .confirmed }
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
                if lhs.coveredHypotheses.count != rhs.coveredHypotheses.count { return lhs.coveredHypotheses.count > rhs.coveredHypotheses.count }
                return lhs.target < rhs.target
            }
            .first

        let contradictions = detectContradictions(latestByTarget: latestByTarget)
        let unresolvedCandidates = candidates.values.filter { $0.status == .unresolved }
        let adaptiveReport = reportForStrategy(from: unresolvedCandidates)
        let baseStrategy = selectAdaptiveStrategy(report: adaptiveReport, candidates: unresolvedCandidates)
        let strategy = conflictResolutionStrategy(contradictions: contradictions, fallback: baseStrategy)
        let resolved = unresolvedCandidates.isEmpty && confirmed == nil
        let summary: String
        if let conflict = contradictions.first {
            summary = "Evidence conflict: \(conflict.upstreamTarget) and \(conflict.downstreamTarget) disagree with the modeled dependency. Resolve the contradiction before pruning further."
        } else if let confirmed {
            if let next = strategy.recommended {
                summary = "\(confirmed.target) is confirmed abnormal. Move upstream next: check \(next.target)."
            } else {
                summary = "\(confirmed.target) is confirmed abnormal. The current topology contains no additional eligible upstream measurement."
            }
        } else if let next = strategy.recommended {
            summary = "Evidence has been pruned. Check \(next.target) next."
        } else if resolved {
            summary = "All modeled failure candidates have been eliminated by the entered measurements. Re-observe the symptom or expand the machine topology."
        } else {
            summary = "No eligible next measurement is available under the current strategy policy."
        }

        let temporalPatterns = temporalObservations.map { TemporalEvidenceAnalyzer.analyze($0, relativeTo: eventMarkers) }
        let temporalRecommendation = selectTemporalRecommendation(patterns: temporalPatterns)

        return AdaptiveTroubleshootingState(
            symptomTarget: report.target,
            desiredValue: report.desiredValue,
            observations: observations,
            candidates: candidates.values.sorted(by: candidateSort),
            strategy: strategy,
            contradictions: contradictions,
            evidenceSummary: EvidenceSummary(observations: observations, contradictions: contradictions),
            temporalPatterns: temporalPatterns,
            temporalRecommendation: temporalRecommendation,
            confirmedCause: confirmed,
            isResolved: resolved,
            summary: temporalRecommendation.map { summary + " Time-domain evidence suggests \($0.mode.displayName.lowercased()) capture on \($0.target)." } ?? summary
        )
    }

    private struct Expectation {
        var expectedHealthyValue: TagValue
        var covered: Set<String>
        var depth: Int
    }

    private func causalExpectations() -> [String: Expectation] {
        let unresolved = report.hypotheses.filter { $0.status != .healthyEvidence }
        var result: [String: Expectation] = [:]
        for hypothesis in unresolved {
            guard let desired = hypothesis.requiredValue ?? invertedBool(hypothesis.observedValue) else { continue }
            mergeExpectation(target: hypothesis.target, expected: desired, hypothesis: hypothesis.target, depth: 0, into: &result)
            let trail = journal.explainWhy(target: hypothesis.target, shouldBe: desired, observedValue: hypothesis.observedValue)
            for (index, step) in trail.steps.dropFirst().enumerated() {
                guard let expected = step.desiredValue else { continue }
                mergeExpectation(target: step.target, expected: expected, hypothesis: hypothesis.target, depth: index + 1, into: &result)
            }
        }
        return result
    }

    private func mergeExpectation(target: String, expected: TagValue, hypothesis: String, depth: Int, into result: inout [String: Expectation]) {
        if var current = result[target] {
            current.covered.insert(hypothesis)
            current.depth = max(current.depth, depth)
            result[target] = current
        } else {
            result[target] = Expectation(expectedHealthyValue: expected, covered: [hypothesis], depth: depth)
        }
    }

    private func reportForStrategy(from candidates: [AdaptiveCauseCandidate]) -> MultiHypothesisReport {
        let hypotheses = candidates.map { candidate in
            DiagnosticHypothesis(
                target: candidate.target,
                instruction: "MEASURE \(candidate.target)",
                status: .unknownUnobserved,
                observedValue: candidate.latestObservation?.value,
                requiredValue: candidate.expectedHealthyValue,
                detail: candidate.rationale
            )
        }
        return MultiHypothesisReport(target: report.target, desiredValue: report.desiredValue, observedValue: report.observedValue, hypotheses: hypotheses, primaryRootTrail: report.primaryRootTrail, recommendedNextCheck: nil, summary: report.summary)
    }

    private func selectAdaptiveStrategy(report adaptiveReport: MultiHypothesisReport, candidates: [AdaptiveCauseCandidate]) -> DiagnosticStrategy {
        guard !candidates.isEmpty else {
            return DiagnosticStrategy(symptomTarget: report.target, candidates: [], recommended: nil, summary: "No unresolved measurement candidates remain.")
        }
        let profileByTarget = Dictionary(uniqueKeysWithValues: profiles.map { ($0.target, $0) })
        let totalHypotheses = Set(candidates.flatMap(\.coveredHypotheses))
        let total = max(1.0, Double(totalHypotheses.count))
        var ranked: [MeasurementCandidate] = candidates.map { candidate in
            let coverage = Double(Set(candidate.coveredHypotheses).count) / total
            let profile = profileByTarget[candidate.target] ?? MeasurementProfile(target: candidate.target)
            let eligible = !(policy.prohibitHazardousForLearners && profile.safety == .hazardous)
            let information = coverage + 0.15 * Double(candidate.depth)
            let penalty = profile.effort * policy.effortWeight
                + profile.estimatedSeconds * policy.timeWeight
                + Double(profile.access.rawValue) * policy.accessWeight
                + Double(profile.safety.rawValue) * policy.safetyWeight
                + (profile.invasive ? policy.invasivePenalty : 0)
            let raw = information * policy.informationWeight + coverage * policy.upstreamCoverageWeight - penalty
            let score = eligible ? raw : -Double.greatestFiniteMagnitude
            return MeasurementCandidate(
                target: candidate.target,
                coveredHypotheses: candidate.coveredHypotheses,
                informationGain: information,
                coverageFraction: coverage,
                score: score,
                profile: profile,
                eligible: eligible,
                rationale: eligible
                    ? "This measurement addresses \(candidate.coveredHypotheses.count) active diagnostic branch(es) at upstream depth \(candidate.depth)."
                    : "Excluded by the learner-safety policy."
            )
        }
        ranked.sort {
            if $0.eligible != $1.eligible { return $0.eligible && !$1.eligible }
            if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
            return $0.target < $1.target
        }
        let recommended = ranked.first(where: \.eligible)
        return DiagnosticStrategy(
            symptomTarget: report.target,
            candidates: ranked,
            recommended: recommended,
            summary: recommended.map { "Check \($0.target) next using the updated evidence from this troubleshooting session." } ?? "No eligible next measurement remains."
        )
    }


    private func detectContradictions(latestByTarget: [String: TroubleshootingObservation]) -> [EvidenceContradiction] {
        topology.dependencies.compactMap { dependency in
            guard let upstream = latestByTarget[dependency.upstream],
                  let downstream = latestByTarget[dependency.downstream],
                  upstream.value == dependency.expectedUpstreamValue,
                  downstream.value != dependency.expectedDownstreamValue else { return nil }
            let minimumConfidence = min(upstream.confidence, downstream.confidence)
            let unloaded = upstream.condition == .unloaded || downstream.condition == .unloaded
            let severity: ContradictionSeverity
            if minimumConfidence < .medium {
                severity = .advisory
            } else if unloaded {
                severity = .meaningful
            } else {
                severity = minimumConfidence >= .high ? .strong : .meaningful
            }
            let target = dependency.verificationTarget ?? "\(dependency.upstream)→\(dependency.downstream)"
            let instruction = dependency.verificationInstruction ?? "Re-measure both sides of the dependency under operating load and verify the connection between \(dependency.upstream) and \(dependency.downstream)."
            return EvidenceContradiction(
                upstreamTarget: dependency.upstream,
                downstreamTarget: dependency.downstream,
                upstreamObservation: upstream,
                downstreamObservation: downstream,
                severity: severity,
                explanation: "\(dependency.upstream) was measured healthy while \(dependency.downstream) was measured unhealthy, which conflicts with the modeled dependency.",
                resolutionTarget: target,
                resolutionInstruction: instruction
            )
        }.sorted { $0.severity > $1.severity }
    }

    private func conflictResolutionStrategy(contradictions: [EvidenceContradiction], fallback: DiagnosticStrategy) -> DiagnosticStrategy {
        guard let conflict = contradictions.first(where: { $0.severity >= .meaningful }) else { return fallback }
        let profileByTarget = Dictionary(uniqueKeysWithValues: profiles.map { ($0.target, $0) })
        let profile = profileByTarget[conflict.resolutionTarget] ?? MeasurementProfile(target: conflict.resolutionTarget, effort: 1.0, estimatedSeconds: 30, safety: .low, access: .panel, invasive: false, description: conflict.resolutionInstruction)
        let eligible = !(policy.prohibitHazardousForLearners && profile.safety == .hazardous)
        let candidate = MeasurementCandidate(
            target: conflict.resolutionTarget,
            coveredHypotheses: [conflict.upstreamTarget, conflict.downstreamTarget],
            informationGain: 2.0,
            coverageFraction: 1.0,
            score: eligible ? 1000.0 : -Double.greatestFiniteMagnitude,
            profile: profile,
            eligible: eligible,
            rationale: conflict.resolutionInstruction
        )
        if eligible {
            return DiagnosticStrategy(symptomTarget: report.target, candidates: [candidate] + fallback.candidates, recommended: candidate, summary: "Resolve contradictory evidence before continuing normal fault-tree pruning. \(conflict.resolutionInstruction)")
        }
        return fallback
    }

    private func invertedBool(_ value: TagValue?) -> TagValue? {
        guard case let .bool(v)? = value else { return nil }
        return .bool(!v)
    }

    private func candidateSort(_ lhs: AdaptiveCauseCandidate, _ rhs: AdaptiveCauseCandidate) -> Bool {
        let order: [AdaptiveCandidateStatus: Int] = [.confirmed: 0, .unresolved: 1, .eliminated: 2, .superseded: 3]
        if order[lhs.status, default: 99] != order[rhs.status, default: 99] { return order[lhs.status, default: 99] < order[rhs.status, default: 99] }
        if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
        return lhs.target < rhs.target
    }

    private func selectTemporalRecommendation(patterns: [TemporalPattern]) -> TemporalCaptureRecommendation? {
        guard !patterns.isEmpty else { return nil }
        let priority: [TemporalPatternKind: Int] = [.chatter: 0, .transientPulse: 1, .intermittent: 2, .singleTransition: 3, .insufficientData: 4, .stable: 5]
        let pattern = patterns.sorted {
            if priority[$0.kind, default: 99] != priority[$1.kind, default: 99] { return priority[$0.kind, default: 99] < priority[$1.kind, default: 99] }
            return $0.transitionCount > $1.transitionCount
        }.first!
        if let eventName = pattern.eventName,
           let event = eventMarkers.first(where: { $0.name == eventName }),
           let race = TemporalEvidenceAnalyzer.timingRaceRecommendation(signalPattern: pattern, event: event, scanPeriodMilliseconds: controllerScanPeriodMilliseconds) {
            return race
        }
        return TemporalEvidenceAnalyzer.recommendCapture(for: pattern, scanPeriodMilliseconds: controllerScanPeriodMilliseconds)
    }

    private func display(_ value: TagValue) -> String { TraceExplainer.display(value) }
}

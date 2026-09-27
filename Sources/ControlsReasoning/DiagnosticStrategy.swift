import Foundation
import ControlsPLC

public enum MeasurementSafety: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = 0
    case elevated = 1
    case hazardous = 2

    public static func < (lhs: MeasurementSafety, rhs: MeasurementSafety) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low risk"
        case .elevated: return "Elevated risk"
        case .hazardous: return "Hazardous"
        }
    }
}

public enum MeasurementAccess: Int, Codable, Sendable, CaseIterable {
    case immediate = 0
    case panel = 1
    case guarded = 2
    case intrusive = 3

    public var displayName: String {
        switch self {
        case .immediate: return "Immediate"
        case .panel: return "Panel access"
        case .guarded: return "Guarded access"
        case .intrusive: return "Intrusive access"
        }
    }
}

/// Optional plant/training metadata for a measurement point. The strategy engine can operate
/// without a catalog, but explicit metadata lets a lesson author teach that the mathematically
/// best split is not always the safest or fastest first check.
public struct MeasurementProfile: Equatable, Sendable {
    public let target: String
    public let effort: Double
    public let estimatedSeconds: Double
    public let safety: MeasurementSafety
    public let access: MeasurementAccess
    public let invasive: Bool
    public let description: String?

    public init(
        target: String,
        effort: Double = 1.0,
        estimatedSeconds: Double = 15,
        safety: MeasurementSafety = .low,
        access: MeasurementAccess = .immediate,
        invasive: Bool = false,
        description: String? = nil
    ) {
        self.target = target
        self.effort = max(0.1, effort)
        self.estimatedSeconds = max(0, estimatedSeconds)
        self.safety = safety
        self.access = access
        self.invasive = invasive
        self.description = description
    }
}

public struct DiagnosticStrategyPolicy: Equatable, Sendable {
    public var informationWeight: Double
    public var upstreamCoverageWeight: Double
    public var effortWeight: Double
    public var timeWeight: Double
    public var accessWeight: Double
    public var safetyWeight: Double
    public var invasivePenalty: Double
    public var prohibitHazardousForLearners: Bool

    public init(
        informationWeight: Double = 5.0,
        upstreamCoverageWeight: Double = 2.5,
        effortWeight: Double = 0.8,
        timeWeight: Double = 0.02,
        accessWeight: Double = 1.25,
        safetyWeight: Double = 4.0,
        invasivePenalty: Double = 2.0,
        prohibitHazardousForLearners: Bool = true
    ) {
        self.informationWeight = informationWeight
        self.upstreamCoverageWeight = upstreamCoverageWeight
        self.effortWeight = effortWeight
        self.timeWeight = timeWeight
        self.accessWeight = accessWeight
        self.safetyWeight = safetyWeight
        self.invasivePenalty = invasivePenalty
        self.prohibitHazardousForLearners = prohibitHazardousForLearners
    }
}

public struct MeasurementCandidate: Identifiable, Equatable, Sendable {
    public var id: String { target }
    public let target: String
    public let coveredHypotheses: [String]
    public let informationGain: Double
    public let coverageFraction: Double
    public let score: Double
    public let profile: MeasurementProfile
    public let eligible: Bool
    public let rationale: String

    public init(target: String, coveredHypotheses: [String], informationGain: Double, coverageFraction: Double, score: Double, profile: MeasurementProfile, eligible: Bool, rationale: String) {
        self.target = target
        self.coveredHypotheses = coveredHypotheses
        self.informationGain = informationGain
        self.coverageFraction = coverageFraction
        self.score = score
        self.profile = profile
        self.eligible = eligible
        self.rationale = rationale
    }
}

public struct DiagnosticStrategy: Equatable, Sendable {
    public let symptomTarget: String
    public let candidates: [MeasurementCandidate]
    public let recommended: MeasurementCandidate?
    public let summary: String

    public init(symptomTarget: String, candidates: [MeasurementCandidate], recommended: MeasurementCandidate?, summary: String) {
        self.symptomTarget = symptomTarget
        self.candidates = candidates
        self.recommended = recommended
        self.summary = summary
    }
}

public extension CausalJournal {
    /// Ranks the next measurement by expected diagnostic value. Candidate coverage is derived
    /// from recorded causal trails, so a shared upstream point can outrank checking several
    /// downstream devices one-by-one. Shannon entropy is used as a simple binary split model:
    /// a check covering about half of the unresolved hypotheses is maximally discriminating,
    /// while a common upstream source receives an additional coverage bonus because one result
    /// can validate or eliminate an entire branch of the diagnostic tree.
    func selectDiagnosticStrategy(
        for report: MultiHypothesisReport,
        profiles: [MeasurementProfile] = [],
        policy: DiagnosticStrategyPolicy = DiagnosticStrategyPolicy()
    ) -> DiagnosticStrategy {
        let unresolved = report.hypotheses.filter { hypothesis in
            hypothesis.status == .confirmedBlocker || hypothesis.status == .contributingCondition || hypothesis.status == .unknownUnobserved
        }
        guard !unresolved.isEmpty else {
            return DiagnosticStrategy(symptomTarget: report.target, candidates: [], recommended: nil, summary: "No unresolved diagnostic hypotheses remain; no additional measurement is justified by the recorded evidence.")
        }

        let profileByTarget = Dictionary(uniqueKeysWithValues: profiles.map { ($0.target, $0) })
        var coverage: [String: Set<String>] = [:]

        for hypothesis in unresolved {
            let desired = hypothesis.requiredValue ?? inferredDesiredValue(for: hypothesis)
            var pathTargets: [String] = [hypothesis.target]
            if let desired {
                let trail = explainWhy(target: hypothesis.target, shouldBe: desired, observedValue: hypothesis.observedValue)
                pathTargets.append(contentsOf: trail.steps.dropFirst().map(\.target))
            }
            for target in unique(pathTargets) {
                coverage[target, default: []].insert(hypothesis.target)
            }
        }

        let total = Double(unresolved.count)
        var candidates: [MeasurementCandidate] = coverage.map { target, covered in
            let count = Double(covered.count)
            let fraction = count / total
            let entropy = binaryEntropy(fraction)
            // Expected diagnostic value combines branch coverage with split quality. Full
            // upstream coverage is valuable even though its binary entropy is zero: a failed
            // common source can collapse the entire tree in one measurement.
            let informationGain = fraction + (entropy * 0.35)
            let coverageBonus = fraction
            let profile = profileByTarget[target] ?? MeasurementProfile(target: target)
            let eligible = !(policy.prohibitHazardousForLearners && profile.safety == .hazardous)

            let penalty = profile.effort * policy.effortWeight
                + profile.estimatedSeconds * policy.timeWeight
                + Double(profile.access.rawValue) * policy.accessWeight
                + Double(profile.safety.rawValue) * policy.safetyWeight
                + (profile.invasive ? policy.invasivePenalty : 0)
            let rawScore = informationGain * policy.informationWeight + coverageBonus * policy.upstreamCoverageWeight - penalty
            let score = eligible ? rawScore : -Double.greatestFiniteMagnitude

            let names = covered.sorted()
            let coveragePhrase = names.count == 1 ? "1 unresolved hypothesis" : "\(names.count) unresolved hypotheses"
            let rationale: String
            if !eligible {
                rationale = "This point could inform \(coveragePhrase), but the current learner-safety policy excludes hazardous measurements."
            } else if covered.count == unresolved.count && unresolved.count > 1 {
                rationale = "One check sits upstream of all \(unresolved.count) unresolved hypotheses, so it can validate or eliminate the whole branch before individual device checks."
            } else {
                rationale = "This check can discriminate \(coveragePhrase) with \(profile.safety.displayName.lowercased()) and \(profile.access.displayName.lowercased())."
            }

            return MeasurementCandidate(
                target: target,
                coveredHypotheses: names,
                informationGain: informationGain,
                coverageFraction: fraction,
                score: score,
                profile: profile,
                eligible: eligible,
                rationale: rationale
            )
        }

        candidates.sort { lhs, rhs in
            if lhs.eligible != rhs.eligible { return lhs.eligible && !rhs.eligible }
            if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score > rhs.score }
            if abs(lhs.coverageFraction - rhs.coverageFraction) > 0.000_001 { return lhs.coverageFraction > rhs.coverageFraction }
            if lhs.profile.safety != rhs.profile.safety { return lhs.profile.safety < rhs.profile.safety }
            return lhs.target < rhs.target
        }

        let recommended = candidates.first(where: \.eligible)
        let summary: String
        if let recommended {
            let percent = Int((recommended.coverageFraction * 100).rounded())
            summary = "Check \(recommended.target) next. It can resolve evidence affecting \(percent)% of the current unresolved hypotheses before lower-value checks."
        } else {
            summary = "No candidate measurement is eligible under the current safety/access policy."
        }
        return DiagnosticStrategy(symptomTarget: report.target, candidates: candidates, recommended: recommended, summary: summary)
    }
}

private func inferredDesiredValue(for hypothesis: DiagnosticHypothesis) -> TagValue? {
    if let required = hypothesis.requiredValue { return required }
    if let observed = hypothesis.observedValue?.boolValue { return .bool(!observed) }
    return nil
}

private func unique(_ strings: [String]) -> [String] {
    var seen: Set<String> = []
    return strings.filter { seen.insert($0).inserted }
}

private func binaryEntropy(_ p: Double) -> Double {
    guard p > 0, p < 1 else { return 0 }
    let q = 1 - p
    return -(p * log2(p) + q * log2(q))
}

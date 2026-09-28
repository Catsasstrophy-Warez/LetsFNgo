import Foundation
import NexusCore

public enum TestSafety: Int, Sendable, Hashable, Comparable {
    case routine
    /// Allowed, but scored at half value to prefer an equally useful safe check.
    case caution
    /// Excluded unless the policy explicitly allows it, however informative.
    case hazardous

    public static func < (lhs: TestSafety, rhs: TestSafety) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A measurement the technician could take next.
public struct TestOption: Sendable, Hashable {
    public var title: String
    public var testPoint: ObjectID
    public var quantity: String
    public var condition: String?
    /// Effort in minutes, including access.
    public var cost: Double
    public var safety: TestSafety

    public init(title: String, testPoint: ObjectID, quantity: String, condition: String? = nil, cost: Double, safety: TestSafety = .routine) {
        self.title = title
        self.testPoint = testPoint
        self.quantity = quantity
        self.condition = condition
        self.cost = cost
        self.safety = safety
    }

    func matches(_ prediction: Prediction) -> Bool {
        prediction.testPoint == testPoint && prediction.quantity == quantity
            && (prediction.condition == nil || prediction.condition == condition)
    }
}

public struct TestRecommendation: Sendable, Hashable {
    public var option: TestOption
    /// Expected reduction in uncertainty about the cause, in bits.
    public var informationGain: Double
    /// Gain per minute, after the safety adjustment.
    public var score: Double
    /// Live hypotheses grouped by the outcome they predict.
    public var outcomes: [[ObjectID]]
    /// Live hypotheses that make no prediction here and survive any outcome.
    public var agnostic: [ObjectID]
}

/// Chooses discriminating tests: the measurement whose possible outcomes best
/// split the live hypotheses, per minute of effort.
///
/// Hypotheses predicting the same interval form one outcome. A hypothesis with
/// no prediction for a test survives every outcome, which is why a test only
/// one hypothesis cares about is worth little.
enum TestSelector {
    static func rank(_ options: [TestOption], hypotheses: [Hypothesis], allowHazardous: Bool) -> [TestRecommendation] {
        let live = hypotheses.filter(\.state.isLive)
        let total = live.map(\.prior).reduce(0, +)
        guard total > 0 else { return [] }
        let weight = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.prior / total) })
        let before = entropy(live.map { weight[$0.id]! })

        return options
            .filter { allowHazardous || $0.safety != .hazardous }
            .map { option in
                var buckets: [[Double]: [ObjectID]] = [:]
                var agnostic: [ObjectID] = []
                for hypothesis in live {
                    if let prediction = hypothesis.predictions.first(where: option.matches) {
                        buckets[[prediction.low, prediction.high], default: []].append(hypothesis.id)
                    } else {
                        agnostic.append(hypothesis.id)
                    }
                }
                let outcomes = buckets.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { buckets[$0]! }
                let gain = before - expectedEntropy(outcomes: outcomes, agnostic: agnostic, weight: weight)
                let safetyFactor = option.safety == .caution ? 0.5 : 1
                return TestRecommendation(
                    option: option, informationGain: gain, score: gain * safetyFactor / max(option.cost, 0.1),
                    outcomes: outcomes, agnostic: agnostic
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.option.cost != rhs.option.cost { return lhs.option.cost < rhs.option.cost }
                return lhs.option.title < rhs.option.title
            }
    }

    private static func expectedEntropy(outcomes: [[ObjectID]], agnostic: [ObjectID], weight: [ObjectID: Double]) -> Double {
        guard !outcomes.isEmpty else { return entropy(agnostic.map { weight[$0]! }) }
        // Agnostic hypotheses are equally compatible with every outcome.
        let spread = 1 / Double(outcomes.count)
        return outcomes.reduce(0) { sum, members in
            let posterior = members.map { weight[$0]! } + agnostic.map { weight[$0]! * spread }
            let probability = posterior.reduce(0, +)
            return sum + probability * entropy(posterior)
        }
    }

    /// Shannon entropy in bits of unnormalized weights.
    static func entropy(_ weights: [Double]) -> Double {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        return weights.reduce(0) { sum, weight in
            let p = weight / total
            return p > 0 ? sum - p * log2(p) : sum
        }
    }
}

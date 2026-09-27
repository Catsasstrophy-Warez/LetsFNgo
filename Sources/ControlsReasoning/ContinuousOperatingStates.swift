import Foundation
import ControlsPLC

public struct ContinuousContextStatistics: Identifiable, Equatable, Sendable {
    public var id: String { key.id }
    public let key: OperatingContextKey
    public let mean: Double
    public let standardDeviation: Double
    public let minimum: Double
    public let maximum: Double
}

public struct ContinuousOperatingRegion: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let cycleCount: Int
    public let centroid: [Double]
    public let standardizedCentroid: [Double]
    public let membershipRadius: Double
    public let healthModel: MultivariateHealthModel?
}

public struct OperatingRegionTransition: Identifiable, Equatable, Sendable {
    public var id: String { "\(fromRegionID)->\(toRegionID)" }
    public let fromRegionID: String
    public let toRegionID: String
    public let count: Int
    public let probability: Double
}

public struct ContinuousOperatingStateModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let contextStatistics: [ContinuousContextStatistics]
    public let regions: [ContinuousOperatingRegion]
    public let transitions: [OperatingRegionTransition]
    public let silhouetteScore: Double
    public let minimumCyclesPerRegion: Int

    public func region(id: String) -> ContinuousOperatingRegion? {
        regions.first { $0.id == id }
    }

    public func transition(from: String, to: String) -> OperatingRegionTransition? {
        transitions.first { $0.fromRegionID == from && $0.toRegionID == to }
    }
}

public enum ContinuousOperatingStateAssessmentStatus: String, Codable, Sendable {
    case assessed
    case unknownRegion
    case insufficientContext
    case insufficientHealthBaseline

    public var displayName: String {
        switch self {
        case .assessed: return "Continuous-state health assessed"
        case .unknownRegion: return "Outside learned operating regions"
        case .insufficientContext: return "Insufficient operating context"
        case .insufficientHealthBaseline: return "Insufficient regional health baseline"
        }
    }
}

public struct ContinuousOperatingStateAssessment: Equatable, Sendable {
    public let status: ContinuousOperatingStateAssessmentStatus
    public let selectedRegionID: String?
    public let selectedRegionName: String?
    public let contextDistance: Double?
    public let healthAssessment: MultivariateHealthAssessment?
    public let summary: String
}

public enum OperatingTransitionNovelty: String, Codable, Sendable {
    case common
    case uncommon
    case unseen

    public var displayName: String {
        switch self {
        case .common: return "Common transition"
        case .uncommon: return "Uncommon transition"
        case .unseen: return "Previously unseen transition"
        }
    }
}

public struct OperatingTransitionAssessment: Equatable, Sendable {
    public let fromRegionName: String
    public let toRegionName: String
    public let probability: Double
    public let novelty: OperatingTransitionNovelty
    public let summary: String
}

public enum ContinuousOperatingStateAnalyzer {
    public static func buildModel(
        name: String = "Continuous operating-state model",
        cycles: [KnownGoodCycle],
        contextKeys: [OperatingContextKey],
        healthFeatureDefinitions: [MultivariateFeatureDefinition],
        clusterCount requestedClusterCount: Int? = nil,
        maximumClusters: Int = 5,
        minimumCyclesPerRegion: Int = 8,
        covarianceRegularization: Double = 0.08
    ) -> ContinuousOperatingStateModel? {
        guard contextKeys.count >= 2, cycles.count >= max(6, minimumCyclesPerRegion * 2) else { return nil }
        let contextChannels = Set(contextKeys.map { "\($0.target)|\($0.layer.rawValue)" })
        guard !healthFeatureDefinitions.contains(where: { contextChannels.contains("\($0.target)|\($0.layer.rawValue)") }) else {
            // Context chooses the operating region; health evidence judges condition inside that region.
            // Keeping those channels separate prevents a degradation signal from selecting its own easier baseline.
            return nil
        }

        let complete: [(KnownGoodCycle, [Double])] = cycles.compactMap { cycle in
            let values = contextKeys.map { numericContext($0, from: cycle) }
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return (cycle, values.map { $0! })
        }
        guard complete.count >= max(6, minimumCyclesPerRegion * 2) else { return nil }

        let rows = complete.map(\.1)
        let stats = contextKeys.indices.map { j -> ContinuousContextStatistics in
            let values = rows.map { $0[j] }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.count > 1 ? values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1) : 0
            return ContinuousContextStatistics(
                key: contextKeys[j], mean: mean, standardDeviation: max(sqrt(max(variance, 0)), 1e-9),
                minimum: values.min() ?? mean, maximum: values.max() ?? mean
            )
        }
        let standardized = rows.map { row in
            zip(row, stats).map { ($0.0 - $0.1.mean) / $0.1.standardDeviation }
        }

        let maxFeasible = min(maximumClusters, max(1, complete.count / max(1, minimumCyclesPerRegion)))
        let clusterCounts: [Int]
        if let requestedClusterCount {
            guard requestedClusterCount >= 2, requestedClusterCount <= maxFeasible else { return nil }
            clusterCounts = [requestedClusterCount]
        } else {
            guard maxFeasible >= 2 else { return nil }
            clusterCounts = Array(2...maxFeasible)
        }

        var best: KMeansResult?
        for k in clusterCounts {
            let candidate = kMeans(standardized, k: k)
            guard candidate.counts.allSatisfy({ $0 >= minimumCyclesPerRegion }) else { continue }
            let score = silhouette(rows: standardized, labels: candidate.labels, k: k)
            let scored = KMeansResult(labels: candidate.labels, centroids: candidate.centroids, counts: candidate.counts, score: score)
            if best == nil || score > best!.score + 1e-9 || (abs(score - best!.score) <= 1e-9 && k < best!.centroids.count) {
                best = scored
            }
        }
        guard let best else { return nil }

        // Stable region numbering: sort centroids lexicographically in raw context space.
        let rawCentroids = best.centroids.map { centroid in
            zip(centroid, stats).map { $0.0 * $0.1.standardDeviation + $0.1.mean }
        }
        let oldOrder = best.centroids.indices.sorted { lhs, rhs in
            lexicographicallyPrecedes(rawCentroids[lhs], rawCentroids[rhs])
        }
        var remap: [Int: Int] = [:]
        for (newIndex, oldIndex) in oldOrder.enumerated() { remap[oldIndex] = newIndex }
        let labels = best.labels.map { remap[$0]! }

        var regions: [ContinuousOperatingRegion] = []
        for newIndex in oldOrder.indices {
            let oldIndex = oldOrder[newIndex]
            let memberIndices = labels.indices.filter { labels[$0] == newIndex }
            let memberDistances = memberIndices.map { euclidean(standardized[$0], best.centroids[oldIndex]) }.sorted()
            let radius = max(percentile(memberDistances, 0.95) * 1.35, sqrt(Double(contextKeys.count)) * 0.35)
            let memberCycles = memberIndices.map { complete[$0].0 }
            let health = MultivariateDegradationAnalyzer.buildModel(
                name: "Operating region \(newIndex + 1) healthy signature",
                cycles: memberCycles,
                featureDefinitions: healthFeatureDefinitions,
                minimumCycles: minimumCyclesPerRegion,
                covarianceRegularization: covarianceRegularization
            )
            regions.append(ContinuousOperatingRegion(
                id: "region-\(newIndex + 1)", name: "Operating Region \(newIndex + 1)",
                cycleCount: memberIndices.count, centroid: rawCentroids[oldIndex],
                standardizedCentroid: best.centroids[oldIndex], membershipRadius: radius, healthModel: health
            ))
        }

        var transitionCounts: [String: Int] = [:]
        var outgoingCounts: [String: Int] = [:]
        if labels.count >= 2 {
            for i in 1..<labels.count {
                let from = regions[labels[i - 1]].id
                let to = regions[labels[i]].id
                transitionCounts["\(from)|\(to)", default: 0] += 1
                outgoingCounts[from, default: 0] += 1
            }
        }
        let transitions = transitionCounts.compactMap { key, count -> OperatingRegionTransition? in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let total = max(outgoingCounts[parts[0]] ?? 0, 1)
            return OperatingRegionTransition(fromRegionID: parts[0], toRegionID: parts[1], count: count, probability: Double(count) / Double(total))
        }.sorted {
            if $0.fromRegionID != $1.fromRegionID { return $0.fromRegionID < $1.fromRegionID }
            return $0.toRegionID < $1.toRegionID
        }

        return ContinuousOperatingStateModel(
            name: name, cycleCount: complete.count, contextStatistics: stats, regions: regions,
            transitions: transitions, silhouetteScore: best.score, minimumCyclesPerRegion: minimumCyclesPerRegion
        )
    }

    public static func assess(cycle: KnownGoodCycle, against model: ContinuousOperatingStateModel) -> ContinuousOperatingStateAssessment {
        let values = model.contextStatistics.map { numericContext($0.key, from: cycle) }
        guard values.allSatisfy({ $0 != nil }) else {
            return ContinuousOperatingStateAssessment(
                status: .insufficientContext, selectedRegionID: nil, selectedRegionName: nil, contextDistance: nil,
                healthAssessment: nil, summary: "The capture is missing one or more continuous context features. Regional health cannot be scored safely."
            )
        }
        let raw = values.map { $0! }
        let standardized = zip(raw, model.contextStatistics).map { ($0.0 - $0.1.mean) / $0.1.standardDeviation }
        let distances = model.regions.map { euclidean(standardized, $0.standardizedCentroid) }
        guard let nearestIndex = distances.indices.min(by: { distances[$0] < distances[$1] }) else {
            return ContinuousOperatingStateAssessment(status: .insufficientContext, selectedRegionID: nil, selectedRegionName: nil, contextDistance: nil, healthAssessment: nil, summary: "No operating regions are available.")
        }
        let region = model.regions[nearestIndex]
        let distance = distances[nearestIndex]
        guard distance <= region.membershipRadius else {
            return ContinuousOperatingStateAssessment(
                status: .unknownRegion, selectedRegionID: nil, selectedRegionName: nil, contextDistance: distance,
                healthAssessment: nil,
                summary: "The current operating point lies outside the learned healthy context regions. Treat it as a new operating condition instead of force-fitting it to \(region.name)."
            )
        }
        guard let healthModel = region.healthModel else {
            return ContinuousOperatingStateAssessment(
                status: .insufficientHealthBaseline, selectedRegionID: region.id, selectedRegionName: region.name,
                contextDistance: distance, healthAssessment: nil,
                summary: "\(region.name) matches the current operating point, but it does not yet contain enough complete healthy cycles for a regional health baseline."
            )
        }
        let health = MultivariateDegradationAnalyzer.assess(cycle: cycle, against: healthModel)
        return ContinuousOperatingStateAssessment(
            status: .assessed, selectedRegionID: region.id, selectedRegionName: region.name,
            contextDistance: distance, healthAssessment: health,
            summary: "Selected \(region.name) from continuous operating context. \(health.summary)"
        )
    }

    public static func assessTransition(from previousRegionID: String, to currentRegionID: String, in model: ContinuousOperatingStateModel) -> OperatingTransitionAssessment? {
        guard let from = model.region(id: previousRegionID), let to = model.region(id: currentRegionID) else { return nil }
        let transition = model.transition(from: previousRegionID, to: currentRegionID)
        let p = transition?.probability ?? 0
        let novelty: OperatingTransitionNovelty = transition == nil ? .unseen : (p < 0.15 ? .uncommon : .common)
        let summary: String
        switch novelty {
        case .common:
            summary = "The transition from \(from.name) to \(to.name) is common in the healthy training history (\(Int(round(p * 100)))%)."
        case .uncommon:
            summary = "The transition from \(from.name) to \(to.name) is uncommon in healthy history (\(Int(round(p * 100)))%). Treat it as context evidence, not a fault by itself."
        case .unseen:
            summary = "The transition from \(from.name) to \(to.name) was not observed in the healthy training history. Investigate the operating sequence before assigning a machine-health cause."
        }
        return OperatingTransitionAssessment(fromRegionName: from.name, toRegionName: to.name, probability: p, novelty: novelty, summary: summary)
    }

    public static func numericContext(_ key: OperatingContextKey, from cycle: KnownGoodCycle) -> Double? {
        guard let value = OperatingModeHealthAnalyzer.contextValue(key, from: cycle) else { return nil }
        switch value {
        case let .bool(v): return v ? 1 : 0
        case let .dint(v): return Double(v)
        case let .real(v): return v
        case let .timer(v): return Double(v.ACC)
        case let .counter(v): return Double(v.ACC)
        }
    }

    private struct KMeansResult {
        let labels: [Int]
        let centroids: [[Double]]
        let counts: [Int]
        let score: Double
        init(labels: [Int], centroids: [[Double]], counts: [Int], score: Double = -.infinity) {
            self.labels = labels; self.centroids = centroids; self.counts = counts; self.score = score
        }
    }

    private static func kMeans(_ rows: [[Double]], k: Int, maxIterations: Int = 100) -> KMeansResult {
        precondition(!rows.isEmpty && k > 0 && k <= rows.count)
        var centroids: [[Double]] = []
        let firstIndex = rows.indices.min { lexicographicallyPrecedes(rows[$0], rows[$1]) } ?? 0
        centroids.append(rows[firstIndex])
        while centroids.count < k {
            let next = rows.indices.max { a, b in
                let da = centroids.map { euclidean(rows[a], $0) }.min() ?? 0
                let db = centroids.map { euclidean(rows[b], $0) }.min() ?? 0
                if abs(da - db) > 1e-12 { return da < db }
                return a > b
            } ?? 0
            centroids.append(rows[next])
        }

        var labels = Array(repeating: 0, count: rows.count)
        for _ in 0..<maxIterations {
            let newLabels = rows.map { row in
                centroids.indices.min { lhs, rhs in
                    let dl = euclidean(row, centroids[lhs]), dr = euclidean(row, centroids[rhs])
                    return abs(dl - dr) > 1e-12 ? dl < dr : lhs < rhs
                } ?? 0
            }
            var newCentroids = centroids
            for c in 0..<k {
                let members = rows.indices.filter { newLabels[$0] == c }.map { rows[$0] }
                if !members.isEmpty {
                    newCentroids[c] = (0..<rows[0].count).map { j in members.map { $0[j] }.reduce(0, +) / Double(members.count) }
                }
            }
            if newLabels == labels && zip(newCentroids, centroids).allSatisfy({ euclidean($0.0, $0.1) < 1e-10 }) {
                labels = newLabels; centroids = newCentroids; break
            }
            labels = newLabels; centroids = newCentroids
        }
        let counts = (0..<k).map { c in labels.filter { $0 == c }.count }
        return KMeansResult(labels: labels, centroids: centroids, counts: counts)
    }

    private static func silhouette(rows: [[Double]], labels: [Int], k: Int) -> Double {
        guard rows.count > 1 else { return 0 }
        var values: [Double] = []
        for i in rows.indices {
            let own = labels[i]
            let ownMembers = rows.indices.filter { $0 != i && labels[$0] == own }
            let a = ownMembers.isEmpty ? 0 : ownMembers.map { euclidean(rows[i], rows[$0]) }.reduce(0, +) / Double(ownMembers.count)
            var b = Double.infinity
            for c in 0..<k where c != own {
                let members = rows.indices.filter { labels[$0] == c }
                guard !members.isEmpty else { continue }
                let distance = members.map { euclidean(rows[i], rows[$0]) }.reduce(0, +) / Double(members.count)
                b = min(b, distance)
            }
            guard b.isFinite else { values.append(0); continue }
            let denom = max(a, b)
            values.append(denom > 1e-12 ? (b - a) / denom : 0)
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).map { pow($0.0 - $0.1, 2) }.reduce(0, +))
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let x = max(0, min(1, p)) * Double(sorted.count - 1)
        let lo = Int(floor(x)), hi = Int(ceil(x))
        if lo == hi { return sorted[lo] }
        let f = x - Double(lo)
        return sorted[lo] * (1 - f) + sorted[hi] * f
    }

    private static func lexicographicallyPrecedes(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if abs(a - b) <= 1e-12 { continue }
            return a < b
        }
        return false
    }
}

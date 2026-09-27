import Foundation
import ControlsPLC

public enum MultivariateNumericAggregation: String, Codable, Sendable, CaseIterable {
    case mean
    case maximum
    case minimum
    case final

    public var displayName: String {
        switch self {
        case .mean: return "Mean"
        case .maximum: return "Maximum"
        case .minimum: return "Minimum"
        case .final: return "Final"
        }
    }
}

public enum MultivariateFeatureKind: Equatable, Sendable {
    case transitionTiming(resultingValue: TagValue, occurrence: Int)
    case numeric(aggregation: MultivariateNumericAggregation)
}

public struct MultivariateFeatureDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let target: String
    public let layer: FlightSignalLayer
    public let kind: MultivariateFeatureKind
    public let displayName: String
    public let unit: String

    public init(
        id: String? = nil,
        target: String,
        layer: FlightSignalLayer,
        kind: MultivariateFeatureKind,
        displayName: String? = nil,
        unit: String = ""
    ) {
        self.target = target
        self.layer = layer
        self.kind = kind
        self.displayName = displayName ?? target
        self.unit = unit
        switch kind {
        case let .transitionTiming(value, occurrence):
            self.id = id ?? "timing|\(target)|\(layer.rawValue)|\(occurrence)|\(String(reflecting: value))"
        case let .numeric(aggregation):
            self.id = id ?? "numeric|\(target)|\(layer.rawValue)|\(aggregation.rawValue)"
        }
    }
}

public struct MultivariateFeatureStatistics: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public let definition: MultivariateFeatureDefinition
    public let sampleCount: Int
    public let mean: Double
    public let standardDeviation: Double
    public let minimum: Double
    public let maximum: Double
    public let slopePerCycle: Double
    public let trendRSquared: Double
}

public struct MultivariateCorrelation: Identifiable, Equatable, Sendable {
    public var id: String { firstFeatureID + "|" + secondFeatureID }
    public let firstFeatureID: String
    public let secondFeatureID: String
    public let coefficient: Double
}

public struct MultivariateHealthModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let features: [MultivariateFeatureStatistics]
    public let covarianceMatrix: [[Double]]
    public let inverseCovarianceMatrix: [[Double]]
    public let correlations: [MultivariateCorrelation]
    public let warningDistance: Double
    public let anomalousDistance: Double
    public let regularization: Double

    public init(
        name: String,
        cycleCount: Int,
        features: [MultivariateFeatureStatistics],
        covarianceMatrix: [[Double]],
        inverseCovarianceMatrix: [[Double]],
        correlations: [MultivariateCorrelation],
        warningDistance: Double,
        anomalousDistance: Double,
        regularization: Double
    ) {
        self.name = name
        self.cycleCount = cycleCount
        self.features = features
        self.covarianceMatrix = covarianceMatrix
        self.inverseCovarianceMatrix = inverseCovarianceMatrix
        self.correlations = correlations
        self.warningDistance = warningDistance
        self.anomalousDistance = anomalousDistance
        self.regularization = regularization
    }
}

public enum MultivariateHealthStatus: String, Codable, Sendable {
    case normal
    case emergingPattern
    case anomalousPattern
    case insufficientData

    public var displayName: String {
        switch self {
        case .normal: return "Normal joint pattern"
        case .emergingPattern: return "Emerging degradation pattern"
        case .anomalousPattern: return "Anomalous joint pattern"
        case .insufficientData: return "Insufficient data"
        }
    }
}

public struct MultivariateFeatureContribution: Identifiable, Equatable, Sendable {
    public var id: String { featureID }
    public let featureID: String
    public let displayName: String
    public let observedValue: Double
    public let healthyMean: Double
    public let standardizedDeviation: Double
    public let contributionScore: Double
    public let unit: String
}

public struct MultivariateHealthAssessment: Equatable, Sendable {
    public let modelName: String
    public let status: MultivariateHealthStatus
    public let mahalanobisDistance: Double?
    public let contributions: [MultivariateFeatureContribution]
    public let summary: String

    public var strongestContributors: [MultivariateFeatureContribution] {
        contributions.sorted { abs($0.contributionScore) > abs($1.contributionScore) }
    }
}

public enum MultivariateDegradationAnalyzer {
    public static func buildModel(
        name: String = "Healthy multivariate signature",
        cycles: [KnownGoodCycle],
        featureDefinitions: [MultivariateFeatureDefinition],
        minimumCycles: Int = 8,
        covarianceRegularization: Double = 0.08
    ) -> MultivariateHealthModel? {
        guard featureDefinitions.count >= 2, cycles.count >= max(3, minimumCycles) else { return nil }

        let rows = cycles.compactMap { cycle -> [Double]? in
            let values = featureDefinitions.map { extract($0, from: cycle) }
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return values.map { $0! }
        }
        guard rows.count >= max(3, minimumCycles) else { return nil }

        let columnCount = featureDefinitions.count
        let means = (0..<columnCount).map { j in rows.map { $0[j] }.reduce(0, +) / Double(rows.count) }
        let covariance = covarianceMatrix(rows: rows, means: means)
        let alpha = max(0.0001, covarianceRegularization)
        var regularized = covariance
        var diagonalRegularization: [Double] = []
        for i in 0..<columnCount {
            let ridge = max(1e-9, max(covariance[i][i], 1e-9) * alpha)
            regularized[i][i] += ridge
            diagonalRegularization.append(ridge)
        }
        let lambda = diagonalRegularization.reduce(0, +) / Double(diagonalRegularization.count)
        guard let inverse = invert(regularized) else { return nil }

        let featureStats = featureDefinitions.enumerated().map { index, definition in
            let values = rows.map { $0[index] }
            let regression = linearRegression(values.enumerated().map { (Double($0.offset), $0.element) })
            return MultivariateFeatureStatistics(
                definition: definition,
                sampleCount: rows.count,
                mean: means[index],
                standardDeviation: sqrt(max(covariance[index][index], 0)),
                minimum: values.min() ?? means[index],
                maximum: values.max() ?? means[index],
                slopePerCycle: regression.slope,
                trendRSquared: regression.rSquared
            )
        }

        var correlations: [MultivariateCorrelation] = []
        for i in 0..<columnCount {
            for j in (i + 1)..<columnCount {
                let denom = sqrt(max(covariance[i][i], 0) * max(covariance[j][j], 0))
                let r = denom > 1e-12 ? covariance[i][j] / denom : 0
                correlations.append(MultivariateCorrelation(
                    firstFeatureID: featureDefinitions[i].id,
                    secondFeatureID: featureDefinitions[j].id,
                    coefficient: max(-1, min(1, r))
                ))
            }
        }

        let trainingDistances = rows.map { row in
            sqrt(max(0, quadraticDistance(vector: zip(row, means).map { $0.0 - $0.1 }, inverse: inverse)))
        }.sorted()
        let empirical95 = percentile(trainingDistances, 0.95)
        let dimensionScale = sqrt(Double(columnCount))
        let warning = max(empirical95 * 1.10, dimensionScale * 1.15)
        let anomalous = max(warning * 1.35, dimensionScale * 1.80)

        return MultivariateHealthModel(
            name: name,
            cycleCount: rows.count,
            features: featureStats,
            covarianceMatrix: covariance,
            inverseCovarianceMatrix: inverse,
            correlations: correlations.sorted { abs($0.coefficient) > abs($1.coefficient) },
            warningDistance: warning,
            anomalousDistance: anomalous,
            regularization: lambda
        )
    }

    public static func assess(cycle: KnownGoodCycle, against model: MultivariateHealthModel) -> MultivariateHealthAssessment {
        let values = model.features.map { extract($0.definition, from: cycle) }
        guard values.allSatisfy({ $0 != nil }) else {
            return MultivariateHealthAssessment(
                modelName: model.name,
                status: .insufficientData,
                mahalanobisDistance: nil,
                contributions: [],
                summary: "This cycle does not contain every feature required by the learned multivariate signature."
            )
        }

        let observed = values.map { $0! }
        let centered = zip(observed, model.features.map(\.mean)).map { $0.0 - $0.1 }
        let transformed = multiply(model.inverseCovarianceMatrix, centered)
        let distanceSquared = max(0, zip(centered, transformed).map { $0.0 * $0.1 }.reduce(0, +))
        let distance = sqrt(distanceSquared)

        let contributions = model.features.enumerated().map { index, feature in
            let sd = max(feature.standardDeviation, 1e-9)
            let z = centered[index] / sd
            let signedContribution = centered[index] * transformed[index]
            return MultivariateFeatureContribution(
                featureID: feature.definition.id,
                displayName: feature.definition.displayName,
                observedValue: observed[index],
                healthyMean: feature.mean,
                standardizedDeviation: z,
                contributionScore: signedContribution,
                unit: feature.definition.unit
            )
        }

        let status: MultivariateHealthStatus
        if distance >= model.anomalousDistance { status = .anomalousPattern }
        else if distance >= model.warningDistance { status = .emergingPattern }
        else { status = .normal }

        let strongest = contributions.sorted { abs($0.contributionScore) > abs($1.contributionScore) }.prefix(3)
        let contributorText = strongest.map { item in
            let direction = item.observedValue >= item.healthyMean ? "higher/later" : "lower/earlier"
            return "\(item.displayName) \(direction) (z \(String(format: "%+.2f", item.standardizedDeviation)))"
        }.joined(separator: ", ")

        let summary: String
        switch status {
        case .normal:
            summary = "The combined feature vector remains inside the learned joint healthy pattern (distance \(String(format: "%.2f", distance)))."
        case .emergingPattern:
            summary = "The signals are still close to their individual ranges, but their combination is departing from the learned covariance pattern. Strongest contributors: \(contributorText)."
        case .anomalousPattern:
            summary = "The combined machine-health signature is outside the learned healthy covariance region. Strongest contributors: \(contributorText)."
        case .insufficientData:
            summary = "Insufficient data."
        }

        return MultivariateHealthAssessment(
            modelName: model.name,
            status: status,
            mahalanobisDistance: distance,
            contributions: contributions,
            summary: summary
        )
    }

    public static func extract(_ definition: MultivariateFeatureDefinition, from cycle: KnownGoodCycle) -> Double? {
        let samples = cycle.signalSamples
            .filter { $0.target == definition.target && $0.layer == definition.layer }
            .sorted {
                if $0.milliseconds != $1.milliseconds { return $0.milliseconds < $1.milliseconds }
                return ($0.stepIndex ?? Int.min) < ($1.stepIndex ?? Int.min)
            }
        guard !samples.isEmpty else { return nil }

        switch definition.kind {
        case let .transitionTiming(resultingValue, occurrence):
            guard samples.count >= 2 else { return nil }
            var previous = samples[0].value
            var seen = 0
            for sample in samples.dropFirst() {
                if sample.value != previous {
                    if sample.value == resultingValue {
                        if seen == occurrence { return Double(sample.milliseconds - cycle.anchorMilliseconds) }
                        seen += 1
                    }
                    previous = sample.value
                }
            }
            return nil

        case let .numeric(aggregation):
            let values = samples.compactMap { numeric($0.value) }
            guard !values.isEmpty else { return nil }
            switch aggregation {
            case .mean: return values.reduce(0, +) / Double(values.count)
            case .maximum: return values.max()
            case .minimum: return values.min()
            case .final: return values.last
            }
        }
    }

    private static func numeric(_ value: TagValue) -> Double? {
        switch value {
        case let .dint(v): return Double(v)
        case let .real(v): return v
        case let .bool(v): return v ? 1 : 0
        case let .timer(v): return Double(v.ACC)
        case let .counter(v): return Double(v.ACC)
        }
    }

    private static func covarianceMatrix(rows: [[Double]], means: [Double]) -> [[Double]] {
        let n = rows.count
        let p = means.count
        var matrix = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        guard n > 1 else { return matrix }
        for row in rows {
            for i in 0..<p {
                for j in i..<p {
                    matrix[i][j] += (row[i] - means[i]) * (row[j] - means[j])
                }
            }
        }
        let denom = Double(n - 1)
        for i in 0..<p {
            for j in i..<p {
                matrix[i][j] /= denom
                matrix[j][i] = matrix[i][j]
            }
        }
        return matrix
    }

    private static func quadraticDistance(vector: [Double], inverse: [[Double]]) -> Double {
        let transformed = multiply(inverse, vector)
        return zip(vector, transformed).map { $0.0 * $0.1 }.reduce(0, +)
    }

    private static func multiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        matrix.map { row in zip(row, vector).map { $0.0 * $0.1 }.reduce(0, +) }
    }

    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var inv = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }

        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(a[row][col]) > abs(a[pivot][col]) { pivot = row }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            if pivot != col {
                a.swapAt(pivot, col)
                inv.swapAt(pivot, col)
            }
            let divisor = a[col][col]
            for j in 0..<n {
                a[col][j] /= divisor
                inv[col][j] /= divisor
            }
            for row in 0..<n where row != col {
                let factor = a[row][col]
                if abs(factor) < 1e-18 { continue }
                for j in 0..<n {
                    a[row][j] -= factor * a[col][j]
                    inv[row][j] -= factor * inv[col][j]
                }
            }
        }
        return inv
    }

    private static func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        if sortedValues.count == 1 { return sortedValues[0] }
        let x = max(0, min(1, p)) * Double(sortedValues.count - 1)
        let lo = Int(floor(x)), hi = Int(ceil(x))
        if lo == hi { return sortedValues[lo] }
        let fraction = x - Double(lo)
        return sortedValues[lo] * (1 - fraction) + sortedValues[hi] * fraction
    }

    private static func linearRegression(_ points: [(Double, Double)]) -> (slope: Double, rSquared: Double) {
        guard points.count >= 2 else { return (0, 0) }
        let meanX = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = points.reduce(0) { $0 + pow($1.0 - meanX, 2) }
        guard denominator > 1e-12 else { return (0, 0) }
        let slope = numerator / denominator
        let predicted = points.map { meanY + slope * ($0.0 - meanX) }
        let ssResidual = zip(points, predicted).reduce(0) { $0 + pow($1.0.0 - $1.1, 2) }
        let ssTotal = points.reduce(0) { $0 + pow($1.1 - meanY, 2) }
        let r2 = ssTotal > 1e-12 ? max(0, min(1, 1 - ssResidual / ssTotal)) : 1
        return (slope, r2)
    }
}


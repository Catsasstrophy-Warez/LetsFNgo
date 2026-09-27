import Foundation
import ControlsPLC

public enum CycleSegmentationRule: Equatable, Sendable {
    /// Each matching event is treated as the cycle anchor. Samples are retained in the configured
    /// window around that anchor, so captures can overlap intentionally for teaching scenarios.
    case event(name: String, preMilliseconds: Int64, postMilliseconds: Int64)
}

public struct SegmentedHealthyCycle: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public let anchorMilliseconds: Int64
    public let cycle: KnownGoodCycle

    public init(id: UUID = UUID(), ordinal: Int, anchorMilliseconds: Int64, cycle: KnownGoodCycle) {
        self.id = id
        self.ordinal = ordinal
        self.anchorMilliseconds = anchorMilliseconds
        self.cycle = cycle
    }
}

public enum HealthyTrendDirection: String, Codable, Sendable {
    case stable
    case driftingEarlier
    case driftingLater
    case insufficientData

    public var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .driftingEarlier: return "Drifting earlier"
        case .driftingLater: return "Drifting later"
        case .insufficientData: return "Insufficient data"
        }
    }
}

public struct HealthyTransitionKey: Hashable, Sendable {
    public let target: String
    public let layer: FlightSignalLayer
    public let occurrence: Int
    public let resultingValue: TagValue

    public init(target: String, layer: FlightSignalLayer, occurrence: Int, resultingValue: TagValue) {
        self.target = target
        self.layer = layer
        self.occurrence = occurrence
        self.resultingValue = resultingValue
    }

    public static func == (lhs: HealthyTransitionKey, rhs: HealthyTransitionKey) -> Bool {
        lhs.target == rhs.target && lhs.layer == rhs.layer && lhs.occurrence == rhs.occurrence && lhs.resultingValue == rhs.resultingValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(target)
        hasher.combine(layer.rawValue)
        hasher.combine(occurrence)
        hasher.combine(String(reflecting: resultingValue))
    }
}

public struct HealthyTimingEnvelope: Identifiable, Equatable, Sendable {
    public var id: String { "\(target)|\(layer.rawValue)|\(occurrence)|\(String(describing: resultingValue))" }
    public let target: String
    public let layer: FlightSignalLayer
    public let occurrence: Int
    public let resultingValue: TagValue
    public let sampleCount: Int
    public let meanRelativeMilliseconds: Double
    public let medianRelativeMilliseconds: Double
    public let standardDeviationMilliseconds: Double
    public let medianAbsoluteDeviationMilliseconds: Double
    public let lowerNormalMilliseconds: Int64
    public let upperNormalMilliseconds: Int64
    public let slopeMillisecondsPerCycle: Double
    public let trendRSquared: Double
    public let trend: HealthyTrendDirection

    public var normalRangeDisplay: String { "T\(formatRelative(lowerNormalMilliseconds)) … T\(formatRelative(upperNormalMilliseconds))" }

    public func contains(relativeMilliseconds: Int64) -> Bool {
        relativeMilliseconds >= lowerNormalMilliseconds && relativeMilliseconds <= upperNormalMilliseconds
    }

    private func formatRelative(_ value: Int64) -> String {
        value >= 0 ? "+\(value) ms" : "\(value) ms"
    }
}

public struct HealthyEnvelopeModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let envelopes: [HealthyTimingEnvelope]
    public let minimumSamplesPerEnvelope: Int

    public init(name: String, cycleCount: Int, envelopes: [HealthyTimingEnvelope], minimumSamplesPerEnvelope: Int) {
        self.name = name
        self.cycleCount = cycleCount
        self.envelopes = envelopes.sorted {
            if $0.meanRelativeMilliseconds != $1.meanRelativeMilliseconds { return $0.meanRelativeMilliseconds < $1.meanRelativeMilliseconds }
            if $0.target != $1.target { return $0.target < $1.target }
            return $0.occurrence < $1.occurrence
        }
        self.minimumSamplesPerEnvelope = minimumSamplesPerEnvelope
    }

    public func envelope(target: String, layer: FlightSignalLayer? = nil, occurrence: Int = 0) -> HealthyTimingEnvelope? {
        envelopes.first { $0.target == target && (layer == nil || $0.layer == layer!) && $0.occurrence == occurrence }
    }
}

public enum EnvelopeObservationStatus: String, Codable, Sendable {
    case insideNormal
    case earlyOutlier
    case lateOutlier
    case missingExpectedTransition
    case unmodeledTransition
}

public struct EnvelopeObservation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let layer: FlightSignalLayer
    public let occurrence: Int
    public let status: EnvelopeObservationStatus
    public let observedRelativeMilliseconds: Int64?
    public let envelope: HealthyTimingEnvelope?
    public let explanation: String

    public init(id: UUID = UUID(), target: String, layer: FlightSignalLayer, occurrence: Int, status: EnvelopeObservationStatus, observedRelativeMilliseconds: Int64?, envelope: HealthyTimingEnvelope?, explanation: String) {
        self.id = id
        self.target = target
        self.layer = layer
        self.occurrence = occurrence
        self.status = status
        self.observedRelativeMilliseconds = observedRelativeMilliseconds
        self.envelope = envelope
        self.explanation = explanation
    }
}

public struct HealthyEnvelopeComparison: Equatable, Sendable {
    public let modelName: String
    public let observations: [EnvelopeObservation]
    public let earliestOutlier: EnvelopeObservation?
    public let summary: String

    public var outliers: [EnvelopeObservation] {
        observations.filter { $0.status == .earlyOutlier || $0.status == .lateOutlier || $0.status == .missingExpectedTransition }
    }
}

private struct HealthyTransitionObservation {
    let key: HealthyTransitionKey
    let relativeMilliseconds: Int64
}

public enum HealthyCycleAnalyzer {
    public static func segment(
        signalSamples: [FlightSignalSample],
        taskExecutions: [TaskExecutionStamp] = [],
        events: [TemporalEventMarker],
        rule: CycleSegmentationRule,
        namePrefix: String = "Healthy cycle"
    ) -> [SegmentedHealthyCycle] {
        switch rule {
        case let .event(name, preMilliseconds, postMilliseconds):
            let pre = max(0, preMilliseconds)
            let post = max(0, postMilliseconds)
            let anchors = events.filter { $0.name == name }.sorted { $0.milliseconds < $1.milliseconds }
            return anchors.enumerated().map { index, marker in
                let start = marker.milliseconds - pre
                let end = marker.milliseconds + post
                let cycle = KnownGoodCycle(
                    name: "\(namePrefix) \(index + 1)",
                    anchorMilliseconds: marker.milliseconds,
                    signalSamples: signalSamples.filter { $0.milliseconds >= start && $0.milliseconds <= end },
                    taskExecutions: taskExecutions.filter { $0.milliseconds >= start && $0.milliseconds <= end },
                    events: events.filter { $0.milliseconds >= start && $0.milliseconds <= end }
                )
                return SegmentedHealthyCycle(ordinal: index, anchorMilliseconds: marker.milliseconds, cycle: cycle)
            }
        }
    }

    public static func buildModel(
        name: String = "Healthy timing envelope",
        cycles: [KnownGoodCycle],
        minimumSamplesPerEnvelope: Int = 5,
        minimumNormalBandMilliseconds: Int64 = 10,
        driftThresholdMillisecondsPerCycle: Double = 2.0
    ) -> HealthyEnvelopeModel {
        let minimumSamples = max(2, minimumSamplesPerEnvelope)
        var grouped: [HealthyTransitionKey: [(cycle: Int, time: Int64)]] = [:]

        for (cycleIndex, cycle) in cycles.enumerated() {
            for observation in transitionObservations(cycle.signalSamples, anchor: cycle.anchorMilliseconds) {
                grouped[observation.key, default: []].append((cycleIndex, observation.relativeMilliseconds))
            }
        }

        let envelopes = grouped.compactMap { key, observations -> HealthyTimingEnvelope? in
            guard observations.count >= minimumSamples else { return nil }
            let values = observations.map { Double($0.time) }
            let sorted = values.sorted()
            let mean = values.reduce(0, +) / Double(values.count)
            let median = percentile(sorted, 0.5)
            let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(1, values.count - 1))
            let sd = sqrt(variance)
            let deviations = values.map { abs($0 - median) }.sorted()
            let mad = percentile(deviations, 0.5)
            let robustSigma = mad * 1.4826
            let empiricalLow = percentile(sorted, 0.05)
            let empiricalHigh = percentile(sorted, 0.95)
            let halfBand = max(Double(minimumNormalBandMilliseconds) / 2.0, robustSigma * 3.0)
            let lower = Int64(floor(min(empiricalLow, median - halfBand)))
            let upper = Int64(ceil(max(empiricalHigh, median + halfBand)))
            let regression = linearRegression(observations.map { (Double($0.cycle), Double($0.time)) })
            let totalProjectedDrift = abs(regression.slope) * Double(max(0, observations.count - 1))
            let meaningfulDrift = abs(regression.slope) >= driftThresholdMillisecondsPerCycle && regression.rSquared >= 0.50 && totalProjectedDrift >= 25.0
            let trend: HealthyTrendDirection
            if observations.count < 5 { trend = .insufficientData }
            else if meaningfulDrift { trend = regression.slope > 0 ? .driftingLater : .driftingEarlier }
            else { trend = .stable }

            return HealthyTimingEnvelope(
                target: key.target,
                layer: key.layer,
                occurrence: key.occurrence,
                resultingValue: key.resultingValue,
                sampleCount: observations.count,
                meanRelativeMilliseconds: mean,
                medianRelativeMilliseconds: median,
                standardDeviationMilliseconds: sd,
                medianAbsoluteDeviationMilliseconds: mad,
                lowerNormalMilliseconds: lower,
                upperNormalMilliseconds: upper,
                slopeMillisecondsPerCycle: regression.slope,
                trendRSquared: regression.rSquared,
                trend: trend
            )
        }

        return HealthyEnvelopeModel(name: name, cycleCount: cycles.count, envelopes: envelopes, minimumSamplesPerEnvelope: minimumSamples)
    }

    public static func compare(cycle: KnownGoodCycle, against model: HealthyEnvelopeModel) -> HealthyEnvelopeComparison {
        let actual = transitionObservations(cycle.signalSamples, anchor: cycle.anchorMilliseconds)
        let actualByKey = Dictionary(uniqueKeysWithValues: actual.map { ($0.key, $0) })
        let envelopeByKey = Dictionary(uniqueKeysWithValues: model.envelopes.map {
            (HealthyTransitionKey(target: $0.target, layer: $0.layer, occurrence: $0.occurrence, resultingValue: $0.resultingValue), $0)
        })
        var observations: [EnvelopeObservation] = []

        for envelope in model.envelopes {
            let key = HealthyTransitionKey(target: envelope.target, layer: envelope.layer, occurrence: envelope.occurrence, resultingValue: envelope.resultingValue)
            guard let item = actualByKey[key] else {
                observations.append(EnvelopeObservation(target: envelope.target, layer: envelope.layer, occurrence: envelope.occurrence, status: .missingExpectedTransition, observedRelativeMilliseconds: nil, envelope: envelope, explanation: "Expected transition was present in the healthy population but is missing from this cycle."))
                continue
            }
            let status: EnvelopeObservationStatus
            if item.relativeMilliseconds < envelope.lowerNormalMilliseconds { status = .earlyOutlier }
            else if item.relativeMilliseconds > envelope.upperNormalMilliseconds { status = .lateOutlier }
            else { status = .insideNormal }
            let explanation: String
            switch status {
            case .insideNormal:
                explanation = "\(item.relativeMilliseconds) ms lies inside the learned normal range \(envelope.lowerNormalMilliseconds)…\(envelope.upperNormalMilliseconds) ms."
            case .earlyOutlier:
                explanation = "Transition occurred \(envelope.lowerNormalMilliseconds - item.relativeMilliseconds) ms earlier than the learned normal boundary."
            case .lateOutlier:
                explanation = "Transition occurred \(item.relativeMilliseconds - envelope.upperNormalMilliseconds) ms later than the learned normal boundary."
            default: explanation = ""
            }
            observations.append(EnvelopeObservation(target: envelope.target, layer: envelope.layer, occurrence: envelope.occurrence, status: status, observedRelativeMilliseconds: item.relativeMilliseconds, envelope: envelope, explanation: explanation))
        }

        for item in actual where envelopeByKey[item.key] == nil {
            observations.append(EnvelopeObservation(target: item.key.target, layer: item.key.layer, occurrence: item.key.occurrence, status: .unmodeledTransition, observedRelativeMilliseconds: item.relativeMilliseconds, envelope: nil, explanation: "This transition was not represented often enough in the healthy population to have a learned envelope."))
        }

        observations.sort {
            let l = $0.observedRelativeMilliseconds ?? $0.envelope?.meanRelativeMilliseconds.rounded().int64Value ?? Int64.max
            let r = $1.observedRelativeMilliseconds ?? $1.envelope?.meanRelativeMilliseconds.rounded().int64Value ?? Int64.max
            if l != r { return l < r }
            return $0.target < $1.target
        }
        let earliest = observations.first { $0.status == .earlyOutlier || $0.status == .lateOutlier || $0.status == .missingExpectedTransition }
        let summary: String
        if let earliest {
            summary = "Earliest departure from the learned \(model.cycleCount)-cycle healthy envelope: \(earliest.target). \(earliest.explanation)"
        } else {
            summary = "This cycle stays inside the learned timing envelopes for all modeled transitions."
        }
        return HealthyEnvelopeComparison(modelName: model.name, observations: observations, earliestOutlier: earliest, summary: summary)
    }

    private static func transitionObservations(_ samples: [FlightSignalSample], anchor: Int64) -> [HealthyTransitionObservation] {
        let grouped = Dictionary(grouping: samples) { "\($0.target)|\($0.layer.rawValue)" }
        var result: [HealthyTransitionObservation] = []
        for values in grouped.values {
            let sorted = values.sorted {
                if $0.milliseconds != $1.milliseconds { return $0.milliseconds < $1.milliseconds }
                return ($0.stepIndex ?? Int.min) < ($1.stepIndex ?? Int.min)
            }
            guard let first = sorted.first else { continue }
            var previous = first.value
            var occurrenceByValue: [String: Int] = [:]
            for sample in sorted.dropFirst() where sample.value != previous {
                let valueKey = String(reflecting: sample.value)
                let occurrence = occurrenceByValue[valueKey, default: 0]
                occurrenceByValue[valueKey] = occurrence + 1
                result.append(HealthyTransitionObservation(
                    key: HealthyTransitionKey(target: sample.target, layer: sample.layer, occurrence: occurrence, resultingValue: sample.value),
                    relativeMilliseconds: sample.milliseconds - anchor
                ))
                previous = sample.value
            }
        }
        return result
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = max(0, min(1, p)) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func linearRegression(_ points: [(Double, Double)]) -> (slope: Double, rSquared: Double) {
        guard points.count >= 2 else { return (0, 0) }
        let meanX = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let sxx = points.reduce(0) { $0 + pow($1.0 - meanX, 2) }
        guard sxx > 0 else { return (0, 0) }
        let sxy = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let ssTotal = points.reduce(0) { $0 + pow($1.1 - meanY, 2) }
        let ssResidual = points.reduce(0) { $0 + pow($1.1 - (intercept + slope * $1.0), 2) }
        let r2 = ssTotal > 0 ? max(0, min(1, 1 - ssResidual / ssTotal)) : 1
        return (slope, r2)
    }
}

private extension Double {
    var int64Value: Int64 { Int64(self) }
}

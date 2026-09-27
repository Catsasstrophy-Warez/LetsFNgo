import Foundation
import ControlsPLC

public struct TrajectoryStatePoint: Identifiable, Equatable, Sendable {
    public var id: String { "\(relativeMilliseconds)|\(regionID ?? "unknown")" }
    public let relativeMilliseconds: Int64
    public let regionID: String?
    public let regionName: String?
    public let contextDistance: Double?
    public let contextValues: [Double]
}

public struct TrajectoryStateSegment: Identifiable, Equatable, Sendable {
    public var id: String { "\(regionID)|\(startRelativeMilliseconds)|\(endRelativeMilliseconds)" }
    public let regionID: String
    public let regionName: String
    public let startRelativeMilliseconds: Int64
    public let endRelativeMilliseconds: Int64
    public let durationMilliseconds: Int64
}

public struct TrajectoryTimingEnvelope: Identifiable, Equatable, Sendable {
    public var id: String { "\(regionID)|\(metric.rawValue)" }
    public enum Metric: String, Codable, Sendable { case firstEntry, dwell }
    public let regionID: String
    public let regionName: String
    public let metric: Metric
    public let sampleCount: Int
    public let meanMilliseconds: Double
    public let medianMilliseconds: Double
    public let lowerMilliseconds: Double
    public let upperMilliseconds: Double
}

public struct TrajectoryTransitionModel: Identifiable, Equatable, Sendable {
    public var id: String { "\(fromRegionID)->\(toRegionID)" }
    public let fromRegionID: String
    public let toRegionID: String
    public let count: Int
    public let probability: Double
}

public struct WithinCycleTrajectoryModel: Equatable, Sendable {
    public let name: String
    public let cycleCount: Int
    public let samplingIntervalMilliseconds: Int64
    public let operatingStateModel: ContinuousOperatingStateModel
    public let entryEnvelopes: [TrajectoryTimingEnvelope]
    public let dwellEnvelopes: [TrajectoryTimingEnvelope]
    public let transitions: [TrajectoryTransitionModel]
    public let dominantPath: [String]

    public func entryEnvelope(for regionID: String) -> TrajectoryTimingEnvelope? { entryEnvelopes.first { $0.regionID == regionID } }
    public func dwellEnvelope(for regionID: String) -> TrajectoryTimingEnvelope? { dwellEnvelopes.first { $0.regionID == regionID } }
    public func transition(from: String, to: String) -> TrajectoryTransitionModel? { transitions.first { $0.fromRegionID == from && $0.toRegionID == to } }
}

public enum TrajectoryAnomalyKind: String, Codable, Sendable {
    case earlyEntry
    case lateEntry
    case excessiveDwell
    case shortDwell
    case unexpectedTransition
    case outsideLearnedOperatingSpace

    public var displayName: String {
        switch self {
        case .earlyEntry: return "Entered state too early"
        case .lateEntry: return "Entered state too late"
        case .excessiveDwell: return "Stayed in state too long"
        case .shortDwell: return "Left state too early"
        case .unexpectedTransition: return "Unexpected transition path"
        case .outsideLearnedOperatingSpace: return "Outside learned operating space"
        }
    }
}

public struct TrajectoryAnomaly: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: TrajectoryAnomalyKind
    public let regionID: String?
    public let regionName: String?
    public let relativeMilliseconds: Int64
    public let magnitudeMilliseconds: Double?
    public let explanation: String

    public init(id: UUID = UUID(), kind: TrajectoryAnomalyKind, regionID: String?, regionName: String?, relativeMilliseconds: Int64, magnitudeMilliseconds: Double?, explanation: String) {
        self.id = id
        self.kind = kind
        self.regionID = regionID
        self.regionName = regionName
        self.relativeMilliseconds = relativeMilliseconds
        self.magnitudeMilliseconds = magnitudeMilliseconds
        self.explanation = explanation
    }
}

public enum TrajectoryAssessmentStatus: String, Codable, Sendable {
    case normal
    case anomalous
    case insufficientData

    public var displayName: String {
        switch self {
        case .normal: return "Normal state trajectory"
        case .anomalous: return "Abnormal state trajectory"
        case .insufficientData: return "Insufficient trajectory data"
        }
    }
}

public struct WithinCycleTrajectoryAssessment: Equatable, Sendable {
    public let status: TrajectoryAssessmentStatus
    public let points: [TrajectoryStatePoint]
    public let segments: [TrajectoryStateSegment]
    public let anomalies: [TrajectoryAnomaly]
    public let summary: String
}

public enum WithinCycleStateTrajectoryAnalyzer {
    /// Learns the operating regions from synchronized *within-cycle* context samples rather than
    /// from one aggregate vector per cycle, then learns entry/dwell/transition timing across cycles.
    public static func buildModel(
        name: String = "Within-cycle state trajectory model",
        cycles: [KnownGoodCycle],
        contextKeys: [OperatingContextKey],
        clusterCount: Int? = nil,
        maximumClusters: Int = 7,
        samplingIntervalMilliseconds: Int64 = 20,
        minimumSamplesPerRegion: Int = 12,
        minimumEnvelopeSamples: Int = 6
    ) -> WithinCycleTrajectoryModel? {
        guard contextKeys.count >= 2, samplingIntervalMilliseconds > 0, cycles.count >= minimumEnvelopeSamples else { return nil }
        let snapshots = cycles.flatMap { snapshotCycles(from: $0, contextKeys: contextKeys, samplingIntervalMilliseconds: samplingIntervalMilliseconds) }
        guard let stateModel = ContinuousOperatingStateAnalyzer.buildModel(
            name: "Within-cycle operating regions",
            cycles: snapshots,
            contextKeys: contextKeys,
            healthFeatureDefinitions: [],
            clusterCount: clusterCount,
            maximumClusters: maximumClusters,
            minimumCyclesPerRegion: minimumSamplesPerRegion
        ) else { return nil }
        return buildModel(
            name: name,
            cycles: cycles,
            operatingStateModel: stateModel,
            samplingIntervalMilliseconds: samplingIntervalMilliseconds,
            minimumEnvelopeSamples: minimumEnvelopeSamples
        )
    }

    public static func buildModel(
        name: String = "Within-cycle state trajectory model",
        cycles: [KnownGoodCycle],
        operatingStateModel: ContinuousOperatingStateModel,
        samplingIntervalMilliseconds: Int64 = 20,
        minimumEnvelopeSamples: Int = 6
    ) -> WithinCycleTrajectoryModel? {
        guard cycles.count >= minimumEnvelopeSamples, samplingIntervalMilliseconds > 0 else { return nil }
        let trajectories = cycles.map { trajectory(for: $0, model: operatingStateModel, samplingIntervalMilliseconds: samplingIntervalMilliseconds) }
            .filter { !$0.segments.isEmpty }
        guard trajectories.count >= minimumEnvelopeSamples else { return nil }

        var entries: [String: [Double]] = [:]
        var dwells: [String: [Double]] = [:]
        var transitionCounts: [String: Int] = [:]
        var outgoingCounts: [String: Int] = [:]
        var pathCounts: [String: Int] = [:]

        for trajectory in trajectories {
            var seen = Set<String>()
            for segment in trajectory.segments {
                if !seen.contains(segment.regionID) {
                    entries[segment.regionID, default: []].append(Double(segment.startRelativeMilliseconds))
                    seen.insert(segment.regionID)
                }
                dwells[segment.regionID, default: []].append(Double(segment.durationMilliseconds))
            }
            if trajectory.segments.count >= 2 {
                for index in 1..<trajectory.segments.count {
                    let from = trajectory.segments[index - 1].regionID
                    let to = trajectory.segments[index].regionID
                    transitionCounts["\(from)|\(to)", default: 0] += 1
                    outgoingCounts[from, default: 0] += 1
                }
            }
            let path = trajectory.segments.map(\.regionID).joined(separator: ">")
            pathCounts[path, default: 0] += 1
        }

        let entryEnvelopes = entries.compactMap { regionID, values -> TrajectoryTimingEnvelope? in
            guard values.count >= minimumEnvelopeSamples, let region = operatingStateModel.region(id: regionID) else { return nil }
            return envelope(region: region, metric: .firstEntry, values: values)
        }.sorted { $0.regionID < $1.regionID }
        let dwellEnvelopes = dwells.compactMap { regionID, values -> TrajectoryTimingEnvelope? in
            guard values.count >= minimumEnvelopeSamples, let region = operatingStateModel.region(id: regionID) else { return nil }
            return envelope(region: region, metric: .dwell, values: values)
        }.sorted { $0.regionID < $1.regionID }

        let transitions = transitionCounts.compactMap { key, count -> TrajectoryTransitionModel? in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return TrajectoryTransitionModel(fromRegionID: parts[0], toRegionID: parts[1], count: count, probability: Double(count) / Double(max(outgoingCounts[parts[0]] ?? 0, 1)))
        }.sorted { $0.id < $1.id }

        let dominantPath = pathCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key.split(separator: ">").map(String.init) ?? []

        return WithinCycleTrajectoryModel(
            name: name,
            cycleCount: trajectories.count,
            samplingIntervalMilliseconds: samplingIntervalMilliseconds,
            operatingStateModel: operatingStateModel,
            entryEnvelopes: entryEnvelopes,
            dwellEnvelopes: dwellEnvelopes,
            transitions: transitions,
            dominantPath: dominantPath
        )
    }

    public static func assess(cycle: KnownGoodCycle, against model: WithinCycleTrajectoryModel) -> WithinCycleTrajectoryAssessment {
        let observed = trajectory(for: cycle, model: model.operatingStateModel, samplingIntervalMilliseconds: model.samplingIntervalMilliseconds)
        guard !observed.points.isEmpty, !observed.segments.isEmpty else {
            return WithinCycleTrajectoryAssessment(status: .insufficientData, points: observed.points, segments: observed.segments, anomalies: [], summary: "The capture does not contain enough synchronized operating-context samples to reconstruct a within-cycle state trajectory.")
        }

        var anomalies: [TrajectoryAnomaly] = []
        var firstEntry: [String: TrajectoryStateSegment] = [:]
        for segment in observed.segments where firstEntry[segment.regionID] == nil { firstEntry[segment.regionID] = segment }

        for (regionID, segment) in firstEntry {
            guard let envelope = model.entryEnvelope(for: regionID) else { continue }
            let value = Double(segment.startRelativeMilliseconds)
            if value < envelope.lowerMilliseconds {
                anomalies.append(TrajectoryAnomaly(kind: .earlyEntry, regionID: regionID, regionName: segment.regionName, relativeMilliseconds: segment.startRelativeMilliseconds, magnitudeMilliseconds: envelope.lowerMilliseconds - value, explanation: "Entered \(segment.regionName) at T\(signed(segment.startRelativeMilliseconds)) ms, \(Int(round(envelope.lowerMilliseconds - value))) ms earlier than the learned healthy entry band."))
            } else if value > envelope.upperMilliseconds {
                anomalies.append(TrajectoryAnomaly(kind: .lateEntry, regionID: regionID, regionName: segment.regionName, relativeMilliseconds: segment.startRelativeMilliseconds, magnitudeMilliseconds: value - envelope.upperMilliseconds, explanation: "Entered \(segment.regionName) at T\(signed(segment.startRelativeMilliseconds)) ms, \(Int(round(value - envelope.upperMilliseconds))) ms later than the learned healthy entry band."))
            }
        }

        for segment in observed.segments {
            guard let envelope = model.dwellEnvelope(for: segment.regionID) else { continue }
            let duration = Double(segment.durationMilliseconds)
            if duration > envelope.upperMilliseconds {
                anomalies.append(TrajectoryAnomaly(kind: .excessiveDwell, regionID: segment.regionID, regionName: segment.regionName, relativeMilliseconds: segment.endRelativeMilliseconds, magnitudeMilliseconds: duration - envelope.upperMilliseconds, explanation: "Stayed in \(segment.regionName) for \(segment.durationMilliseconds) ms, \(Int(round(duration - envelope.upperMilliseconds))) ms beyond the learned healthy dwell band."))
            } else if duration < envelope.lowerMilliseconds {
                anomalies.append(TrajectoryAnomaly(kind: .shortDwell, regionID: segment.regionID, regionName: segment.regionName, relativeMilliseconds: segment.endRelativeMilliseconds, magnitudeMilliseconds: envelope.lowerMilliseconds - duration, explanation: "Left \(segment.regionName) after \(segment.durationMilliseconds) ms, \(Int(round(envelope.lowerMilliseconds - duration))) ms sooner than the learned healthy dwell band."))
            }
        }

        if observed.segments.count >= 2 {
            for index in 1..<observed.segments.count {
                let from = observed.segments[index - 1]
                let to = observed.segments[index]
                guard model.transition(from: from.regionID, to: to.regionID) == nil else { continue }
                anomalies.append(TrajectoryAnomaly(kind: .unexpectedTransition, regionID: to.regionID, regionName: to.regionName, relativeMilliseconds: to.startRelativeMilliseconds, magnitudeMilliseconds: nil, explanation: "The transition \(from.regionName) → \(to.regionName) was not observed in the healthy within-cycle training paths."))
            }
        }

        let unknownPoints = observed.points.filter { $0.regionID == nil }
        if let firstUnknown = unknownPoints.first {
            anomalies.append(TrajectoryAnomaly(kind: .outsideLearnedOperatingSpace, regionID: nil, regionName: nil, relativeMilliseconds: firstUnknown.relativeMilliseconds, magnitudeMilliseconds: nil, explanation: "The trajectory left every learned healthy operating region near T\(signed(firstUnknown.relativeMilliseconds)) ms. Treat this as novel operating context, not automatically as a component failure."))
        }

        anomalies.sort {
            if $0.relativeMilliseconds != $1.relativeMilliseconds { return $0.relativeMilliseconds < $1.relativeMilliseconds }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        let status: TrajectoryAssessmentStatus = anomalies.isEmpty ? .normal : .anomalous
        let summary: String
        if anomalies.isEmpty {
            summary = "The cycle followed the learned within-cycle state path with entry timing, dwell times, and transitions inside the healthy envelopes."
        } else {
            let earliest = anomalies[0]
            summary = "Detected \(anomalies.count) trajectory anomaly\(anomalies.count == 1 ? "" : "ies"). Earliest: \(earliest.kind.displayName) near T\(signed(earliest.relativeMilliseconds)) ms. This is behavioral evidence; causal provenance is still required before naming a physical root cause."
        }
        return WithinCycleTrajectoryAssessment(status: status, points: observed.points, segments: observed.segments, anomalies: anomalies, summary: summary)
    }

    public static func trajectory(
        for cycle: KnownGoodCycle,
        model: ContinuousOperatingStateModel,
        samplingIntervalMilliseconds: Int64 = 20
    ) -> (points: [TrajectoryStatePoint], segments: [TrajectoryStateSegment]) {
        guard samplingIntervalMilliseconds > 0, !model.contextStatistics.isEmpty else { return ([], []) }
        let relevant = model.contextStatistics.compactMap { stats in
            cycle.signalSamples.filter { $0.target == stats.key.target && $0.layer == stats.key.layer }.map(\.milliseconds).min()
        }
        let relevantMax = model.contextStatistics.compactMap { stats in
            cycle.signalSamples.filter { $0.target == stats.key.target && $0.layer == stats.key.layer }.map(\.milliseconds).max()
        }
        guard let start = relevant.max(), let end = relevantMax.min(), end >= start else { return ([], []) }

        var sampleTimes: [Int64] = []
        var t = start
        while t <= end { sampleTimes.append(t); t += samplingIntervalMilliseconds }
        if sampleTimes.last != end { sampleTimes.append(end) }

        let points = sampleTimes.compactMap { absolute -> TrajectoryStatePoint? in
            let rawValues = model.contextStatistics.map { timedNumericContext($0.key, cycle: cycle, at: absolute) }
            guard rawValues.allSatisfy({ $0 != nil }) else { return nil }
            let raw = rawValues.map { $0! }
            let standardized = zip(raw, model.contextStatistics).map { ($0.0 - $0.1.mean) / max($0.1.standardDeviation, 1e-9) }
            let distances = model.regions.map { euclidean(standardized, $0.standardizedCentroid) }
            guard let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }) else { return nil }
            let region = model.regions[nearest]
            let distance = distances[nearest]
            let accepted = distance <= region.membershipRadius
            return TrajectoryStatePoint(relativeMilliseconds: absolute - cycle.anchorMilliseconds, regionID: accepted ? region.id : nil, regionName: accepted ? region.name : nil, contextDistance: distance, contextValues: raw)
        }
        guard !points.isEmpty else { return ([], []) }

        var segments: [TrajectoryStateSegment] = []
        var currentRegionID: String?
        var currentRegionName: String?
        var currentStart: Int64?
        var previousTime: Int64?

        func closeSegment(end: Int64) {
            guard let id = currentRegionID, let name = currentRegionName, let start = currentStart else { return }
            let duration = max(samplingIntervalMilliseconds, end - start + samplingIntervalMilliseconds)
            segments.append(TrajectoryStateSegment(regionID: id, regionName: name, startRelativeMilliseconds: start, endRelativeMilliseconds: end, durationMilliseconds: duration))
        }

        for point in points {
            if point.regionID == currentRegionID {
                previousTime = point.relativeMilliseconds
                continue
            }
            if let previousTime { closeSegment(end: previousTime) }
            currentRegionID = point.regionID
            currentRegionName = point.regionName
            currentStart = point.regionID == nil ? nil : point.relativeMilliseconds
            previousTime = point.relativeMilliseconds
        }
        if let previousTime { closeSegment(end: previousTime) }
        return (points, segments)
    }

    private static func snapshotCycles(from cycle: KnownGoodCycle, contextKeys: [OperatingContextKey], samplingIntervalMilliseconds: Int64) -> [KnownGoodCycle] {
        let starts = contextKeys.compactMap { key in
            cycle.signalSamples.filter { $0.target == key.target && $0.layer == key.layer }.map(\.milliseconds).min()
        }
        let ends = contextKeys.compactMap { key in
            cycle.signalSamples.filter { $0.target == key.target && $0.layer == key.layer }.map(\.milliseconds).max()
        }
        guard let start = starts.max(), let end = ends.min(), end >= start else { return [] }
        var result: [KnownGoodCycle] = []
        var time = start
        var index = 0
        while time <= end {
            let values = contextKeys.map { timedNumericContext($0, cycle: cycle, at: time) }
            if values.allSatisfy({ $0 != nil }) {
                let samples = zip(contextKeys, values).map { key, value in
                    FlightSignalSample(target: key.target, layer: key.layer, milliseconds: time, value: .real(value!))
                }
                result.append(KnownGoodCycle(name: "\(cycle.name) state sample \(index)", anchorMilliseconds: time, signalSamples: samples))
                index += 1
            }
            time += samplingIntervalMilliseconds
        }
        return result
    }

    private static func timedNumericContext(_ key: OperatingContextKey, cycle: KnownGoodCycle, at milliseconds: Int64) -> Double? {
        let samples = cycle.signalSamples
            .filter { $0.target == key.target && $0.layer == key.layer && $0.milliseconds <= milliseconds }
            .sorted { $0.milliseconds < $1.milliseconds }
        guard let value = samples.last?.value else { return nil }
        switch value {
        case let .bool(v): return v ? 1 : 0
        case let .dint(v): return Double(v)
        case let .real(v): return v
        case let .timer(v): return Double(v.ACC)
        case let .counter(v): return Double(v.ACC)
        }
    }

    private static func envelope(region: ContinuousOperatingRegion, metric: TrajectoryTimingEnvelope.Metric, values: [Double]) -> TrajectoryTimingEnvelope {
        let sorted = values.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let median = percentile(sorted, 0.5)
        let absolute = sorted.map { abs($0 - median) }.sorted()
        let mad = percentile(absolute, 0.5)
        let robustSigma = max(mad * 1.4826, 1.0)
        let lowPercentile = percentile(sorted, 0.05)
        let highPercentile = percentile(sorted, 0.95)
        let lower = min(lowPercentile, median - 2.5 * robustSigma)
        let upper = max(highPercentile, median + 2.5 * robustSigma)
        return TrajectoryTimingEnvelope(regionID: region.id, regionName: region.name, metric: metric, sampleCount: values.count, meanMilliseconds: mean, medianMilliseconds: median, lowerMilliseconds: lower, upperMilliseconds: upper)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let x = max(0, min(1, p)) * Double(sorted.count - 1)
        let lo = Int(floor(x)), hi = Int(ceil(x))
        if lo == hi { return sorted[lo] }
        let fraction = x - Double(lo)
        return sorted[lo] * (1 - fraction) + sorted[hi] * fraction
    }

    private static func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).map { pow($0.0 - $0.1, 2) }.reduce(0, +))
    }

    private static func signed(_ value: Int64) -> String { value >= 0 ? "+\(value)" : "\(value)" }
}

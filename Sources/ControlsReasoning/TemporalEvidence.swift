import Foundation
import ControlsPLC

public enum TemporalPatternKind: String, Codable, Sendable, CaseIterable {
    case stable
    case singleTransition
    case transientPulse
    case chatter
    case intermittent
    case insufficientData

    public var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .singleTransition: return "Single transition"
        case .transientPulse: return "Transient pulse"
        case .chatter: return "Chatter / bounce"
        case .intermittent: return "Intermittent"
        case .insufficientData: return "Insufficient data"
        }
    }
}

public enum TemporalCaptureMode: String, Codable, Sendable, CaseIterable {
    case meter
    case trend
    case edgeTrigger
    case highSpeedTrend
    case scanTrace
    case debounceInspection

    public var displayName: String {
        switch self {
        case .meter: return "Meter"
        case .trend: return "Trend"
        case .edgeTrigger: return "Edge trigger"
        case .highSpeedTrend: return "High-speed trend"
        case .scanTrace: return "Scan trace"
        case .debounceInspection: return "Debounce inspection"
        }
    }
}

public struct TimedEvidenceSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let milliseconds: Int64
    public let value: TagValue
    public let confidence: EvidenceConfidence
    public let condition: MeasurementCondition

    public init(id: UUID = UUID(), milliseconds: Int64, value: TagValue, confidence: EvidenceConfidence = .high, condition: MeasurementCondition = .simulated) {
        self.id = id
        self.milliseconds = milliseconds
        self.value = value
        self.confidence = confidence
        self.condition = condition
    }
}

public struct TemporalObservation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let samples: [TimedEvidenceSample]
    public let source: ObservationSource
    public let note: String?

    public init(id: UUID = UUID(), target: String, samples: [TimedEvidenceSample], source: ObservationSource = .simulator, note: String? = nil) {
        self.id = id
        self.target = target
        self.samples = samples.sorted { $0.milliseconds < $1.milliseconds }
        self.source = source
        self.note = note
    }
}

public struct TemporalEventMarker: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let milliseconds: Int64
    public let note: String?

    public init(id: UUID = UUID(), name: String, milliseconds: Int64, note: String? = nil) {
        self.id = id
        self.name = name
        self.milliseconds = milliseconds
        self.note = note
    }
}

public struct TemporalPattern: Identifiable, Equatable, Sendable {
    public var id: String { target }
    public let target: String
    public let kind: TemporalPatternKind
    public let durationMilliseconds: Int64
    public let transitionCount: Int
    public let shortestStateDurationMilliseconds: Int64?
    public let eventName: String?
    public let eventLagMilliseconds: Int64?
    public let confidence: EvidenceConfidence
    public let explanation: String
}

public struct TemporalCaptureRecommendation: Identifiable, Equatable, Sendable {
    public var id: String { "\(target)#\(mode.rawValue)" }
    public let target: String
    public let mode: TemporalCaptureMode
    public let trigger: String
    public let samplePeriodMilliseconds: Int?
    public let captureWindowMilliseconds: Int
    public let rationale: String
}

public enum TemporalEvidenceAnalyzer {
    public static func analyze(_ observation: TemporalObservation, relativeTo events: [TemporalEventMarker] = []) -> TemporalPattern {
        let samples = observation.samples
        guard samples.count >= 2 else {
            return TemporalPattern(target: observation.target, kind: .insufficientData, durationMilliseconds: 0, transitionCount: 0, shortestStateDurationMilliseconds: nil, eventName: nil, eventLagMilliseconds: nil, confidence: samples.first?.confidence ?? .low, explanation: "At least two time-stamped samples are required to characterize stability or intermittence.")
        }

        var transitions: [(index: Int, time: Int64)] = []
        for i in 1..<samples.count where samples[i].value != samples[i - 1].value {
            transitions.append((i, samples[i].milliseconds))
        }
        let duration = max(0, samples.last!.milliseconds - samples.first!.milliseconds)
        let shortest = shortestStateDuration(samples: samples, transitions: transitions)
        let kind: TemporalPatternKind
        if transitions.isEmpty {
            kind = .stable
        } else if transitions.count == 1 {
            kind = .singleTransition
        } else if returnsToInitial(samples: samples) && transitions.count == 2 {
            kind = .transientPulse
        } else if transitions.count >= 4, let shortest, shortest <= 50 {
            kind = .chatter
        } else {
            kind = .intermittent
        }

        let effectiveConfidence = samples.map(\.confidence).min() ?? .low
        let correlation = nearestEvent(after: transitions.first?.time, events: events)
        let explanation = explanation(target: observation.target, kind: kind, duration: duration, transitions: transitions.count, shortest: shortest, correlation: correlation)
        return TemporalPattern(
            target: observation.target,
            kind: kind,
            durationMilliseconds: duration,
            transitionCount: transitions.count,
            shortestStateDurationMilliseconds: shortest,
            eventName: correlation?.event.name,
            eventLagMilliseconds: correlation?.lag,
            confidence: effectiveConfidence,
            explanation: explanation
        )
    }

    public static func recommendCapture(for pattern: TemporalPattern, scanPeriodMilliseconds: Int = 10) -> TemporalCaptureRecommendation {
        switch pattern.kind {
        case .stable:
            return TemporalCaptureRecommendation(target: pattern.target, mode: .meter, trigger: "Observe while the symptom is present", samplePeriodMilliseconds: nil, captureWindowMilliseconds: 0, rationale: "The recorded signal was stable. A static verification is more useful than a faster trace unless the fault is reported intermittent.")
        case .singleTransition:
            return TemporalCaptureRecommendation(target: pattern.target, mode: .edgeTrigger, trigger: "Trigger on the next transition of \(pattern.target)", samplePeriodMilliseconds: max(1, scanPeriodMilliseconds / 2), captureWindowMilliseconds: max(500, Int(pattern.durationMilliseconds)), rationale: "One transition was observed. Capture pre-trigger and post-trigger context to determine what changed immediately before and after it.")
        case .transientPulse:
            let pulse = Int(pattern.shortestStateDurationMilliseconds ?? Int64(scanPeriodMilliseconds))
            return TemporalCaptureRecommendation(target: pattern.target, mode: pulse <= scanPeriodMilliseconds ? .highSpeedTrend : .edgeTrigger, trigger: "Trigger on either edge of \(pattern.target)", samplePeriodMilliseconds: max(1, min(scanPeriodMilliseconds / 4, max(1, pulse / 8))), captureWindowMilliseconds: max(500, pulse * 6), rationale: "A short pulse returned to its original state. Use triggered capture so a fault that disappears before a technician arrives is preserved with context.")
        case .chatter:
            return TemporalCaptureRecommendation(target: pattern.target, mode: .debounceInspection, trigger: "Trigger on the first edge, then retain every transition", samplePeriodMilliseconds: 1, captureWindowMilliseconds: max(500, Int(pattern.durationMilliseconds)), rationale: "Rapid repeated transitions resemble contact bounce, vibration, a loose connection, or insufficient input filtering. Capture faster than the shortest state interval and compare against debounce/input-filter settings.")
        case .intermittent:
            return TemporalCaptureRecommendation(target: pattern.target, mode: .trend, trigger: "Record continuously and mark the machine fault event", samplePeriodMilliseconds: max(1, scanPeriodMilliseconds), captureWindowMilliseconds: max(2_000, Int(pattern.durationMilliseconds * 2)), rationale: "Multiple non-periodic transitions were observed. A longer trend is more likely to expose correlation with machine state, vibration, or sequence timing.")
        case .insufficientData:
            return TemporalCaptureRecommendation(target: pattern.target, mode: .trend, trigger: "Begin before reproducing the symptom", samplePeriodMilliseconds: max(1, scanPeriodMilliseconds), captureWindowMilliseconds: 2_000, rationale: "There is not enough time-domain evidence yet. Establish a baseline trend before assigning an intermittent-fault theory.")
        }
    }

    public static func timingRaceRecommendation(signalPattern: TemporalPattern, event: TemporalEventMarker, scanPeriodMilliseconds: Int) -> TemporalCaptureRecommendation? {
        guard let lag = signalPattern.eventLagMilliseconds, abs(lag) <= Int64(scanPeriodMilliseconds * 2) else { return nil }
        return TemporalCaptureRecommendation(target: signalPattern.target, mode: .scanTrace, trigger: "Trigger on \(signalPattern.target) edge and correlate with \(event.name)", samplePeriodMilliseconds: max(1, scanPeriodMilliseconds), captureWindowMilliseconds: max(200, scanPeriodMilliseconds * 20), rationale: "The event occurred only \(abs(lag)) ms after the signal transition, within roughly two controller scans. Inspect scan order, task timing, and edge-sensitive logic before blaming the field device alone.")
    }

    private static func returnsToInitial(samples: [TimedEvidenceSample]) -> Bool {
        samples.first?.value == samples.last?.value
    }

    private static func shortestStateDuration(samples: [TimedEvidenceSample], transitions: [(index: Int, time: Int64)]) -> Int64? {
        guard !transitions.isEmpty else { return nil }
        let boundaries = [samples.first!.milliseconds] + transitions.map(\.time) + [samples.last!.milliseconds]
        if boundaries.count < 2 { return nil }
        var durations: [Int64] = []
        for i in 1..<boundaries.count {
            let d = boundaries[i] - boundaries[i - 1]
            if d > 0 { durations.append(d) }
        }
        return durations.min()
    }

    private static func nearestEvent(after transitionTime: Int64?, events: [TemporalEventMarker]) -> (event: TemporalEventMarker, lag: Int64)? {
        guard let transitionTime else { return nil }
        return events
            .map { ($0, $0.milliseconds - transitionTime) }
            .filter { $0.1 >= 0 }
            .min { $0.1 < $1.1 }
    }

    private static func explanation(target: String, kind: TemporalPatternKind, duration: Int64, transitions: Int, shortest: Int64?, correlation: (event: TemporalEventMarker, lag: Int64)?) -> String {
        var text = "\(target) showed \(transitions) transition(s) over \(duration) ms and is classified as \(kind.displayName.lowercased())."
        if let shortest { text += " The shortest observed state lasted \(shortest) ms." }
        if let correlation { text += " \(correlation.event.name) followed the first transition by \(correlation.lag) ms." }
        return text
    }
}

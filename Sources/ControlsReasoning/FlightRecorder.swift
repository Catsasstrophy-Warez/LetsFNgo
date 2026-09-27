import Foundation
import ControlsPLC

public enum FlightSignalLayer: String, Codable, Sendable, CaseIterable {
    case field
    case controllerInput
    case logic
    case structuredMember
    case controllerOutput

    public var displayName: String {
        switch self {
        case .field: return "Field"
        case .controllerInput: return "Controller input"
        case .logic: return "Logic"
        case .structuredMember: return "Structured member"
        case .controllerOutput: return "Controller output"
        }
    }
}

public struct FlightSignalSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let layer: FlightSignalLayer
    public let milliseconds: Int64
    public let value: TagValue
    public let scanNumber: UInt64?
    public let stepIndex: Int?

    public init(id: UUID = UUID(), target: String, layer: FlightSignalLayer, milliseconds: Int64, value: TagValue, scanNumber: UInt64? = nil, stepIndex: Int? = nil) {
        self.id = id
        self.target = target
        self.layer = layer
        self.milliseconds = milliseconds
        self.value = value
        self.scanNumber = scanNumber
        self.stepIndex = stepIndex
    }
}

public struct TaskExecutionStamp: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskName: String
    public let programName: String?
    public let routineName: String?
    public let rungNumber: Int?
    public let milliseconds: Int64
    public let scanNumber: UInt64
    public let stepIndex: Int?

    public init(id: UUID = UUID(), taskName: String, programName: String? = nil, routineName: String? = nil, rungNumber: Int? = nil, milliseconds: Int64, scanNumber: UInt64, stepIndex: Int? = nil) {
        self.id = id
        self.taskName = taskName
        self.programName = programName
        self.routineName = routineName
        self.rungNumber = rungNumber
        self.milliseconds = milliseconds
        self.scanNumber = scanNumber
        self.stepIndex = stepIndex
    }
}

public struct FlightCausalLink: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let upstream: String
    public let downstream: String
    public let rationale: String

    public init(id: UUID = UUID(), upstream: String, downstream: String, rationale: String = "Recorded logic dependency") {
        self.id = id
        self.upstream = upstream
        self.downstream = downstream
        self.rationale = rationale
    }
}


public struct FlightNonCausalAssertion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let first: String
    public let second: String
    public let rationale: String

    public init(id: UUID = UUID(), first: String, second: String, rationale: String) {
        self.id = id
        self.first = first
        self.second = second
        self.rationale = rationale
    }

    public func matches(_ a: String, _ b: String) -> Bool {
        (first == a && second == b) || (first == b && second == a)
    }
}

public enum PLCObservationStatus: String, Codable, Sendable {
    case observed
    case missedBetweenExecutions
    case indeterminate

    public var displayName: String {
        switch self {
        case .observed: return "Observed by PLC"
        case .missedBetweenExecutions: return "Missed between executions"
        case .indeterminate: return "Indeterminate"
        }
    }
}

public struct PulseVisibilityResult: Equatable, Sendable {
    public let target: String
    public let pulseStartMilliseconds: Int64?
    public let pulseEndMilliseconds: Int64?
    public let pulseValue: TagValue?
    public let status: PLCObservationStatus
    public let explanation: String
}

public struct BetweenExecutionsResult: Equatable, Sendable {
    public let target: String
    public let taskName: String
    public let changedBetweenExecutions: Bool?
    public let previousExecutionMilliseconds: Int64?
    public let nextExecutionMilliseconds: Int64?
    public let transitionMilliseconds: Int64?
    public let explanation: String
}

public enum CorrelationRelationshipKind: String, Codable, Sendable {
    case recordedConsequence
    case precedes
    case follows
    case coincidental
    case simultaneous
    case unknown
}

public struct CorrelationRelationship: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fromTarget: String
    public let toTarget: String
    public let lagMilliseconds: Int64?
    public let kind: CorrelationRelationshipKind
    public let confidence: EvidenceConfidence
    public let explanation: String

    public init(id: UUID = UUID(), fromTarget: String, toTarget: String, lagMilliseconds: Int64?, kind: CorrelationRelationshipKind, confidence: EvidenceConfidence, explanation: String) {
        self.id = id
        self.fromTarget = fromTarget
        self.toTarget = toTarget
        self.lagMilliseconds = lagMilliseconds
        self.kind = kind
        self.confidence = confidence
        self.explanation = explanation
    }
}


public enum FlightTimelineKind: String, Codable, Sendable {
    case signalTransition
    case taskExecution
    case eventMarker
}

public struct FlightTimelineEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let milliseconds: Int64
    public let kind: FlightTimelineKind
    public let label: String
    public let detail: String

    public init(id: UUID = UUID(), milliseconds: Int64, kind: FlightTimelineKind, label: String, detail: String) {
        self.id = id
        self.milliseconds = milliseconds
        self.kind = kind
        self.label = label
        self.detail = detail
    }
}


public enum FlightCaptureState: String, Codable, Sendable {
    case idle
    case armed
    case triggered
    case frozen

    public var displayName: String { rawValue.uppercased() }
}

public enum FlightTriggerCondition: Equatable, Sendable {
    case manual(name: String)
    case eventNamed(String)
    case signalEquals(target: String, layer: FlightSignalLayer?, value: TagValue)

    public var displayName: String {
        switch self {
        case let .manual(name): return name
        case let .eventNamed(name): return "Event: \(name)"
        case let .signalEquals(target, layer, value):
            let layerText = layer.map { " [\($0.displayName)]" } ?? ""
            return "\(target)\(layerText) = \(FlightValueFormatter.display(value))"
        }
    }
}

public struct FlightCaptureConfiguration: Equatable, Sendable {
    public var preTriggerMilliseconds: Int64
    public var postTriggerMilliseconds: Int64
    public var trigger: FlightTriggerCondition

    public init(preTriggerMilliseconds: Int64 = 5_000, postTriggerMilliseconds: Int64 = 2_000, trigger: FlightTriggerCondition) {
        self.preTriggerMilliseconds = max(0, preTriggerMilliseconds)
        self.postTriggerMilliseconds = max(0, postTriggerMilliseconds)
        self.trigger = trigger
    }
}

public struct FlightFrozenCapture: Equatable, Sendable {
    public let triggerName: String
    public let triggerMilliseconds: Int64
    public let windowStartMilliseconds: Int64
    public let windowEndMilliseconds: Int64
    public let signalSamples: [FlightSignalSample]
    public let taskExecutions: [TaskExecutionStamp]
    public let events: [TemporalEventMarker]

    public var preTriggerDurationMilliseconds: Int64 { triggerMilliseconds - windowStartMilliseconds }
    public var postTriggerDurationMilliseconds: Int64 { windowEndMilliseconds - triggerMilliseconds }
    public func relativeMilliseconds(for absoluteMilliseconds: Int64) -> Int64 { absoluteMilliseconds - triggerMilliseconds }
}

private enum FlightValueFormatter {
    static func display(_ value: TagValue) -> String {
        switch value {
        case let .bool(v): return v ? "TRUE" : "FALSE"
        case let .dint(v): return String(v)
        case let .real(v): return String(format: "%.3f", v)
        case let .timer(v): return "TIMER ACC=\(v.ACC) PRE=\(v.PRE) DN=\(v.DN)"
        case let .counter(v): return "COUNTER ACC=\(v.ACC) PRE=\(v.PRE) DN=\(v.DN)"
        }
    }
}

public struct FlightRecorderReport: Equatable, Sendable {
    public let firstChangedTarget: String?
    public let firstChangeMilliseconds: Int64?
    public let orderedTransitions: [FlightSignalSample]
    public let relationships: [CorrelationRelationship]
    public let timeline: [FlightTimelineEntry]
    public let summary: String
}

/// A synchronized controls-oriented event recorder. It deliberately keeps field-side samples,
/// controller-observed samples, execution stamps, and event markers distinct. Temporal proximity
/// alone is never promoted to causation; recorded causal links are required for that label.
public struct ControlsFlightRecorder: Sendable {
    public private(set) var signalSamples: [FlightSignalSample] = []
    public private(set) var taskExecutions: [TaskExecutionStamp] = []
    public private(set) var events: [TemporalEventMarker] = []
    public private(set) var causalLinks: [FlightCausalLink] = []
    public private(set) var nonCausalAssertions: [FlightNonCausalAssertion] = []
    public private(set) var captureState: FlightCaptureState = .idle
    public private(set) var captureConfiguration: FlightCaptureConfiguration?
    public private(set) var triggerMilliseconds: Int64?
    public private(set) var frozenCapture: FlightFrozenCapture?
    public var maximumSamples: Int

    public init(maximumSamples: Int = 10_000) {
        self.maximumSamples = max(500, maximumSamples)
    }

    public mutating func clear() {
        signalSamples.removeAll(keepingCapacity: true)
        taskExecutions.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        causalLinks.removeAll(keepingCapacity: true)
        nonCausalAssertions.removeAll(keepingCapacity: true)
        captureState = .idle
        captureConfiguration = nil
        triggerMilliseconds = nil
        frozenCapture = nil
    }

    public mutating func arm(_ configuration: FlightCaptureConfiguration) {
        signalSamples.removeAll(keepingCapacity: true)
        taskExecutions.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        captureConfiguration = configuration
        triggerMilliseconds = nil
        frozenCapture = nil
        captureState = .armed
    }

    public mutating func rearm() {
        guard let configuration = captureConfiguration else { return }
        arm(configuration)
    }

    public mutating func triggerNow(name: String = "Manual trigger", milliseconds: Int64) {
        guard captureState == .armed else { return }
        activateTrigger(name: name, milliseconds: milliseconds)
        finalizeIfReady(latestMilliseconds: milliseconds)
    }

    public mutating func record(_ sample: FlightSignalSample) {
        guard captureState != .frozen else { return }
        signalSamples.append(sample)
        signalSamples.sort { lhs, rhs in
            if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
            return (lhs.stepIndex ?? -1) < (rhs.stepIndex ?? -1)
        }
        evaluateTrigger(for: sample)
        maintainRollingWindow(latestMilliseconds: sample.milliseconds)
        finalizeIfReady(latestMilliseconds: sample.milliseconds)
        trim()
    }

    public mutating func record(samples: [FlightSignalSample]) {
        for sample in samples.sorted(by: { $0.milliseconds < $1.milliseconds }) { record(sample) }
    }

    public mutating func record(taskExecution: TaskExecutionStamp) {
        guard captureState != .frozen else { return }
        taskExecutions.append(taskExecution)
        taskExecutions.sort { $0.milliseconds < $1.milliseconds }
        maintainRollingWindow(latestMilliseconds: taskExecution.milliseconds)
        finalizeIfReady(latestMilliseconds: taskExecution.milliseconds)
    }

    public mutating func record(event: TemporalEventMarker) {
        guard captureState != .frozen else { return }
        events.append(event)
        events.sort { $0.milliseconds < $1.milliseconds }
        if case let .eventNamed(name) = captureConfiguration?.trigger, captureState == .armed, name == event.name {
            activateTrigger(name: event.name, milliseconds: event.milliseconds)
        }
        maintainRollingWindow(latestMilliseconds: event.milliseconds)
        finalizeIfReady(latestMilliseconds: event.milliseconds)
    }

    public mutating func addCausalLink(_ link: FlightCausalLink) {
        if !causalLinks.contains(where: { $0.upstream == link.upstream && $0.downstream == link.downstream }) {
            causalLinks.append(link)
        }
    }

    public mutating func markCoincidental(_ assertion: FlightNonCausalAssertion) {
        if !nonCausalAssertions.contains(where: { $0.matches(assertion.first, assertion.second) }) {
            nonCausalAssertions.append(assertion)
        }
    }

    public func consequenceChain(startingAt target: String) -> [String] {
        var chain = [target]
        var current = target
        var visited: Set<String> = [target]
        while let next = causalLinks.first(where: { $0.upstream == current && !visited.contains($0.downstream) })?.downstream {
            chain.append(next)
            visited.insert(next)
            current = next
        }
        return chain
    }

    public func samples(for target: String, layer: FlightSignalLayer? = nil) -> [FlightSignalSample] {
        signalSamples.filter { $0.target == target && (layer == nil || $0.layer == layer!) }
    }

    public func transitions(for target: String, layer: FlightSignalLayer? = nil) -> [FlightSignalSample] {
        let source = samples(for: target, layer: layer)
        guard source.count > 1 else { return [] }
        var result: [FlightSignalSample] = []
        for index in 1..<source.count where source[index].value != source[index - 1].value {
            result.append(source[index])
        }
        return result
    }

    public func report(targets: [String]? = nil) -> FlightRecorderReport {
        let selected = targets.map(Set.init)
        let groupedChannels = Set(signalSamples.map { "\($0.target)#\($0.layer.rawValue)" })
        let ordered = groupedChannels.flatMap { key -> [FlightSignalSample] in
            let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
            guard parts.count == 2, let layer = FlightSignalLayer(rawValue: parts[1]) else { return [] }
            let target = parts[0]
            guard selected == nil || selected!.contains(target) else { return [] }
            return transitions(for: target, layer: layer)
        }.sorted { lhs, rhs in
            if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
            return lhs.target < rhs.target
        }
        let first = ordered.first
        var relationships: [CorrelationRelationship] = []

        for i in ordered.indices {
            for j in ordered.indices where j > i {
                let a = ordered[i]
                let b = ordered[j]
                guard a.target != b.target else { continue }
                let lag = b.milliseconds - a.milliseconds
                let recordedLink = causalLinks.contains { $0.upstream == a.target && $0.downstream == b.target }
                let reverseLink = causalLinks.contains { $0.upstream == b.target && $0.downstream == a.target }
                let nonCausal = nonCausalAssertions.first { $0.matches(a.target, b.target) }
                let kind: CorrelationRelationshipKind
                let confidence: EvidenceConfidence
                let explanation: String
                if let nonCausal {
                    kind = .coincidental
                    confidence = .verified
                    explanation = "The transitions occurred \(lag) ms apart, but this relationship was explicitly ruled non-causal: \(nonCausal.rationale)"
                } else if recordedLink {
                    kind = .recordedConsequence
                    confidence = .verified
                    explanation = "\(a.target) changed \(lag) ms before \(b.target), and the recorder has a declared/recorded causal dependency from \(a.target) to \(b.target)."
                } else if reverseLink {
                    kind = .follows
                    confidence = .high
                    explanation = "\(a.target) changed before its recorded upstream dependency \(b.target). The timing does not support \(b.target) causing this particular transition."
                } else if lag == 0 {
                    kind = .simultaneous
                    confidence = .medium
                    explanation = "The two transitions share a timestamp. Ordering within the available time resolution is unknown."
                } else {
                    kind = .precedes
                    confidence = .medium
                    explanation = "\(a.target) changed \(lag) ms before \(b.target), but no causal dependency is recorded. Treat this as temporal precedence, not proof of cause."
                }
                relationships.append(CorrelationRelationship(fromTarget: a.target, toTarget: b.target, lagMilliseconds: lag, kind: kind, confidence: confidence, explanation: explanation))
            }
        }

        var timeline: [FlightTimelineEntry] = ordered.map { transition in
            FlightTimelineEntry(milliseconds: transition.milliseconds, kind: .signalTransition, label: transition.target, detail: "\(transition.layer.displayName): \(displayValue(transition.value))")
        }
        timeline += taskExecutions.map { execution in
            let location = [execution.programName, execution.routineName, execution.rungNumber.map { "Rung \($0)" }].compactMap { $0 }.joined(separator: " / ")
            return FlightTimelineEntry(milliseconds: execution.milliseconds, kind: .taskExecution, label: execution.taskName, detail: location.isEmpty ? "Task execution" : location)
        }
        timeline += events.map { event in
            FlightTimelineEntry(milliseconds: event.milliseconds, kind: .eventMarker, label: event.name, detail: event.note ?? "Event marker")
        }
        timeline.sort { lhs, rhs in
            if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
            let rank: [FlightTimelineKind: Int] = [.taskExecution: 0, .signalTransition: 1, .eventMarker: 2]
            return (rank[lhs.kind] ?? 9) < (rank[rhs.kind] ?? 9)
        }

        let summary: String
        if let first {
            summary = "First recorded transition: \(first.target) at \(first.milliseconds) ms. Temporal order is separated from causal claims; only explicit recorded dependencies are labeled consequences."
        } else {
            summary = "No transitions are present in the selected capture window."
        }
        return FlightRecorderReport(firstChangedTarget: first?.target, firstChangeMilliseconds: first?.milliseconds, orderedTransitions: ordered, relationships: relationships, timeline: timeline, summary: summary)
    }

    /// Determines whether a field-side Boolean pulse was represented in the controller-input
    /// channel. A pulse entirely between controller executions/samples is classified as missed;
    /// absent paired evidence remains indeterminate rather than guessed.
    public func plcVisibility(ofFieldPulse target: String) -> PulseVisibilityResult {
        let field = samples(for: target, layer: .field)
        let controller = samples(for: target, layer: .controllerInput)
        guard field.count >= 3 else {
            return PulseVisibilityResult(target: target, pulseStartMilliseconds: nil, pulseEndMilliseconds: nil, pulseValue: nil, status: .indeterminate, explanation: "At least three field samples are required to prove a pulse that leaves and returns to its original state.")
        }
        guard let pulse = firstPulse(in: field) else {
            return PulseVisibilityResult(target: target, pulseStartMilliseconds: nil, pulseEndMilliseconds: nil, pulseValue: nil, status: .indeterminate, explanation: "No complete field-side pulse was found in the capture window.")
        }
        guard !controller.isEmpty else {
            return PulseVisibilityResult(target: target, pulseStartMilliseconds: pulse.start, pulseEndMilliseconds: pulse.end, pulseValue: pulse.value, status: .indeterminate, explanation: "A field pulse was recorded, but no controller-input samples exist to prove whether the PLC observed it.")
        }

        let controllerInsidePulse = controller.filter { $0.milliseconds >= pulse.start && $0.milliseconds <= pulse.end }
        if controllerInsidePulse.contains(where: { $0.value == pulse.value }) {
            return PulseVisibilityResult(target: target, pulseStartMilliseconds: pulse.start, pulseEndMilliseconds: pulse.end, pulseValue: pulse.value, status: .observed, explanation: "The controller-input channel recorded the pulse state during the field pulse window.")
        }

        let before = controller.last { $0.milliseconds <= pulse.start }
        let after = controller.first { $0.milliseconds >= pulse.end }
        if let before, let after, before.value == field.first?.value, after.value == field.first?.value {
            return PulseVisibilityResult(target: target, pulseStartMilliseconds: pulse.start, pulseEndMilliseconds: pulse.end, pulseValue: pulse.value, status: .missedBetweenExecutions, explanation: "The field changed and returned between controller observations. The PLC channel never recorded the pulse state, so this capture supports a missed-between-executions explanation.")
        }

        return PulseVisibilityResult(target: target, pulseStartMilliseconds: pulse.start, pulseEndMilliseconds: pulse.end, pulseValue: pulse.value, status: .indeterminate, explanation: "The paired field/controller capture is incomplete around the pulse boundary, so PLC visibility cannot be proven.")
    }

    public func changedBetweenTaskExecutions(target: String, taskName: String, layer: FlightSignalLayer = .field) -> BetweenExecutionsResult {
        guard let transition = transitions(for: target, layer: layer).first else {
            return BetweenExecutionsResult(target: target, taskName: taskName, changedBetweenExecutions: false, previousExecutionMilliseconds: nil, nextExecutionMilliseconds: nil, transitionMilliseconds: nil, explanation: "No transition was recorded for \(target) on the selected layer.")
        }
        let executions = taskExecutions.filter { $0.taskName == taskName }.sorted { $0.milliseconds < $1.milliseconds }
        guard let previous = executions.last(where: { $0.milliseconds < transition.milliseconds }),
              let next = executions.first(where: { $0.milliseconds > transition.milliseconds }) else {
            return BetweenExecutionsResult(target: target, taskName: taskName, changedBetweenExecutions: nil, previousExecutionMilliseconds: executions.last(where: { $0.milliseconds < transition.milliseconds })?.milliseconds, nextExecutionMilliseconds: executions.first(where: { $0.milliseconds > transition.milliseconds })?.milliseconds, transitionMilliseconds: transition.milliseconds, explanation: "A transition was recorded, but the capture does not bracket it with two executions of \(taskName).")
        }
        return BetweenExecutionsResult(target: target, taskName: taskName, changedBetweenExecutions: true, previousExecutionMilliseconds: previous.milliseconds, nextExecutionMilliseconds: next.milliseconds, transitionMilliseconds: transition.milliseconds, explanation: "\(target) changed at \(transition.milliseconds) ms between \(taskName) executions at \(previous.milliseconds) ms and \(next.milliseconds) ms.")
    }

    public func relationship(from upstream: String, to downstream: String) -> CorrelationRelationship? {
        let a = transitions(for: upstream).first
        let b = transitions(for: downstream).first
        guard let a, let b else { return nil }
        let lag = b.milliseconds - a.milliseconds
        if let nonCausal = nonCausalAssertions.first(where: { $0.matches(upstream, downstream) }) {
            return CorrelationRelationship(fromTarget: upstream, toTarget: downstream, lagMilliseconds: lag, kind: .coincidental, confidence: .verified, explanation: "These transitions are close in time, but their relationship was explicitly ruled non-causal: \(nonCausal.rationale)")
        }
        if causalLinks.contains(where: { $0.upstream == upstream && $0.downstream == downstream }) {
            if lag >= 0 {
                return CorrelationRelationship(fromTarget: upstream, toTarget: downstream, lagMilliseconds: lag, kind: .recordedConsequence, confidence: .verified, explanation: "Recorded dependency and temporal order agree: \(downstream) changed \(lag) ms after \(upstream).")
            }
            return CorrelationRelationship(fromTarget: upstream, toTarget: downstream, lagMilliseconds: lag, kind: .unknown, confidence: .high, explanation: "A causal dependency exists, but the captured downstream transition precedes the upstream transition. Re-check scan ordering, timestamps, or whether these are the matching events.")
        }
        return CorrelationRelationship(fromTarget: upstream, toTarget: downstream, lagMilliseconds: lag, kind: lag == 0 ? .simultaneous : (lag > 0 ? .precedes : .follows), confidence: .medium, explanation: "The capture establishes timing only. No recorded dependency supports a causal conclusion between these two signals.")
    }

    private func firstPulse(in samples: [FlightSignalSample]) -> (start: Int64, end: Int64, value: TagValue)? {
        let initial = samples[0].value
        var start: Int64?
        var pulseValue: TagValue?
        for index in 1..<samples.count {
            let value = samples[index].value
            if start == nil, value != initial {
                start = samples[index].milliseconds
                pulseValue = value
            } else if let start, value == initial {
                return (start, samples[index].milliseconds, pulseValue!)
            }
        }
        return nil
    }

    private func displayValue(_ value: TagValue) -> String { FlightValueFormatter.display(value) }

    private mutating func evaluateTrigger(for sample: FlightSignalSample) {
        guard captureState == .armed, let trigger = captureConfiguration?.trigger else { return }
        if case let .signalEquals(target, layer, value) = trigger,
           sample.target == target, (layer == nil || layer == sample.layer), sample.value == value {
            activateTrigger(name: trigger.displayName, milliseconds: sample.milliseconds)
        }
    }

    private mutating func activateTrigger(name: String, milliseconds: Int64) {
        guard captureState == .armed else { return }
        triggerMilliseconds = milliseconds
        captureState = .triggered
        // Preserve a trigger marker even for signal/manual triggers so the frozen timeline has a visible zero point.
        if !events.contains(where: { $0.name == name && $0.milliseconds == milliseconds }) {
            events.append(TemporalEventMarker(name: name, milliseconds: milliseconds, note: "Flight-recorder trigger"))
            events.sort { $0.milliseconds < $1.milliseconds }
        }
    }

    private mutating func maintainRollingWindow(latestMilliseconds: Int64) {
        guard captureState == .armed, let configuration = captureConfiguration else { return }
        let cutoff = latestMilliseconds - configuration.preTriggerMilliseconds
        signalSamples.removeAll { $0.milliseconds < cutoff }
        taskExecutions.removeAll { $0.milliseconds < cutoff }
        events.removeAll { $0.milliseconds < cutoff }
    }

    private mutating func finalizeIfReady(latestMilliseconds: Int64) {
        guard captureState == .triggered, let configuration = captureConfiguration, let triggerMilliseconds else { return }
        let end = triggerMilliseconds + configuration.postTriggerMilliseconds
        guard latestMilliseconds >= end else { return }
        let start = triggerMilliseconds - configuration.preTriggerMilliseconds
        let boundedSignals = signalSamples.filter { $0.milliseconds >= start && $0.milliseconds <= end }
        let boundedExecutions = taskExecutions.filter { $0.milliseconds >= start && $0.milliseconds <= end }
        let boundedEvents = events.filter { $0.milliseconds >= start && $0.milliseconds <= end }
        frozenCapture = FlightFrozenCapture(
            triggerName: configuration.trigger.displayName,
            triggerMilliseconds: triggerMilliseconds,
            windowStartMilliseconds: start,
            windowEndMilliseconds: end,
            signalSamples: boundedSignals,
            taskExecutions: boundedExecutions,
            events: boundedEvents
        )
        signalSamples = boundedSignals
        taskExecutions = boundedExecutions
        events = boundedEvents
        captureState = .frozen
    }

    private mutating func trim() {
        if signalSamples.count > maximumSamples {
            signalSamples.removeFirst(signalSamples.count - maximumSamples)
        }
    }
}

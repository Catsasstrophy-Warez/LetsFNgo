import Foundation
import ControlsPLC

public enum CommunicationTransportKind: String, Codable, CaseIterable, Sendable {
    case etherNetIPIO
    case producedConsumed
    case cipDataTableRead
    case cipDataTableWrite
    case hmiPolling

    public var displayName: String {
        switch self {
        case .etherNetIPIO: "EtherNet/IP I/O Connection"
        case .producedConsumed: "Produced / Consumed Tags"
        case .cipDataTableRead: "MSG CIP Data Table Read"
        case .cipDataTableWrite: "MSG CIP Data Table Write"
        case .hmiPolling: "HMI / SCADA Tag Polling"
        }
    }
}

public enum CommunicationQuality: String, Codable, Sendable {
    case good
    case stale
    case disconnected
    case error
}

public struct CommunicationSample: Codable, Equatable, Sendable {
    public var timeMilliseconds: Int64
    public var tagName: String
    public var value: Double
    public var quality: CommunicationQuality

    public init(timeMilliseconds: Int64, tagName: String, value: Double, quality: CommunicationQuality = .good) {
        self.timeMilliseconds = timeMilliseconds
        self.tagName = tagName
        self.value = value
        self.quality = quality
    }
}

public struct CommunicationLinkConfiguration: Codable, Equatable, Sendable {
    public var kind: CommunicationTransportKind
    public var updatePeriodMilliseconds: Int32
    public var messageLatencyMilliseconds: Int32
    public var enabled: Bool

    public init(kind: CommunicationTransportKind, updatePeriodMilliseconds: Int32 = 100, messageLatencyMilliseconds: Int32 = 40, enabled: Bool = true) {
        self.kind = kind
        self.updatePeriodMilliseconds = max(1, updatePeriodMilliseconds)
        self.messageLatencyMilliseconds = max(1, messageLatencyMilliseconds)
        self.enabled = enabled
    }
}

public struct CommunicationMessageState: Codable, Equatable, Sendable {
    public var enable: Bool = false
    public var waiting: Bool = false
    public var done: Bool = false
    public var error: Bool = false
    public var sourceTag: String = ""
    public var destinationTag: String = ""
    public var requestedAtMilliseconds: Int64?

    public init() {}
}

/// Deterministic teaching simulator for the timing differences between cyclic I/O,
/// produced/consumed tags, explicit MSG transfers, and HMI polling.
/// It deliberately models timing and freshness rather than wire-level EtherNet/IP packets.
public struct IndustrialCommunicationRuntime: Sendable {
    public var configuration: CommunicationLinkConfiguration
    public private(set) var elapsedMilliseconds: Int64 = 0
    public private(set) var localTags: [String: Double] = [:]
    public private(set) var remoteTags: [String: Double] = [:]
    public private(set) var transferHistory: [CommunicationSample] = []
    public private(set) var message = CommunicationMessageState()
    private var nextCyclicUpdateMilliseconds: Int64 = 0

    public init(configuration: CommunicationLinkConfiguration, localTags: [String: Double] = [:], remoteTags: [String: Double] = [:]) {
        self.configuration = configuration
        self.localTags = localTags
        self.remoteTags = remoteTags
        self.nextCyclicUpdateMilliseconds = Int64(configuration.updatePeriodMilliseconds)
    }

    public mutating func setLocal(_ tag: String, value: Double) { localTags[tag] = value }
    public mutating func setRemote(_ tag: String, value: Double) { remoteTags[tag] = value }

    public mutating func triggerMessage(sourceTag: String, destinationTag: String) {
        guard configuration.kind == .cipDataTableRead || configuration.kind == .cipDataTableWrite else { return }
        guard !message.enable && !message.waiting else { return }
        message.enable = true
        message.waiting = true
        message.done = false
        message.error = false
        message.sourceTag = sourceTag
        message.destinationTag = destinationTag
        message.requestedAtMilliseconds = elapsedMilliseconds
    }

    public mutating func resetMessageEnable() {
        message.enable = false
        if !message.waiting { message.done = false; message.error = false }
    }

    public mutating func step(milliseconds: Int32) {
        guard milliseconds > 0 else { return }
        let target = elapsedMilliseconds + Int64(milliseconds)
        while elapsedMilliseconds < target {
            elapsedMilliseconds += 1
            processCyclicTransferIfNeeded()
            processMessageIfNeeded()
        }
    }

    private mutating func processCyclicTransferIfNeeded() {
        guard configuration.enabled else { return }
        switch configuration.kind {
        case .etherNetIPIO, .producedConsumed, .hmiPolling:
            guard elapsedMilliseconds >= nextCyclicUpdateMilliseconds else { return }
            nextCyclicUpdateMilliseconds += Int64(configuration.updatePeriodMilliseconds)
            for (tag, value) in remoteTags.sorted(by: { $0.key < $1.key }) {
                localTags[tag] = value
                transferHistory.append(.init(timeMilliseconds: elapsedMilliseconds, tagName: tag, value: value))
            }
        case .cipDataTableRead, .cipDataTableWrite:
            break
        }
    }

    private mutating func processMessageIfNeeded() {
        guard configuration.enabled, message.waiting, let started = message.requestedAtMilliseconds else { return }
        guard elapsedMilliseconds - started >= Int64(configuration.messageLatencyMilliseconds) else { return }

        switch configuration.kind {
        case .cipDataTableRead:
            guard let value = remoteTags[message.sourceTag] else { finishMessage(error: true); return }
            localTags[message.destinationTag] = value
            transferHistory.append(.init(timeMilliseconds: elapsedMilliseconds, tagName: message.destinationTag, value: value))
            finishMessage(error: false)
        case .cipDataTableWrite:
            guard let value = localTags[message.sourceTag] else { finishMessage(error: true); return }
            remoteTags[message.destinationTag] = value
            transferHistory.append(.init(timeMilliseconds: elapsedMilliseconds, tagName: message.destinationTag, value: value))
            finishMessage(error: false)
        default:
            break
        }
    }

    private mutating func finishMessage(error: Bool) {
        message.waiting = false
        message.done = !error
        message.error = error
    }
}

public struct HistorianPointConfiguration: Codable, Equatable, Sendable {
    public var sourceTag: String
    public var pointName: String
    public var scanPeriodMilliseconds: Int32
    public var engineeringUnits: String

    public init(sourceTag: String, pointName: String? = nil, scanPeriodMilliseconds: Int32 = 1_000, engineeringUnits: String = "") {
        self.sourceTag = sourceTag
        self.pointName = pointName ?? sourceTag
        self.scanPeriodMilliseconds = max(1, scanPeriodMilliseconds)
        self.engineeringUnits = engineeringUnits
    }
}

public struct HistorianStoredSample: Codable, Equatable, Sendable {
    public var timeMilliseconds: Int64
    public var pointName: String
    public var value: Double
    public var quality: CommunicationQuality

    public init(timeMilliseconds: Int64, pointName: String, value: Double, quality: CommunicationQuality) {
        self.timeMilliseconds = timeMilliseconds
        self.pointName = pointName
        self.value = value
        self.quality = quality
    }
}

/// A small scan-class historian teaching model. It demonstrates point configuration,
/// sample interval, timestamp/quality, trend queries, and the consequence of choosing
/// a scan period too slow for the event being studied.
public struct HistorianLabRuntime: Sendable {
    public private(set) var elapsedMilliseconds: Int64 = 0
    public private(set) var points: [HistorianPointConfiguration]
    public private(set) var samples: [HistorianStoredSample] = []
    private var nextScan: [String: Int64] = [:]

    public init(points: [HistorianPointConfiguration]) {
        self.points = points
        self.nextScan = Dictionary(uniqueKeysWithValues: points.map { ($0.pointName, Int64($0.scanPeriodMilliseconds)) })
    }

    public mutating func step(milliseconds: Int32, sourceValues: [String: Double], qualities: [String: CommunicationQuality] = [:]) {
        guard milliseconds > 0 else { return }
        let target = elapsedMilliseconds + Int64(milliseconds)
        while elapsedMilliseconds < target {
            elapsedMilliseconds += 1
            for point in points {
                guard elapsedMilliseconds >= (nextScan[point.pointName] ?? 0) else { continue }
                nextScan[point.pointName, default: elapsedMilliseconds] += Int64(point.scanPeriodMilliseconds)
                guard let value = sourceValues[point.sourceTag] else {
                    samples.append(.init(timeMilliseconds: elapsedMilliseconds, pointName: point.pointName, value: .nan, quality: .error))
                    continue
                }
                samples.append(.init(timeMilliseconds: elapsedMilliseconds, pointName: point.pointName, value: value, quality: qualities[point.sourceTag] ?? .good))
            }
        }
    }

    public func samples(pointName: String, from start: Int64 = 0, through end: Int64 = .max) -> [HistorianStoredSample] {
        samples.filter { $0.pointName == pointName && $0.timeMilliseconds >= start && $0.timeMilliseconds <= end }
    }

    public func latest(pointName: String) -> HistorianStoredSample? {
        samples.last { $0.pointName == pointName }
    }
}

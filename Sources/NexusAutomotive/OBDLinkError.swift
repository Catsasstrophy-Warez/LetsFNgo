import Foundation
import NexusCore

/// What can go wrong between the app, an adapter and a vehicle.
public enum OBDLinkError: Error, Equatable, Sendable {
    /// The link isn't open, or closed while waiting.
    case notConnected
    /// The Bluetooth or network link failed.
    case transport(String)
    /// The adapter didn't finish a reply (no `>` prompt) in time, after retries.
    case timeout(command: String)
    /// The vehicle didn't answer this request ("NO DATA").
    case noData(command: String)
    /// No ECU answered the first request: the ignition is off, the adapter
    /// isn't plugged in, or the protocol search failed.
    case noVehicleResponse(String)
    /// The adapter answered `?`: it doesn't know the command.
    case unsupportedCommand(String)
    /// A bus or adapter error that persisted through retries ("CAN ERROR").
    case bus(String)
    /// A reply the parser couldn't read.
    case malformed(String)
    /// The ECU refused the request (`7F service code`), e.g. 0x22 "conditions
    /// not correct" when clearing codes with the engine running.
    case negativeResponse(service: UInt8, code: UInt8)
    /// Clearing codes needs a person's fresh, explicit confirmation for this vehicle.
    case confirmationRequired(String)
    /// The VIN the car reported isn't the vehicle the drive was started for.
    case vinMismatch(expected: String, found: String)
    /// The car didn't report a VIN and no vehicle was chosen.
    case vinUnavailable
}

extension OBDLinkError {
    /// Worth sending the same command again after a short pause.
    var isRetryable: Bool {
        switch self {
        case .timeout, .bus: true
        default: false
        }
    }

    /// Plain words for an ECU negative response code (ISO 14229 / 15031-5).
    public static func describe(negativeResponse code: UInt8) -> String {
        switch code {
        case 0x10: "general reject"
        case 0x11: "service not supported"
        case 0x12: "sub-function not supported"
        case 0x21: "busy, repeat request"
        case 0x22: "conditions not correct"
        case 0x31: "request out of range"
        case 0x78: "response pending"
        default: "code \(ELM327.hex(code))"
        }
    }
}

extension OBDLinkError: ClassifiableError {
    public var classified: ClassifiedError {
        let kept = ["Readings already stored are kept."]
        switch self {
        case .notConnected, .transport:
            return ClassifiedError(
                category: .dataSource, whatHappened: "The adapter isn't connected.", whatSurvived: kept,
                nextActions: [NextAction("Check the adapter is powered and in range"), NextAction("Connect again")]
            )
        case .timeout(let command):
            return ClassifiedError(
                category: .dataSource, whatHappened: "The adapter stopped answering (\(command)).", whatSurvived: kept,
                nextActions: [NextAction("Move closer or reconnect the adapter"), NextAction("Unplug the adapter for a few seconds")]
            )
        case .noData(let command):
            return ClassifiedError(
                category: .dataSource, whatHappened: "The vehicle didn't answer \(command).", whatSurvived: kept,
                nextActions: [NextAction("Turn the ignition on"), NextAction("Choose other readings")]
            )
        case .noVehicleResponse:
            return ClassifiedError(
                category: .dataSource, whatHappened: "The adapter is connected, but no control module answered. The ignition may be off.",
                whatSurvived: kept, nextActions: [NextAction("Turn the ignition on or start the engine"), NextAction("Try again")]
            )
        case .unsupportedCommand(let command):
            return ClassifiedError(
                category: .dataSource, whatHappened: "The adapter doesn't support \(command).", whatSurvived: kept,
                nextActions: [NextAction("Use a genuine ELM327 v1.5 or later adapter")]
            )
        case .bus(let detail):
            return ClassifiedError(
                category: .dataSource, whatHappened: "The vehicle bus reported \(detail).", whatSurvived: kept,
                nextActions: [NextAction("Check the adapter is fully seated"), NextAction("Try again with the ignition on")]
            )
        case .malformed:
            return ClassifiedError(
                category: .dataSource, whatHappened: "The adapter sent a reply that couldn't be read.", whatSurvived: kept,
                nextActions: [NextAction("Try again")]
            )
        case .negativeResponse(let service, let code):
            return ClassifiedError(
                category: .dataSource,
                whatHappened: "The vehicle refused mode \(ELM327.hex(service)): \(Self.describe(negativeResponse: code)).",
                whatSurvived: ["Nothing on the vehicle was changed."] + kept,
                nextActions: [NextAction(service == 0x04 ? "Turn the engine off, leave the ignition on, and try again" : "Try again")]
            )
        case .confirmationRequired(let reason):
            return ClassifiedError(
                category: .agentTool, whatHappened: "Clearing trouble codes needs your confirmation: \(reason).",
                whatSurvived: ["The codes on the vehicle were not cleared."], nextActions: [NextAction("Confirm clearing the codes")]
            )
        case .vinMismatch(let expected, let found):
            return ClassifiedError(
                category: .evidenceVerification, whatHappened: "The connected car reports VIN \(found), not \(expected).",
                whatSurvived: ["Nothing was stored against the wrong vehicle."], nextActions: [NextAction("Open the matching vehicle")]
            )
        case .vinUnavailable:
            return ClassifiedError(
                category: .dataSource, whatHappened: "The car didn't report its VIN, so it can't be matched to a vehicle.",
                whatSurvived: kept, nextActions: [NextAction("Connect from the vehicle's page")]
            )
        }
    }
}

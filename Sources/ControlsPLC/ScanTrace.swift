import Foundation

public struct TagChange: Codable, Equatable, Sendable {
    public let tag: String
    public let oldValue: TagValue
    public let newValue: TagValue

    public init(tag: String, oldValue: TagValue, newValue: TagValue) {
        self.tag = tag; self.oldValue = oldValue; self.newValue = newValue
    }
}

/// A value captured at instruction execution time. These observations make later
/// "Why is this true/false?" explanations deterministic instead of reconstructing
/// causes from a data table that may already have changed later in the scan.
public struct TraceObservation: Codable, Equatable, Sendable {
    public let label: String
    public let value: TagValue

    public init(label: String, value: TagValue) {
        self.label = label
        self.value = value
    }
}

public struct InstructionTrace: Codable, Equatable, Sendable {
    public let mnemonic: String
    public let reference: String
    public let incomingCondition: Bool
    public let outgoingCondition: Bool
    public let changes: [TagChange]
    public let nodePath: String?
    public let observations: [TraceObservation]
    public let readTags: [String]
    public let writeTags: [String]

    public init(
        mnemonic: String,
        reference: String,
        incomingCondition: Bool,
        outgoingCondition: Bool,
        changes: [TagChange],
        nodePath: String? = nil,
        observations: [TraceObservation] = [],
        readTags: [String] = [],
        writeTags: [String] = []
    ) {
        self.mnemonic = mnemonic
        self.reference = reference
        self.incomingCondition = incomingCondition
        self.outgoingCondition = outgoingCondition
        self.changes = changes
        self.nodePath = nodePath
        self.observations = observations
        self.readTags = readTags
        self.writeTags = writeTags
    }
}

public enum PowerNodeKind: String, Codable, Sendable {
    case instruction
    case series
    case parallel
}

/// Flat, path-addressed AST power record. Paths remain stable for the lifetime of a
/// rung topology (root.s0, root.s1.p0, ...), so duplicate instructions are still
/// individually addressable by the visual debugger and reasoning tutor.
public struct PowerNodeTrace: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: PowerNodeKind
    public let incomingCondition: Bool
    public let outgoingCondition: Bool
    public let branchIndex: Int?

    public init(path: String, kind: PowerNodeKind, incomingCondition: Bool, outgoingCondition: Bool, branchIndex: Int? = nil) {
        self.path = path
        self.kind = kind
        self.incomingCondition = incomingCondition
        self.outgoingCondition = outgoingCondition
        self.branchIndex = branchIndex
    }
}

public struct RungTrace: Codable, Equatable, Sendable {
    public let rungNumber: Int
    public let incomingCondition: Bool
    public let outgoingCondition: Bool
    public let instructions: [InstructionTrace]
    public let powerNodes: [PowerNodeTrace]

    public init(
        rungNumber: Int,
        incomingCondition: Bool,
        outgoingCondition: Bool,
        instructions: [InstructionTrace],
        powerNodes: [PowerNodeTrace] = []
    ) {
        self.rungNumber = rungNumber
        self.incomingCondition = incomingCondition
        self.outgoingCondition = outgoingCondition
        self.instructions = instructions
        self.powerNodes = powerNodes
    }

    public func power(at path: String) -> PowerNodeTrace? {
        powerNodes.first { $0.path == path }
    }

    public func instruction(at path: String) -> InstructionTrace? {
        instructions.first { $0.nodePath == path }
    }
}

public struct ScanTrace: Codable, Equatable, Sendable {
    public let scanNumber: UInt64
    public let startedAt: Date
    public let elapsedMilliseconds: Int32
    public let rungs: [RungTrace]
}

public struct ScanSession: Equatable, Sendable {
    public let scanNumber: UInt64
    public let startedAt: Date
    public let elapsedMilliseconds: Int32
    public let routine: LadderRoutine
    public private(set) var nextRungIndex: Int
    public private(set) var rungTraces: [RungTrace]

    public var isComplete: Bool { nextRungIndex >= routine.rungs.count }
    public var nextRungNumber: Int? { isComplete ? nil : routine.rungs[nextRungIndex].number }

    init(scanNumber: UInt64, startedAt: Date, elapsedMilliseconds: Int32, routine: LadderRoutine) {
        self.scanNumber = scanNumber
        self.startedAt = startedAt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.routine = LadderRoutine(id: routine.id, name: routine.name, rungs: routine.rungs.sorted { $0.number < $1.number })
        self.nextRungIndex = 0
        self.rungTraces = []
    }

    mutating func append(_ trace: RungTrace) {
        rungTraces.append(trace)
        nextRungIndex += 1
    }
}

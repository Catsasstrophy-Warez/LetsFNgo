import Foundation
import ControlsPLC

public struct WhyEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let scanNumber: UInt64
    public let task: String
    public let program: String
    public let routine: String
    public let rung: Int
    public let headline: String
    public let explanation: String
    public let changes: [TagChange]

    public init(
        id: UUID = UUID(), scanNumber: UInt64, task: String, program: String,
        routine: String, rung: Int, headline: String, explanation: String, changes: [TagChange]
    ) {
        self.id = id; self.scanNumber = scanNumber; self.task = task; self.program = program
        self.routine = routine; self.rung = rung; self.headline = headline
        self.explanation = explanation; self.changes = changes
    }
}

public enum TraceExplainer {
    public static func explain(step: ControllerDebugStep, scanNumber: UInt64) -> WhyEvent {
        let instructions = step.trace.instructions
        let passing = instructions.filter(\.outgoingCondition)
        let changes = instructions.flatMap(\.changes)
        let last = instructions.last

        let headline: String
        if !changes.isEmpty {
            headline = changes.map { "\($0.tag): \(display($0.oldValue)) → \(display($0.newValue))" }.joined(separator: " · ")
        } else if let failed = instructions.first(where: { $0.incomingCondition && !$0.outgoingCondition }) {
            headline = "Power stopped at \(failed.mnemonic) \(failed.reference)"
        } else if let last {
            headline = "Rung completed \(last.outgoingCondition ? "true" : "false")"
        } else {
            headline = "Rung evaluated"
        }

        var clauses: [String] = []
        for instruction in instructions {
            let ref = instruction.reference.isEmpty ? "" : " \(instruction.reference)"
            if !instruction.incomingCondition {
                clauses.append("\(instruction.mnemonic)\(ref) received no incoming power")
            } else {
                clauses.append("\(instruction.mnemonic)\(ref) \(instruction.outgoingCondition ? "passed" : "blocked") power")
            }
        }
        if !changes.isEmpty {
            clauses.append(changes.map { "\($0.tag) changed from \(display($0.oldValue)) to \(display($0.newValue))" }.joined(separator: ", "))
        } else if passing.isEmpty && !instructions.isEmpty {
            clauses.append("No destination value changed on this rung")
        }

        return WhyEvent(
            scanNumber: scanNumber,
            task: step.taskName,
            program: step.programName,
            routine: step.routineName,
            rung: step.rungNumber,
            headline: headline,
            explanation: clauses.joined(separator: ". ") + (clauses.isEmpty ? "" : "."),
            changes: changes
        )
    }

    public static func display(_ value: TagValue) -> String {
        switch value {
        case let .bool(v): return v ? "TRUE" : "FALSE"
        case let .dint(v): return String(v)
        case let .real(v): return String(format: "%.3f", v)
        case let .timer(v): return "PRE \(v.PRE) · ACC \(v.ACC) · EN \(bit(v.EN)) TT \(bit(v.TT)) DN \(bit(v.DN))"
        case let .counter(v): return "PRE \(v.PRE) · ACC \(v.ACC) · CU \(bit(v.CU)) CD \(bit(v.CD)) DN \(bit(v.DN)) OV \(bit(v.OV)) UN \(bit(v.UN))"
        }
    }

    private static func bit(_ value: Bool) -> String { value ? "1" : "0" }
}

public struct TagSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: TagDataType
    public let role: TagRole
    public let raw: TagValue
    public let logical: TagValue
    public let forced: TagValue?
    public let field: TagValue
    public let force: ForceEntry?
    public let changedOnLastRung: Bool
    public let watched: Bool

    public init(name: String, type: TagDataType, role: TagRole, raw: TagValue, logical: TagValue, forced: TagValue?, field: TagValue, force: ForceEntry?, changedOnLastRung: Bool, watched: Bool = false) {
        self.name = name
        self.type = type
        self.role = role
        self.raw = raw
        self.logical = logical
        self.forced = forced
        self.field = field
        self.force = force
        self.changedOnLastRung = changedOnLastRung
        self.watched = watched
    }
}

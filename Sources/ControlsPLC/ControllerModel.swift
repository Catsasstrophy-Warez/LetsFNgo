import Foundation

public enum ControllerMode: String, Codable, Sendable {
    case program
    case run
}

public enum TaskKind: Codable, Equatable, Sendable {
    case continuous
    case periodic(periodMilliseconds: Int32, priority: UInt8)
}

public struct ControllerTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: TaskKind
    public var watchdogMilliseconds: Int32
    public var inhibited: Bool
    public var programs: [ControllerProgram]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TaskKind = .continuous,
        watchdogMilliseconds: Int32 = 500,
        inhibited: Bool = false,
        programs: [ControllerProgram] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.watchdogMilliseconds = watchdogMilliseconds
        self.inhibited = inhibited
        self.programs = programs
    }
}

public struct ControllerProgram: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var mainRoutineName: String
    public var routines: [LadderRoutine]
    public var tags: TagStore

    public init(
        id: UUID = UUID(),
        name: String,
        mainRoutineName: String = "MainRoutine",
        routines: [LadderRoutine] = [],
        tags: TagStore = try! TagStore()
    ) {
        self.id = id
        self.name = name
        self.mainRoutineName = mainRoutineName
        self.routines = routines
        self.tags = tags
    }

    public func routine(named name: String) -> LadderRoutine? {
        routines.first { $0.name == name }
    }
}

public struct ControllerProject: Codable, Equatable, Sendable {
    public var name: String
    public var controllerTags: TagStore
    public var tasks: [ControllerTask]

    public init(name: String = "Controller", controllerTags: TagStore = try! TagStore(), tasks: [ControllerTask] = []) {
        self.name = name
        self.controllerTags = controllerTags
        self.tasks = tasks
    }
}

public enum ControllerFaultCode: String, Codable, Sendable {
    case watchdog
    case instruction
    case missingMainRoutine
    case missingSubroutine
    case recursiveSubroutine
    case invalidMode
}

public struct ControllerFault: Error, Codable, Equatable, Sendable {
    public let code: ControllerFaultCode
    public let message: String
    public let task: String?
    public let program: String?
    public let routine: String?

    public init(code: ControllerFaultCode, message: String, task: String? = nil, program: String? = nil, routine: String? = nil) {
        self.code = code
        self.message = message
        self.task = task
        self.program = program
        self.routine = routine
    }
}

public enum ForceKind: String, Codable, Sendable {
    case input
    case output
}

public struct ForceEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var tag: String
    public var value: TagValue
    public var kind: ForceKind
    public var enabled: Bool

    public init(id: UUID = UUID(), tag: String, value: TagValue, kind: ForceKind, enabled: Bool = true) {
        self.id = id
        self.tag = tag
        self.value = value
        self.kind = kind
        self.enabled = enabled
    }
}

public struct ForceTable: Codable, Equatable, Sendable {
    public var masterEnabled: Bool
    public private(set) var entries: [ForceEntry]

    public init(masterEnabled: Bool = false, entries: [ForceEntry] = []) {
        self.masterEnabled = masterEnabled
        self.entries = entries
    }

    public mutating func set(_ entry: ForceEntry) {
        entries.removeAll { $0.tag == entry.tag && $0.kind == entry.kind }
        entries.append(entry)
    }

    public mutating func remove(tag: String, kind: ForceKind? = nil) {
        entries.removeAll { $0.tag == tag && (kind == nil || $0.kind == kind) }
    }

    public func activeValue(for tag: String, kind: ForceKind) -> TagValue? {
        guard masterEnabled else { return nil }
        return entries.last { $0.enabled && $0.tag == tag && $0.kind == kind }?.value
    }
}

public struct ControllerLifecycleEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let controllerScanNumber: UInt64
    public let taskName: String
    public let programName: String
    public let trace: LifecycleTrace

    public init(id: UUID = UUID(), controllerScanNumber: UInt64, taskName: String, programName: String, trace: LifecycleTrace) {
        self.id = id
        self.controllerScanNumber = controllerScanNumber
        self.taskName = taskName
        self.programName = programName
        self.trace = trace
    }
}

public struct ProgramScanTrace: Codable, Equatable, Sendable {
    public let taskName: String
    public let programName: String
    public let routineTraces: [NamedRoutineTrace]
    public let isFirstScan: Bool

    public init(taskName: String, programName: String, routineTraces: [NamedRoutineTrace], isFirstScan: Bool = false) {
        self.taskName = taskName
        self.programName = programName
        self.routineTraces = routineTraces
        self.isFirstScan = isFirstScan
    }
}

public struct NamedRoutineTrace: Codable, Equatable, Sendable {
    public let routineName: String
    public let rungs: [RungTrace]
}

public struct ControllerScanTrace: Codable, Equatable, Sendable {
    public let scanNumber: UInt64
    public let startedAt: Date
    public let elapsedMilliseconds: Int32
    public let programs: [ProgramScanTrace]
}

public struct DebugRoutineFrame: Codable, Equatable, Sendable {
    public let routineName: String
    public var nextRungIndex: Int

    public init(routineName: String, nextRungIndex: Int = 0) {
        self.routineName = routineName
        self.nextRungIndex = nextRungIndex
    }
}

public struct ControllerDebugSession: Codable, Equatable, Sendable {
    public let scanNumber: UInt64
    public let taskName: String
    public let programName: String
    public let elapsedMilliseconds: Int32
    public let isFirstScan: Bool
    public var workingTags: TagStore
    public var callStack: [DebugRoutineFrame]
    public private(set) var stepsExecuted: Int

    public var isComplete: Bool { callStack.isEmpty }
    public var currentRoutineName: String? { callStack.last?.routineName }
    public var callDepth: Int { callStack.count }

    public init(scanNumber: UInt64, taskName: String, programName: String, elapsedMilliseconds: Int32, isFirstScan: Bool = false, workingTags: TagStore, callStack: [DebugRoutineFrame], stepsExecuted: Int = 0) {
        self.scanNumber = scanNumber
        self.taskName = taskName
        self.programName = programName
        self.elapsedMilliseconds = elapsedMilliseconds
        self.isFirstScan = isFirstScan
        self.workingTags = workingTags
        self.callStack = callStack
        self.stepsExecuted = stepsExecuted
    }

    mutating func incrementSteps() { stepsExecuted += 1 }
}

public struct ControllerDebugStep: Codable, Equatable, Sendable {
    public let taskName: String
    public let programName: String
    public let routineName: String
    public let rungNumber: Int
    public let callDepth: Int
    public let trace: RungTrace
    public let nextRoutineName: String?
    public let nextRungNumber: Int?

    public init(taskName: String, programName: String, routineName: String, rungNumber: Int, callDepth: Int, trace: RungTrace, nextRoutineName: String?, nextRungNumber: Int?) {
        self.taskName = taskName
        self.programName = programName
        self.routineName = routineName
        self.rungNumber = rungNumber
        self.callDepth = callDepth
        self.trace = trace
        self.nextRoutineName = nextRoutineName
        self.nextRungNumber = nextRungNumber
    }
}

import Foundation

public struct ControllerRuntime: Sendable {
    public private(set) var project: ControllerProject
    public private(set) var mode: ControllerMode = .program
    public private(set) var majorFault: ControllerFault?
    public private(set) var controllerScanNumber: UInt64 = 0
    public private(set) var clockMilliseconds: Int64 = 0
    public private(set) var lifecycleHistory: [ControllerLifecycleEvent] = []
    public var forces: ForceTable

    private var nextPeriodicDue: [UUID: Int64] = [:]
    private var firstScanPendingProgramIDs: Set<UUID> = []

    public init(project: ControllerProject, forces: ForceTable = ForceTable()) {
        self.project = project
        self.forces = forces
        for task in project.tasks {
            if case let .periodic(period, _) = task.kind {
                nextPeriodicDue[task.id] = Int64(max(1, period))
            }
        }
    }

    public mutating func clearFault() {
        majorFault = nil
    }

    /// Updates the controller data-table value without rebuilding the runtime. This is the
    /// hook a simulated field-input panel should use. Forces remain separate, so the UI can
    /// continue to show raw versus effective values while the controller is running.
    public mutating func setControllerTagValue(_ name: String, to value: TagValue) throws {
        try project.controllerTags.setValue(name, value)
    }

    /// Program -> Run performs one complete prescan of every scheduled program, including
    /// inhibited tasks. Transitioning Run -> Program simply stops normal execution; postscan
    /// is exposed separately because Logix postscan is associated with disabling logic such as
    /// SFC automatic-reset actions rather than being a generic Run -> Program pass.
    public mutating func setMode(_ newMode: ControllerMode) throws {
        guard majorFault == nil else {
            throw ControllerFault(code: .invalidMode, message: "Clear the controller major fault before changing mode.")
        }
        if mode == .program && newMode == .run {
            try prescanController()
        }
        mode = newMode
    }

    /// Explicit postscan hook for logic that is being disabled. This is intentionally not
    /// coupled to Run -> Program mode changes.
    @discardableResult
    public mutating func postscan(taskName: String, programName: String, routineName: String) throws -> LifecycleTrace {
        guard let taskIndex = project.tasks.firstIndex(where: { $0.name == taskName }),
              let programIndex = project.tasks[taskIndex].programs.firstIndex(where: { $0.name == programName }),
              let routine = project.tasks[taskIndex].programs[programIndex].routine(named: routineName)
        else {
            throw ControllerFault(code: .missingMainRoutine, message: "Unable to locate postscan target \(taskName)/\(programName)/\(routineName).")
        }

        var merged = try mergedTags(forTask: taskIndex, program: programIndex)
        var engine = PLCEngine(tags: merged)
        let program = project.tasks[taskIndex].programs[programIndex]
        let trace = try engine.lifecycleScan(mainRoutine: routine, routines: program.routines, mode: .postscan)
        merged = engine.tags
        try sync(merged, taskIndex: taskIndex, programIndex: programIndex)
        lifecycleHistory.append(ControllerLifecycleEvent(
            controllerScanNumber: controllerScanNumber,
            taskName: taskName,
            programName: programName,
            trace: trace
        ))
        return trace
    }

    @discardableResult
    public mutating func scan(
        elapsedMilliseconds: Int32 = 1,
        startedAt: Date = Date(),
        simulatedRungCostMicroseconds: Int32 = 100
    ) throws -> ControllerScanTrace {
        guard mode == .run else {
            throw ControllerFault(code: .invalidMode, message: "Controller logic can only scan in RUN mode.")
        }
        guard majorFault == nil else { throw majorFault! }
        guard elapsedMilliseconds >= 0 else { throw PLCEngineError.invalidElapsedTime(elapsedMilliseconds) }
        guard simulatedRungCostMicroseconds >= 0 else { throw PLCEngineError.invalidElapsedTime(simulatedRungCostMicroseconds) }

        controllerScanNumber &+= 1
        clockMilliseconds += Int64(elapsedMilliseconds)

        var programTraces: [ProgramScanTrace] = []
        for taskIndex in dueTaskIndices() {
            if project.tasks[taskIndex].inhibited { continue }
            let task = project.tasks[taskIndex]
            var taskCost: Int64 = 0

            for programIndex in project.tasks[taskIndex].programs.indices {
                do {
                    let result = try executeProgram(
                        taskIndex: taskIndex,
                        programIndex: programIndex,
                        elapsedMilliseconds: elapsedMilliseconds,
                        simulatedRungCostMicroseconds: simulatedRungCostMicroseconds
                    )
                    taskCost += result.costMicroseconds
                    programTraces.append(result.trace)
                } catch let fault as ControllerFault {
                    majorFault = fault
                    throw fault
                } catch {
                    let fault = ControllerFault(
                        code: .instruction,
                        message: "Instruction execution fault: \(error)",
                        task: task.name,
                        program: project.tasks[taskIndex].programs[programIndex].name
                    )
                    majorFault = fault
                    throw fault
                }
            }

            let watchdogMicros = Int64(max(0, task.watchdogMilliseconds)) * 1_000
            if watchdogMicros > 0 && taskCost > watchdogMicros {
                let fault = ControllerFault(
                    code: .watchdog,
                    message: "Task \(task.name) exceeded its \(task.watchdogMilliseconds) ms watchdog with a deterministic simulated execution cost of \(taskCost) µs.",
                    task: task.name
                )
                majorFault = fault
                throw fault
            }
        }

        return ControllerScanTrace(
            scanNumber: controllerScanNumber,
            startedAt: startedAt,
            elapsedMilliseconds: elapsedMilliseconds,
            programs: programTraces
        )
    }

    public mutating func beginDebugScan(
        taskName: String,
        programName: String,
        elapsedMilliseconds: Int32 = 1
    ) throws -> ControllerDebugSession {
        guard mode == .run else {
            throw ControllerFault(code: .invalidMode, message: "Controller must be in RUN mode to begin a debug scan.")
        }
        guard elapsedMilliseconds >= 0 else { throw PLCEngineError.invalidElapsedTime(elapsedMilliseconds) }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.name == taskName }),
              let programIndex = project.tasks[taskIndex].programs.firstIndex(where: { $0.name == programName })
        else {
            throw ControllerFault(code: .missingMainRoutine, message: "Unable to locate debug target \(taskName)/\(programName).")
        }
        let program = project.tasks[taskIndex].programs[programIndex]
        guard program.routine(named: program.mainRoutineName) != nil else {
            throw ControllerFault(code: .missingMainRoutine, message: "Program \(program.name) has no main routine named \(program.mainRoutineName).")
        }
        controllerScanNumber &+= 1
        clockMilliseconds += Int64(elapsedMilliseconds)
        var merged = try mergedTags(forTask: taskIndex, program: programIndex)
        let firstScan = firstScanPendingProgramIDs.contains(program.id)
        try injectFirstScanFlag(into: &merged, active: firstScan)
        try applyInputForces(to: &merged)
        return ControllerDebugSession(
            scanNumber: controllerScanNumber,
            taskName: taskName,
            programName: programName,
            elapsedMilliseconds: elapsedMilliseconds,
            isFirstScan: firstScan,
            workingTags: merged,
            callStack: [DebugRoutineFrame(routineName: program.mainRoutineName)]
        )
    }

    /// Executes exactly one ladder rung, including a JSR/RET boundary, while preserving a
    /// real routine call stack. A JSR pushes its target after the calling rung is evaluated,
    /// so the next debugger step enters the subroutine. RET returns to the caller.
    @discardableResult
    public mutating func stepDebug(_ session: inout ControllerDebugSession) throws -> ControllerDebugStep? {
        guard !session.isComplete else { return nil }
        guard let taskIndex = project.tasks.firstIndex(where: { $0.name == session.taskName }),
              let programIndex = project.tasks[taskIndex].programs.firstIndex(where: { $0.name == session.programName })
        else {
            throw ControllerFault(code: .missingMainRoutine, message: "Debug session target no longer exists.")
        }
        let program = project.tasks[taskIndex].programs[programIndex]

        while let frame = session.callStack.last {
            guard let routine = program.routine(named: frame.routineName) else {
                throw ControllerFault(code: .missingSubroutine, message: "Routine \(frame.routineName) no longer exists.", program: program.name)
            }
            let sortedRungs = routine.rungs.sorted { $0.number < $1.number }
            if frame.nextRungIndex >= sortedRungs.count {
                _ = session.callStack.popLast()
                if session.callStack.isEmpty { return nil }
                continue
            }

            let depth = session.callStack.count
            let rung = sortedRungs[frame.nextRungIndex]
            session.callStack[session.callStack.count - 1].nextRungIndex += 1
            let split = splitTerminalControl(from: rung.logic)

            var engine = PLCEngine(tags: session.workingTags)
            let power: Bool
            var instructionTraces: [InstructionTrace] = []
            var powerNodes: [PowerNodeTrace] = []
            if let logic = split.logic {
                let temp = LadderRoutine(name: "__debug_step__", rungs: [Rung(number: rung.number, comment: rung.comment, logic: logic)])
                let trace = try engine.scan(temp, elapsedMilliseconds: session.elapsedMilliseconds)
                power = trace.rungs[0].outgoingCondition
                instructionTraces = trace.rungs[0].instructions
                powerNodes = trace.rungs[0].powerNodes
            } else {
                power = true
            }
            session.workingTags = engine.tags

            if let control = split.control {
                switch control {
                case let .jsr(target):
                    instructionTraces.append(InstructionTrace(mnemonic: "JSR", reference: target, incomingCondition: power, outgoingCondition: power, changes: []))
                    if power {
                        guard program.routine(named: target) != nil else {
                            throw ControllerFault(code: .missingSubroutine, message: "JSR references missing routine \(target).", program: program.name, routine: routine.name)
                        }
                        if session.callStack.contains(where: { $0.routineName == target }) {
                            throw ControllerFault(code: .recursiveSubroutine, message: "Recursive JSR call detected while stepping into \(target).", program: program.name, routine: routine.name)
                        }
                        session.callStack.append(DebugRoutineFrame(routineName: target))
                    }
                case .ret:
                    instructionTraces.append(InstructionTrace(mnemonic: "RET", reference: "", incomingCondition: power, outgoingCondition: power, changes: []))
                    if power { _ = session.callStack.popLast() }
                default:
                    break
                }
            } else if let current = session.callStack.last,
                      current.routineName == routine.name,
                      current.nextRungIndex >= sortedRungs.count {
                _ = session.callStack.popLast()
            }

            session.incrementSteps()
            try sync(session.workingTags, taskIndex: taskIndex, programIndex: programIndex)

            let nextRoutine = session.callStack.last?.routineName
            var nextRung: Int?
            if let nextFrame = session.callStack.last,
               let nextRoutineDef = program.routine(named: nextFrame.routineName) {
                let nextSorted = nextRoutineDef.rungs.sorted { $0.number < $1.number }
                if nextFrame.nextRungIndex < nextSorted.count { nextRung = nextSorted[nextFrame.nextRungIndex].number }
            }

            let rungTrace = RungTrace(
                rungNumber: rung.number,
                incomingCondition: true,
                outgoingCondition: power,
                instructions: instructionTraces,
                powerNodes: powerNodes
            )
            if session.isComplete && session.isFirstScan {
                firstScanPendingProgramIDs.remove(program.id)
            }

            return ControllerDebugStep(
                taskName: session.taskName,
                programName: session.programName,
                routineName: routine.name,
                rungNumber: rung.number,
                callDepth: depth,
                trace: rungTrace,
                nextRoutineName: nextRoutine,
                nextRungNumber: nextRung
            )
        }
        return nil
    }

    /// Returns the value a simulated field device should see after output forces are applied.
    /// The controller data table remains visible separately so a troubleshooting UI can show
    /// the crucial distinction between "logic commanded" and "field output forced".
    public func effectiveOutputValue(controllerTag name: String) throws -> TagValue {
        if let forced = forces.activeValue(for: name, kind: .output) { return forced }
        return try project.controllerTags.value(for: name)
    }

    private mutating func prescanController() throws {
        for taskIndex in project.tasks.indices {
            for programIndex in project.tasks[taskIndex].programs.indices {
                var merged = try mergedTags(forTask: taskIndex, program: programIndex)
                try applyInputForces(to: &merged)
                let program = project.tasks[taskIndex].programs[programIndex]
                guard let main = program.routine(named: program.mainRoutineName) else {
                    let fault = ControllerFault(
                        code: .missingMainRoutine,
                        message: "Program \(program.name) has no main routine named \(program.mainRoutineName).",
                        task: project.tasks[taskIndex].name,
                        program: program.name
                    )
                    majorFault = fault
                    throw fault
                }
                var engine = PLCEngine(tags: merged)
                do {
                    let trace = try engine.lifecycleScan(mainRoutine: main, routines: program.routines, mode: .prescan)
                    lifecycleHistory.append(ControllerLifecycleEvent(
                        controllerScanNumber: controllerScanNumber,
                        taskName: project.tasks[taskIndex].name,
                        programName: program.name,
                        trace: trace
                    ))
                    firstScanPendingProgramIDs.insert(program.id)
                } catch {
                    let fault = ControllerFault(
                        code: .instruction,
                        message: "Prescan fault: \(error)",
                        task: project.tasks[taskIndex].name,
                        program: program.name,
                        routine: main.name
                    )
                    majorFault = fault
                    throw fault
                }
                try sync(engine.tags, taskIndex: taskIndex, programIndex: programIndex)
            }
        }
    }

    private mutating func dueTaskIndices() -> [Int] {
        var periodic: [(index: Int, priority: UInt8)] = []
        var continuous: [Int] = []

        for index in project.tasks.indices {
            switch project.tasks[index].kind {
            case .continuous:
                continuous.append(index)
            case let .periodic(period, priority):
                let safePeriod = Int64(max(1, period))
                let due = nextPeriodicDue[project.tasks[index].id] ?? safePeriod
                if clockMilliseconds >= due {
                    periodic.append((index, priority))
                    var next = due
                    while next <= clockMilliseconds { next += safePeriod }
                    nextPeriodicDue[project.tasks[index].id] = next
                }
            }
        }

        periodic.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.index < rhs.index
        }
        return periodic.map(\.index) + continuous
    }

    private mutating func executeProgram(
        taskIndex: Int,
        programIndex: Int,
        elapsedMilliseconds: Int32,
        simulatedRungCostMicroseconds: Int32
    ) throws -> (trace: ProgramScanTrace, costMicroseconds: Int64) {
        var merged = try mergedTags(forTask: taskIndex, program: programIndex)
        let program = project.tasks[taskIndex].programs[programIndex]
        let firstScan = firstScanPendingProgramIDs.contains(program.id)
        try injectFirstScanFlag(into: &merged, active: firstScan)
        try applyInputForces(to: &merged)
        var engine = PLCEngine(tags: merged)
        guard let main = program.routine(named: program.mainRoutineName) else {
            throw ControllerFault(
                code: .missingMainRoutine,
                message: "Program \(program.name) has no main routine named \(program.mainRoutineName).",
                task: project.tasks[taskIndex].name,
                program: program.name
            )
        }

        var traces: [NamedRoutineTrace] = []
        var stack: [String] = []
        var cost: Int64 = 0
        try executeRoutine(
            main,
            program: program,
            engine: &engine,
            elapsedMilliseconds: elapsedMilliseconds,
            rungCostMicroseconds: simulatedRungCostMicroseconds,
            stack: &stack,
            traces: &traces,
            costMicroseconds: &cost
        )
        try sync(engine.tags, taskIndex: taskIndex, programIndex: programIndex)

        if firstScan { firstScanPendingProgramIDs.remove(program.id) }
        return (ProgramScanTrace(
            taskName: project.tasks[taskIndex].name,
            programName: program.name,
            routineTraces: traces,
            isFirstScan: firstScan
        ), cost)
    }

    private func executeRoutine(
        _ routine: LadderRoutine,
        program: ControllerProgram,
        engine: inout PLCEngine,
        elapsedMilliseconds: Int32,
        rungCostMicroseconds: Int32,
        stack: inout [String],
        traces: inout [NamedRoutineTrace],
        costMicroseconds: inout Int64
    ) throws {
        if stack.contains(routine.name) {
            throw ControllerFault(
                code: .recursiveSubroutine,
                message: "Recursive JSR call detected: \((stack + [routine.name]).joined(separator: " → ")).",
                program: program.name,
                routine: routine.name
            )
        }
        stack.append(routine.name)
        defer { _ = stack.popLast() }

        var rungTraces: [RungTrace] = []
        var shouldReturn = false
        for rung in routine.rungs.sorted(by: { $0.number < $1.number }) {
            if shouldReturn { break }
            costMicroseconds += Int64(rungCostMicroseconds)

            let split = splitTerminalControl(from: rung.logic)
            let power: Bool
            var instructionTraces: [InstructionTrace] = []
            var powerNodes: [PowerNodeTrace] = []

            if let logic = split.logic {
                let temp = LadderRoutine(name: "__step__", rungs: [Rung(number: rung.number, comment: rung.comment, logic: logic)])
                let trace = try engine.scan(temp, elapsedMilliseconds: elapsedMilliseconds)
                let rt = trace.rungs[0]
                power = rt.outgoingCondition
                instructionTraces = rt.instructions
                powerNodes = rt.powerNodes
            } else {
                power = true
            }

            if let control = split.control {
                switch control {
                case let .jsr(target):
                    instructionTraces.append(InstructionTrace(
                        mnemonic: "JSR", reference: target,
                        incomingCondition: power, outgoingCondition: power, changes: []
                    ))
                    if power {
                        guard let targetRoutine = program.routine(named: target) else {
                            throw ControllerFault(
                                code: .missingSubroutine,
                                message: "JSR references missing routine \(target).",
                                program: program.name,
                                routine: routine.name
                            )
                        }
                        try executeRoutine(
                            targetRoutine,
                            program: program,
                            engine: &engine,
                            elapsedMilliseconds: elapsedMilliseconds,
                            rungCostMicroseconds: rungCostMicroseconds,
                            stack: &stack,
                            traces: &traces,
                            costMicroseconds: &costMicroseconds
                        )
                    }
                case .ret:
                    instructionTraces.append(InstructionTrace(
                        mnemonic: "RET", reference: "",
                        incomingCondition: power, outgoingCondition: power, changes: []
                    ))
                    shouldReturn = power
                default:
                    break
                }
            }

            rungTraces.append(RungTrace(
                rungNumber: rung.number,
                incomingCondition: true,
                outgoingCondition: power,
                instructions: instructionTraces,
                powerNodes: powerNodes
            ))
        }
        traces.append(NamedRoutineTrace(routineName: routine.name, rungs: rungTraces))
    }

    private func splitTerminalControl(from logic: LogicNode) -> (logic: LogicNode?, control: Instruction?) {
        switch logic {
        case let .instruction(instruction):
            switch instruction {
            case .jsr, .ret: return (nil, instruction)
            default: return (logic, nil)
            }
        case let .series(nodes):
            guard let last = nodes.last else { return (logic, nil) }
            if case let .instruction(instruction) = last {
                switch instruction {
                case .jsr, .ret:
                    let prefix = Array(nodes.dropLast())
                    if prefix.isEmpty { return (nil, instruction) }
                    if prefix.count == 1 { return (prefix[0], instruction) }
                    return (.series(prefix), instruction)
                default: break
                }
            }
            return (logic, nil)
        case .parallel:
            return (logic, nil)
        }
    }

    private func mergedTags(forTask taskIndex: Int, program programIndex: Int) throws -> TagStore {
        let localNames = Set(project.tasks[taskIndex].programs[programIndex].tags.allTags.map(\.name))
        var tags = project.controllerTags.allTags.filter { !localNames.contains($0.name) }
        tags.append(contentsOf: project.tasks[taskIndex].programs[programIndex].tags.allTags)
        return try TagStore(tags: tags)
    }

    private mutating func sync(_ merged: TagStore, taskIndex: Int, programIndex: Int) throws {
        let localNames = Set(project.tasks[taskIndex].programs[programIndex].tags.allTags.map(\.name))
        for tag in merged.allTags {
            if tag.name == "S:FS" { continue }
            // Input forces alter the value presented to logic without destroying the underlying
            // data-table value. This lets the debugger show both raw and forced state.
            if forces.activeValue(for: tag.name, kind: .input) != nil { continue }
            if localNames.contains(tag.name) {
                try project.tasks[taskIndex].programs[programIndex].tags.setValue(tag.name, tag.value)
            } else if project.controllerTags.contains(tag.name) {
                try project.controllerTags.setValue(tag.name, tag.value)
            }
        }
    }

    public func isFirstScanPending(taskName: String, programName: String) -> Bool {
        guard let task = project.tasks.first(where: { $0.name == taskName }),
              let program = task.programs.first(where: { $0.name == programName }) else { return false }
        return firstScanPendingProgramIDs.contains(program.id)
    }

    private func injectFirstScanFlag(into tags: inout TagStore, active: Bool) throws {
        if tags.contains("S:FS") {
            try tags.setBool("S:FS", active)
        } else {
            try tags.add(PLCTag(
                name: "S:FS",
                value: .bool(active),
                description: "Synthetic Logix first-scan status flag",
                role: .internalValue
            ))
        }
    }

    private func applyInputForces(to tags: inout TagStore) throws {
        guard forces.masterEnabled else { return }
        for entry in forces.entries where entry.enabled && entry.kind == .input {
            guard tags.contains(entry.tag) else { continue }
            try tags.setValue(entry.tag, entry.value)
        }
    }
}

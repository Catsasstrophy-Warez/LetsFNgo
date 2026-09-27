import Foundation

public enum PLCEngineError: Error, Equatable {
    case invalidParallelBranch
    case invalidElapsedTime(Int32)
    case divideByZero
    case resetUnsupportedType(String)
    case timerFault(tag: String, PRE: Int32, ACC: Int32)
    case programControlRequiresController(String)
}

public struct PLCEngine: Sendable {
    public private(set) var tags: TagStore
    public private(set) var scanNumber: UInt64 = 0

    public init(tags: TagStore) {
        self.tags = tags
    }

    public mutating func forceInput(_ tag: String, value: Bool) throws {
        try tags.setBool(tag, value)
    }

    public mutating func forceDInt(_ tag: String, value: Int32) throws {
        try tags.setDInt(tag, value)
    }

    public mutating func forceReal(_ tag: String, value: Double) throws {
        try tags.setReal(tag, value)
    }

    public mutating func beginScan(
        _ routine: LadderRoutine,
        elapsedMilliseconds: Int32,
        startedAt: Date = Date()
    ) throws -> ScanSession {
        guard elapsedMilliseconds >= 0 else { throw PLCEngineError.invalidElapsedTime(elapsedMilliseconds) }
        scanNumber &+= 1
        return ScanSession(
            scanNumber: scanNumber,
            startedAt: startedAt,
            elapsedMilliseconds: elapsedMilliseconds,
            routine: routine
        )
    }

    /// Executes exactly one rung in the active scan session. The caller can inspect
    /// `tags` after every step, which is the basis for the visual scan debugger.
    @discardableResult
    public mutating func step(_ session: inout ScanSession) throws -> RungTrace? {
        guard !session.isComplete else { return nil }
        let rung = session.routine.rungs[session.nextRungIndex]
        var traces: [InstructionTrace] = []
        var powerNodes: [PowerNodeTrace] = []
        let outgoing = try evaluate(
            rung.logic,
            incoming: true,
            elapsedMilliseconds: session.elapsedMilliseconds,
            path: "root",
            traces: &traces,
            powerNodes: &powerNodes
        )
        let rungTrace = RungTrace(
            rungNumber: rung.number,
            incomingCondition: true,
            outgoingCondition: outgoing,
            instructions: traces,
            powerNodes: powerNodes
        )
        session.append(rungTrace)
        return rungTrace
    }

    public func finish(_ session: ScanSession) -> ScanTrace? {
        guard session.isComplete else { return nil }
        return ScanTrace(
            scanNumber: session.scanNumber,
            startedAt: session.startedAt,
            elapsedMilliseconds: session.elapsedMilliseconds,
            rungs: session.rungTraces
        )
    }

    @discardableResult
    public mutating func scan(
        _ routine: LadderRoutine,
        elapsedMilliseconds: Int32 = 1,
        startedAt: Date = Date()
    ) throws -> ScanTrace {
        var session = try beginScan(routine, elapsedMilliseconds: elapsedMilliseconds, startedAt: startedAt)
        while !session.isComplete { try step(&session) }
        return finish(session)!
    }

    /// Executes Rockwell-style lifecycle semantics for the built-in instructions currently
    /// modeled by the engine. JSR traversal is handled recursively and each subroutine is
    /// visited at most once during prescan/postscan, matching Logix initialization behavior.
    @discardableResult
    public mutating func lifecycleScan(
        mainRoutine: LadderRoutine,
        routines: [LadderRoutine] = [],
        mode: InstructionScanMode
    ) throws -> LifecycleTrace {
        precondition(mode != .normal, "Use scan(_:elapsedMilliseconds:) for normal execution")
        var catalog = Dictionary(uniqueKeysWithValues: routines.map { ($0.name, $0) })
        catalog[mainRoutine.name] = mainRoutine
        var visited = Set<String>()
        var names: [String] = []
        var changes: [TagChange] = []
        try lifecycleRoutine(mainRoutine, catalog: catalog, mode: mode, visited: &visited, names: &names, changes: &changes)
        return LifecycleTrace(mode: mode, routineNames: names, changes: changes)
    }

    private mutating func evaluate(
        _ node: LogicNode,
        incoming: Bool,
        elapsedMilliseconds: Int32,
        path: String,
        traces: inout [InstructionTrace],
        powerNodes: inout [PowerNodeTrace]
    ) throws -> Bool {
        switch node {
        case let .instruction(instruction):
            let outgoing = try execute(
                instruction,
                incoming: incoming,
                elapsedMilliseconds: elapsedMilliseconds,
                nodePath: path,
                traces: &traces
            )
            powerNodes.append(PowerNodeTrace(path: path, kind: .instruction, incomingCondition: incoming, outgoingCondition: outgoing))
            return outgoing

        case let .series(nodes):
            var condition = incoming
            for (index, child) in nodes.enumerated() {
                condition = try evaluate(
                    child,
                    incoming: condition,
                    elapsedMilliseconds: elapsedMilliseconds,
                    path: "\(path).s\(index)",
                    traces: &traces,
                    powerNodes: &powerNodes
                )
            }
            powerNodes.append(PowerNodeTrace(path: path, kind: .series, incomingCondition: incoming, outgoingCondition: condition))
            return condition

        case let .parallel(branches):
            guard !branches.isEmpty else { throw PLCEngineError.invalidParallelBranch }
            var anyTrue = false
            for (index, branch) in branches.enumerated() {
                let branchResult = try evaluate(
                    branch,
                    incoming: incoming,
                    elapsedMilliseconds: elapsedMilliseconds,
                    path: "\(path).p\(index)",
                    traces: &traces,
                    powerNodes: &powerNodes
                )
                powerNodes.append(PowerNodeTrace(
                    path: "\(path).branch\(index)",
                    kind: .parallel,
                    incomingCondition: incoming,
                    outgoingCondition: branchResult,
                    branchIndex: index
                ))
                anyTrue = anyTrue || branchResult
            }
            powerNodes.append(PowerNodeTrace(path: path, kind: .parallel, incomingCondition: incoming, outgoingCondition: anyTrue))
            return anyTrue
        }
    }

    private mutating func execute(
        _ instruction: Instruction,
        incoming: Bool,
        elapsedMilliseconds: Int32,
        nodePath: String,
        traces: inout [InstructionTrace]
    ) throws -> Bool {
        let outgoing: Bool
        var changes: [TagChange] = []
        var observations: [TraceObservation] = []

        switch instruction {
        case let .xic(tag):
            let value = try tags.bool(tag)
            observations.append(TraceObservation(label: tag, value: .bool(value)))
            outgoing = incoming && value

        case let .xio(tag):
            let value = try tags.bool(tag)
            observations.append(TraceObservation(label: tag, value: .bool(value)))
            outgoing = incoming && !value

        case let .ote(tag):
            outgoing = incoming
            try setBoolTracked(tag, value: incoming, changes: &changes)

        case let .otl(tag):
            outgoing = incoming
            if incoming { try setBoolTracked(tag, value: true, changes: &changes) }

        case let .otu(tag):
            outgoing = incoming
            if incoming { try setBoolTracked(tag, value: false, changes: &changes) }

        case let .ons(storageTag):
            let previous = try tags.bool(storageTag)
            observations.append(TraceObservation(label: "storage-before", value: .bool(previous)))
            outgoing = incoming && !previous
            try setBoolTracked(storageTag, value: incoming, changes: &changes)

        case let .ton(timerName):
            outgoing = incoming
            var timer = try tags.timer(timerName)
            observations.append(TraceObservation(label: "before", value: .timer(timer)))
            observations.append(TraceObservation(label: "elapsed-ms", value: .dint(elapsedMilliseconds)))
            try validate(timer, named: timerName)
            let old = TagValue.timer(timer)
            if incoming {
                timer.EN = true
                if !timer.DN {
                    timer.ACC = saturatingAdd(timer.ACC, elapsedMilliseconds, upperBound: timer.PRE)
                    timer.DN = timer.ACC >= timer.PRE
                }
                timer.TT = !timer.DN
            } else {
                timer.ACC = 0
                timer.EN = false
                timer.TT = false
                timer.DN = false
            }
            try tags.setTimer(timerName, timer)
            appendChangeIfNeeded(tag: timerName, old: old, new: .timer(timer), into: &changes)
            observations.append(TraceObservation(label: "after", value: .timer(timer)))

        case let .tof(timerName):
            outgoing = incoming
            var timer = try tags.timer(timerName)
            observations.append(TraceObservation(label: "before", value: .timer(timer)))
            observations.append(TraceObservation(label: "elapsed-ms", value: .dint(elapsedMilliseconds)))
            try validate(timer, named: timerName)
            let old = TagValue.timer(timer)
            if incoming {
                timer.EN = true
                timer.TT = false
                timer.DN = true
                timer.ACC = 0
            } else {
                timer.EN = false
                if timer.DN {
                    timer.ACC = saturatingAdd(timer.ACC, elapsedMilliseconds, upperBound: timer.PRE)
                    timer.DN = timer.ACC < timer.PRE
                    timer.TT = timer.DN
                } else {
                    timer.TT = false
                }
            }
            try tags.setTimer(timerName, timer)
            appendChangeIfNeeded(tag: timerName, old: old, new: .timer(timer), into: &changes)
            observations.append(TraceObservation(label: "after", value: .timer(timer)))

        case let .rto(timerName):
            outgoing = incoming
            var timer = try tags.timer(timerName)
            observations.append(TraceObservation(label: "before", value: .timer(timer)))
            observations.append(TraceObservation(label: "elapsed-ms", value: .dint(elapsedMilliseconds)))
            try validate(timer, named: timerName)
            let old = TagValue.timer(timer)
            if incoming {
                timer.EN = true
                if !timer.DN {
                    timer.ACC = saturatingAdd(timer.ACC, elapsedMilliseconds, upperBound: timer.PRE)
                    timer.DN = timer.ACC >= timer.PRE
                }
                timer.TT = !timer.DN
            } else {
                timer.EN = false
                timer.TT = false
            }
            try tags.setTimer(timerName, timer)
            appendChangeIfNeeded(tag: timerName, old: old, new: .timer(timer), into: &changes)
            observations.append(TraceObservation(label: "after", value: .timer(timer)))

        case let .ctu(counterName):
            outgoing = incoming
            var counter = try tags.counter(counterName)
            observations.append(TraceObservation(label: "before", value: .counter(counter)))
            let old = TagValue.counter(counter)
            let rising = incoming && !counter.CU
            if rising {
                if counter.ACC == Int32.max {
                    counter.ACC = Int32.min
                    if !counter.UN {
                        counter.OV = true
                    } else {
                        counter.UN = false
                        counter.OV = false
                    }
                } else {
                    counter.ACC += 1
                }
            }
            counter.CU = incoming
            if !counter.OV && !counter.UN { counter.DN = counter.ACC >= counter.PRE }
            try tags.setCounter(counterName, counter)
            appendChangeIfNeeded(tag: counterName, old: old, new: .counter(counter), into: &changes)
            observations.append(TraceObservation(label: "after", value: .counter(counter)))

        case let .ctd(counterName):
            outgoing = incoming
            var counter = try tags.counter(counterName)
            observations.append(TraceObservation(label: "before", value: .counter(counter)))
            let old = TagValue.counter(counter)
            let rising = incoming && !counter.CD
            if rising {
                if counter.ACC == Int32.min {
                    counter.ACC = Int32.max
                    if !counter.OV {
                        counter.UN = true
                    } else {
                        counter.OV = false
                        counter.UN = false
                    }
                } else {
                    counter.ACC -= 1
                }
            }
            counter.CD = incoming
            if !counter.OV && !counter.UN { counter.DN = counter.ACC >= counter.PRE }
            try tags.setCounter(counterName, counter)
            appendChangeIfNeeded(tag: counterName, old: old, new: .counter(counter), into: &changes)
            observations.append(TraceObservation(label: "after", value: .counter(counter)))

        case let .res(tag):
            outgoing = incoming
            if incoming {
                let old = try tags.value(for: tag)
                switch old {
                case let .timer(timer):
                    var reset = timer
                    reset.ACC = 0; reset.EN = false; reset.TT = false; reset.DN = false
                    try tags.setTimer(tag, reset)
                    appendChangeIfNeeded(tag: tag, old: old, new: .timer(reset), into: &changes)
                case let .counter(counter):
                    var reset = counter
                    reset.ACC = 0; reset.CU = false; reset.CD = false; reset.DN = false; reset.OV = false; reset.UN = false
                    try tags.setCounter(tag, reset)
                    appendChangeIfNeeded(tag: tag, old: old, new: .counter(reset), into: &changes)
                default:
                    throw PLCEngineError.resetUnsupportedType(tag)
                }
            }

        case let .equ(a, b):
            let av = try numeric(a), bv = try numeric(b)
            let result = av == bv
            observations += numericObservations(aOperand: a, a: av, bOperand: b, b: bv, result: result)
            outgoing = incoming && result
        case let .neq(a, b):
            let av = try numeric(a), bv = try numeric(b)
            let result = av != bv
            observations += numericObservations(aOperand: a, a: av, bOperand: b, b: bv, result: result)
            outgoing = incoming && result
        case let .les(a, b):
            let av = try numeric(a), bv = try numeric(b)
            let result = av < bv
            observations += numericObservations(aOperand: a, a: av, bOperand: b, b: bv, result: result)
            outgoing = incoming && result
        case let .leq(a, b):
            let av = try numeric(a), bv = try numeric(b)
            let result = av <= bv
            observations += numericObservations(aOperand: a, a: av, bOperand: b, b: bv, result: result)
            outgoing = incoming && result
        case let .grt(a, b):
            let av = try numeric(a), bv = try numeric(b)
            let result = av > bv
            observations += numericObservations(aOperand: a, a: av, bOperand: b, b: bv, result: result)
            outgoing = incoming && result
        case let .geq(a, b):
            let av = try numeric(a), bv = try numeric(b)
            let result = av >= bv
            observations += numericObservations(aOperand: a, a: av, bOperand: b, b: bv, result: result)
            outgoing = incoming && result
        case let .lim(low, test, high):
            let lowValue = try numeric(low), testValue = try numeric(test), highValue = try numeric(high)
            // Logix LIM is inclusive. If low > high, the valid region wraps outside the bounds.
            let passes = lowValue <= highValue
                ? (testValue >= lowValue && testValue <= highValue)
                : (testValue >= lowValue || testValue <= highValue)
            observations.append(TraceObservation(label: "low", value: .real(lowValue)))
            observations.append(TraceObservation(label: "test", value: .real(testValue)))
            observations.append(TraceObservation(label: "high", value: .real(highValue)))
            observations.append(TraceObservation(label: "comparison-result", value: .bool(passes)))
            outgoing = incoming && passes

        case let .mov(source, destination):
            outgoing = incoming
            if incoming { try writeNumeric(try numeric(source), to: destination, changes: &changes) }

        case let .add(a, b, destination):
            outgoing = incoming
            if incoming { try writeNumeric(try numeric(a) + numeric(b), to: destination, changes: &changes) }

        case let .sub(a, b, destination):
            outgoing = incoming
            if incoming { try writeNumeric(try numeric(a) - numeric(b), to: destination, changes: &changes) }

        case let .mul(a, b, destination):
            outgoing = incoming
            if incoming { try writeNumeric(try numeric(a) * numeric(b), to: destination, changes: &changes) }

        case let .div(a, b, destination):
            outgoing = incoming
            if incoming {
                let divisor = try numeric(b)
                guard divisor != 0 else { throw PLCEngineError.divideByZero }
                try writeNumeric(try numeric(a) / divisor, to: destination, changes: &changes)
            }

        case let .jsr(routine):
            throw PLCEngineError.programControlRequiresController("JSR \(routine)")

        case .ret:
            throw PLCEngineError.programControlRequiresController("RET")
        }

        traces.append(InstructionTrace(
            mnemonic: instruction.mnemonic,
            reference: instruction.displayReference,
            incomingCondition: incoming,
            outgoingCondition: outgoing,
            changes: changes,
            nodePath: nodePath,
            observations: observations,
            readTags: instruction.readTagNames,
            writeTags: instruction.writeTagNames
        ))
        return outgoing
    }


    private func numericObservations(aOperand: NumericOperand, a: Double, bOperand: NumericOperand, b: Double, result: Bool) -> [TraceObservation] {
        [
            TraceObservation(label: aOperand.displayName, value: .real(a)),
            TraceObservation(label: bOperand.displayName, value: .real(b)),
            TraceObservation(label: "comparison-result", value: .bool(result))
        ]
    }
    private func numeric(_ operand: NumericOperand) throws -> Double {
        switch operand {
        case let .tag(name): try tags.numeric(name)
        case let .dint(value): Double(value)
        case let .real(value): value
        }
    }

    private mutating func writeNumeric(_ value: Double, to destination: String, changes: inout [TagChange]) throws {
        try setNumericTracked(destination, value: value, changes: &changes)
    }

    private mutating func setBoolTracked(_ tag: String, value: Bool, changes: inout [TagChange]) throws {
        let old = try tags.value(for: tag)
        try tags.setBool(tag, value)
        let new = try tags.value(for: tag)
        appendChangeIfNeeded(tag: tag, old: old, new: new, into: &changes)
    }

    private mutating func setNumericTracked(_ tag: String, value: Double, changes: inout [TagChange]) throws {
        let old = try tags.value(for: tag)
        try tags.setNumeric(tag, value)
        let new = try tags.value(for: tag)
        appendChangeIfNeeded(tag: tag, old: old, new: new, into: &changes)
    }

    private func appendChangeIfNeeded(tag: String, old: TagValue, new: TagValue, into changes: inout [TagChange]) {
        if old != new { changes.append(TagChange(tag: tag, oldValue: old, newValue: new)) }
    }

    private func validate(_ timer: TimerValue, named name: String) throws {
        guard timer.PRE >= 0, timer.ACC >= 0 else {
            throw PLCEngineError.timerFault(tag: name, PRE: timer.PRE, ACC: timer.ACC)
        }
    }

    private func saturatingAdd(_ value: Int32, _ increment: Int32, upperBound: Int32) -> Int32 {
        guard upperBound > 0 else { return 0 }
        let sum = Int64(value) + Int64(increment)
        return Int32(min(Int64(upperBound), max(0, sum)))
    }

    private mutating func lifecycleRoutine(
        _ routine: LadderRoutine,
        catalog: [String: LadderRoutine],
        mode: InstructionScanMode,
        visited: inout Set<String>,
        names: inout [String],
        changes: inout [TagChange]
    ) throws {
        if visited.contains(routine.name) { return }
        visited.insert(routine.name)
        names.append(routine.name)
        for rung in routine.rungs.sorted(by: { $0.number < $1.number }) {
            try lifecycleNode(rung.logic, catalog: catalog, mode: mode, visited: &visited, names: &names, changes: &changes)
        }
    }

    private mutating func lifecycleNode(
        _ node: LogicNode,
        catalog: [String: LadderRoutine],
        mode: InstructionScanMode,
        visited: inout Set<String>,
        names: inout [String],
        changes: inout [TagChange]
    ) throws {
        switch node {
        case let .instruction(instruction):
            try lifecycleInstruction(instruction, catalog: catalog, mode: mode, visited: &visited, names: &names, changes: &changes)
        case let .series(nodes), let .parallel(nodes):
            for child in nodes {
                try lifecycleNode(child, catalog: catalog, mode: mode, visited: &visited, names: &names, changes: &changes)
            }
        }
    }

    private mutating func lifecycleInstruction(
        _ instruction: Instruction,
        catalog: [String: LadderRoutine],
        mode: InstructionScanMode,
        visited: inout Set<String>,
        names: inout [String],
        changes: inout [TagChange]
    ) throws {
        switch instruction {
        case let .ote(tag):
            if mode == .prescan || mode == .postscan {
                try setBoolTracked(tag, value: false, changes: &changes)
            }

        case let .ons(storageTag):
            if mode == .prescan {
                try setBoolTracked(storageTag, value: true, changes: &changes)
            }

        case let .ton(timerName):
            if mode == .prescan || mode == .postscan {
                var timer = try tags.timer(timerName)
                let old = TagValue.timer(timer)
                timer.ACC = 0; timer.EN = false; timer.TT = false; timer.DN = false
                try tags.setTimer(timerName, timer)
                appendChangeIfNeeded(tag: timerName, old: old, new: .timer(timer), into: &changes)
            }

        case let .tof(timerName):
            if mode == .prescan || mode == .postscan {
                var timer = try tags.timer(timerName)
                try validate(timer, named: timerName)
                let old = TagValue.timer(timer)
                timer.ACC = timer.PRE; timer.EN = false; timer.TT = false; timer.DN = false
                try tags.setTimer(timerName, timer)
                appendChangeIfNeeded(tag: timerName, old: old, new: .timer(timer), into: &changes)
            }

        case let .rto(timerName):
            if mode == .prescan {
                var timer = try tags.timer(timerName)
                try validate(timer, named: timerName)
                let old = TagValue.timer(timer)
                timer.EN = false; timer.TT = false
                try tags.setTimer(timerName, timer)
                appendChangeIfNeeded(tag: timerName, old: old, new: .timer(timer), into: &changes)
            }

        case let .ctu(counterName):
            if mode == .prescan {
                var counter = try tags.counter(counterName)
                let old = TagValue.counter(counter)
                counter.CU = true
                try tags.setCounter(counterName, counter)
                appendChangeIfNeeded(tag: counterName, old: old, new: .counter(counter), into: &changes)
            }

        case let .ctd(counterName):
            if mode == .prescan {
                var counter = try tags.counter(counterName)
                let old = TagValue.counter(counter)
                counter.CD = true
                try tags.setCounter(counterName, counter)
                appendChangeIfNeeded(tag: counterName, old: old, new: .counter(counter), into: &changes)
            }

        case let .jsr(routineName):
            if let routine = catalog[routineName] {
                try lifecycleRoutine(routine, catalog: catalog, mode: mode, visited: &visited, names: &names, changes: &changes)
            }

        // RET is intentionally ignored in lifecycle scans so the complete routine is visited.
        case .ret:
            break

        // These instructions have no lifecycle-specific state for the subset we model.
        case .xic, .xio, .otl, .otu, .res,
             .equ, .neq, .les, .leq, .grt, .geq, .lim,
             .mov, .add, .sub, .mul, .div:
            break
        }
    }

}

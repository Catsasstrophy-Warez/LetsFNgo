import Testing
@testable import ControlsPLC

private func store(_ tags: PLCTag...) throws -> TagStore { try TagStore(tags: tags) }

@Test func xicTruePassesPowerToOTE() throws {
    let tags = try store(
        PLCTag(name: "Start", value: .bool(true)),
        PLCTag(name: "Motor", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([
            .instruction(.xic(tag: "Start")),
            .instruction(.ote(tag: "Motor"))
        ]))
    ])

    let trace = try engine.scan(routine)
    #expect(try engine.tags.bool("Motor") == true)
    #expect(trace.rungs[0].instructions.last?.changes.count == 1)
}

@Test func xioFalsePassesPower() throws {
    let tags = try store(
        PLCTag(name: "Stop", value: .bool(false)),
        PLCTag(name: "Motor", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([
            .instruction(.xio(tag: "Stop")),
            .instruction(.ote(tag: "Motor"))
        ]))
    ])
    try engine.scan(routine)
    #expect(try engine.tags.bool("Motor") == true)
}

@Test func parallelBranchImplementsOR() throws {
    let tags = try store(
        PLCTag(name: "A", value: .bool(false)),
        PLCTag(name: "B", value: .bool(true)),
        PLCTag(name: "Y", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([
            .parallel([
                .instruction(.xic(tag: "A")),
                .instruction(.xic(tag: "B"))
            ]),
            .instruction(.ote(tag: "Y"))
        ]))
    ])
    try engine.scan(routine)
    #expect(try engine.tags.bool("Y") == true)
}

@Test func laterOTEWinsInSameScan() throws {
    let tags = try store(
        PLCTag(name: "A", value: .bool(true)),
        PLCTag(name: "B", value: .bool(false)),
        PLCTag(name: "Motor", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "A")), .instruction(.ote(tag: "Motor"))])),
        Rung(number: 1, logic: .series([.instruction(.xic(tag: "B")), .instruction(.ote(tag: "Motor"))]))
    ])
    try engine.scan(routine)
    #expect(try engine.tags.bool("Motor") == false)
}

@Test func latchRetainsUntilUnlatched() throws {
    let tags = try store(
        PLCTag(name: "Set", value: .bool(true)),
        PLCTag(name: "Reset", value: .bool(false)),
        PLCTag(name: "Alarm", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "Set")), .instruction(.otl(tag: "Alarm"))])),
        Rung(number: 1, logic: .series([.instruction(.xic(tag: "Reset")), .instruction(.otu(tag: "Alarm"))]))
    ])

    try engine.scan(routine)
    #expect(try engine.tags.bool("Alarm") == true)
    try engine.forceInput("Set", value: false)
    try engine.scan(routine)
    #expect(try engine.tags.bool("Alarm") == true)
    try engine.forceInput("Reset", value: true)
    try engine.scan(routine)
    #expect(try engine.tags.bool("Alarm") == false)
}

@Test func analyzerFindsDuplicateDestructiveWrites() {
    let routine = LadderRoutine(rungs: [
        Rung(number: 5, logic: .instruction(.ote(tag: "Motor"))),
        Rung(number: 72, logic: .instruction(.ote(tag: "Motor")))
    ])
    let diagnostics = LadderAnalyzer.analyze(routine)
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0].tag == "Motor")
    #expect(diagnostics[0].rungNumbers == [5, 72])
}

@Test func tonAccumulatesElapsedScanTimeAndResetsWhenFalse() throws {
    let tags = try store(
        PLCTag(name: "Enable", value: .bool(true)),
        PLCTag(name: "T1", value: .timer(TimerValue(PRE: 100)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Enable")), .instruction(.ton(timer: "T1"))
    ]))])

    try engine.scan(routine, elapsedMilliseconds: 40)
    var timer = try engine.tags.timer("T1")
    #expect(timer.ACC == 40 && timer.EN && timer.TT && !timer.DN)

    try engine.scan(routine, elapsedMilliseconds: 60)
    timer = try engine.tags.timer("T1")
    #expect(timer.ACC == 100 && timer.EN && !timer.TT && timer.DN)

    try engine.forceInput("Enable", value: false)
    try engine.scan(routine, elapsedMilliseconds: 10)
    timer = try engine.tags.timer("T1")
    #expect(timer.ACC == 0 && !timer.EN && !timer.TT && !timer.DN)
}

@Test func tofHoldsDoneDuringOffDelayThenClears() throws {
    let tags = try store(
        PLCTag(name: "Enable", value: .bool(true)),
        PLCTag(name: "T1", value: .timer(TimerValue(PRE: 100)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Enable")), .instruction(.tof(timer: "T1"))
    ]))])

    try engine.scan(routine, elapsedMilliseconds: 10)
    #expect(try engine.tags.timer("T1").DN == true)

    try engine.forceInput("Enable", value: false)
    try engine.scan(routine, elapsedMilliseconds: 40)
    var timer = try engine.tags.timer("T1")
    #expect(timer.ACC == 40 && !timer.EN && timer.TT && timer.DN)

    try engine.scan(routine, elapsedMilliseconds: 60)
    timer = try engine.tags.timer("T1")
    #expect(timer.ACC == 100 && !timer.TT && !timer.DN)
}

@Test func rtoRetainsAccumulationUntilRES() throws {
    let tags = try store(
        PLCTag(name: "Enable", value: .bool(true)),
        PLCTag(name: "Reset", value: .bool(false)),
        PLCTag(name: "T1", value: .timer(TimerValue(PRE: 100)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "Enable")), .instruction(.rto(timer: "T1"))])),
        Rung(number: 1, logic: .series([.instruction(.xic(tag: "Reset")), .instruction(.res(tag: "T1"))]))
    ])

    try engine.scan(routine, elapsedMilliseconds: 35)
    try engine.forceInput("Enable", value: false)
    try engine.scan(routine, elapsedMilliseconds: 50)
    #expect(try engine.tags.timer("T1").ACC == 35)

    try engine.forceInput("Reset", value: true)
    try engine.scan(routine, elapsedMilliseconds: 1)
    let timer = try engine.tags.timer("T1")
    #expect(timer.ACC == 0 && !timer.DN && !timer.EN)
}

@Test func ctuCountsOnlyFalseToTrueTransitions() throws {
    let tags = try store(
        PLCTag(name: "Pulse", value: .bool(false)),
        PLCTag(name: "C1", value: .counter(CounterValue(PRE: 2)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Pulse")), .instruction(.ctu(counter: "C1"))
    ]))])

    try engine.scan(routine)
    try engine.forceInput("Pulse", value: true)
    try engine.scan(routine)
    try engine.scan(routine)
    #expect(try engine.tags.counter("C1").ACC == 1)

    try engine.forceInput("Pulse", value: false)
    try engine.scan(routine)
    try engine.forceInput("Pulse", value: true)
    try engine.scan(routine)
    let counter = try engine.tags.counter("C1")
    #expect(counter.ACC == 2 && counter.DN)
}

@Test func ctdCountsDownOnRisingEdges() throws {
    let tags = try store(
        PLCTag(name: "Pulse", value: .bool(false)),
        PLCTag(name: "C1", value: .counter(CounterValue(PRE: 3, ACC: 5)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Pulse")), .instruction(.ctd(counter: "C1"))
    ]))])

    try engine.scan(routine)
    try engine.forceInput("Pulse", value: true)
    try engine.scan(routine)
    #expect(try engine.tags.counter("C1").ACC == 4)
    try engine.forceInput("Pulse", value: false)
    try engine.scan(routine)
    try engine.forceInput("Pulse", value: true)
    try engine.scan(routine)
    let counter = try engine.tags.counter("C1")
    #expect(counter.ACC == 3 && counter.DN)
}

@Test func counterRESClearsAccumulatorAndStatus() throws {
    let tags = try store(
        PLCTag(name: "Reset", value: .bool(true)),
        PLCTag(name: "C1", value: .counter(CounterValue(PRE: 3, ACC: 9, CU: true, CD: true, DN: true, OV: true, UN: true)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Reset")), .instruction(.res(tag: "C1"))
    ]))])
    try engine.scan(routine)
    let counter = try engine.tags.counter("C1")
    #expect(counter.ACC == 0 && !counter.CU && !counter.CD && !counter.DN && !counter.OV && !counter.UN)
}

@Test func onsPulsesForExactlyOneScanPerRisingEdge() throws {
    let tags = try store(
        PLCTag(name: "Input", value: .bool(false)),
        PLCTag(name: "ONSStorage", value: .bool(false)),
        PLCTag(name: "Pulse", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Input")),
        .instruction(.ons(storageTag: "ONSStorage")),
        .instruction(.ote(tag: "Pulse"))
    ]))])

    try engine.forceInput("Input", value: true)
    try engine.scan(routine)
    #expect(try engine.tags.bool("Pulse") == true)
    try engine.scan(routine)
    #expect(try engine.tags.bool("Pulse") == false)
    try engine.forceInput("Input", value: false)
    try engine.scan(routine)
    try engine.forceInput("Input", value: true)
    try engine.scan(routine)
    #expect(try engine.tags.bool("Pulse") == true)
}

@Test func comparisonsAndLIMGateRungPower() throws {
    let tags = try store(
        PLCTag(name: "Value", value: .dint(7)),
        PLCTag(name: "Result", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.geq(.tag("Value"), .dint(5))),
        .instruction(.lim(low: .dint(0), test: .tag("Value"), high: .dint(10))),
        .instruction(.ote(tag: "Result"))
    ]))])
    try engine.scan(routine)
    #expect(try engine.tags.bool("Result") == true)
}

@Test func wrappedLIMAcceptsValuesOutsideReversedBounds() throws {
    let tags = try store(
        PLCTag(name: "Value", value: .dint(95)),
        PLCTag(name: "Result", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .series([
        .instruction(.lim(low: .dint(90), test: .tag("Value"), high: .dint(10))),
        .instruction(.ote(tag: "Result"))
    ]))])
    try engine.scan(routine)
    #expect(try engine.tags.bool("Result") == true)
}

@Test func movAndMathWriteTypedDestinations() throws {
    let tags = try store(
        PLCTag(name: "Source", value: .dint(10)),
        PLCTag(name: "DIntResult", value: .dint(0)),
        PLCTag(name: "RealResult", value: .real(0))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .instruction(.mov(source: .tag("Source"), destination: "DIntResult"))),
        Rung(number: 1, logic: .instruction(.add(.tag("Source"), .real(2.5), destination: "RealResult"))),
        Rung(number: 2, logic: .instruction(.div(.tag("Source"), .dint(4), destination: "DIntResult")))
    ])
    try engine.scan(routine)
    #expect(try engine.tags.real("RealResult") == 12.5)
    #expect(try engine.tags.dint("DIntResult") == 2)
}

@Test func divideByZeroProducesEngineError() throws {
    let tags = try store(PLCTag(name: "Result", value: .real(0)))
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.div(.dint(1), .dint(0), destination: "Result")))])
    #expect(throws: PLCEngineError.divideByZero) { try engine.scan(routine) }
}

@Test func singleRungStepperExposesIntermediateScanState() throws {
    let tags = try store(
        PLCTag(name: "A", value: .bool(true)),
        PLCTag(name: "B", value: .bool(false)),
        PLCTag(name: "C", value: .bool(false))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 10, logic: .series([.instruction(.xic(tag: "A")), .instruction(.ote(tag: "B"))])),
        Rung(number: 20, logic: .series([.instruction(.xic(tag: "B")), .instruction(.ote(tag: "C"))]))
    ])

    var session = try engine.beginScan(routine, elapsedMilliseconds: 5)
    #expect(session.nextRungNumber == 10)
    let first = try engine.step(&session)
    #expect(first?.rungNumber == 10)
    #expect(try engine.tags.bool("B") == true)
    #expect(try engine.tags.bool("C") == false)
    #expect(session.nextRungNumber == 20)

    try engine.step(&session)
    #expect(try engine.tags.bool("C") == true)
    #expect(session.isComplete)
    #expect(engine.finish(session)?.rungs.count == 2)
}

@Test func traceCapturesStructuredTimerTransition() throws {
    let tags = try store(PLCTag(name: "T1", value: .timer(TimerValue(PRE: 50))))
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.ton(timer: "T1")))])
    let trace = try engine.scan(routine, elapsedMilliseconds: 10)
    let change = trace.rungs[0].instructions[0].changes.first
    #expect(change?.tag == "T1")
    #expect(change?.newValue == .timer(TimerValue(PRE: 50, ACC: 10, EN: true, TT: true, DN: false)))
}

@Test func richerAnalyzerFindsMissingTagsAndMixedOutputSemantics() throws {
    let tags = try store(PLCTag(name: "Motor", value: .bool(false)))
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .instruction(.ote(tag: "Motor"))),
        Rung(number: 1, logic: .instruction(.otl(tag: "Motor"))),
        Rung(number: 2, logic: .instruction(.xic(tag: "MissingInput")))
    ])
    let diagnostics = LadderAnalyzer.analyze(routine, tags: tags)
    #expect(diagnostics.contains { $0.code == .multipleWrites && $0.tag == "Motor" })
    #expect(diagnostics.contains { $0.code == .mixedOutputSemantics && $0.tag == "Motor" })
    #expect(diagnostics.contains { $0.code == .missingTag && $0.tag == "MissingInput" })
}

@Test func analyzerFlagsInvalidInstructionTagTypes() throws {
    let tags = try store(PLCTag(name: "Speed", value: .real(12.5)))
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.xic(tag: "Speed")))])
    let diagnostics = LadderAnalyzer.analyze(routine, tags: tags)
    #expect(diagnostics.contains { $0.code == .invalidInstructionType && $0.tag == "Speed" })
}

@Test func invalidNegativeTimerPresetSurfacesControllerStyleFault() throws {
    let tags = try store(PLCTag(name: "BadTimer", value: .timer(TimerValue(PRE: -1))))
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.ton(timer: "BadTimer")))])
    #expect(throws: PLCEngineError.timerFault(tag: "BadTimer", PRE: -1, ACC: 0)) {
        try engine.scan(routine, elapsedMilliseconds: 1)
    }
}

@Test func negativeElapsedScanTimeIsRejected() throws {
    let tags = try store()
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine()
    #expect(throws: PLCEngineError.invalidElapsedTime(-1)) {
        try engine.scan(routine, elapsedMilliseconds: -1)
    }
}

@Test func counterOverflowAndUnderflowBitsAreModeled() throws {
    var upEngine = PLCEngine(tags: try store(PLCTag(name: "C", value: .counter(CounterValue(PRE: 0, ACC: Int32.max)))))
    let up = LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.ctu(counter: "C")))])
    try upEngine.scan(up)
    var c = try upEngine.tags.counter("C")
    #expect(c.ACC == Int32.min && c.OV)

    var downEngine = PLCEngine(tags: try store(PLCTag(name: "C", value: .counter(CounterValue(PRE: 0, ACC: Int32.min)))))
    let down = LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.ctd(counter: "C")))])
    try downEngine.scan(down)
    c = try downEngine.tags.counter("C")
    #expect(c.ACC == Int32.max && c.UN)
}

@Test func prescanSeedsONSAndCounterEdgesWithoutFalseFirstScanEvents() throws {
    let tags = try store(
        PLCTag(name: "Input", value: .bool(true)),
        PLCTag(name: "ONSStorage", value: .bool(false)),
        PLCTag(name: "Pulse", value: .bool(true)),
        PLCTag(name: "C1", value: .counter(CounterValue(PRE: 1)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .series([
            .instruction(.xic(tag: "Input")), .instruction(.ons(storageTag: "ONSStorage")), .instruction(.ote(tag: "Pulse"))
        ])),
        Rung(number: 1, logic: .series([
            .instruction(.xic(tag: "Input")), .instruction(.ctu(counter: "C1"))
        ]))
    ])

    _ = try engine.lifecycleScan(mainRoutine: routine, mode: .prescan)
    #expect(try engine.tags.bool("ONSStorage"))
    #expect(try engine.tags.counter("C1").CU)

    try engine.scan(routine)
    #expect(try engine.tags.bool("Pulse") == false)
    #expect(try engine.tags.counter("C1").ACC == 0)

    try engine.forceInput("Input", value: false)
    try engine.scan(routine)
    try engine.forceInput("Input", value: true)
    try engine.scan(routine)
    #expect(try engine.tags.bool("Pulse") == true)
    #expect(try engine.tags.counter("C1").ACC == 1)
}

@Test func prescanAndPostscanApplyTimerAndOTELifecycleRules() throws {
    let tags = try store(
        PLCTag(name: "Output", value: .bool(true)),
        PLCTag(name: "TON1", value: .timer(TimerValue(PRE: 100, ACC: 80, EN: true, TT: true, DN: true))),
        PLCTag(name: "TOF1", value: .timer(TimerValue(PRE: 100, ACC: 20, EN: true, TT: true, DN: true))),
        PLCTag(name: "RTO1", value: .timer(TimerValue(PRE: 100, ACC: 80, EN: true, TT: true, DN: true)))
    )
    var engine = PLCEngine(tags: tags)
    let routine = LadderRoutine(rungs: [
        Rung(number: 0, logic: .instruction(.ote(tag: "Output"))),
        Rung(number: 1, logic: .instruction(.ton(timer: "TON1"))),
        Rung(number: 2, logic: .instruction(.tof(timer: "TOF1"))),
        Rung(number: 3, logic: .instruction(.rto(timer: "RTO1")))
    ])

    try engine.lifecycleScan(mainRoutine: routine, mode: .prescan)
    #expect(try engine.tags.bool("Output") == false)
    #expect(try engine.tags.timer("TON1") == TimerValue(PRE: 100))
    #expect(try engine.tags.timer("TOF1") == TimerValue(PRE: 100, ACC: 100))
    #expect(try engine.tags.timer("RTO1") == TimerValue(PRE: 100, ACC: 80, EN: false, TT: false, DN: true))

    try engine.scan(routine, elapsedMilliseconds: 50)
    try engine.lifecycleScan(mainRoutine: routine, mode: .postscan)
    #expect(try engine.tags.bool("Output") == false)
    #expect(try engine.tags.timer("TON1") == TimerValue(PRE: 100))
    #expect(try engine.tags.timer("TOF1") == TimerValue(PRE: 100, ACC: 100))
}

@Test func lifecycleJSRPrescansSubroutineOnceAndIgnoresRET() throws {
    let tags = try store(PLCTag(name: "SubOutput", value: .bool(true)))
    var engine = PLCEngine(tags: tags)
    let sub = LadderRoutine(name: "Sub", rungs: [
        Rung(number: 0, logic: .instruction(.ret)),
        Rung(number: 1, logic: .instruction(.ote(tag: "SubOutput")))
    ])
    let main = LadderRoutine(name: "Main", rungs: [
        Rung(number: 0, logic: .instruction(.jsr(routine: "Sub"))),
        Rung(number: 1, logic: .instruction(.jsr(routine: "Sub")))
    ])

    let trace = try engine.lifecycleScan(mainRoutine: main, routines: [sub], mode: .prescan)
    #expect(trace.routineNames == ["Main", "Sub"])
    #expect(try engine.tags.bool("SubOutput") == false)
}

@Test func programScopedTagShadowsControllerScopedTag() throws {
    let controllerTags = try store(
        PLCTag(name: "State", value: .bool(false)),
        PLCTag(name: "Output", value: .bool(false))
    )
    let localTags = try store(PLCTag(name: "State", value: .bool(true)))
    let main = LadderRoutine(name: "Main", rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "State")), .instruction(.ote(tag: "Output"))
    ]))])
    let program = ControllerProgram(name: "P1", mainRoutineName: "Main", routines: [main], tags: localTags)
    let task = ControllerTask(name: "MainTask", programs: [program])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: controllerTags, tasks: [task]))

    try runtime.setMode(.run)
    try runtime.scan()
    #expect(try runtime.project.controllerTags.bool("State") == false)
    #expect(try runtime.project.tasks[0].programs[0].tags.bool("State") == true)
    #expect(try runtime.project.controllerTags.bool("Output") == true)
}

@Test func controllerExecutesJSRAndRETInRoutineCallOrder() throws {
    let tags = try store(
        PLCTag(name: "Call", value: .bool(true)),
        PLCTag(name: "SubRan", value: .bool(false)),
        PLCTag(name: "After", value: .bool(false))
    )
    let sub = LadderRoutine(name: "Sub", rungs: [
        Rung(number: 0, logic: .instruction(.ote(tag: "SubRan"))),
        Rung(number: 1, logic: .instruction(.ret)),
        Rung(number: 2, logic: .instruction(.otu(tag: "SubRan")))
    ])
    let main = LadderRoutine(name: "Main", rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "Call")), .instruction(.jsr(routine: "Sub"))])),
        Rung(number: 1, logic: .instruction(.ote(tag: "After")))
    ])
    let program = ControllerProgram(name: "P1", mainRoutineName: "Main", routines: [main, sub])
    let task = ControllerTask(name: "MainTask", programs: [program])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [task]))

    try runtime.setMode(.run)
    let trace = try runtime.scan()
    #expect(try runtime.project.controllerTags.bool("SubRan") == true)
    #expect(try runtime.project.controllerTags.bool("After") == true)
    #expect(trace.programs[0].routineTraces.contains { $0.routineName == "Sub" })
}

@Test func debugStepperWalksIntoJSRAndBackToCallerOneRungAtATime() throws {
    let tags = try store(
        PLCTag(name: "A", value: .bool(false)),
        PLCTag(name: "B", value: .bool(false))
    )
    let sub = LadderRoutine(name: "Sub", rungs: [Rung(number: 100, logic: .instruction(.ote(tag: "A")))])
    let main = LadderRoutine(name: "Main", rungs: [
        Rung(number: 10, logic: .instruction(.jsr(routine: "Sub"))),
        Rung(number: 20, logic: .instruction(.ote(tag: "B")))
    ])
    let program = ControllerProgram(name: "P1", mainRoutineName: "Main", routines: [main, sub])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [ControllerTask(name: "MainTask", programs: [program])]))
    try runtime.setMode(.run)

    var session = try runtime.beginDebugScan(taskName: "MainTask", programName: "P1")
    let s1 = try runtime.stepDebug(&session)
    #expect(s1?.routineName == "Main" && s1?.rungNumber == 10)
    #expect(s1?.nextRoutineName == "Sub" && s1?.nextRungNumber == 100)
    #expect(try runtime.project.controllerTags.bool("A") == false)

    let s2 = try runtime.stepDebug(&session)
    #expect(s2?.routineName == "Sub" && s2?.rungNumber == 100)
    #expect(try runtime.project.controllerTags.bool("A") == true)
    #expect(s2?.nextRoutineName == "Main" && s2?.nextRungNumber == 20)

    let s3 = try runtime.stepDebug(&session)
    #expect(s3?.routineName == "Main" && s3?.rungNumber == 20)
    #expect(try runtime.project.controllerTags.bool("B") == true)
    #expect(session.isComplete)
}

@Test func forceTableSeparatesForcedInputAndPhysicalOutputFromLogicState() throws {
    let tags = try store(
        PLCTag(name: "Input", value: .bool(false)),
        PLCTag(name: "Output", value: .bool(false))
    )
    let main = LadderRoutine(name: "Main", rungs: [Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "Input")), .instruction(.ote(tag: "Output"))
    ]))])
    let program = ControllerProgram(name: "P1", mainRoutineName: "Main", routines: [main])
    var forces = ForceTable(masterEnabled: true)
    forces.set(ForceEntry(tag: "Input", value: .bool(true), kind: .input))
    forces.set(ForceEntry(tag: "Output", value: .bool(false), kind: .output))
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [ControllerTask(name: "MainTask", programs: [program])]), forces: forces)

    try runtime.setMode(.run)
    try runtime.scan()
    #expect(try runtime.project.controllerTags.bool("Input") == false)
    #expect(try runtime.project.controllerTags.bool("Output") == true)
    #expect(try runtime.effectiveOutputValue(controllerTag: "Output") == .bool(false))
}

@Test func taskWatchdogCreatesMajorControllerFaultDeterministically() throws {
    let tags = try store(
        PLCTag(name: "A", value: .bool(false)),
        PLCTag(name: "B", value: .bool(false))
    )
    let main = LadderRoutine(name: "Main", rungs: [
        Rung(number: 0, logic: .instruction(.ote(tag: "A"))),
        Rung(number: 1, logic: .instruction(.ote(tag: "B")))
    ])
    let program = ControllerProgram(name: "P1", mainRoutineName: "Main", routines: [main])
    let task = ControllerTask(name: "FastTask", watchdogMilliseconds: 1, programs: [program])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [task]))
    try runtime.setMode(.run)

    #expect(throws: ControllerFault.self) {
        try runtime.scan(simulatedRungCostMicroseconds: 600)
    }
    #expect(runtime.majorFault?.code == .watchdog)
}

@Test func periodicTaskRunsOnlyWhenItsPeriodIsDue() throws {
    let tags = try store(PLCTag(name: "Tick", value: .bool(false)))
    let main = LadderRoutine(name: "Main", rungs: [Rung(number: 0, logic: .instruction(.ote(tag: "Tick")))])
    let program = ControllerProgram(name: "PeriodicProgram", mainRoutineName: "Main", routines: [main])
    let task = ControllerTask(name: "P10", kind: .periodic(periodMilliseconds: 10, priority: 5), programs: [program])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [task]))
    try runtime.setMode(.run)

    let first = try runtime.scan(elapsedMilliseconds: 5)
    #expect(first.programs.isEmpty)
    let second = try runtime.scan(elapsedMilliseconds: 5)
    #expect(second.programs.count == 1)
}

@Test func inhibitedTaskIsStillPrescannedOnProgramToRunTransition() throws {
    let tags = try store(PLCTag(name: "Output", value: .bool(true)))
    let main = LadderRoutine(name: "Main", rungs: [Rung(number: 0, logic: .instruction(.ote(tag: "Output")))])
    let program = ControllerProgram(name: "P1", mainRoutineName: "Main", routines: [main])
    let task = ControllerTask(name: "Inhibited", inhibited: true, programs: [program])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [task]))

    try runtime.setMode(.run)
    #expect(try runtime.project.controllerTags.bool("Output") == false)
    let trace = try runtime.scan()
    #expect(trace.programs.isEmpty)
}

@Test func powerTraceRecordsEveryASTNodeAndParallelBranch() throws {
    let tags = try TagStore(tags: [
        PLCTag(name: "A", value: .bool(true)),
        PLCTag(name: "B", value: .bool(false)),
        PLCTag(name: "C", value: .bool(true)),
        PLCTag(name: "Y", value: .bool(false))
    ])
    let rung = Rung(number: 0, logic: .series([
        .instruction(.xic(tag: "A")),
        .parallel([
            .instruction(.xic(tag: "B")),
            .instruction(.xic(tag: "C"))
        ]),
        .instruction(.ote(tag: "Y"))
    ]))
    var engine = PLCEngine(tags: tags)
    let trace = try engine.scan(LadderRoutine(rungs: [rung]))
    let rt = trace.rungs[0]

    #expect(rt.power(at: "root.s0")?.outgoingCondition == true)
    #expect(rt.power(at: "root.s1.p0")?.outgoingCondition == false)
    #expect(rt.power(at: "root.s1.p1")?.outgoingCondition == true)
    #expect(rt.power(at: "root.s1.branch0")?.outgoingCondition == false)
    #expect(rt.power(at: "root.s1.branch1")?.outgoingCondition == true)
    #expect(rt.power(at: "root.s1")?.outgoingCondition == true)
    #expect(rt.instruction(at: "root.s2")?.mnemonic == "OTE")
}

@Test func instructionTraceCapturesOperandValueAtExecutionTime() throws {
    let tags = try TagStore(tags: [PLCTag(name: "PE203", value: .bool(true))])
    var engine = PLCEngine(tags: tags)
    let trace = try engine.scan(LadderRoutine(rungs: [Rung(number: 0, logic: .instruction(.xio(tag: "PE203")))]))
    let instruction = trace.rungs[0].instructions[0]
    #expect(instruction.nodePath == "root")
    #expect(instruction.observations.first?.label == "PE203")
    #expect(instruction.observations.first?.value == .bool(true))
}

@Test func firstScanFlagExecutesForOneProgramScanAfterPrescan() throws {
    let tags = try TagStore(tags: [PLCTag(name: "SeenFirst", value: .bool(false), role: .output)])
    let main = LadderRoutine(name: "MainRoutine", rungs: [
        Rung(number: 0, logic: .series([.instruction(.xic(tag: "S:FS")), .instruction(.ote(tag: "SeenFirst"))]))
    ])
    let program = ControllerProgram(name: "P", routines: [main])
    let task = ControllerTask(name: "T", programs: [program])
    var runtime = ControllerRuntime(project: ControllerProject(controllerTags: tags, tasks: [task]))

    try runtime.setMode(.run)
    #expect(runtime.lifecycleHistory.last?.trace.mode == .prescan)
    #expect(runtime.isFirstScanPending(taskName: "T", programName: "P"))

    let first = try runtime.scan()
    #expect(first.programs[0].isFirstScan)
    #expect(try runtime.project.controllerTags.bool("SeenFirst") == true)

    let second = try runtime.scan()
    #expect(!second.programs[0].isFirstScan)
    #expect(try runtime.project.controllerTags.bool("SeenFirst") == false)
}

import Foundation
import ControlsPLC

public enum DemoProjectFactory {
    public static func packagingCell() throws -> ControllerProject {
        let controllerTags = try TagStore(tags: [
            PLCTag(name: "Start_PB", value: .bool(false), description: "Momentary operator start pushbutton", role: .input),
            PLCTag(name: "Stop_OK", value: .bool(true), description: "Healthy stop circuit", role: .input),
            PLCTag(name: "PE203", value: .bool(false), description: "Transfer photoeye", role: .input),
            PLCTag(name: "Motor_Run", value: .bool(false), description: "Conveyor motor command", role: .output),
            PLCTag(name: "TransferCmd", value: .bool(false), description: "Transfer conveyor command", role: .output),
            PLCTag(name: "State", value: .dint(30), description: "Automatic sequence state"),
            PLCTag(name: "TransferDelay", value: .timer(TimerValue(PRE: 1500)), description: "Transfer clear delay"),
            PLCTag(name: "BoxCount", value: .counter(CounterValue(PRE: 12)), description: "Completed boxes")
        ])

        let main = LadderRoutine(name: "MainRoutine", rungs: [
            Rung(number: 0, comment: "Run permissive", logic: .series([
                .instruction(.xic(tag: "Start_PB")),
                .instruction(.xic(tag: "Stop_OK")),
                .instruction(.ote(tag: "Motor_Run"))
            ])),
            Rung(number: 10, comment: "Evaluate automatic sequence", logic: .series([
                .instruction(.xic(tag: "Motor_Run")),
                .instruction(.jsr(routine: "StateLogic"))
            ])),
            Rung(number: 20, comment: "Count completed transfers", logic: .series([
                .instruction(.xic(tag: "TransferCmd")),
                .instruction(.ctu(counter: "BoxCount"))
            ]))
        ])

        let stateLogic = LadderRoutine(name: "StateLogic", rungs: [
            Rung(number: 100, comment: "State 30 waits for PE203 to clear", logic: .series([
                .instruction(.equ(.tag("State"), .dint(30))),
                .instruction(.xio(tag: "PE203")),
                .instruction(.ton(timer: "TransferDelay"))
            ])),
            Rung(number: 110, comment: "Advance when the clear delay is complete", logic: .series([
                .instruction(.equ(.tag("State"), .dint(30))),
                .instruction(.xic(tag: "TransferDelay.DN")),
                .instruction(.mov(source: .dint(40), destination: "State"))
            ])),
            Rung(number: 120, comment: "State 40 commands transfer", logic: .series([
                .instruction(.equ(.tag("State"), .dint(40))),
                .instruction(.ote(tag: "TransferCmd"))
            ])),
            Rung(number: 130, comment: "Return to caller", logic: .instruction(.ret))
        ])

        let program = ControllerProgram(
            name: "Packaging",
            mainRoutineName: "MainRoutine",
            routines: [main, stateLogic]
        )
        let task = ControllerTask(name: "MainTask", kind: .continuous, watchdogMilliseconds: 500, programs: [program])
        return ControllerProject(name: "Packaging Cell Trainer", controllerTags: controllerTags, tasks: [task])
    }
}

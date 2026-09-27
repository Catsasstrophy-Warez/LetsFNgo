import ControlsPLC
import ControlsReasoning
import Foundation
import NexusSimulation

/// "Why isn't X on?" questions over small generated permissive chains,
/// answered by the trainer's `CausalJournal` from one recorded scan.
///
/// Each routine has zero to two intermediate permissive rungs (series XIC/XIO
/// contacts driving an OTE) feeding a final rung that drives the output. Input
/// values are drawn so some permissives are unsatisfied, and the output is
/// always off.
enum LadderExamples {
    /// Normally-true conditions, examined with XIC.
    static let permissives = [
        "GuardDoor_Closed", "EStop_OK", "Auto_Mode", "VFD_Ready", "AirPressure_OK", "LubeLevel_OK", "HydPump_Running",
        "Conveyor_Clear", "Part_Present", "Clamp_Closed", "Robot_Home", "LightCurtain_OK", "OilTemp_OK", "Door_Locked",
    ]
    /// Normally-false conditions, examined with XIO.
    static let faults = ["Motor_Overload", "Jam_Detected", "Low_Air", "High_Temp", "Drive_Fault", "Estop_Pressed", "Guard_Open"]
    static let outputs = ["Motor_Run", "Conveyor_Run", "Pump_Start", "Clamp_Solenoid", "Spindle_Enable", "Fan_Run"]
    static let intermediates = ["Safety_OK", "Ready_Perm", "Auto_Perm", "Guard_Perm"]
    static let scanTime = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct Contact {
        var tag: String
        /// XIC when true, XIO when false.
        var examinesOn: Bool

        var instruction: Instruction { examinesOn ? .xic(tag: tag) : .xio(tag: tag) }
        var text: String { examinesOn ? "XIC(\(tag))" : "XIO(\(tag))" }
    }

    struct Program {
        var rungs: [(number: Int, contacts: [Contact], coil: String)]
        var inputs: [String: Bool]
        var output: String
        var routine: String
    }

    static func shuffled<T>(_ items: [T], _ rng: inout SplitMix64) -> [T] {
        var items = items
        for index in stride(from: items.count - 1, to: 0, by: -1) {
            items.swapAt(index, rng.nextInt(below: index + 1))
        }
        return items
    }

    static func program(_ rng: inout SplitMix64) -> Program {
        var permissivePool = shuffled(permissives, &rng)
        var faultPool = shuffled(faults, &rng)
        let intermediateNames = shuffled(intermediates, &rng)
        let output = rng.pick(outputs)
        var inputs: [String: Bool] = [:]

        func contact() -> Contact {
            if faultPool.isEmpty || (!permissivePool.isEmpty && rng.chance(0.7)) {
                let tag = permissivePool.removeLast()
                inputs[tag] = rng.chance(0.75)
                return Contact(tag: tag, examinesOn: true)
            }
            let tag = faultPool.removeLast()
            inputs[tag] = rng.chance(0.2)
            return Contact(tag: tag, examinesOn: false)
        }

        var rungs: [(number: Int, contacts: [Contact], coil: String)] = []
        let intermediateCount = rng.nextInt(below: 3)
        for index in 0..<intermediateCount {
            let contacts = (0..<(2 + rng.nextInt(below: 2))).map { _ in contact() }
            rungs.append((index * 10, contacts, intermediateNames[index]))
        }
        var last = rungs.map { Contact(tag: $0.coil, examinesOn: true) }
        last += (0..<(1 + rng.nextInt(below: 2))).map { _ in contact() }
        rungs.append((intermediateCount * 10, shuffled(last, &rng), output))
        return Program(rungs: rungs, inputs: inputs, output: output, routine: "\(output.replacingOccurrences(of: "_", with: ""))Logic")
    }

    static func routine(_ program: Program) -> LadderRoutine {
        LadderRoutine(name: program.routine, rungs: program.rungs.map { rung in
            Rung(number: rung.number, logic: .series(rung.contacts.map { .instruction($0.instruction) } + [.instruction(.ote(tag: rung.coil))]))
        })
    }

    static func scan(_ program: Program) throws -> (journal: CausalJournal, outputOn: Bool) {
        var tags = program.inputs.keys.sorted().map { PLCTag(name: $0, value: .bool(program.inputs[$0]!), role: .input) }
        tags += program.rungs.map { PLCTag(name: $0.coil, value: .bool(false), role: $0.coil == program.output ? .output : .internalValue) }
        var engine = PLCEngine(tags: try TagStore(tags: tags))
        let ladder = routine(program)
        var journal = CausalJournal()
        // Two recorded scans: the earlier one is the history that lets the
        // journal prove an input was never written by the program.
        for scanNumber in 1...2 {
            let scan = try engine.scan(ladder, startedAt: scanTime.addingTimeInterval(Double(scanNumber) * 0.01))
            for (index, trace) in scan.rungs.enumerated() {
                journal.ingest(CausalExecutionRecord(
                    scanNumber: UInt64(scanNumber), stepIndex: index + 1, taskName: "MainTask", programName: "MainProgram",
                    routineName: program.routine, rungNumber: trace.rungNumber, trace: trace
                ))
            }
        }
        let on = try engine.tags.value(for: program.output).boolValue ?? false
        return (journal, on)
    }

    static func example(seed: UInt64, id: String, split: DatasetSplit) throws -> TrainingExample {
        var rng = SplitMix64(seed: SplitMix64.mix(seed ^ 0x6C61_6464_6572))
        var program = program(&rng)
        var result = try scan(program)
        // Force a blocked output: flip one satisfied input contact until the output is off.
        while result.outputOn {
            let contacts = program.rungs.flatMap(\.contacts).filter { program.inputs[$0.tag] != nil }
            let chosen = contacts[rng.nextInt(below: contacts.count)]
            program.inputs[chosen.tag] = !chosen.examinesOn
            result = try scan(program)
        }

        let trail = result.journal.explainWhy(target: program.output, shouldBe: .bool(true), observedValue: .bool(false))
        let report = result.journal.diagnose(target: program.output, shouldBe: .bool(true), observedValue: .bool(false))
        let root = trail.steps.last!
        let blockers = (report.confirmedBlockers + report.contributingConditions).map(\.target)
        let unsatisfiedInputs = program.rungs.flatMap(\.contacts)
            .filter { contact in program.inputs[contact.tag].map { $0 != contact.examinesOn } ?? false }
            .map(\.tag)

        let rungText = program.rungs.map { rung in
            LadderRungExample(number: rung.number, text: (rung.contacts.map(\.text) + ["OTE(\(rung.coil))"]).joined(separator: " "))
        }
        let inputNames = program.inputs.keys.sorted()
        let prompt = "Why isn't \(program.output) on?\nRoutine \(program.routine):\n"
            + rungText.map { "Rung \($0.number): \($0.text)" }.joined(separator: "\n")
            + "\nInput tags (recorded from the controller): "
            + inputNames.map { "\($0) = \(program.inputs[$0]! ? "TRUE" : "FALSE")" }.joined(separator: ", ")

        var text = "\(program.output) is off. "
        text += trail.steps.dropFirst().map(\.headline).joined(separator: " → ") + ". "
        text += trail.reachedRootCondition ? "Root condition: \(root.target) (recorded from the controller). " : "The trail does not reach a unique root condition. "
        let others = unsatisfiedInputs.filter { $0 != root.target }
        if !others.isEmpty {
            text += "Also unsatisfied: \(others.joined(separator: ", ")). "
        }
        if let check = report.recommendedNextCheck {
            text += "Next check: \(check)"
        }

        return TrainingExample(
            id: id, kind: .ladderWhy, split: split, seed: seed, prompt: prompt,
            observations: inputNames.map { name in
                ObservationExample(
                    name: name, object: program.routine, value: program.inputs[name]! ? 1 : 0, unit: "bool",
                    truth: .recorded, source: "controller tag table"
                )
            },
            tests: nil, hypotheses: nil, scenario: nil, messages: nil,
            ladder: LadderContextExample(routine: program.routine, rungs: rungText, target: program.output),
            answer: AnswerKey(
                cause: root.target, nextTest: nil, text: text.trimmingCharacters(in: .whitespaces), ranking: nil, expertPath: nil,
                firstDivergence: nil,
                trail: trail.steps.map { TrailStepExample(kind: $0.kind.rawValue, target: $0.target, headline: $0.headline) },
                blockers: blockers
            )
        )
    }
}

import Foundation

public struct StepByStepTeachingScaffold: Equatable, Sendable {
    public var predictionPrompt: String
    public var commonMistakes: [String]
    public var practiceChallenge: String
    public var proofOfLearning: String
}

public enum StepByStepPedagogy {
    public static func scaffold(for lesson: StepByStepLesson) -> StepByStepTeachingScaffold {
        let generic = StepByStepTeachingScaffold(
            predictionPrompt: "Before you run anything, predict the important tag or rung state and explain why.",
            commonMistakes: ["Copying the reference without tracing rung power.", "Changing several things at once instead of proving one behavior."],
            practiceChallenge: "Rebuild the same concept with different tag names or on another machine function without copying the reference rung.",
            proofOfLearning: "Run the program, compare evidence with your prediction, then explain the result in your own words."
        )
        switch lesson.id {
        case "foundation-scan":
            return .init(predictionPrompt:"If a field input changes just after the task scan, when can this routine first react?", commonMistakes:["Thinking ladder runs only when an input changes.", "Treating field state and controller-visible input state as identical at every instant."], practiceChallenge:"Describe one scan of a conveyor photoeye changing from false to true.", proofOfLearning:"Correctly order input visibility, rung execution and output update for one scan.")
        case "foundation-tags":
            return .init(predictionPrompt:"Which type would you choose for a pushbutton, product count and pressure value?", commonMistakes:["Using REAL for every numeric value.", "Naming tags after addresses instead of machine meaning."], practiceChallenge:"Design five tags for a small tank: start, pump command, level, batch count and fill timer.", proofOfLearning:"Choose suitable data types and explain whether each tag is input-facing, output-facing or internal.")
        case "foundation-first-rung":
            return .init(predictionPrompt:"With Start_PB false, then true, what will Motor_Run be after each scan?", commonMistakes:["Reading XIC as a drawing of a physical normally-open contact.", "Assuming OTE proves the real motor is running."], practiceChallenge:"Build a Lamp_Test input driving a Panel_Lamp output.", proofOfLearning:"Build, run and explain the XIC/OTE rung without viewing the reference first.")
        case "digital-xic-xio":
            return .init(predictionPrompt:"For bit states TRUE and FALSE, write the XIC and XIO result table before running.", commonMistakes:["Equating XIO with a physically normally-closed device.", "Ignoring incoming rung condition."], practiceChallenge:"Write Ready = Guard_OK AND NOT Faulted using XIC/XIO.", proofOfLearning:"Correctly predict all four XIC/XIO bit-state cases and explain them from tag truth.")
        case "digital-command-feedback":
            return .init(predictionPrompt:"If Motor_RunCmd is true but the auxiliary contact never changes, what has and has not been proven?", commonMistakes:["Using one BOOL for command and status.", "Treating an energized OTE as proof of physical motion."], practiceChallenge:"Create Valve_OpenCmd and Valve_OpenFB and describe a failed-to-open condition.", proofOfLearning:"Demonstrate a command-present/feedback-absent case and explain the diagnostic meaning.")
        case "digital-motor-seal":
            return .init(predictionPrompt:"After Start_PB is released, which parallel path keeps the rung true?", commonMistakes:["Putting Start and seal contacts in series.", "Putting Stop_OK inside only one branch."], practiceChallenge:"Build the same seal-in for a fan with different tags.", proofOfLearning:"Start, seal, release Start, then stop the motor while explaining each power path.")
        case "sequence-timer-counter":
            return .init(predictionPrompt:"What happens to TON ACC and DN if its enable goes false before PRE? What makes CTU increment?", commonMistakes:["Assuming CTU increments every scan while true.", "Using a timer done bit as the sequence state itself."], practiceChallenge:"Add a second timed state and predict its transitions.", proofOfLearning:"Predict and verify timer/counter/state behavior over several scans.")
        case "analog-input-scaling":
            return .init(predictionPrompt:"What engineering value should raw minimum, midpoint and raw maximum produce?", commonMistakes:["Overwriting the raw input.", "Using integer math where fractional scaling is required."], practiceChallenge:"Scale a 4–20 mA-style raw range into 0–300 psi using different constants.", proofOfLearning:"Calculate endpoint and midpoint values by hand, then verify them in the runtime.")
        case "comm-io-rpi":
            return .init(predictionPrompt:"Can a 10 ms physical pulse be guaranteed visible with a 20 ms I/O update and independent task timing?", commonMistakes:["Calling RPI the PLC scan time.", "Assuming every field transition becomes ladder evidence."], practiceChallenge:"Compare 10 ms, 20 ms and 50 ms update periods for the same short pulse.", proofOfLearning:"Explain source change, network/module update and task execution as three separate times.")
        case "historian-points-scan":
            return .init(predictionPrompt:"Will an 80 ms event always appear in a historian sampled every 1 second?", commonMistakes:["Using historian data as if it were scan-level evidence.", "Ignoring timestamp and quality."], practiceChallenge:"Choose collection periods for pressure, machine state and a 12 ms diagnostic pulse.", proofOfLearning:"Choose historian versus flight recorder correctly for fast faults and long degradation trends.")
        case "foundation-logix-tasks":
            return .init(predictionPrompt:"A 10 ms periodic task and a 50 ms periodic task both come due while the continuous task is running. In what order do they execute?", commonMistakes:["Calling the continuous task 'the scan' and assuming fixed timing.", "Putting time-critical interlocks in the continuous task."], practiceChallenge:"Assign a period and priority to interlock logic, a bottle-fill sequence, and a PID loop, and justify each.", proofOfLearning:"Explain task preemption, name where a given block of logic should run, and describe a task overlap and its fix.")
        case "foundation-instruction-families":
            return .init(predictionPrompt:"For a TON whose enable goes false at .ACC = 300 with .PRE = 500, what are .ACC and .DN on the next scan?", commonMistakes:["Assuming CTU increments every scan its rung is true.", "Using integer math where a fraction is required, or forgetting DIV truncates."], practiceChallenge:"Pick one instruction for: a band test, an expression result, a masked bit update, an atomic structure copy.", proofOfLearning:"Name a family for each task and recall its key timing trap.")
        case "digital-one-shots":
            return .init(predictionPrompt:"Start_Request stays true for 12 scans. How many times does the ONS-gated action run — with the one-shot, and without it?", commonMistakes:["Sharing one storage bit between two ONS instructions.", "Using a level contact where an edge is required, so an action repeats every scan."], practiceChallenge:"Detect the falling edge of a guard-closed signal to trigger a single re-home command.", proofOfLearning:"Choose ONS vs OSR/OSF based on whether other rungs need the pulse, and explain why storage bits must be unique.")
        case "sequence-retentive-timers":
            return .init(predictionPrompt:"A motor runs 3 min, stops 1 min, runs 2 min. What does an RTO show vs a TON on the same rung?", commonMistakes:["Expecting an RTO to reset itself when the rung goes false.", "Clearing the accumulator with a stray RES and losing run-hours history."], practiceChallenge:"Track cumulative fault time across many separate trips and flag it at a threshold.", proofOfLearning:"Explain RTO vs TON on a false rung and describe a deliberate, gated RES.")
        case "comm-io-catalog":
            return .init(predictionPrompt:"A 3-wire PNP proximity sensor is wired to a 1756-IV16. Does the input work? Why or why not?", commonMistakes:["Confusing sinking/sourcing at the module vs PNP/NPN at the sensor.", "Leaving an analog output's connection-loss behavior unconfigured so a valve freezes instead of failing safe."], practiceChallenge:"Choose modules for: a 230 V AC float switch, a loop-powered 4–20 mA transmitter, a 3-wire RTD, and a modulating control valve.", proofOfLearning:"Decode a 1756 catalog number and state the channel configuration and safe-state decision before commissioning.")
        default: return generic
        }
    }
}

public struct StepByStepCurriculumAuditFinding: Equatable, Sendable {
    public enum Severity: String, Sendable { case warning, failure }
    public var severity: Severity
    public var lessonID: String
    public var message: String
}

public enum StepByStepCurriculumAuditor {
    public static func audit(_ lessons: [StepByStepLesson] = StepByStepCatalog.all) -> [StepByStepCurriculumAuditFinding] {
        var findings: [StepByStepCurriculumAuditFinding] = []
        let ids = lessons.map(\.id)
        if Set(ids).count != ids.count { findings.append(.init(severity:.failure, lessonID:"catalog", message:"Lesson IDs must be unique.")) }
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        for lesson in lessons {
            if lesson.objectives.isEmpty || lesson.steps.isEmpty { findings.append(.init(severity:.failure, lessonID:lesson.id, message:"Every lesson needs objectives and actionable steps.")) }
            if lesson.steps.contains(where: { $0.whyItMatters.isEmpty || $0.checkpoint.isEmpty }) { findings.append(.init(severity:.failure, lessonID:lesson.id, message:"Every build step needs why-it-matters and a checkpoint.")) }
            let scaffold = StepByStepPedagogy.scaffold(for: lesson)
            if scaffold.predictionPrompt.isEmpty || scaffold.commonMistakes.isEmpty || scaffold.practiceChallenge.isEmpty || scaffold.proofOfLearning.isEmpty { findings.append(.init(severity:.failure, lessonID:lesson.id, message:"Prediction, mistakes, transfer practice and proof are mandatory.")) }
            for prereq in StepByStepCatalog.prerequisites(for: lesson.id) {
                guard let p = positions[prereq] else { findings.append(.init(severity:.failure, lessonID:lesson.id, message:"Missing prerequisite \(prereq).")); continue }
                if let here = positions[lesson.id], p >= here { findings.append(.init(severity:.failure, lessonID:lesson.id, message:"Prerequisite \(prereq) must appear earlier.")) }
            }
        }
        if lessons.last?.id != "capstone-networked-pump" { findings.append(.init(severity:.failure, lessonID:"catalog", message:"Capstone must be last.")) }
        return findings
    }
}

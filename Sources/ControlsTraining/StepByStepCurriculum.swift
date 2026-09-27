import Foundation
import ControlsPLC
import ControlsSimulation

public enum StepByStepTrack: String, Codable, CaseIterable, Sendable {
    case foundations
    case digitalIO
    case analogIO
    case sequencing
    case communications
    case historian

    public var title: String {
        switch self {
        case .foundations: "PLC Foundations"
        case .digitalIO: "Digital I/O"
        case .analogIO: "Analog I/O"
        case .sequencing: "Sequencing & Interlocks"
        case .communications: "Communications"
        case .historian: "Historian & Data"
        }
    }
}

public enum StepByStepDifficulty: String, Codable, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced
}

public enum StepByStepLabKind: Codable, Equatable, Sendable {
    case ladder
    case ioTiming
    case producedConsumed
    case cipMessageRead
    case cipMessageWrite
    case hmiPolling
    case historianScan
    case integratedCapstone
}

public struct StepByStepBuildStep: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var instruction: String
    public var whyItMatters: String
    public var checkpoint: String

    public init(_ id: String, title: String, instruction: String, whyItMatters: String, checkpoint: String) {
        self.id = id; self.title = title; self.instruction = instruction; self.whyItMatters = whyItMatters; self.checkpoint = checkpoint
    }
}

public struct StepByStepReferenceRung: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var rungNumber: Int
    public var purpose: String
    public var ladderText: String
    public var explanation: String

    public init(_ id: String, rungNumber: Int, purpose: String, ladderText: String, explanation: String) {
        self.id = id; self.rungNumber = rungNumber; self.purpose = purpose; self.ladderText = ladderText; self.explanation = explanation
    }
}

public struct StepByStepLesson: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var track: StepByStepTrack
    public var difficulty: StepByStepDifficulty
    public var estimatedMinutes: Int
    public var summary: String
    public var objectives: [String]
    public var tagsToCreate: [String]
    public var steps: [StepByStepBuildStep]
    public var referenceRungs: [StepByStepReferenceRung]
    public var labKind: StepByStepLabKind
    public var fieldNote: String

    public init(id: String, title: String, track: StepByStepTrack, difficulty: StepByStepDifficulty, estimatedMinutes: Int, summary: String, objectives: [String], tagsToCreate: [String], steps: [StepByStepBuildStep], referenceRungs: [StepByStepReferenceRung], labKind: StepByStepLabKind = .ladder, fieldNote: String = "") {
        self.id=id; self.title=title; self.track=track; self.difficulty=difficulty; self.estimatedMinutes=estimatedMinutes; self.summary=summary; self.objectives=objectives; self.tagsToCreate=tagsToCreate; self.steps=steps; self.referenceRungs=referenceRungs; self.labKind=labKind; self.fieldNote=fieldNote
    }
}

public struct StepByStepLessonSession: Codable, Equatable, Sendable {
    public var lessonID: String
    public private(set) var revealedStepCount: Int
    public private(set) var completedCheckpoints: Set<String>
    public private(set) var prediction: String
    public private(set) var transferResponse: String

    public init(lessonID: String, revealedStepCount: Int = 1, completedCheckpoints: Set<String> = [], prediction: String = "", transferResponse: String = "") {
        self.lessonID = lessonID
        self.revealedStepCount = max(1, revealedStepCount)
        self.completedCheckpoints = completedCheckpoints
        self.prediction = prediction
        self.transferResponse = transferResponse
    }

    public mutating func revealNext(in lesson: StepByStepLesson) {
        revealedStepCount = min(lesson.steps.count, revealedStepCount + 1)
    }

    public mutating func markCheckpoint(_ stepID: String, complete: Bool = true) {
        if complete { completedCheckpoints.insert(stepID) } else { completedCheckpoints.remove(stepID) }
    }

    public mutating func recordPrediction(_ text: String) { prediction = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public mutating func recordTransferResponse(_ text: String) { transferResponse = text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func isComplete(_ lesson: StepByStepLesson) -> Bool {
        !lesson.steps.isEmpty
        && lesson.steps.allSatisfy { completedCheckpoints.contains($0.id) }
        && !prediction.isEmpty
        && !transferResponse.isEmpty
    }
}

public struct StepByStepLabOutcome: Equatable, Sendable {
    public var title: String
    public var observations: [String]
    public var passed: Bool

    public init(title: String, observations: [String], passed: Bool) {
        self.title = title; self.observations = observations; self.passed = passed
    }
}

public enum StepByStepLabRunner {
    public static func run(_ lesson: StepByStepLesson) -> StepByStepLabOutcome {
        switch lesson.labKind {
        case .ioTiming:
            var runtime = IndustrialCommunicationRuntime(configuration: .init(kind: .etherNetIPIO, updatePeriodMilliseconds: 20), remoteTags: ["Local:1:I.Data.0": 0])
            runtime.setRemote("Local:1:I.Data.0", value: 1)
            runtime.step(milliseconds: 19)
            let before = runtime.localTags["Local:1:I.Data.0"] ?? 0
            runtime.step(milliseconds: 1)
            let after = runtime.localTags["Local:1:I.Data.0"] ?? 0
            return .init(title: "Cyclic I/O timing", observations: ["At 19 ms the controller-side value is \(before).", "At the 20 ms update boundary it becomes \(after).", "The lab separates physical/source change time from controller-visible update time."], passed: before == 0 && after == 1)
        case .producedConsumed:
            var runtime = IndustrialCommunicationRuntime(configuration: .init(kind: .producedConsumed, updatePeriodMilliseconds: 50), remoteTags: ["Line1_Status.Speed": 42])
            runtime.step(milliseconds: 49); let before = runtime.localTags["Line1_Status.Speed"]
            runtime.step(milliseconds: 1); let after = runtime.localTags["Line1_Status.Speed"]
            let beforeText = before.map { String(format: "%.3f", $0) } ?? "no consumed update"
            let afterText = after.map { String(format: "%.3f", $0) } ?? "missing"
            return .init(title: "Produced / consumed RPI", observations: ["Before RPI: \(beforeText)", "At RPI: \(afterText)"], passed: before == nil && after == 42)
        case .cipMessageRead:
            var runtime = IndustrialCommunicationRuntime(configuration: .init(kind: .cipDataTableRead, messageLatencyMilliseconds: 35), localTags: ["RemoteSpeedCopy": 0], remoteTags: ["PumpSpeed": 57.5])
            runtime.triggerMessage(sourceTag: "PumpSpeed", destinationTag: "RemoteSpeedCopy")
            runtime.step(milliseconds: 34); let busy = runtime.message.waiting
            runtime.step(milliseconds: 1)
            return .init(title: "CIP Data Table Read", observations: ["MSG remains pending before configured completion: \(busy).", "Destination after completion: \(runtime.localTags["RemoteSpeedCopy"] ?? .nan).", "Done=\(runtime.message.done), Error=\(runtime.message.error)."], passed: busy && runtime.message.done && runtime.localTags["RemoteSpeedCopy"] == 57.5)
        case .cipMessageWrite:
            var runtime = IndustrialCommunicationRuntime(configuration: .init(kind: .cipDataTableWrite, messageLatencyMilliseconds: 35), localTags: ["LineCommand": 1], remoteTags: ["RemoteLineCommand": 0])
            runtime.triggerMessage(sourceTag: "LineCommand", destinationTag: "RemoteLineCommand")
            runtime.step(milliseconds: 35)
            return .init(title: "CIP Data Table Write", observations: ["Remote destination after MSG: \(runtime.remoteTags["RemoteLineCommand"] ?? .nan).", "The message is an explicit transaction rather than a continuously updated I/O connection."], passed: runtime.message.done && runtime.remoteTags["RemoteLineCommand"] == 1)
        case .hmiPolling:
            var runtime = IndustrialCommunicationRuntime(configuration: .init(kind: .hmiPolling, updatePeriodMilliseconds: 250), remoteTags: ["TankLevel": 61.2])
            runtime.step(milliseconds: 250)
            return .init(title: "HMI polling", observations: ["HMI-visible TankLevel: \(runtime.localTags["TankLevel"] ?? .nan).", "Display freshness is governed by the teaching poll interval, independent of ladder scan execution."], passed: runtime.localTags["TankLevel"] == 61.2)
        case .historianScan:
            var historian = HistorianLabRuntime(points: [.init(sourceTag: "PressurePV", scanPeriodMilliseconds: 1_000, engineeringUnits: "psi")])
            historian.step(milliseconds: 999, sourceValues: ["PressurePV": 45])
            let before = historian.samples.count
            historian.step(milliseconds: 1, sourceValues: ["PressurePV": 46])
            return .init(title: "Historian scan class", observations: ["Samples before the 1 s scan boundary: \(before).", "Stored value at 1 s: \(historian.latest(pointName: "PressurePV")?.value ?? .nan).", "The historian stores timestamped point data on its configured teaching scan interval."], passed: before == 0 && historian.samples.count == 1)
        case .integratedCapstone:
            var network = IndustrialCommunicationRuntime(configuration: .init(kind: .producedConsumed, updatePeriodMilliseconds: 100), remoteTags: ["Skid_Status.Pressure": 52])
            network.step(milliseconds: 100)
            var historian = HistorianLabRuntime(points: [.init(sourceTag: "Skid_Status.Pressure", scanPeriodMilliseconds: 100)])
            historian.step(milliseconds: 100, sourceValues: network.localTags)
            let stored = historian.latest(pointName: "Skid_Status.Pressure")?.value
            return .init(title: "Integrated controls data path", observations: ["Remote controller value reached the consumer: \(network.localTags["Skid_Status.Pressure"] ?? .nan).", "Historian then stored that controller-visible value: \(stored ?? .nan)."], passed: stored == 52)
        case .ladder:
            return .init(title: "Ladder construction lab", observations: ["Use the rung references as the target, then verify truth flow in the Controls Microscope.", "The lesson emphasizes why each contact/instruction exists, not rote copying."], passed: true)
        }
    }
}

public enum StepByStepCatalog {
    public static let all: [StepByStepLesson] = [
        scanBasics(), logixTaskModel(), tagBasics(), firstRung(), controllerOrganization(), instructionFamilies(), xicXioTruth(), commandVsFeedback(), oneShots(),
        motorStarter(), interlocks(), routineOrganization(), timerSequence(), retentiveTimers(),
        analogInput(), analogAlarm(), analogOutput(), levelControl(), structuredData(), remoteIOOrganization(), ioCatalog(),
        ioRPI(), producedConsumed(), msgRead(), msgWrite(), hmi(), historian(), capstone()
    ]

    public static func lessons(in track: StepByStepTrack) -> [StepByStepLesson] { all.filter { $0.track == track } }
    public static func lesson(_ id: String) -> StepByStepLesson? { all.first { $0.id == id } }

    private static func scanBasics() -> StepByStepLesson { .init(id:"foundation-scan", title:"1. What a PLC Scan Actually Does", track:.foundations, difficulty:.beginner, estimatedMinutes:12, summary:"Learn the repeating read → solve logic → write-output mental model before writing any program.", objectives:["Explain why ladder is evaluated repeatedly", "Separate a field change from when logic observes it", "Predict one scan from known inputs"], tagsToCreate:[], steps:[
        .init("s1", title:"Follow one scan", instruction:"Trace the sequence: controller-visible inputs → ladder execution → output image/state.", whyItMatters:"Every later timer, seal-in, communication, and troubleshooting lesson depends on knowing when values are observed and written.", checkpoint:"You can explain why a field input changing between scans may not affect the rung until the next execution."),
        .init("s2", title:"Predict before running", instruction:"Assume Start_PB is FALSE at the beginning of a scan. Predict the final rung condition for XIC Start_PB.", whyItMatters:"Prediction builds the habit of reasoning from known controller state instead of guessing from animation.", checkpoint:"You predict FALSE before seeing the trace."),
        .init("s3", title:"Verify with a scan", instruction:"Run the teaching lab and compare the observed execution with your prediction.", whyItMatters:"A controls technician constantly cycles between prediction and evidence.", checkpoint:"You can state what changed during the scan and what did not.")
    ], referenceRungs:[], labKind:.ladder, fieldNote:"A real Logix controller has additional scheduling and I/O details, but this read/execute/write mental model is the right beginner foundation.") }

    private static func tagBasics() -> StepByStepLesson { .init(id:"foundation-tags", title:"2. Create and Understand Tags", track:.foundations, difficulty:.beginner, estimatedMinutes:15, summary:"Learn BOOL, DINT, REAL, TIMER and COUNTER tags, and distinguish input, output and internal controller data.", objectives:["Choose an appropriate basic data type", "Understand input/output/internal teaching roles", "Use clear names that describe machine meaning"], tagsToCreate:["Start_PB : BOOL input", "Motor_Run : BOOL output", "BatchCount : DINT internal"], steps:[
        .init("tg1", title:"Create a digital input tag", instruction:"Create Start_PB as BOOL and mark it input-facing.", whyItMatters:"The ladder references controller data, not the pushbutton hardware directly.", checkpoint:"Start_PB exists as BOOL input-facing data."),
        .init("tg2", title:"Create a digital output tag", instruction:"Create Motor_Run as BOOL and mark it output-facing.", whyItMatters:"Commanded output state and physical motor feedback are different concepts.", checkpoint:"Motor_Run exists separately from Start_PB."),
        .init("tg3", title:"Create internal data", instruction:"Create BatchCount as DINT internal data.", whyItMatters:"Programs need memory that is neither a physical input nor physical output.", checkpoint:"You can explain when BOOL, DINT and REAL are appropriate.")
    ], referenceRungs:[], labKind:.ladder) }

    private static func firstRung() -> StepByStepLesson { .init(id:"foundation-first-rung", title:"3. Write Your First XIC / OTE Rung", track:.foundations, difficulty:.beginner, estimatedMinutes:18, summary:"Build the smallest useful rung and watch logical continuity flow from input condition to output command.", objectives:["Place XIC and OTE", "Trace rung condition left to right", "Run the exact ladder you built"], tagsToCreate:["Start_PB : BOOL input", "Motor_Run : BOOL output"], steps:[
        .init("fr1", title:"Place XIC Start_PB", instruction:"Add XIC Start_PB as the input condition.", whyItMatters:"XIC evaluates whether its BOOL operand is true when rung power reaches it.", checkpoint:"With Start_PB FALSE, power stops at the XIC."),
        .init("fr2", title:"Place OTE Motor_Run", instruction:"Add OTE Motor_Run after the XIC.", whyItMatters:"OTE writes its destination according to the final rung condition.", checkpoint:"Start_PB TRUE produces a true Motor_Run command on that scan."),
        .init("fr3", title:"Run and explain", instruction:"Toggle Start_PB, step scans, and explain every transition before moving on.", whyItMatters:"Writing ladder without predicting behavior creates fragile memorization.", checkpoint:"You can predict Motor_Run for both Start_PB states before pressing Run.")
    ], referenceRungs:[.init("first0", rungNumber:0, purpose:"First digital rung", ladderText:"|----[XIC Start_PB]----------------(OTE Motor_Run)----|", explanation:"The first rung intentionally contains no seal-in or safety logic. It exists only to teach instruction truth and power flow.")], labKind:.ladder) }

    private static func controllerOrganization() -> StepByStepLesson { .init(id:"foundation-controller-organization", title:"4. Controller → Task → Program → Routine", track:.foundations, difficulty:.beginner, estimatedMinutes:18, summary:"Place your rung in the controller hierarchy and learn where controller-scoped and program-scoped data belong.", objectives:["Navigate task/program/routine hierarchy", "Distinguish controller and program scope", "Understand that code must belong to a scheduled task path to execute"], tagsToCreate:["Controller-scoped Plant_Enable : BOOL", "Program-scoped Motor_Run : BOOL"], steps:[
        .init("co1", title:"Inspect the controller", instruction:"Open the organization lab and locate the local chassis, MainTask, program and MainRoutine.", whyItMatters:"A rung only executes when its routine belongs to a program scheduled by an executing task.", checkpoint:"You can trace Controller → MainTask → Program → MainRoutine."),
        .init("co2", title:"Compare scopes", instruction:"Inspect one controller-scoped and one program-scoped tag.", whyItMatters:"Scope determines which programs and communication features can directly reference data.", checkpoint:"You can explain why produced/consumed data later uses controller scope."),
        .init("co3", title:"Keep it simple", instruction:"Do not add remote racks, UDTs or arrays yet. Focus on where ordinary ladder lives.", whyItMatters:"Organization is useful only after the learner has a rung to organize.", checkpoint:"You can say where your first rung executes without describing advanced data structures.")
    ], referenceRungs:[], labKind:.ladder) }

    private static func xicXioTruth() -> StepByStepLesson { .init(id:"digital-xic-xio", title:"5. XIC vs XIO: Read the Bit, Not the Symbol", track:.digitalIO, difficulty:.beginner, estimatedMinutes:18, summary:"Learn exactly when XIC and XIO pass rung power, including the common normally-open/normally-closed misconception.", objectives:["Predict XIC truth", "Predict XIO truth", "Separate ladder instruction semantics from physical contact construction"], tagsToCreate:["Guard_OK : BOOL", "Faulted : BOOL"], steps:[
        .init("xx1", title:"Predict XIC", instruction:"Set Guard_OK TRUE and predict whether XIC Guard_OK passes power.", whyItMatters:"XIC asks whether the controller bit is true when rung power arrives.", checkpoint:"TRUE bit + true RCI gives true RCO."),
        .init("xx2", title:"Predict XIO", instruction:"Set Faulted FALSE and predict whether XIO Faulted passes power.", whyItMatters:"XIO passes when the referenced bit is false, not because a field device is physically normally closed.", checkpoint:"FALSE bit + true RCI gives true RCO."),
        .init("xx3", title:"Transfer the idea", instruction:"Explain how a normally-closed stop contact can still appear in ladder as XIC Stop_OK when the PLC input bit means 'circuit healthy'.", whyItMatters:"Naming the bit by meaning prevents symbol-based confusion.", checkpoint:"You reason from tag meaning and observed bit state, not contact artwork alone.")
    ], referenceRungs:[.init("xx0", rungNumber:0, purpose:"Truth comparison", ladderText:"|--[XIC Guard_OK]--[XIO Faulted]------------(OTE Ready)--|", explanation:"The rung is true when Guard_OK is true and Faulted is false.")]) }

    private static func commandVsFeedback() -> StepByStepLesson { .init(id:"digital-command-feedback", title:"6. Command Is Not Feedback", track:.digitalIO, difficulty:.beginner, estimatedMinutes:18, summary:"Keep what the PLC requests separate from what the machine proves actually happened.", objectives:["Separate command and status tags", "Understand why OTE truth is not physical proof", "Build a basic run-proven pattern"], tagsToCreate:["Motor_RunCmd : BOOL output", "Motor_RunningFB : BOOL input", "Motor_FailedToRun : BOOL"], steps:[
        .init("cf1", title:"Create separate tags", instruction:"Create Motor_RunCmd and Motor_RunningFB as different BOOLs.", whyItMatters:"A controller may command a starter while the contactor, drive or motor fails physically.", checkpoint:"Command and feedback are never represented by the same tag."),
        .init("cf2", title:"Compare request to proof", instruction:"Imagine Motor_RunCmd TRUE while Motor_RunningFB remains FALSE.", whyItMatters:"This is the beginning of real equipment diagnostics.", checkpoint:"You identify this as command present but operation unproven."),
        .init("cf3", title:"Carry the model forward", instruction:"Use command/status separation in every later HMI and historian lesson.", whyItMatters:"Good data contracts make troubleshooting possible outside the ladder editor too.", checkpoint:"You can describe which value belongs on an HMI 'requested' indicator and which belongs on 'running'.")
    ], referenceRungs:[]) }

    private static func routineOrganization() -> StepByStepLesson { .init(id:"sequence-routine-jsr", title:"9. Break Logic into Routines with JSR", track:.sequencing, difficulty:.beginner, estimatedMinutes:22, summary:"Move from one growing MainRoutine to organized machine functions and explicitly call them.", objectives:["Create a second routine", "Use JSR", "Understand that uncalled routines do not execute"], tagsToCreate:["Conveyor_Enable : BOOL", "Transfer_Enable : BOOL"], steps:[
        .init("js1", title:"Create a functional routine", instruction:"Create ConveyorLogic separately from MainRoutine.", whyItMatters:"Routine boundaries help humans navigate and reason about a machine without changing scan semantics by themselves.", checkpoint:"The new routine exists but is not assumed to execute automatically."),
        .init("js2", title:"Call it", instruction:"Place JSR ConveyorLogic in MainRoutine.", whyItMatters:"A routine must be reachable from executed controller logic to run.", checkpoint:"The call stack now includes ConveyorLogic during the scan."),
        .init("js3", title:"Prove execution", instruction:"Remove or disable the call and predict what logic stops executing.", whyItMatters:"This prevents the common beginner assumption that every routine shown in the project tree runs automatically.", checkpoint:"You can explain why an uncalled routine has no effect.")
    ], referenceRungs:[.init("jsr0", rungNumber:0, purpose:"Call conveyor routine", ladderText:"|--------------------------------[JSR ConveyorLogic]----|", explanation:"The program explicitly transfers execution into the subroutine and returns afterward.")]) }

    private static func structuredData() -> StepByStepLesson { .init(id:"foundation-structured-data", title:"15. Organize Repeated Data with Arrays, UDTs & Aliases", track:.foundations, difficulty:.intermediate, estimatedMinutes:30, summary:"Introduce structured-data concepts only after basic ladder, sequencing and analog work are familiar.", objectives:["Describe arrays and UDTs", "Understand alias intent", "Know current simulator limits"], tagsToCreate:["MotorStatus[4] : conceptual BOOL array", "PumpStatus : conceptual UDT", "Local_Start : conceptual alias"], steps:[
        .init("sd1", title:"Use an array for repeated data", instruction:"Group repeated same-type values conceptually into an indexed array.", whyItMatters:"Arrays reduce tag sprawl when equipment is genuinely homogeneous.", checkpoint:"You can explain why MotorStatus[2] and MotorStatus[3] share one element type."),
        .init("sd2", title:"Use a UDT for related fields", instruction:"Group RunCmd, RunningFB, Faulted and Speed into a conceptual PumpStatus structure.", whyItMatters:"UDTs describe one equipment object's related data instead of unrelated flat tags.", checkpoint:"You can distinguish array-of-same-type from structure-of-different-members."),
        .init("sd3", title:"Treat aliases cautiously", instruction:"Inspect an alias relationship and identify the base tag it points to.", whyItMatters:"Aliases improve naming but can hide the physical source if overused.", checkpoint:"You can trace an alias back to its base tag.")
    ], referenceRungs:[], fieldNote:"Arrays, UDTs and aliases are modeled here as controller-organization teaching concepts. Full native structured storage/editing remains a future runtime fidelity upgrade.") }

    private static func remoteIOOrganization() -> StepByStepLesson { .init(id:"comm-remote-io-tree", title:"16. Add a Remote I/O Rack to the I/O Tree", track:.communications, difficulty:.intermediate, estimatedMinutes:28, summary:"Place remote digital/analog modules in a networked chassis before studying RPI timing.", objectives:["Distinguish local and remote modules", "Bind a point to module/channel", "Understand that remote data arrives through an I/O connection"], tagsToCreate:["RemoteDI_0 : BOOL", "RemoteAI_0 : REAL"], steps:[
        .init("ri1", title:"Inspect local chassis", instruction:"Identify the controller and local module slots in the organization lab.", whyItMatters:"Physical topology is the bridge between a field wire and controller-visible data.", checkpoint:"You can name controller slot and local I/O slot separately."),
        .init("ri2", title:"Add remote rack", instruction:"Inspect the remote EtherNet/IP rack and its digital/analog modules.", whyItMatters:"Remote I/O is not executed as a remote ladder routine; module data is exchanged cyclically.", checkpoint:"You can trace RemoteAI_0 to a remote chassis/module/channel."),
        .init("ri3", title:"Prepare for RPI", instruction:"Identify the configured RPI and compare it conceptually with the task period.", whyItMatters:"The next lesson depends on separating network update cadence from ladder execution cadence.", checkpoint:"You do not describe RPI as the ladder scan time.")
    ], referenceRungs:[], labKind:.ioTiming) }

    private static func motorStarter() -> StepByStepLesson { .init(id:"digital-motor-seal", title:"Three-Wire Motor Start/Stop Seal-In", track:.digitalIO, difficulty:.beginner, estimatedMinutes:30, summary:"Build a classic maintained run command from momentary Start and Stop inputs.", objectives:["Use XIC/XIO correctly", "Build a parallel seal-in branch", "Understand why stop logic belongs in series with the latch path"], tagsToCreate:["Start_PB : BOOL", "Stop_OK : BOOL", "Motor_Run : BOOL"], steps:[
        .init("m1", title:"Establish the stop permissive", instruction:"Place XIC Stop_OK at the left side of the rung.", whyItMatters:"Every path capable of running the motor must pass through the stop condition.", checkpoint:"Opening Stop_OK removes power from every downstream branch."),
        .init("m2", title:"Create the start/seal branch", instruction:"Create parallel paths containing XIC Start_PB and XIC Motor_Run.", whyItMatters:"The output's own controller state maintains the request after the momentary Start input releases.", checkpoint:"Either Start_PB or an already true Motor_Run can carry power through the branch."),
        .init("m3", title:"Drive the output", instruction:"Place OTE Motor_Run after the branch merge.", whyItMatters:"The output follows the complete permissive + start/seal expression.", checkpoint:"The motor seals in after Start and drops immediately when Stop_OK becomes false.")
    ], referenceRungs:[.init("mr0", rungNumber:0, purpose:"Motor run seal", ladderText:"|--[XIC Stop_OK]--+--[XIC Start_PB]--+--(OTE Motor_Run)--|\n|                 +--[XIC Motor_Run]-+                   |", explanation:"The stop permissive is outside the parallel branch so it interrupts both starting and sealing paths.")], fieldNote:"In a real machine, safety functions may be implemented in safety-rated hardware/controllers. Do not treat a standard ladder stop rung as a substitute for required safety design.") }

    private static func interlocks() -> StepByStepLesson { .init(id:"digital-interlocks", title:"Permissives, Interlocks, Fault Latch & Reset", track:.sequencing, difficulty:.beginner, estimatedMinutes:35, summary:"Build a machine-ready request that only runs when multiple conditions agree and latches a fault when a trip occurs.", objectives:["Separate permissives from commands", "Latch a fault with OTL", "Reset intentionally with OTU"], tagsToCreate:["Run_Request : BOOL", "Guard_OK : BOOL", "Air_OK : BOOL", "OverloadTrip : BOOL", "Machine_Run : BOOL", "Machine_Fault : BOOL", "Reset_PB : BOOL"], steps:[
        .init("i1", title:"Build the run permissives", instruction:"Series Run_Request, Guard_OK, Air_OK and XIO Machine_Fault before OTE Machine_Run.", whyItMatters:"A run command is not permission to run. Permissives and active faults must be satisfied too.", checkpoint:"Removing any permissive drops Machine_Run."),
        .init("i2", title:"Latch the trip", instruction:"Use XIC OverloadTrip to OTL Machine_Fault.", whyItMatters:"Momentary fault evidence should remain available after the initiating input clears.", checkpoint:"Machine_Fault remains true after OverloadTrip returns false."),
        .init("i3", title:"Reset deliberately", instruction:"Use XIC Reset_PB AND XIO OverloadTrip to OTU Machine_Fault.", whyItMatters:"Resetting while the trip remains active hides the actual condition.", checkpoint:"Reset clears the latch only after the overload input is no longer active.")
    ], referenceRungs:[
        .init("ir0", rungNumber:0, purpose:"Run permissives", ladderText:"|--[XIC Run_Request]--[XIC Guard_OK]--[XIC Air_OK]--[XIO Machine_Fault]--(OTE Machine_Run)--|", explanation:"All requirements must be true and the latched fault must be false."),
        .init("ir1", rungNumber:10, purpose:"Latch fault", ladderText:"|--[XIC OverloadTrip]----------------------------(OTL Machine_Fault)--|", explanation:"OTL remembers the trip after its source clears."),
        .init("ir2", rungNumber:20, purpose:"Reset fault", ladderText:"|--[XIC Reset_PB]--[XIO OverloadTrip]------------(OTU Machine_Fault)--|", explanation:"The reset is conditioned on the trip being clear.")
    ]) }

    private static func timerSequence() -> StepByStepLesson { .init(id:"sequence-timer-counter", title:"Timers, Counters & a Two-Step Sequence", track:.sequencing, difficulty:.intermediate, estimatedMinutes:40, summary:"Use TON, CTU and state logic to advance a simple machine sequence.", objectives:["Understand TON .DN", "Count completed events", "Separate sequence state from physical outputs"], tagsToCreate:["Step1Active : BOOL", "PE_Clear : BOOL", "TransferDelay : TIMER", "State : DINT", "BoxCount : COUNTER"], steps:[
        .init("t1", title:"Enable the timer", instruction:"When State equals 10 and PE_Clear is true, execute TON TransferDelay.", whyItMatters:"The timer accumulates only while the enabling logic is true.", checkpoint:"TransferDelay.DN becomes true only after the configured PRE is reached."),
        .init("t2", title:"Advance state", instruction:"When State equals 10 and TransferDelay.DN is true, MOV 20 into State.", whyItMatters:"The timer does not directly become the next output. It proves a transition condition.", checkpoint:"The sequence leaves State 10 only after the timer is done."),
        .init("t3", title:"Count completed transfers", instruction:"Use the transfer-complete transition to drive CTU BoxCount.", whyItMatters:"Counters count qualifying false-to-true events, which is different from simply mirroring a BOOL.", checkpoint:"One completed transfer increments the counter once.")
    ], referenceRungs:[
        .init("tr0", rungNumber:100, purpose:"Dwell timer", ladderText:"|--[EQU State 10]--[XIC PE_Clear]----------------(TON TransferDelay)--|", explanation:"The timer proves that State 10 has remained eligible long enough."),
        .init("tr1", rungNumber:110, purpose:"State transition", ladderText:"|--[EQU State 10]--[XIC TransferDelay.DN]--------[MOV 20 State]------|", explanation:"A state transition is an explicit write, making later causal tracing easier."),
        .init("tr2", rungNumber:120, purpose:"Count", ladderText:"|--[XIC TransferComplete]------------------------(CTU BoxCount)------|", explanation:"Use a transition/event signal to count discrete completions.")
    ]) }

    private static func analogInput() -> StepByStepLesson { .init(id:"analog-input-scaling", title:"Analog Input: Raw Counts to Engineering Units", track:.analogIO, difficulty:.intermediate, estimatedMinutes:40, summary:"Scale a raw analog channel into engineering units using explicit arithmetic and preserve the raw signal for diagnostics.", objectives:["Keep raw and scaled values separate", "Apply linear scaling", "Recognize bad-range and clamping considerations"], tagsToCreate:["Pressure_Raw : REAL input", "Pressure_Offset : REAL", "Pressure_SpanCounts : REAL", "Pressure_ScaledSpan : REAL", "PressurePV : REAL"], steps:[
        .init("a1", title:"Preserve the raw input", instruction:"Keep the module/raw channel value in Pressure_Raw rather than overwriting it.", whyItMatters:"Raw counts are invaluable when diagnosing wiring, module scaling, and transmitter problems.", checkpoint:"Pressure_Raw and PressurePV are separate tags."),
        .init("a2", title:"Subtract raw minimum", instruction:"SUB Pressure_Raw RawMin → Pressure_Offset.", whyItMatters:"Linear scaling begins by measuring position inside the raw span.", checkpoint:"At RawMin, Pressure_Offset equals zero."),
        .init("a3", title:"Normalize and scale", instruction:"DIV Pressure_Offset RawSpan → Pressure_Normalized, then MUL by EU span and ADD EU minimum.", whyItMatters:"This is the general raw→engineering-unit relationship used across analog instrumentation.", checkpoint:"RawMin maps to EUMin and RawMax maps to EUMax."),
        .init("a4", title:"Validate fault behavior", instruction:"Test a raw value below minimum and above maximum and decide whether your application should clamp, alarm, or preserve the out-of-range engineering result.", whyItMatters:"A scaling formula should not silently erase evidence of an underrange/overrange condition.", checkpoint:"You can explain what your program does outside the calibrated raw range.")
    ], referenceRungs:[
        .init("ar0", rungNumber:0, purpose:"Remove raw offset", ladderText:"|--------------------------------[SUB Pressure_Raw RawMin Pressure_Offset]--|", explanation:"Start with the unscaled signal minus its configured raw minimum."),
        .init("ar1", rungNumber:10, purpose:"Normalize", ladderText:"|----------------------------[DIV Pressure_Offset RawSpan Pressure_Normalized]--|", explanation:"Normalize the value to its position within the input span."),
        .init("ar2", rungNumber:20, purpose:"Scale span", ladderText:"|---------------------------[MUL Pressure_Normalized EUSpan Pressure_ScaledSpan]--|", explanation:"Apply the engineering span."),
        .init("ar3", rungNumber:30, purpose:"Add EU minimum", ladderText:"|----------------------------[ADD Pressure_ScaledSpan EUMin PressurePV]--|", explanation:"Offset into final engineering units.")
    ], fieldNote:"Modern Rockwell process instructions can provide configurable raw/PV scaling. This lesson uses explicit arithmetic so the learner understands the underlying relationship before using higher-level instructions.") }

    private static func analogAlarm() -> StepByStepLesson { .init(id:"analog-alarms", title:"Analog High/Low Alarms with Hysteresis", track:.analogIO, difficulty:.intermediate, estimatedMinutes:35, summary:"Create analog limit alarms that do not chatter at the threshold.", objectives:["Use GEQ/LEQ comparisons", "Add reset hysteresis", "Separate alarm state from process value"], tagsToCreate:["PressurePV : REAL", "HighLimit : REAL", "HighReset : REAL", "PressureHigh : BOOL"], steps:[
        .init("aa1", title:"Latch the high alarm", instruction:"GEQ PressurePV HighLimit → OTL PressureHigh.", whyItMatters:"A limit crossing should remain visible until an intentional reset condition is met.", checkpoint:"Crossing HighLimit latches the alarm."),
        .init("aa2", title:"Add hysteresis", instruction:"LEQ PressurePV HighReset → OTU PressureHigh, where HighReset is below HighLimit.", whyItMatters:"Separate trip/reset thresholds prevent chatter when PV hovers near the limit.", checkpoint:"The alarm remains active between HighLimit and HighReset after a trip."),
        .init("aa3", title:"Test noisy data", instruction:"Move PressurePV above and below HighLimit by small amounts and compare behavior with and without hysteresis.", whyItMatters:"Noise and normal process variation make a single threshold fragile.", checkpoint:"You can explain why the alarm state is path-dependent inside the hysteresis band.")
    ], referenceRungs:[
        .init("aar0", rungNumber:0, purpose:"Trip high alarm", ladderText:"|--[GEQ PressurePV HighLimit]--------------------(OTL PressureHigh)--|", explanation:"Latch when the process reaches the high limit."),
        .init("aar1", rungNumber:10, purpose:"Reset below lower threshold", ladderText:"|--[LEQ PressurePV HighReset]--------------------(OTU PressureHigh)--|", explanation:"Reset only after the process has moved far enough back into normal range.")
    ]) }

    private static func analogOutput() -> StepByStepLesson { .init(id:"analog-output-command", title:"Analog Output: Percent Command, Limits & Safe State", track:.analogIO, difficulty:.intermediate, estimatedMinutes:40, summary:"Build an internal 0–100% command, apply permissives and limits, then scale toward an analog output representation.", objectives:["Keep engineering command separate from raw output", "Apply output limits", "Force a deliberate safe state when permissives are lost"], tagsToCreate:["ValveCmdPct : REAL", "ValveCmdLimited : REAL", "ValveRaw : REAL output", "Air_OK : BOOL", "Process_Enable : BOOL"], steps:[
        .init("ao1", title:"Work in engineering percent", instruction:"Create ValveCmdPct as the controller-facing 0–100% command.", whyItMatters:"Control strategy is easier to reason about in engineering terms than raw module counts.", checkpoint:"ValveCmdPct has a documented 0–100% intended range."),
        .init("ao2", title:"Apply interlocks before output", instruction:"When Process_Enable or Air_OK is false, MOV the configured safe percent into ValveCmdLimited.", whyItMatters:"An analog output should have an explicit safe behavior rather than inheriting a stale command accidentally.", checkpoint:"Loss of a permissive produces the intended safe command."),
        .init("ao3", title:"Scale to module representation", instruction:"Apply the inverse linear scaling from engineering percent to the chosen module/raw representation.", whyItMatters:"Keeping the final hardware representation at the edge preserves diagnostic clarity.", checkpoint:"0% and 100% map correctly to the configured output endpoints.")
    ], referenceRungs:[.init("aor0", rungNumber:0, purpose:"Safe output override", ladderText:"|--+--[XIO Process_Enable]--+----------------[MOV SafePct ValveCmdLimited]--|\n|  +--[XIO Air_OK]----------+                                               |", explanation:"Any lost permissive forces a deliberate safe engineering command before raw conversion.")], fieldNote:"PlantPAx PAO can provide richer analog output scaling, mode handling, feedback and interlock behavior on supported platforms. This lesson starts with the transferable fundamentals.") }

    private static func levelControl() -> StepByStepLesson { .init(id:"analog-level-hysteresis", title:"Simple On/Off Level Control with Deadband", track:.analogIO, difficulty:.intermediate, estimatedMinutes:30, summary:"Control a fill valve with separate low-start and high-stop thresholds.", objectives:["Create hysteretic on/off control", "Avoid rapid output chatter", "Reason about path dependence"], tagsToCreate:["LevelPV : REAL", "LowStart : REAL", "HighStop : REAL", "FillValve : BOOL"], steps:[
        .init("lc1", title:"Start below low threshold", instruction:"LEQ LevelPV LowStart → OTL FillValve.", whyItMatters:"The valve starts only after level falls sufficiently low.", checkpoint:"Level below LowStart latches FillValve."),
        .init("lc2", title:"Stop above high threshold", instruction:"GEQ LevelPV HighStop → OTU FillValve.", whyItMatters:"The difference between start and stop levels is deliberate process deadband.", checkpoint:"FillValve remains on through the band until HighStop is reached."),
        .init("lc3", title:"Simulate a full cycle", instruction:"Move level from low to high and back down and sketch the valve state.", whyItMatters:"This is a compact introduction to stateful control and hysteresis.", checkpoint:"You can predict valve state anywhere inside the deadband from the direction/history of travel.")
    ], referenceRungs:[
        .init("lcr0", rungNumber:0, purpose:"Start fill", ladderText:"|--[LEQ LevelPV LowStart]------------------------(OTL FillValve)--|", explanation:"Latch fill when level is low."),
        .init("lcr1", rungNumber:10, purpose:"Stop fill", ladderText:"|--[GEQ LevelPV HighStop]------------------------(OTU FillValve)--|", explanation:"Unlatch only after reaching the higher stop level.")
    ]) }

    private static func ioRPI() -> StepByStepLesson { .init(id:"comm-io-rpi", title:"EtherNet/IP Remote I/O and RPI", track:.communications, difficulty:.intermediate, estimatedMinutes:35, summary:"See why a field transition, module update, and PLC task scan are different time events.", objectives:["Understand cyclic I/O update timing", "Separate RPI from ladder task period", "Recognize missed/late visibility scenarios"], tagsToCreate:["RemoteDI : BOOL", "RemoteAI : REAL"], steps:[
        .init("io1", title:"Choose an I/O update period", instruction:"Configure the teaching link with a 20 ms RPI.", whyItMatters:"The requested packet interval determines how frequently the connection updates controller-visible data in this teaching model.", checkpoint:"You can state the configured RPI and the task period separately."),
        .init("io2", title:"Change the remote source", instruction:"Toggle the source value 1 ms after an update and inspect the controller-side value before the next update.", whyItMatters:"A physical/source change is not necessarily visible to the controller immediately.", checkpoint:"The local copy remains stale until the modeled cyclic update."),
        .init("io3", title:"Compare with task execution", instruction:"Overlay I/O update timing and a periodic PLC task.", whyItMatters:"Input age at the instant a task executes matters for diagnosing short pulses and races.", checkpoint:"You can describe at least one timing alignment that misses a short event.")
    ], referenceRungs:[], labKind:.ioTiming) }

    private static func producedConsumed() -> StepByStepLesson { .init(id:"comm-produced-consumed", title:"Controller-to-Controller Produced / Consumed Tags", track:.communications, difficulty:.intermediate, estimatedMinutes:35, summary:"Share structured controller-scoped status data cyclically without triggering a MSG in ladder logic.", objectives:["Know producer vs consumer roles", "Understand compatible data structure requirement", "Relate consumed-tag RPI to data freshness"], tagsToCreate:["Line1_Status : controller-scoped UDT (conceptual)", "Line1_Status_Consumed : matching consumed tag"], steps:[
        .init("pc1", title:"Define shared data", instruction:"Create a controller-scoped status structure containing only the data the other controller needs.", whyItMatters:"A stable interface prevents every internal tag from becoming a network contract.", checkpoint:"The interface has documented ownership and meaning."),
        .init("pc2", title:"Configure producer/consumer", instruction:"Mark the source controller tag Produced and configure a matching Consumed tag in the receiving controller.", whyItMatters:"Produced/consumed tags transfer cyclic controller data without a ladder-triggered MSG transaction.", checkpoint:"Producer and consumer structures match."),
        .init("pc3", title:"Choose RPI intentionally", instruction:"Set a consumed-tag RPI appropriate to how quickly the receiving logic needs fresh data.", whyItMatters:"Faster is not automatically better; network update needs should match process timing.", checkpoint:"You can justify the RPI from the process requirement rather than habit.")
    ], referenceRungs:[.init("pcr0", rungNumber:0, purpose:"Use received status", ladderText:"|--[XIC Line1_Status_Consumed.Ready]--[XIC LocalPermissive]--(OTE TransferEnable)--|", explanation:"The ladder consumes the received data like other controller tags; the cyclic transfer itself is configured, not triggered by this rung.")], labKind:.producedConsumed, fieldNote:"Rockwell documentation specifies produced and consumed tags as controller-scoped shared tags, with the consumed tag's RPI governing update period.") }

    private static func msgRead() -> StepByStepLesson { .init(id:"comm-msg-read", title:"MSG: CIP Data Table Read", track:.communications, difficulty:.advanced, estimatedMinutes:45, summary:"Trigger an explicit read from another Logix controller and reason about enable, pending, done and error states.", objectives:["Understand explicit message transactions", "Separate source and destination tags", "Avoid continuously retriggering a MSG"], tagsToCreate:["ReadRemoteData : MESSAGE control (conceptual)", "RemoteSpeedCopy : REAL"], steps:[
        .init("mr1", title:"Create the control tag", instruction:"Create a dedicated MESSAGE control tag for the MSG instruction.", whyItMatters:"Each MSG needs its own control state so enable/done/error behavior is observable.", checkpoint:"The message has a dedicated control tag rather than sharing control state."),
        .init("mr2", title:"Configure CIP Data Table Read", instruction:"Set the remote Source Element, number of elements, and local Destination Element.", whyItMatters:"A read copies remote data into a local destination; source/destination direction is easy to reverse mentally.", checkpoint:"You can point to the remote source and local destination."),
        .init("mr3", title:"Trigger on an event", instruction:"Enable the MSG from a one-shot or deliberate request condition, then wait for Done or Error before requesting again.", whyItMatters:"Treat MSG as an asynchronous transaction, not a continuously evaluated arithmetic instruction.", checkpoint:"The request does not pile up every scan."),
        .init("mr4", title:"Handle error and timeout", instruction:"Build logic that records a communication fault after an error/retry policy rather than assuming data is always fresh.", whyItMatters:"Communication state belongs in the machine's diagnostic model.", checkpoint:"Loss of the remote controller cannot silently masquerade as a valid stale value.")
    ], referenceRungs:[.init("mrr0", rungNumber:0, purpose:"Trigger explicit read", ladderText:"|--[XIC ReadRequest]--[ONS ReadONS]----------------[MSG ReadRemoteData]--|", explanation:"The training pattern triggers one transaction per request and then monitors the message control state separately.")], labKind:.cipMessageRead, fieldNote:"Current Logix Designer documentation describes CIP Data Table Read/Write for transferring data between Logix 5000 controllers and requires a separate MESSAGE control tag for each MSG instruction.") }

    private static func msgWrite() -> StepByStepLesson { .init(id:"comm-msg-write", title:"MSG: CIP Data Table Write", track:.communications, difficulty:.advanced, estimatedMinutes:40, summary:"Send an explicit command/data block to a remote Logix controller and design ownership so two controllers do not fight over the same state.", objectives:["Configure local source vs remote destination", "Use handshake/ownership concepts", "Handle Done/Error explicitly"], tagsToCreate:["WriteRemoteData : MESSAGE control (conceptual)", "LineCommand : DINT"], steps:[
        .init("mw1", title:"Define ownership", instruction:"Decide which controller owns the command and which controller owns the resulting equipment state.", whyItMatters:"Network writes without ownership rules can create two masters for one machine function.", checkpoint:"The interface document names one owner for each command/status field."),
        .init("mw2", title:"Configure the write", instruction:"Choose the local source tag and remote destination element for CIP Data Table Write.", whyItMatters:"Write direction is the inverse of the read lesson.", checkpoint:"You can explain exactly which controller memory changes on success."),
        .init("mw3", title:"Add handshake", instruction:"After Done, wait for a remote acknowledgement/status change instead of assuming the physical action occurred merely because the message transmitted.", whyItMatters:"Communication success proves data transfer, not process execution.", checkpoint:"The program differentiates message success from equipment success.")
    ], referenceRungs:[.init("mwr0", rungNumber:0, purpose:"Send remote command", ladderText:"|--[XIC SendCommand]--[ONS SendONS]----------------[MSG WriteRemoteData]--|", explanation:"Explicit writes should be deliberate transactions with clear ownership and response checking.")], labKind:.cipMessageWrite) }

    private static func hmi() -> StepByStepLesson { .init(id:"comm-hmi-scada", title:"HMI / SCADA Tag Access and Data Contracts", track:.communications, difficulty:.intermediate, estimatedMinutes:35, summary:"Design controller tags for operator displays and understand that display polling is not the same thing as PLC scan execution.", objectives:["Create readable HMI-facing tags", "Separate commands from status", "Recognize display/update latency"], tagsToCreate:["HMI_StartCmd : BOOL", "HMI_StopCmd : BOOL", "Machine_Status : DINT/structure concept", "PressurePV : REAL"], steps:[
        .init("h1", title:"Separate command and feedback", instruction:"Give operator commands and equipment status distinct tags rather than using one BOOL for both.", whyItMatters:"The HMI can show whether a command was requested and whether the machine actually achieved it.", checkpoint:"Start command and running feedback are separate values."),
        .init("h2", title:"Expose engineering values", instruction:"Publish PressurePV in engineering units with a useful description and units.", whyItMatters:"Operator screens and historians should not need to reverse-engineer raw module counts.", checkpoint:"The HMI-facing value has meaningful engineering units."),
        .init("h3", title:"Test polling delay", instruction:"Compare a 10 ms PLC task with a 250 ms HMI teaching poll interval.", whyItMatters:"A display can lag a rapidly changing controller value without the PLC being late.", checkpoint:"You can identify whether latency is controller execution, communications, or display refresh.")
    ], referenceRungs:[.init("hr0", rungNumber:0, purpose:"Convert HMI request into machine request", ladderText:"|--[XIC HMI_StartCmd]--[XIC RemoteStartAllowed]----(OTL Run_Request)--|", explanation:"Operator commands should enter the same permissive/interlock architecture as local commands rather than bypassing it.")], labKind:.hmiPolling) }

    private static func historian() -> StepByStepLesson { .init(id:"historian-points-scan", title:"Historian Points, Scan Classes, Quality & Trends", track:.historian, difficulty:.intermediate, estimatedMinutes:45, summary:"Choose what to historize, configure meaningful sampling intervals, and discover what a slow historian can miss.", objectives:["Select useful process points", "Relate scan period to phenomenon duration", "Preserve timestamp and quality", "Distinguish controller history from historian history"], tagsToCreate:["PressurePV : REAL", "ValvePosition : REAL", "MachineState : DINT", "Faulted : BOOL"], steps:[
        .init("hs1", title:"Choose points by question", instruction:"Select PressurePV, ValvePosition, MachineState and Faulted because they answer process, actuator, sequence and event questions.", whyItMatters:"Historizing every tag is not a substitute for designing useful evidence.", checkpoint:"Each selected point has a troubleshooting question it can answer."),
        .init("hs2", title:"Assign collection rates", instruction:"Choose faster collection for rapidly changing pressure/valve data and slower collection for slowly changing context where appropriate.", whyItMatters:"Collection frequency should match the dynamics you need to reconstruct.", checkpoint:"Your scan period is shorter than the shortest event you expect the historian to characterize."),
        .init("hs3", title:"Preserve timestamp and quality", instruction:"Treat timestamp and data quality as part of each stored sample, not decoration.", whyItMatters:"A numeric value with bad quality can be worse than no value at all during root-cause analysis.", checkpoint:"A disconnected/bad-quality sample is visibly different from a valid zero."),
        .init("hs4", title:"Compare recorder vs historian", instruction:"Use the controls flight recorder for scan-level pre-fault evidence and the historian for longer-term population/trend evidence.", whyItMatters:"Different data systems answer different time-scale questions.", checkpoint:"You can choose which system to use for a 12 ms pulse versus a six-week degradation trend.")
    ], referenceRungs:[], labKind:.historianScan, fieldNote:"FactoryTalk Historian SE point discovery/configuration supports scan-class selection for data collection. This trainer models scan timing and quality concepts, not the full Historian server/compression stack.") }

    private static func logixTaskModel() -> StepByStepLesson { .init(id:"foundation-logix-tasks", title:"The Logix Task Model", track:.foundations, difficulty:.beginner, estimatedMinutes:16, summary:"Replace the classic single scan loop with the Logix reality: a continuous task, periodic tasks, and event tasks running at different rates.", objectives:["Distinguish continuous, periodic and event tasks", "Explain why periodic tasks hold machine logic", "Recognize a task overlap and its cause"], tagsToCreate:["FastInterlockTask : conceptual periodic task", "SequencingTask : conceptual periodic task"], steps:[
        .init("lt1", title:"Place logic in a periodic task", instruction:"Assign interlock/E-stop-response logic to a fast periodic task and sequencing logic to a slower one.", whyItMatters:"The continuous task runs only in leftover time; deterministic machine behavior comes from periodic tasks with a defined rate and priority.", checkpoint:"You can state a period and priority for each block of logic rather than 'it just runs'."),
        .init("lt2", title:"Reason about interruption", instruction:"Predict what happens to the continuous task when a 10 ms periodic task and a 50 ms periodic task both come due.", whyItMatters:"Higher-priority periodic tasks preempt lower-priority tasks and the continuous task; understanding this predicts jitter and starvation.", checkpoint:"You can order execution when multiple tasks are ready."),
        .init("lt3", title:"Identify an overlap", instruction:"Describe a 20 ms periodic task whose logic takes 24 ms to solve.", whyItMatters:"An overlap is logged as a minor fault and, past a threshold, a major fault; the fix is less work per execution or a higher priority.", checkpoint:"You can explain what an overlap means and two ways to resolve it.")
    ], referenceRungs:[], labKind:.ladder, fieldNote:"A real controller also runs I/O updates asynchronously at the RPI, prescan on the Program→Run transition, and a per-task watchdog (default 500 ms). Those details build on this task model.") }

    private static func instructionFamilies() -> StepByStepLesson { .init(id:"foundation-instruction-families", title:"Instruction Families: Bit, Timer, Counter, Compare, Math, Data", track:.foundations, difficulty:.beginner, estimatedMinutes:20, summary:"Map the Logix instruction set into families so you reach for the right one and know its timing trap.", objectives:["Name the core instruction families and one member of each", "State the retentive-vs-nonretentive behavior of OTE/OTL/RTO/CTU", "Recall one common gotcha per family"], tagsToCreate:["Cycle_Timer : TIMER", "Part_Count : COUNTER", "Scaled_Flow : REAL"], steps:[
        .init("if1", title:"Bit and edge", instruction:"Compare XIC/XIO (level) with ONS/OSR/OSF (one scan on an edge) and OTE (nonretentive) vs OTL/OTU (retentive).", whyItMatters:"Choosing level vs edge and retentive vs nonretentive is the difference between counting one part and counting ten.", checkpoint:"You can say when an ONS is required and why each bit gets exactly one OTE."),
        .init("if2", title:"Timing and counting", instruction:"State TON (resets on false), TOF (delays the drop), RTO (holds .ACC), and CTU (one count per false→true edge, keeps counting past preset).", whyItMatters:"Their status bits are how the rest of the program observes elapsed time and completed events.", checkpoint:"You can predict .ACC and .DN for a TON whose enable drops before preset."),
        .init("if3", title:"Compare, math and data", instruction:"Match a task to an instruction: a band test (LIM), an expression result (CPT), a masked bit update (MVM), a whole-array fill (FLL), an atomic structure copy (CPS).", whyItMatters:"Integer math truncates, DIV by zero faults, and a large FAL/FSC in ALL mode can blow the watchdog — knowing the family tells you the risk.", checkpoint:"You can choose CPT over a chain of MUL/ADD rungs and explain why .0 on a constant matters.")
    ], referenceRungs:[.init("if0", rungNumber:0, purpose:"One instruction per family", ladderText:"|--[GEQ Scaled_Flow 5.0]--[XIC PE_Part]--[ONS PartEdge]--(CTU Part_Count)--|", explanation:"A compare gates an edge-detected count — three families cooperating on one rung.")], labKind:.ladder, fieldNote:"The authoritative catalog is Rockwell publication 1756-RM003 (General Instructions) plus the process, motion and safety reference manuals.") }

    private static func oneShots() -> StepByStepLesson { .init(id:"digital-one-shots", title:"One-Shots: ONS, OSR and OSF", track:.digitalIO, difficulty:.beginner, estimatedMinutes:20, summary:"Act exactly once per transition instead of every scan the condition is true.", objectives:["Use ONS on the input side with a unique storage bit", "Use OSR/OSF to produce a named one-scan pulse", "Recognize when a level contact would misfire"], tagsToCreate:["Start_Request : BOOL", "Start_ONS : BOOL storage", "Latch_Snapshot : BOOL", "Reset_Edge : BOOL"], steps:[
        .init("os1", title:"Detect the rising edge", instruction:"Place ONS with a dedicated storage bit before the action that must run once when Start_Request goes true.", whyItMatters:"Without the one-shot, a request held true for 10 scans triggers the action 10 times.", checkpoint:"The downstream action fires on exactly one scan per false→true transition."),
        .init("os2", title:"Never share a storage bit", instruction:"Give each ONS its own storage BOOL.", whyItMatters:"A shared storage bit makes one one-shot suppress the other and both misfire.", checkpoint:"You can explain why ONS storage bits must be unique."),
        .init("os3", title:"Use an output-side one-shot", instruction:"Use OSR to set Reset_Edge true for one scan on a rising edge so several other rungs can consume the same pulse.", whyItMatters:"OSR/OSF give the edge event a name; OSF fires on the falling edge (end of a condition).", checkpoint:"You can choose ONS vs OSR/OSF based on whether other rungs need the pulse.")
    ], referenceRungs:[
        .init("osr0", rungNumber:0, purpose:"One count per request", ladderText:"|--[XIC Start_Request]--[ONS Start_ONS]---------(OTL Latch_Snapshot)--|", explanation:"The latch is set once even though Start_Request may stay true for many scans."),
        .init("osr1", rungNumber:10, purpose:"Named reset pulse", ladderText:"|--[XIC Reset_PB]-----------------------------------[OSR Reset_Edge]--|", explanation:"Reset_Edge is true for exactly one scan and can be examined by multiple downstream rungs.")
    ], labKind:.ladder) }

    private static func retentiveTimers() -> StepByStepLesson { .init(id:"sequence-retentive-timers", title:"Retentive Timing with RTO and RES", track:.sequencing, difficulty:.intermediate, estimatedMinutes:25, summary:"Accumulate elapsed time across interruptions and reset it deliberately.", objectives:["Distinguish RTO from TON on a false rung", "Use RES to clear a retentive timer", "Apply RTO to run-hours and cumulative fault time"], tagsToCreate:["Motor_Running : BOOL", "Runtime_Timer : TIMER", "Runtime_Reset : BOOL", "Maintenance_Due : BOOL"], steps:[
        .init("rt1", title:"Accumulate while running", instruction:"Execute RTO Runtime_Timer while Motor_Running is true.", whyItMatters:"Unlike TON, an RTO keeps its .ACC when the rung goes false, so total running time survives every stop.", checkpoint:"Stopping and restarting the motor does not zero Runtime_Timer.ACC."),
        .init("rt2", title:"Flag maintenance", instruction:"When Runtime_Timer.DN is true, set Maintenance_Due.", whyItMatters:"The done bit reaching preset is the cumulative-hours milestone.", checkpoint:"Maintenance_Due latches only after the configured accumulated time."),
        .init("rt3", title:"Reset deliberately", instruction:"Use RES Runtime_Timer from a maintenance-completed condition only.", whyItMatters:"An RTO has no automatic reset; clearing it accidentally loses the maintenance history.", checkpoint:"Runtime_Timer.ACC returns to zero only on the intended reset event.")
    ], referenceRungs:[
        .init("rtr0", rungNumber:0, purpose:"Accumulate run time", ladderText:"|--[XIC Motor_Running]------------------------------(RTO Runtime_Timer)--|", explanation:"The accumulator advances only while running and holds through every stop."),
        .init("rtr1", rungNumber:10, purpose:"Deliberate reset", ladderText:"|--[XIC Runtime_Reset]--[XIO Motor_Running]-----------(RES Runtime_Timer)--|", explanation:"Reset is gated so history is only cleared when maintenance is actually done.")
    ], labKind:.ladder, fieldNote:"A DINT millisecond preset covers up to ~24.8 days; for longer horizons accumulate whole hours in a DINT on each RTO.DN and RES cycle.") }

    private static func ioCatalog() -> StepByStepLesson { .init(id:"comm-io-catalog", title:"I/O Module Types and Catalog Numbers", track:.communications, difficulty:.intermediate, estimatedMinutes:28, summary:"Decode a 1756 I/O catalog number and choose the right module for a field signal.", objectives:["Decode the signal-class letter and feature suffixes", "Match a sensor to a sinking or sourcing input", "Identify the configuration a channel needs (scaling, filter, safe state)"], tagsToCreate:["DI_Prox_PNP : BOOL input", "AI_Pressure : REAL input", "AO_Valve : REAL output"], steps:[
        .init("ic1", title:"Decode the number", instruction:"Read 1756-OB16E as output / 24 V DC sourcing (B) / 16 points / electronically protected (E).", whyItMatters:"The catalog number tells you voltage, direction, density and features before you open a manual.", checkpoint:"You can decode IB16, IV16, OA16, OW16I, IF8, IR6I and IT6I from the letters."),
        .init("ic2", title:"Match sensor to input", instruction:"A 3-wire PNP proximity sensor sources +24 V, so it needs a sinking input (1756-IB x). An NPN sensor needs a sourcing input (1756-IV x).", whyItMatters:"A mismatch reads permanently on (leakage) or never on.", checkpoint:"You can pick the input module for a given sensor type and explain the current path."),
        .init("ic3", title:"Plan the channel configuration", instruction:"For an analog input, list what you must set: electrical range, engineering scaling, RTS, filter, per-channel alarms, and the hold-last vs safe-value behavior on connection loss.", whyItMatters:"An unconfigured safe state means a valve freezes on comms loss instead of failing to a known position.", checkpoint:"You can state the safe-state decision for an analog output before commissioning.")
    ], referenceRungs:[.init("ico0", rungNumber:0, purpose:"Alias, don't hard-address", ladderText:"|--[XIC DI_Prox_PNP]--[XIO AI_Pressure_Fault]---------(OTE Feed_Permissive)--|", explanation:"Program against aliased plant names; the alias maps to Local:x:I.Data.y and the module's channel-fault bit, so logic still reads clearly if the module moves.")], labKind:.ladder, fieldNote:"5069 Compact 5000 I/O uses the same ideas with a universal analog input (5069-IY4) and integrated safety modules; POINT (1734) and FLEX (1794) I/O add per-point granularity and hazardous-area variants.") }

    private static func capstone() -> StepByStepLesson { .init(id:"capstone-networked-pump", title:"Capstone: Networked Pump Skid with Digital + Analog I/O and Historian", track:.historian, difficulty:.advanced, estimatedMinutes:90, summary:"Build a small pump application from field I/O through controller logic, controller-to-controller status exchange, HMI exposure and historical evidence.", objectives:["Combine digital permissives and analog process values", "Build clear command/status ownership", "Choose cyclic vs explicit communications intentionally", "Create a historian point plan", "Troubleshoot the complete data path"], tagsToCreate:["Start_PB : BOOL", "Stop_OK : BOOL", "Pump_Run : BOOL", "Pressure_Raw : REAL", "PressurePV : REAL", "SpeedCmdPct : REAL", "Skid_Status : structure concept", "Remote_Status : consumed structure", "Historian points: PressurePV, SpeedCmdPct, Pump_Run, Faulted"], steps:[
        .init("c1", title:"Build local motor permissives", instruction:"Create Start/Stop/interlock logic and prove it in the microscope.", whyItMatters:"Network and historian layers are useless if the local machine logic is ambiguous.", checkpoint:"The pump can only run under valid local permissives."),
        .init("c2", title:"Scale the pressure transmitter", instruction:"Preserve Pressure_Raw and calculate PressurePV in engineering units.", whyItMatters:"Every downstream consumer should receive a physically meaningful value.", checkpoint:"Raw endpoints map to the intended pressure range."),
        .init("c3", title:"Create the analog speed command", instruction:"Generate SpeedCmdPct, enforce limits/safe state, then convert at the hardware boundary.", whyItMatters:"Command authority and safe-state behavior must remain obvious.", checkpoint:"Loss of a permissive forces the intended speed command."),
        .init("c4", title:"Publish status", instruction:"Create a controller-owned status structure and share it through a produced/consumed teaching link.", whyItMatters:"Cyclic status exchange is a contract between controllers, not a collection of ad hoc tag reads.", checkpoint:"The remote controller receives a coherent status snapshot."),
        .init("c5", title:"Add an explicit maintenance read", instruction:"Use a CIP Data Table Read teaching MSG for a data item that does not need a continuous cyclic connection.", whyItMatters:"Choose communications based on timing/ownership needs rather than using MSG for everything.", checkpoint:"The explicit read has a deliberate trigger and error handling."),
        .init("c6", title:"Plan the historian", instruction:"Historize pressure, command, run state and faults at rates appropriate to their dynamics.", whyItMatters:"The stored evidence should reconstruct both process behavior and controller state over time.", checkpoint:"The point plan can answer both a transient fault question and a degradation-trend question."),
        .init("c7", title:"Break the data path", instruction:"Introduce a communication delay or stale point and diagnose whether the problem lies in field I/O, PLC logic, controller communications, HMI polling or historian collection.", whyItMatters:"The capstone's goal is end-to-end mental-model separation.", checkpoint:"You identify the failed layer from evidence rather than guessing from the final symptom.")
    ], referenceRungs:[
        .init("cr0", rungNumber:0, purpose:"Pump permissives", ladderText:"|--[XIC Stop_OK]--[XIC PressurePermissive]--+--[XIC Start_PB]--+--(OTE Pump_Run)--|\n|                                           +--[XIC Pump_Run]--+                  |", explanation:"Local machine operation remains deterministic even when higher-level communications are unavailable."),
        .init("cr1", rungNumber:100, purpose:"Remote-ready interlock", ladderText:"|--[XIC Remote_Status.DownstreamReady]--[XIC LocalReady]--(OTE TransferPermissive)--|", explanation:"Received network status participates in logic, but its freshness/quality must be considered separately.")
    ], labKind:.integratedCapstone, fieldNote:"The capstone intentionally treats controller logic, I/O transport, controller-to-controller communication, HMI access, and historian storage as separate evidence layers.") }
}

public enum StepByStepReferenceProjectFactory {
    public static func project(for lessonID: String) throws -> ControllerProject? {
        switch lessonID {
        case "foundation-first-rung": return try simpleProject(name: "FirstRung", tags: [
            .init(name:"Start_PB", value:.bool(false), role:.input), .init(name:"Motor_Run", value:.bool(false), role:.output)
        ], rungs:[.init(number:0, comment:"Direct digital input to output", logic:.series([.instruction(.xic(tag:"Start_PB")), .instruction(.ote(tag:"Motor_Run"))]))])
        case "digital-motor-seal": return try simpleProject(name:"MotorSealIn", tags:[
            .init(name:"Start_PB", value:.bool(false), role:.input), .init(name:"Stop_OK", value:.bool(true), role:.input), .init(name:"Motor_Run", value:.bool(false), role:.output)
        ], rungs:[.init(number:0, comment:"Three-wire start/stop seal-in", logic:.series([
            .instruction(.xic(tag:"Stop_OK")),
            .parallel([.instruction(.xic(tag:"Start_PB")), .instruction(.xic(tag:"Motor_Run"))]),
            .instruction(.ote(tag:"Motor_Run"))
        ]))])
        case "digital-interlocks": return try simpleProject(name:"PermissivesAndFaults", tags:[
            .init(name:"Run_Request", value:.bool(false), role:.input), .init(name:"Guard_OK", value:.bool(true), role:.input), .init(name:"Air_OK", value:.bool(true), role:.input), .init(name:"OverloadTrip", value:.bool(false), role:.input), .init(name:"Reset_PB", value:.bool(false), role:.input), .init(name:"Machine_Run", value:.bool(false), role:.output), .init(name:"Machine_Fault", value:.bool(false))
        ], rungs:[
            .init(number:0, comment:"Run permissives", logic:.series([.instruction(.xic(tag:"Run_Request")), .instruction(.xic(tag:"Guard_OK")), .instruction(.xic(tag:"Air_OK")), .instruction(.xio(tag:"Machine_Fault")), .instruction(.ote(tag:"Machine_Run"))])),
            .init(number:10, comment:"Latch overload fault", logic:.series([.instruction(.xic(tag:"OverloadTrip")), .instruction(.otl(tag:"Machine_Fault"))])),
            .init(number:20, comment:"Reset only when trip is clear", logic:.series([.instruction(.xic(tag:"Reset_PB")), .instruction(.xio(tag:"OverloadTrip")), .instruction(.otu(tag:"Machine_Fault"))]))
        ])
        case "sequence-timer-counter": return try simpleProject(name:"TimerSequence", tags:[
            .init(name:"PE_Clear", value:.bool(true), role:.input), .init(name:"TransferComplete", value:.bool(false), role:.input), .init(name:"State", value:.dint(10)), .init(name:"TransferDelay", value:.timer(.init(PRE:500))), .init(name:"BoxCount", value:.counter(.init(PRE:100)))
        ], rungs:[
            .init(number:100, comment:"State-10 dwell", logic:.series([.instruction(.equ(.tag("State"), .dint(10))), .instruction(.xic(tag:"PE_Clear")), .instruction(.ton(timer:"TransferDelay"))])),
            .init(number:110, comment:"Advance to State 20", logic:.series([.instruction(.equ(.tag("State"), .dint(10))), .instruction(.xic(tag:"TransferDelay.DN")), .instruction(.mov(source:.dint(20), destination:"State"))])),
            .init(number:120, comment:"Count transfer events", logic:.series([.instruction(.xic(tag:"TransferComplete")), .instruction(.ctu(counter:"BoxCount"))]))
        ])
        case "analog-input-scaling": return try simpleProject(name:"AnalogScaling", tags:[
            .init(name:"Pressure_Raw", value:.real(8_000), role:.input), .init(name:"RawMin", value:.real(4_000)), .init(name:"RawSpan", value:.real(16_000)), .init(name:"EUMin", value:.real(0)), .init(name:"EUSpan", value:.real(150)), .init(name:"Pressure_Offset", value:.real(0)), .init(name:"Pressure_Normalized", value:.real(0)), .init(name:"Pressure_ScaledSpan", value:.real(0)), .init(name:"PressurePV", value:.real(0))
        ], rungs:[
            .init(number:0, comment:"Remove raw offset", logic:.instruction(.sub(.tag("Pressure_Raw"), .tag("RawMin"), destination:"Pressure_Offset"))),
            .init(number:10, comment:"Normalize raw span", logic:.instruction(.div(.tag("Pressure_Offset"), .tag("RawSpan"), destination:"Pressure_Normalized"))),
            .init(number:20, comment:"Apply engineering span", logic:.instruction(.mul(.tag("Pressure_Normalized"), .tag("EUSpan"), destination:"Pressure_ScaledSpan"))),
            .init(number:30, comment:"Add engineering minimum", logic:.instruction(.add(.tag("Pressure_ScaledSpan"), .tag("EUMin"), destination:"PressurePV")))
        ])
        case "analog-alarms": return try simpleProject(name:"AnalogAlarm", tags:[
            .init(name:"PressurePV", value:.real(50), role:.input), .init(name:"HighLimit", value:.real(120)), .init(name:"HighReset", value:.real(110)), .init(name:"PressureHigh", value:.bool(false))
        ], rungs:[
            .init(number:0, comment:"Latch high alarm", logic:.series([.instruction(.geq(.tag("PressurePV"), .tag("HighLimit"))), .instruction(.otl(tag:"PressureHigh"))])),
            .init(number:10, comment:"Reset below hysteresis threshold", logic:.series([.instruction(.leq(.tag("PressurePV"), .tag("HighReset"))), .instruction(.otu(tag:"PressureHigh"))]))
        ])
        case "analog-level-hysteresis": return try simpleProject(name:"LevelDeadband", tags:[
            .init(name:"LevelPV", value:.real(50), role:.input), .init(name:"LowStart", value:.real(30)), .init(name:"HighStop", value:.real(70)), .init(name:"FillValve", value:.bool(false), role:.output)
        ], rungs:[
            .init(number:0, comment:"Start fill below low threshold", logic:.series([.instruction(.leq(.tag("LevelPV"), .tag("LowStart"))), .instruction(.otl(tag:"FillValve"))])),
            .init(number:10, comment:"Stop fill above high threshold", logic:.series([.instruction(.geq(.tag("LevelPV"), .tag("HighStop"))), .instruction(.otu(tag:"FillValve"))]))
        ])
        case "comm-hmi-scada": return try simpleProject(name:"HMICommandPattern", tags:[
            .init(name:"HMI_StartCmd", value:.bool(false), role:.input), .init(name:"RemoteStartAllowed", value:.bool(true)), .init(name:"Run_Request", value:.bool(false)), .init(name:"Machine_Running", value:.bool(false), role:.output), .init(name:"PressurePV", value:.real(0), role:.input)
        ], rungs:[
            .init(number:0, comment:"HMI start enters command architecture", logic:.series([.instruction(.xic(tag:"HMI_StartCmd")), .instruction(.xic(tag:"RemoteStartAllowed")), .instruction(.otl(tag:"Run_Request"))])),
            .init(number:10, comment:"Status remains distinct from command", logic:.series([.instruction(.xic(tag:"Run_Request")), .instruction(.ote(tag:"Machine_Running"))]))
        ])
        default: return nil
        }
    }

    private static func simpleProject(name: String, tags: [PLCTag], rungs: [Rung]) throws -> ControllerProject {
        let store = try TagStore(tags: tags)
        let routine = LadderRoutine(name:"MainRoutine", rungs:rungs)
        let program = ControllerProgram(name:"StepByStep", mainRoutineName:"MainRoutine", routines:[routine])
        let task = ControllerTask(name:"MainTask", kind:.continuous, watchdogMilliseconds:500, programs:[program])
        return ControllerProject(name:name, controllerTags:store, tasks:[task])
    }
}

public enum StepByStepValidationSeverity: String, Codable, Sendable {
    case pass
    case warning
    case failure
}

public struct StepByStepValidationFinding: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var severity: StepByStepValidationSeverity
    public var title: String
    public var detail: String

    public init(_ id: String, severity: StepByStepValidationSeverity, title: String, detail: String) {
        self.id=id; self.severity=severity; self.title=title; self.detail=detail
    }
}

public struct StepByStepValidationReport: Codable, Equatable, Sendable {
    public var lessonID: String
    public var findings: [StepByStepValidationFinding]
    public var passed: Bool { !findings.contains { $0.severity == .failure } }
    public var passCount: Int { findings.filter { $0.severity == .pass }.count }

    public init(lessonID: String, findings: [StepByStepValidationFinding]) {
        self.lessonID=lessonID; self.findings=findings
    }
}

/// Structural project checker for lessons that have an executable ladder target.
/// It intentionally checks teaching invariants rather than requiring byte-for-byte equality
/// with the reference project, leaving room for alternate valid rung numbers/comments.
public enum StepByStepProjectValidator {
    public static func validate(project: ControllerProject, lesson: StepByStepLesson) -> StepByStepValidationReport {
        let rungs = project.tasks.flatMap(\.programs).flatMap(\.routines).flatMap(\.rungs)
        let instructions = rungs.flatMap { flatten($0.logic) }
        var findings: [StepByStepValidationFinding] = []

        func tag(_ name: String, type: TagDataType, role: TagRole? = nil) -> Bool {
            let all = project.controllerTags.allTags + project.tasks.flatMap(\.programs).flatMap { $0.tags.allTags }
            guard let candidate = all.first(where: { $0.name == name }) else {
                findings.append(.init("tag-\(name)", severity:.failure, title:"Missing tag \(name)", detail:"Create \(name) before validating the rung.")); return false
            }
            guard candidate.dataType == type else {
                findings.append(.init("tag-\(name)", severity:.failure, title:"Wrong type for \(name)", detail:"Expected \(type.rawValue), found \(candidate.dataType.rawValue).")); return false
            }
            if let role, candidate.role != role {
                findings.append(.init("tag-\(name)-role", severity:.warning, title:"Check role for \(name)", detail:"The lesson expects \(role.rawValue); this project marks it \(candidate.role.rawValue)."))
            } else {
                findings.append(.init("tag-\(name)", severity:.pass, title:"Tag \(name) is ready", detail:"Type and teaching role are compatible."))
            }
            return true
        }

        func require(_ condition: Bool, _ id: String, _ title: String, _ detail: String) {
            findings.append(.init(id, severity: condition ? .pass : .failure, title:title, detail:detail))
        }

        switch lesson.id {
        case "foundation-first-rung":
            _=tag("Start_PB", type:.bool, role:.input); _=tag("Motor_Run", type:.bool, role:.output)
            require(instructions.contains(.xic(tag:"Start_PB")), "xic-start", "XIC Start_PB", "The input contact must participate in logic.")
            require(instructions.contains(.ote(tag:"Motor_Run")), "ote-motor", "OTE Motor_Run", "The output must be driven by ladder logic.")
        case "digital-motor-seal":
            _=tag("Start_PB", type:.bool); _=tag("Stop_OK", type:.bool); _=tag("Motor_Run", type:.bool)
            require(instructions.contains(.xic(tag:"Stop_OK")), "stop", "Stop permissive is present", "The stop/permissive condition must interrupt the run path.")
            require(instructions.contains(.ote(tag:"Motor_Run")), "motor-output", "Motor output is driven", "Motor_Run needs an OTE in the completed rung.")
            let hasSealParallel = rungs.contains { containsParallelSeal(node:$0.logic, startTag:"Start_PB", sealTag:"Motor_Run") }
            require(hasSealParallel, "seal", "Parallel start/seal branch", "Create parallel XIC Start_PB and XIC Motor_Run paths rather than putting them in series.")
        case "digital-interlocks":
            ["Run_Request","Guard_OK","Air_OK","OverloadTrip","Reset_PB","Machine_Run","Machine_Fault"].forEach { _=tag($0, type:.bool) }
            require(instructions.contains(.otl(tag:"Machine_Fault")), "fault-latch", "Fault latch exists", "Use OTL to retain the trip after the initiating condition clears.")
            require(instructions.contains(.otu(tag:"Machine_Fault")), "fault-reset", "Fault reset exists", "Use a deliberate OTU reset path.")
            require(instructions.contains(.xio(tag:"Machine_Fault")), "fault-inhibit", "Latched fault blocks run", "The run path should be inhibited while Machine_Fault is true.")
        case "sequence-timer-counter":
            _=tag("State", type:.dint); _=tag("TransferDelay", type:.timer); _=tag("BoxCount", type:.counter)
            require(instructions.contains(.ton(timer:"TransferDelay")), "timer", "TON TransferDelay", "The sequence needs a timed dwell.")
            require(instructions.contains(.ctu(counter:"BoxCount")), "counter", "CTU BoxCount", "The sequence counts completed events.")
            require(instructions.contains(where: { if case .mov(_, let destination) = $0 { destination == "State" } else { false } }), "state-write", "Explicit state transition", "Write the next state explicitly so the transition is traceable.")
        case "analog-input-scaling":
            _=tag("Pressure_Raw", type:.real, role:.input); _=tag("PressurePV", type:.real)
            require(instructions.contains(where: { if case .sub(.tag("Pressure_Raw"), _, _) = $0 { true } else { false } }), "scale-sub", "Raw offset subtraction", "Remove the raw minimum before normalizing.")
            require(instructions.contains(where: { if case .div(_, _, _) = $0 { true } else { false } }), "scale-div", "Normalization division", "Divide by the raw span.")
            require(instructions.contains(where: { if case .mul(_, _, _) = $0 { true } else { false } }), "scale-mul", "Engineering span multiplication", "Apply the engineering span.")
            require(instructions.contains(where: { if case .add(_, _, let destination) = $0 { destination == "PressurePV" } else { false } }), "scale-add", "Engineering minimum applied", "The final step writes PressurePV.")
        case "analog-alarms":
            _=tag("PressurePV", type:.real); _=tag("PressureHigh", type:.bool)
            require(instructions.contains(where: { if case .geq(.tag("PressurePV"), _) = $0 { true } else { false } }), "high-trip", "High comparison exists", "Use GEQ for the high trip threshold.")
            require(instructions.contains(.otl(tag:"PressureHigh")), "high-latch", "High alarm latches", "The alarm retains evidence of the crossing.")
            require(instructions.contains(where: { if case .leq(.tag("PressurePV"), _) = $0 { true } else { false } }), "high-reset-threshold", "Separate reset comparison exists", "Use a lower reset threshold to create hysteresis.")
            require(instructions.contains(.otu(tag:"PressureHigh")), "high-reset", "High alarm reset exists", "Reset the alarm after PV returns sufficiently low.")
        case "analog-level-hysteresis":
            _=tag("LevelPV", type:.real); _=tag("FillValve", type:.bool, role:.output)
            require(instructions.contains(where: { if case .leq(.tag("LevelPV"), _) = $0 { true } else { false } }), "level-start", "Low threshold exists", "Start fill at or below the low threshold.")
            require(instructions.contains(where: { if case .geq(.tag("LevelPV"), _) = $0 { true } else { false } }), "level-stop", "High threshold exists", "Stop fill at or above the high threshold.")
            require(instructions.contains(.otl(tag:"FillValve")) && instructions.contains(.otu(tag:"FillValve")), "level-memory", "Valve uses hysteretic memory", "The output must retain its state through the deadband.")
        case "comm-hmi-scada":
            _=tag("HMI_StartCmd", type:.bool); _=tag("Machine_Running", type:.bool)
            require("HMI_StartCmd" != "Machine_Running", "command-status", "Command and status are separate", "Operator requests should not double as equipment feedback.")
            require(instructions.contains(.xic(tag:"HMI_StartCmd")), "hmi-request", "HMI request enters ladder logic", "The command is processed through controller logic rather than directly equated to physical state.")
        default:
            findings.append(.init("no-validator", severity:.warning, title:"No structural ladder validator for this lesson yet", detail:"Use the deterministic lab and lesson checkpoints for this communications/data lesson."))
        }
        return .init(lessonID:lesson.id, findings:findings)
    }

    private static func flatten(_ node: LogicNode) -> [Instruction] {
        switch node {
        case let .instruction(i): [i]
        case let .series(nodes), let .parallel(nodes): nodes.flatMap(flatten)
        }
    }

    private static func containsParallelSeal(node: LogicNode, startTag: String, sealTag: String) -> Bool {
        switch node {
        case .instruction: return false
        case let .series(nodes): return nodes.contains { containsParallelSeal(node:$0, startTag:startTag, sealTag:sealTag) }
        case let .parallel(nodes):
            let branches = nodes.map(flatten)
            let hasStart = branches.contains { $0.contains(.xic(tag:startTag)) }
            let hasSeal = branches.contains { $0.contains(.xic(tag:sealTag)) }
            return (hasStart && hasSeal) || nodes.contains { containsParallelSeal(node:$0, startTag:startTag, sealTag:sealTag) }
        }
    }
}

public struct StepByStepProgressProfile: Codable, Equatable, Sendable {
    public private(set) var completedLessonIDs: Set<String>

    public init(completedLessonIDs: Set<String> = []) { self.completedLessonIDs = completedLessonIDs }

    public mutating func markComplete(_ lessonID: String) { completedLessonIDs.insert(lessonID) }
    public mutating func reset(_ lessonID: String) { completedLessonIDs.remove(lessonID) }
    public func isComplete(_ lessonID: String) -> Bool { completedLessonIDs.contains(lessonID) }

    public func isUnlocked(_ lesson: StepByStepLesson) -> Bool {
        StepByStepCatalog.prerequisites(for: lesson.id).allSatisfy(completedLessonIDs.contains)
    }

    public var completionFraction: Double {
        guard !StepByStepCatalog.all.isEmpty else { return 0 }
        return Double(completedLessonIDs.intersection(Set(StepByStepCatalog.all.map(\.id))).count) / Double(StepByStepCatalog.all.count)
    }
}

public extension StepByStepCatalog {
    static func prerequisites(for lessonID: String) -> [String] {
        switch lessonID {
        case "foundation-scan": []
        case "foundation-logix-tasks": ["foundation-scan"]
        case "foundation-tags": ["foundation-scan"]
        case "foundation-first-rung": ["foundation-tags"]
        case "foundation-controller-organization": ["foundation-first-rung"]
        case "foundation-instruction-families": ["foundation-first-rung"]
        case "digital-xic-xio": ["foundation-first-rung"]
        case "digital-command-feedback": ["digital-xic-xio"]
        case "digital-one-shots": ["digital-xic-xio"]
        case "digital-motor-seal": ["digital-command-feedback", "foundation-controller-organization"]
        case "digital-interlocks": ["digital-motor-seal"]
        case "sequence-routine-jsr": ["digital-interlocks"]
        case "sequence-timer-counter": ["sequence-routine-jsr"]
        case "sequence-retentive-timers": ["sequence-timer-counter"]
        case "analog-input-scaling": ["foundation-first-rung"]
        case "analog-alarms": ["analog-input-scaling", "digital-xic-xio"]
        case "analog-output-command": ["analog-input-scaling", "digital-interlocks"]
        case "analog-level-hysteresis": ["analog-alarms"]
        case "foundation-structured-data": ["sequence-timer-counter", "analog-input-scaling"]
        case "comm-remote-io-tree": ["foundation-structured-data"]
        case "comm-io-catalog": ["comm-remote-io-tree"]
        case "comm-io-rpi": ["comm-remote-io-tree"]
        case "comm-produced-consumed": ["comm-io-rpi", "foundation-structured-data"]
        case "comm-msg-read": ["comm-produced-consumed"]
        case "comm-msg-write": ["comm-msg-read"]
        case "comm-hmi-scada": ["digital-command-feedback", "analog-input-scaling"]
        case "historian-points-scan": ["comm-hmi-scada", "analog-alarms"]
        case "capstone-networked-pump": all.filter { $0.id != "capstone-networked-pump" }.map(\.id)
        default: []
        }
    }
}

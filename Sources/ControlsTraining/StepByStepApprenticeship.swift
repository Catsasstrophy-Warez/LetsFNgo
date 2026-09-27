import Foundation
import ControlsPLC

public enum ApprenticeshipSkill: String, Codable, CaseIterable, Sendable {
    case scanReasoning
    case tagsAndTypes
    case instructionChoice
    case rungTopology
    case interlocksAndState
    case analogMath
    case communications
    case historianReasoning
    case verification

    public var title: String {
        switch self {
        case .scanReasoning: "Scan reasoning"
        case .tagsAndTypes: "Tags & data types"
        case .instructionChoice: "Instruction choice"
        case .rungTopology: "Rung topology"
        case .interlocksAndState: "Interlocks & sequence state"
        case .analogMath: "Analog math"
        case .communications: "Communications"
        case .historianReasoning: "Historian & evidence"
        case .verification: "Verification discipline"
        }
    }
}

public struct ApprenticeshipSkillProfile: Codable, Equatable, Sendable {
    public private(set) var scores: [ApprenticeshipSkill: Double]

    public init(scores: [ApprenticeshipSkill: Double] = [:]) {
        self.scores = scores
    }

    public func score(for skill: ApprenticeshipSkill) -> Double { scores[skill] ?? 0.5 }

    public var weakestSkill: ApprenticeshipSkill {
        ApprenticeshipSkill.allCases.min { score(for:$0) < score(for:$1) } ?? .scanReasoning
    }

    public mutating func apply(_ result: ApprenticeshipGrade) {
        for component in result.components {
            let old = score(for: component.skill)
            let observed = component.possiblePoints > 0 ? component.awardedPoints / component.possiblePoints : 1
            scores[component.skill] = max(0, min(1, old * 0.65 + observed * 0.35))
        }
    }
}

public enum ApprenticeshipExerciseKind: String, Codable, Sendable {
    case buildFromScratch
    case repairBrokenProgram
    case predictThenRun
}

public struct ApprenticeshipExercise: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var lessonID: String
    public var kind: ApprenticeshipExerciseKind
    public var title: String
    public var prompt: String
    public var targetSkills: [ApprenticeshipSkill]
    public var seed: UInt64
    public var hints: [String]

    public init(id: String, lessonID: String, kind: ApprenticeshipExerciseKind, title: String, prompt: String, targetSkills: [ApprenticeshipSkill], seed: UInt64, hints: [String] = []) {
        self.id=id; self.lessonID=lessonID; self.kind=kind; self.title=title; self.prompt=prompt; self.targetSkills=targetSkills; self.seed=seed; self.hints=hints
    }
}

public struct ApprenticeshipGradeComponent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var skill: ApprenticeshipSkill
    public var title: String
    public var awardedPoints: Double
    public var possiblePoints: Double
    public var feedback: String

    public init(id: String, skill: ApprenticeshipSkill, title: String, awardedPoints: Double, possiblePoints: Double, feedback: String) {
        self.id=id; self.skill=skill; self.title=title; self.awardedPoints=awardedPoints; self.possiblePoints=possiblePoints; self.feedback=feedback
    }
}

public struct ApprenticeshipGrade: Codable, Equatable, Sendable {
    public var lessonID: String
    public var components: [ApprenticeshipGradeComponent]
    public var validation: StepByStepValidationReport
    public var verificationPerformed: Bool

    public var awardedPoints: Double { components.reduce(0) { $0 + $1.awardedPoints } }
    public var possiblePoints: Double { components.reduce(0) { $0 + $1.possiblePoints } }
    public var percent: Double { possiblePoints > 0 ? awardedPoints / possiblePoints * 100 : 0 }
    public var passed: Bool { validation.passed && verificationPerformed && percent >= 70 }
}



public enum ApprenticeshipChallengeStyle: String, Codable, CaseIterable, Sendable {
    case build
    case repair
    case diagnose
    case commission
}

public struct ApprenticeshipChallengeTemplate: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var lessonID: String
    public var style: ApprenticeshipChallengeStyle
    public var prompt: String
    public var targetSkills: [ApprenticeshipSkill]
    public var difficulty: Int
    public var machineContext: String
    public var acceptanceEvidence: [String]
}

/// Larger apprenticeship bank used to keep repeated practice from collapsing into memorization.
public enum ApprenticeshipChallengeCatalog {
    public static let all: [ApprenticeshipChallengeTemplate] = [
        .init(id:"first-rung-no-output", title:"The light never turns on", lessonID:"foundation-first-rung", style:.repair, prompt:"A pilot-light rung compiles, but pressing the pushbutton never energizes the output. Repair the instruction choice and prove the output follows the input.", targetSkills:[.instructionChoice,.verification], difficulty:1, machineContext:"Bench trainer", acceptanceEvidence:["Output follows input TRUE/FALSE", "No missing tag references"]),
        .init(id:"seal-in-drops", title:"Starter drops when Start is released", lessonID:"digital-motor-seal", style:.repair, prompt:"The motor runs only while Start is held. Repair the holding circuit without bypassing Stop_OK.", targetSkills:[.rungTopology,.instructionChoice,.verification], difficulty:2, machineContext:"Motor starter", acceptanceEvidence:["Motor seals after Start release", "Stop_OK still interrupts run"]),
        .init(id:"fault-wont-reset", title:"Fault reset does nothing", lessonID:"digital-interlocks", style:.repair, prompt:"The overload alarm latches correctly, but Reset clears it even while the overload is still active in one version and never clears in another. Build the safe reset path.", targetSkills:[.interlocksAndState,.instructionChoice,.verification], difficulty:3, machineContext:"Packaging cell", acceptanceEvidence:["Fault latches on trip", "Reset blocked while trip active", "Reset succeeds after trip clears"]),
        .init(id:"permissive-bypass", title:"Machine starts with guard open", lessonID:"digital-interlocks", style:.diagnose, prompt:"A recent edit accidentally moved Guard_OK out of the effective run path. Find the topology mistake and restore a permissive chain that cannot be bypassed by the seal branch.", targetSkills:[.rungTopology,.interlocksAndState], difficulty:4, machineContext:"Conveyor cell", acceptanceEvidence:["Guard open prevents start", "Existing run state drops when required by design"]),
        .init(id:"timer-never-done", title:"Transfer timer never reaches DN", lessonID:"sequence-timer-counter", style:.diagnose, prompt:"TransferDelay.ACC repeatedly climbs and resets before PRE. Determine which enable condition is chattering, then restructure the sequence so the timer sees the intended continuous dwell.", targetSkills:[.scanReasoning,.interlocksAndState,.verification], difficulty:4, machineContext:"Transfer station", acceptanceEvidence:["Timer enable remains continuous", "DN transitions after PRE"]),
        .init(id:"counter-overcounts", title:"One box counts many times", lessonID:"sequence-timer-counter", style:.repair, prompt:"BoxCount increases more than once for a single physical event. Repair the event logic and explain the edge behavior that CTU expects.", targetSkills:[.scanReasoning,.instructionChoice,.interlocksAndState], difficulty:4, machineContext:"Packaging cell", acceptanceEvidence:["One event produces one count", "Held TRUE does not repeatedly count"]),
        .init(id:"scaling-offset", title:"4 mA does not read zero", lessonID:"analog-input-scaling", style:.repair, prompt:"The pressure transmitter reads 37.5 psi too high across its range. Inspect the scaling chain and repair the raw-offset/span math.", targetSkills:[.analogMath,.verification], difficulty:3, machineContext:"Pressure skid", acceptanceEvidence:["Raw minimum maps to EU minimum", "Raw maximum maps to EU maximum", "Midscale is linear"]),
        .init(id:"scaling-span", title:"Midscale is wrong", lessonID:"analog-input-scaling", style:.diagnose, prompt:"Zero is correct but full scale is low. Determine whether the raw span or engineering span is wrong and prove the correction with three test points.", targetSkills:[.analogMath,.verification], difficulty:4, machineContext:"Tank level transmitter", acceptanceEvidence:["Three-point calibration passes", "Raw value remains visible for diagnostics"]),
        .init(id:"alarm-chatters", title:"High alarm chatters at the threshold", lessonID:"analog-alarms", style:.repair, prompt:"PressureHigh rapidly toggles around the trip threshold. Add a separate reset threshold and memory so the alarm behaves predictably.", targetSkills:[.analogMath,.instructionChoice,.verification], difficulty:3, machineContext:"Pressure skid", acceptanceEvidence:["Distinct trip/reset thresholds", "Alarm remains latched inside hysteresis band"]),
        .init(id:"fill-valve-chatters", title:"Fill valve chatters near setpoint", lessonID:"analog-level-hysteresis", style:.repair, prompt:"The fill valve is commanded directly from one comparison and chatters near 50%. Rebuild the logic with start/stop thresholds and retained state.", targetSkills:[.analogMath,.interlocksAndState,.verification], difficulty:3, machineContext:"Batch tank", acceptanceEvidence:["Valve starts below LowStart", "Valve stops above HighStop", "State holds through deadband"]),
        .init(id:"hmi-command-is-status", title:"HMI shows Running before motor moves", lessonID:"comm-hmi-scada", style:.repair, prompt:"An HMI Start command tag was reused as machine running status. Separate request, controller command, and equipment feedback so operators cannot mistake intent for reality.", targetSkills:[.communications,.tagsAndTypes,.verification], difficulty:4, machineContext:"Remote conveyor HMI", acceptanceEvidence:["Command and status use separate tags", "Status derives from controller/feedback path"]),
        .init(id:"remote-rpi-blindspot", title:"Remote input pulse disappears", lessonID:"comm-remote-io", style:.diagnose, prompt:"A short remote photoeye pulse is visible electrically but intermittently absent in logic. Compare pulse width, module update/RPI, and task execution before changing ladder code.", targetSkills:[.communications,.scanReasoning,.verification], difficulty:5, machineContext:"Remote I/O rack", acceptanceEvidence:["Explain RPI vs task period", "Choose a capture strategy that preserves the event"]),
        .init(id:"msg-stale-data", title:"MSG completes but data is stale", lessonID:"comm-msg-read", style:.diagnose, prompt:"The CIP Data Table Read reports success, yet the value is older than expected. Separate message completion, trigger frequency, source update, and application freshness.", targetSkills:[.communications,.verification], difficulty:5, machineContext:"Two-controller skid", acceptanceEvidence:["Distinguish .DN from data freshness", "Identify trigger/update timing"]),
        .init(id:"historian-misses-pulse", title:"Historian never saw the trip precursor", lessonID:"historian-points", style:.diagnose, prompt:"An 80 ms precursor exists in the PLC flight recorder but not the 1 s historian trend. Explain why and propose the right evidence strategy without simply making every historian tag high speed.", targetSkills:[.historianReasoning,.verification], difficulty:4, machineContext:"Plant historian", acceptanceEvidence:["Explain sampling blind spot", "Select appropriate scan class or event capture"]),
        .init(id:"capstone-pump-commission", title:"Commission the networked pump skid", lessonID:"capstone-networked-pump", style:.commission, prompt:"Commission the skid from cold start. Prove permissives, analog scaling, remote commands/status, communications health, and historian collection before declaring it production-ready.", targetSkills:[.rungTopology,.analogMath,.communications,.historianReasoning,.verification], difficulty:6, machineContext:"VFD pump skid", acceptanceEvidence:["Digital permissives verified", "Analog loop checked", "Remote status proven", "Historian samples include timestamp and quality"])
    ]

    public static func candidates(for skill: ApprenticeshipSkill, unlockedLessonIDs: Set<String>) -> [ApprenticeshipChallengeTemplate] {
        let targeted = all.filter { unlockedLessonIDs.contains($0.lessonID) && $0.targetSkills.contains(skill) }
        return targeted.isEmpty ? all.filter { unlockedLessonIDs.contains($0.lessonID) } : targeted
    }
}

public struct ScenarioFieldAssignment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var machineID: HeroMachineID
    public var faultID: String
    public var title: String
    public var briefing: String
    public var objectives: [String]
    public var difficulty: ScenarioDifficulty
}

/// Extra field assignments reuse the live seven-machine physics but vary operating context and diagnostic objective.
public enum ScenarioFieldAssignmentCatalog {
    public static let all: [ScenarioFieldAssignment] = [
        .init(id:"packaging-intermittent", machineID:.packagingCell, faultID:"pe203-sticky", title:"Intermittent transfer hold", briefing:"Operators report one stalled transfer every few hundred boxes, mostly late in the shift.", objectives:["Capture the first abnormal event", "Distinguish sensor state from sequence consequence", "Verify repair over repeated cycles"], difficulty:.intermediate),
        .init(id:"packaging-highspeed", machineID:.packagingCell, faultID:"short-pulse", title:"High-speed missed product", briefing:"The line is reliable at normal speed but loses counts after a production-rate increase.", objectives:["Compare pulse width to observation timing", "Prove whether the PLC ever saw the pulse", "Recommend an appropriate capture method"], difficulty:.advanced),
        .init(id:"pressure-stiction-early", machineID:.pressureSkid, faultID:"valve-stiction", title:"Catch stiction before the oscillation", briefing:"There is no visible pressure cycling yet. Maintenance suspects the valve is beginning to drag.", objectives:["Use command-position lag", "Avoid unnecessary PID tuning", "Identify earliest useful evidence"], difficulty:.advanced),
        .init(id:"pressure-delay-change", machineID:.pressureSkid, faultID:"dead-time-growth", title:"Yesterday's tuning, today's plant", briefing:"PID gains are unchanged but recovery after load changes is getting worse.", objectives:["Identify current plant", "Compare stability margins", "Explain plant-change vulnerability"], difficulty:.expert),
        .init(id:"servo-load-resonance", machineID:.servoConveyor, faultID:"bearing-resonance", title:"Only shakes when loaded", briefing:"Empty indexes look clean; high-load moves develop vibration and tracking error.", objectives:["Compare operating regimes", "Track dominant frequency vs speed/load", "Separate resonance from generic aggressive tuning"], difficulty:.advanced),
        .init(id:"pump-peak-demand", machineID:.pumpStation, faultID:"cavitation", title:"Peak-demand pump noise", briefing:"The station is quiet overnight but noisy at afternoon peak demand.", objectives:["Use suction/discharge context", "Recognize broadband hydraulic evidence", "Avoid treating every spectrum peak as resonance"], difficulty:.advanced),
        .init(id:"ahu-summer-beat", machineID:.airHandlingUnit, faultID:"loop-interaction", title:"Summer comfort oscillation", briefing:"Two individually stable loops create a slow comfort swing only during hot occupied periods.", objectives:["Resolve two spectral components", "Compare loop phase/frequency", "Repeat under a lighter operating mode"], difficulty:.expert),
        .init(id:"batch-drag-trend", machineID:.batchMixingTank, faultID:"agitator-drag", title:"Batch time slowly stretching", briefing:"No discrete fault exists, but current and mix dwell have drifted for weeks.", objectives:["Use multivariate evidence", "Compare recipe-aware trajectory", "Identify earliest degradation stage"], difficulty:.advanced),
        .init(id:"oven-forced-oscillation", machineID:.industrialOven, faultID:"burner-disturbance", title:"Temperature oscillation is not the PID", briefing:"Zone temperature has a narrow spectral line while controller margins remain healthy.", objectives:["Match external disturbance frequency", "Prove linear controller remains plausible", "Trace disturbance propagation"], difficulty:.expert)
,
        .init(id:"palletizer-grip", machineID:.roboticPalletizer, faultID:"vacuum-loss", title:"Heavy cartons lose grip", briefing:"The robot only faults on heavier cartons and the sequence sometimes continues past a weak pick.", objectives:["Compare GripOK timing by payload", "Prove vacuum margin is the initiating fault", "Verify motion interlock behavior"], difficulty:.advanced),
        .init(id:"liftstation-backflow", machineID:.wastewaterLiftStation, faultID:"check-valve-leak", title:"Why is the wet well refilling?", briefing:"Pump drawdown looks normal until the pump stops, then level rebounds abnormally fast.", objectives:["Compare post-stop level slope", "Check discharge-pressure decay", "Separate inflow from backflow"], difficulty:.intermediate),
        .init(id:"rack-hotday", machineID:.refrigerationRack, faultID:"condenser-fouling", title:"High head only on hot days", briefing:"The refrigeration rack is acceptable overnight but power and head pressure rise sharply in hot weather.", objectives:["Normalize by ambient", "Compare fan command to head pressure", "Distinguish load from fouling"], difficulty:.advanced),
        .init(id:"boiler-rich", machineID:.boilerSteamPlant, faultID:"fuel-air-drift", title:"Steam pressure looks fine, combustion does not", briefing:"Operators see no steam-pressure issue, but emissions and oxygen trend poorly at high fire.", objectives:["Compare O2 and CO with firing rate", "Avoid using steam pressure as combustion proof", "Identify load dependence"], difficulty:.expert),
        .init(id:"cnc-filter", machineID:.cncCoolantCell, faultID:"coolant-restriction", title:"Pressure up, flow down", briefing:"Coolant pressure increased after maintenance while flow alarms appear under heavy cutting.", objectives:["Use filter DP", "Compare pump command vs delivered flow", "Reject the temptation to simply raise speed"], difficulty:.intermediate),
        .init(id:"cleanroom-dp", machineID:.cleanroomPressureSystem, faultID:"door-leak", title:"Intermittent cleanroom pressure loss", briefing:"Room pressure dips during traffic periods even while fan command rises.", objectives:["Correlate DP dips with leakage events", "Separate controller response from disturbance", "Use temporal evidence"], difficulty:.advanced),
        .init(id:"asrs-docking", machineID:.asrsCrane, faultID:"encoder-slip", title:"In-position but misaligned", briefing:"The crane reports InPosition while physical docking error grows over repeated moves.", objectives:["Compare feedback to independent physical position", "Trend encoder bias", "Prove feedback integrity before retuning motion"], difficulty:.advanced),
        .init(id:"bottling-underfill", machineID:.bottlingLine, faultID:"fill-valve-drift", title:"Only the fast bottles are underfilled", briefing:"Fill checks pass at reduced rate but rejects spike during full production.", objectives:["Compare fill volume by line speed","Trend valve command vs delivered volume","Verify restored fill accuracy at full rate"], difficulty:.intermediate),
        .init(id:"cip-conductivity", machineID:.cipSkid, faultID:"conductivity-drift", title:"CIP concentration disagrees with chemistry", briefing:"The controller says concentration is acceptable but grab samples tell another story.", objectives:["Compare indicated and independent concentration evidence","Check drift across rinse and chemical phases","Avoid changing recipe strength before proving instrumentation"], difficulty:.advanced),
        .init(id:"airplant-night-leak", machineID:.compressedAirPlant, faultID:"air-leak-growth", title:"Why is the compressor loaded at night?", briefing:"Production is idle but compressor duty and energy stay unexpectedly high.", objectives:["Separate productive demand from leak load","Use night baseline","Verify header recovery after repair"], difficulty:.intermediate),
        .init(id:"ro-fouling", machineID:.reverseOsmosisPlant, faultID:"membrane-fouling", title:"Pressure up, permeate down", briefing:"Feed pressure still looks strong while water production and quality slowly degrade.", objectives:["Combine membrane DP, flow and conductivity","Normalize by recovery/load","Identify fouling rather than raising pressure blindly"], difficulty:.advanced),
        .init(id:"datacenter-stiction", machineID:.dataCenterCooling, faultID:"cooling-valve-stiction", title:"Rack temperature hunts under peak load", briefing:"Cooling demand moves continuously but one CRAH valve responds in jumps.", objectives:["Compare valve command and stem position","Separate stiction from PID instability","Verify thermal recovery after valve service"], difficulty:.expert),
        .init(id:"parcel-highspeed", machineID:.parcelSortation, faultID:"diverter-timing", title:"Misroutes only at peak sort rate", briefing:"The logic sequence is healthy at low speed but parcels miss their chute when rate increases.", objectives:["Relate timing error to belt speed","Use flight recorder around misroute","Prove timing-window cause rather than sensor noise"], difficulty:.advanced),
        .init(id:"paintbooth-airflow", machineID:.automotivePaintBooth, faultID:"filter-loading", title:"Fan command climbs, booth airflow falls", briefing:"The exhaust drive works harder every week while booth velocity trends down.", objectives:["Trend filter DP and air velocity","Normalize by production load","Verify filter service restores airflow"], difficulty:.intermediate),
        .init(id:"molding-zone2", machineID:.injectionMoldingCell, faultID:"heater-failure", title:"One barrel zone never catches up", briefing:"Cycle time stretches because Zone 2 remains cold even at high heater output.", objectives:["Compare heater authority to temperature response","Separate sensor error from lost thermal power","Verify recovery during a full cycle"], difficulty:.advanced),
        .init(id:"crusher-slip", machineID:.crusherConveyor, faultID:"belt-slip", title:"Drive says speed, belt says otherwise", briefing:"Crusher current rises and belt feedback falls behind command only under heavy ore.", objectives:["Compare command vs speed feedback","Correlate slip with load/current","Avoid retuning speed loop around traction loss"], difficulty:.advanced),
        .init(id:"grain-bearing", machineID:.grainElevator, faultID:"bearing-drag", title:"Harvest load exposes hot head bearing", briefing:"Temperature and current look acceptable empty but climb together at high throughput.", objectives:["Compare load regimes","Use vibration/current/temp covariance","Identify mechanical drag before trip"], difficulty:.advanced),
        .init(id:"pasteurizer-divert", machineID:.htstPasteurizer, faultID:"divert-leak", title:"Forward-flow permissive is true, isolation is not", briefing:"Temperature logic is correct but independent evidence suggests leakage across the divert valve.", objectives:["Separate commanded state from physical isolation","Trace permissive and feedback","Verify sanitary isolation after repair"], difficulty:.expert),
        .init(id:"bioreactor-do", machineID:.bioreactor, faultID:"oxygen-transfer-loss", title:"More air, less oxygen margin", briefing:"Airflow and agitation climb while dissolved oxygen still decays during high OUR.", objectives:["Normalize by biological demand","Compare actuator effort to DO response","Distinguish transfer loss from controller weakness"], difficulty:.expert),
        .init(id:"chw-dp-bias", machineID:.chilledWaterPlant, faultID:"dp-bias", title:"Pumps work harder than the building needs", briefing:"Measured DP drives pump command high, but independent hydraulic evidence says the loop is already satisfied.", objectives:["Compare measured vs independent DP","Quantify energy penalty","Verify corrected sensor feedback lowers pump command"], difficulty:.advanced),
        .init(id:"battery-contact", machineID:.batteryFormationLine, faultID:"contact-resistance", title:"Fixture heats only at high formation current", briefing:"Voltage drop and local temperature rise together on one formation fixture.", objectives:["Relate contact resistance to current and voltage drop","Separate cell behavior from fixture behavior","Verify repaired contact under high-current step"], difficulty:.advanced)
    ]
}

public enum ApprenticeshipExerciseGenerator {
    public static func next(for progress: StepByStepProgressProfile, skills: ApprenticeshipSkillProfile, seed: UInt64 = 1) -> ApprenticeshipExercise? {
        let unlocked = StepByStepCatalog.all.filter { progress.isUnlocked($0) }
        guard !unlocked.isEmpty else { return nil }
        let unlockedIDs = Set(unlocked.map(\.id))
        let weak = skills.weakestSkill
        let challengePool = ApprenticeshipChallengeCatalog.candidates(for: weak, unlockedLessonIDs: unlockedIDs)
        if !challengePool.isEmpty {
            let challenge = challengePool[Int(seed % UInt64(challengePool.count))]
            let kind: ApprenticeshipExerciseKind = challenge.style == .repair ? .repairBrokenProgram : (challenge.style == .build ? .buildFromScratch : .predictThenRun)
            return .init(id:"challenge-\(challenge.id)-\(seed)", lessonID:challenge.lessonID, kind:kind, title:challenge.title, prompt:challenge.prompt, targetSkills:challenge.targetSkills, seed:seed, hints:Array(challenge.acceptanceEvidence.prefix(2)))
        }
        let candidates = unlocked.filter { skillsForLesson($0.id).contains(weak) }
        let pool = candidates.isEmpty ? unlocked : candidates
        let lesson = pool[Int(seed % UInt64(pool.count))]
        let kind: ApprenticeshipExerciseKind = lesson.labKind == .ladder ? (seed % 3 == 0 ? .repairBrokenProgram : .buildFromScratch) : .predictThenRun
        return .init(id:"\(lesson.id)-\(kind.rawValue)-\(seed)", lessonID:lesson.id, kind:kind, title:"Targeted practice", prompt:StepByStepPedagogy.scaffold(for:lesson).predictionPrompt, targetSkills:skillsForLesson(lesson.id), seed:seed, hints:Array(StepByStepPedagogy.scaffold(for:lesson).commonMistakes.prefix(2)))
    }

    public static func skillsForLesson(_ id: String) -> [ApprenticeshipSkill] {
        switch id {
        case "foundation-scan": [.scanReasoning, .verification]
        case "foundation-tags", "foundation-controller-organization", "foundation-structured-data": [.tagsAndTypes]
        case "foundation-first-rung", "digital-xic-xio": [.instructionChoice, .verification]
        case "digital-command-feedback": [.tagsAndTypes, .verification]
        case "digital-motor-seal": [.instructionChoice, .rungTopology, .verification]
        case "digital-interlocks", "sequence-routine-jsr", "sequence-timer-counter": [.interlocksAndState, .instructionChoice, .verification]
        case "analog-input-scaling", "analog-alarms", "analog-output-safe", "analog-level-hysteresis": [.analogMath, .instructionChoice, .verification]
        case let x where x.hasPrefix("comm-"): [.communications, .verification]
        case let x where x.hasPrefix("historian-"): [.historianReasoning, .verification]
        case "capstone-networked-pump": [.rungTopology, .analogMath, .communications, .historianReasoning, .verification]
        default: [.verification]
        }
    }

    /// Supplies intentionally broken workbenches only where the current structural validator can teach a concrete ladder mistake.
    public static func brokenWorkbench(for lessonID: String) throws -> LadderConstructionWorkbench? {
        switch lessonID {
        case "foundation-first-rung":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r = wb.addRung(comment:"Broken: wrong instruction truth")
            try wb.append(.instruction(.xio(tag:"Start_PB")), toRung:r)
            try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
            return wb
        case "digital-motor-seal":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r = wb.addRung(comment:"Broken: seal contact incorrectly in series")
            try wb.append(.instruction(.xic(tag:"Stop_OK")), toRung:r)
            try wb.append(.instruction(.xic(tag:"Start_PB")), toRung:r)
            try wb.append(.instruction(.xic(tag:"Motor_Run")), toRung:r)
            try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
            return wb
        case "digital-interlocks":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let run = wb.addRung(comment:"Broken: fault does not inhibit run")
            try wb.append(.instruction(.xic(tag:"Run_Request")), toRung:run)
            try wb.append(.instruction(.xic(tag:"Guard_OK")), toRung:run)
            try wb.append(.instruction(.xic(tag:"Air_OK")), toRung:run)
            try wb.append(.instruction(.ote(tag:"Machine_Run")), toRung:run)
            let trip = wb.addRung(comment:"Latch overload")
            try wb.append(.instruction(.xic(tag:"OverloadTrip")), toRung:trip)
            try wb.append(.instruction(.otl(tag:"Machine_Fault")), toRung:trip)
            return wb
        case "sequence-timer-counter":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r = wb.addRung(comment:"Broken: count level instead of event")
            try wb.append(.instruction(.xic(tag:"TransferComplete")), toRung:r)
            try wb.append(.instruction(.ote(tag:"PE_Clear")), toRung:r)
            return wb
        case "analog-input-scaling":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r0 = wb.addRung(comment:"Broken: normalizes raw value without subtracting RawMin")
            try wb.append(.instruction(.div(.tag("Pressure_Raw"), .tag("RawSpan"), destination:"Pressure_Normalized")), toRung:r0)
            let r1 = wb.addRung(comment:"Apply engineering span")
            try wb.append(.instruction(.mul(.tag("Pressure_Normalized"), .tag("EUSpan"), destination:"Pressure_ScaledSpan")), toRung:r1)
            let r2 = wb.addRung(comment:"Write PV")
            try wb.append(.instruction(.add(.tag("Pressure_ScaledSpan"), .tag("EUMin"), destination:"PressurePV")), toRung:r2)
            return wb
        case "analog-alarms":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r = wb.addRung(comment:"Broken: no hysteresis memory")
            try wb.append(.instruction(.geq(.tag("PressurePV"), .tag("HighLimit"))), toRung:r)
            try wb.append(.instruction(.ote(tag:"PressureHigh")), toRung:r)
            return wb
        case "analog-level-hysteresis":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r = wb.addRung(comment:"Broken: single threshold-like direct command")
            try wb.append(.instruction(.leq(.tag("LevelPV"), .tag("LowStart"))), toRung:r)
            try wb.append(.instruction(.ote(tag:"FillValve")), toRung:r)
            return wb
        case "comm-hmi-scada":
            var wb = try WorkbenchLessonFactory.starter(for:lessonID)
            let r = wb.addRung(comment:"Broken: HMI command directly presented as running status")
            try wb.append(.instruction(.xic(tag:"HMI_StartCmd")), toRung:r)
            try wb.append(.instruction(.ote(tag:"Machine_Running")), toRung:r)
            return wb
        default: return nil
        }
    }
}

public enum ApprenticeshipGrader {
    public static func grade(workbench: LadderConstructionWorkbench, lesson: StepByStepLesson, verificationPerformed: Bool) -> ApprenticeshipGrade {
        guard let project = workbench.compile().project else {
            let validation = StepByStepValidationReport(lessonID:lesson.id, findings:[.init("compile", severity:.failure, title:"Program does not compile", detail:"Resolve missing tags, empty rungs, or invalid references first.")])
            return .init(lessonID:lesson.id, components:[.init(id:"compile", skill:.verification, title:"Executable program", awardedPoints:0, possiblePoints:20, feedback:"The program must compile before behavior can be verified.")], validation:validation, verificationPerformed:false)
        }
        let validation = StepByStepProjectValidator.validate(project:project, lesson:lesson)
        var components:[ApprenticeshipGradeComponent] = []
        for finding in validation.findings where finding.id != "no-validator" {
            let skill = skill(for:finding.id, lessonID:lesson.id)
            let points: Double = finding.severity == .pass ? 10 : (finding.severity == .warning ? 6 : 0)
            components.append(.init(id:finding.id, skill:skill, title:finding.title, awardedPoints:points, possiblePoints:10, feedback:finding.detail))
        }
        if components.isEmpty {
            components.append(.init(id:"concept", skill:ApprenticeshipExerciseGenerator.skillsForLesson(lesson.id).first ?? .verification, title:"Lesson concept", awardedPoints:validation.passed ? 20 : 0, possiblePoints:20, feedback:validation.findings.map(\.detail).joined(separator:" ")))
        }
        components.append(.init(id:"verification", skill:.verification, title:"Prove it works", awardedPoints:verificationPerformed ? 15 : 0, possiblePoints:15, feedback:verificationPerformed ? "You ran/observed evidence after building or repairing the logic." : "Run the program and compare the result to your prediction before calling the exercise complete."))
        return .init(lessonID:lesson.id, components:components, validation:validation, verificationPerformed:verificationPerformed)
    }

    private static func skill(for findingID: String, lessonID: String) -> ApprenticeshipSkill {
        if findingID.hasPrefix("tag-") { return .tagsAndTypes }
        if ["seal"].contains(findingID) { return .rungTopology }
        if ["timer","counter","state-write","fault-latch","fault-reset","fault-inhibit"].contains(findingID) { return .interlocksAndState }
        if findingID.hasPrefix("scale-") || findingID.hasPrefix("level-") || findingID.hasPrefix("high-") { return .analogMath }
        if findingID.contains("hmi") || findingID == "command-status" { return .communications }
        if findingID.contains("xic") || findingID.contains("ote") || findingID == "stop" || findingID == "motor-output" { return .instructionChoice }
        return ApprenticeshipExerciseGenerator.skillsForLesson(lessonID).first ?? .verification
    }
}

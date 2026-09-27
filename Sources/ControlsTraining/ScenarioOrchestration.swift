import Foundation
import ControlsPLC
import ControlsSimulation

public enum HeroMachineID: String, Codable, CaseIterable, Sendable {
    case packagingCell
    case pressureSkid
    case servoConveyor
    case pumpStation
    case airHandlingUnit
    case batchMixingTank
    case industrialOven
    case roboticPalletizer
    case wastewaterLiftStation
    case refrigerationRack
    case boilerSteamPlant
    case cncCoolantCell
    case cleanroomPressureSystem
    case asrsCrane
    case bottlingLine
    case cipSkid
    case compressedAirPlant
    case reverseOsmosisPlant
    case dataCenterCooling
    case parcelSortation
    case automotivePaintBooth
    case injectionMoldingCell
    case crusherConveyor
    case grainElevator
    case htstPasteurizer
    case bioreactor
    case chilledWaterPlant
    case batteryFormationLine
}

public enum ScenarioDifficulty: String, Codable, CaseIterable, Sendable {
    case beginner, intermediate, advanced, expert
}

public enum ScenarioRunMode: String, Codable, CaseIterable, Sendable {
    case guided
    case technician

    public var displayName: String { self == .guided ? "Guided learning" : "Unguided technician" }
}

public enum ScenarioDiagnosticCapability: String, Codable, CaseIterable, Sendable {
    case ladderPowerFlow, causalTracing, adaptiveTroubleshooting, temporalEvidence, flightRecorder
    case sequenceReconstruction, healthyEnvelopes, multivariateHealth, operatingModes, continuousStates
    case withinCycleTrajectories, phaseWarping, crossSignalLag, dynamicResponse, systemIdentification
    case stabilityMargins, sampledPID, actuatorNonlinearities, limitCycleFingerprinting, spectralAnalysis
}

public struct ScenarioHealthyPopulation: Equatable, Sendable {
    public let cycleCount: Int
    public let simulatedWeeks: Int
    public let operatingRegions: [String]
    public let learnedSignals: [String]
    public let description: String
}

public struct ScenarioProgressionStage: Identifiable, Equatable, Sendable {
    public let id: String
    public let day: Int
    public let label: String
    public let severity: Double
    public let visibleSymptoms: [String]
    public let hiddenMechanism: String
}

public struct HeroFaultScenario: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let difficulty: ScenarioDifficulty
    public let symptom: String
    public let rootMechanism: String
    public let capabilities: [ScenarioDiagnosticCapability]
    public let progression: [ScenarioProgressionStage]
    public let technicianChecks: [String]
}

public struct GuidedLessonStep: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let prompt: String
    public let teachingGoal: String
    public let unlockedCapabilities: [ScenarioDiagnosticCapability]
}

public struct HeroMachineScenario: Identifiable, Sendable {
    public var id: HeroMachineID
    public let title: String
    public let application: String
    public let learningPurpose: String
    public let processSignals: [String]
    public let healthyPopulation: ScenarioHealthyPopulation
    public let faults: [HeroFaultScenario]
    public let guidedPath: [GuidedLessonStep]
    public let projectFactory: @Sendable () throws -> ControllerProject
}

public struct ScenarioSession: Sendable {
    public let machine: HeroMachineScenario
    public let fault: HeroFaultScenario
    public let mode: ScenarioRunMode
    public private(set) var simulatedDay: Int
    public private(set) var revealedGuidedStepCount: Int

    public var currentProgression: ScenarioProgressionStage {
        fault.progression.last(where: { $0.day <= simulatedDay }) ?? fault.progression[0]
    }

    public var visibleLessonSteps: [GuidedLessonStep] {
        guard mode == .guided else { return [] }
        return Array(machine.guidedPath.prefix(revealedGuidedStepCount))
    }

    public mutating func advance(days: Int) { simulatedDay = max(0, simulatedDay + days) }
    public mutating func revealNextGuidedStep() { if mode == .guided { revealedGuidedStepCount = min(machine.guidedPath.count, revealedGuidedStepCount + 1) } }
}

public enum HeroMachineCatalog {
    public static let all: [HeroMachineScenario] = [
        packagingCell(), pressureSkid(), servoConveyor(), pumpStation(), airHandlingUnit(), batchMixingTank(), industrialOven(),
        roboticPalletizer(), wastewaterLiftStation(), refrigerationRack(), boilerSteamPlant(), cncCoolantCell(), cleanroomPressureSystem(), asrsCrane(),
        bottlingLine(), cipSkid(), compressedAirPlant(), reverseOsmosisPlant(), dataCenterCooling(), parcelSortation(), automotivePaintBooth(), injectionMoldingCell(),
        crusherConveyor(), grainElevator(), htstPasteurizer(), bioreactor(), chilledWaterPlant(), batteryFormationLine()
    ]

    public static func machine(_ id: HeroMachineID) -> HeroMachineScenario? { all.first { $0.id == id } }

    public static func start(machine id: HeroMachineID, faultID: String, mode: ScenarioRunMode) -> ScenarioSession? {
        guard let machine = machine(id), let fault = machine.faults.first(where: { $0.id == faultID }) else { return nil }
        return .init(machine: machine, fault: fault, mode: mode, simulatedDay: 0, revealedGuidedStepCount: mode == .guided ? 1 : 0)
    }

    private static func stage(_ id: String, _ day: Int, _ label: String, _ severity: Double, _ symptoms: [String], _ mechanism: String) -> ScenarioProgressionStage {
        .init(id: id, day: day, label: label, severity: severity, visibleSymptoms: symptoms, hiddenMechanism: mechanism)
    }

    private static func lesson(_ id: String, _ title: String, _ prompt: String, _ goal: String, _ caps: [ScenarioDiagnosticCapability]) -> GuidedLessonStep {
        .init(id: id, title: title, prompt: prompt, teachingGoal: goal, unlockedCapabilities: caps)
    }

    private static func commonGuidedPath(advanced: [ScenarioDiagnosticCapability]) -> [GuidedLessonStep] {
        [
            lesson("observe", "Observe before diagnosing", "Describe the symptom and mark the first abnormal event without changing anything.", "Separate observation from explanation.", [.flightRecorder, .temporalEvidence]),
            lesson("logic", "Prove the controller state", "Trace the relevant permissive or command and explain why it is true or false.", "Ground physical symptoms in actual executed logic.", [.ladderPowerFlow, .causalTracing]),
            lesson("measure", "Choose the next measurement", "Select the check that removes the most uncertainty while respecting safety and access.", "Practice diagnostic strategy instead of parts swapping.", [.adaptiveTroubleshooting]),
            lesson("compare", "Compare with healthy behavior", "Compare this cycle with the correct healthy operating regime.", "Avoid mistaking normal load effects for degradation.", [.healthyEnvelopes, .operatingModes]),
            lesson("mechanism", "Explain the mechanism", "Use advanced evidence to identify the physical/control mechanism and state what evidence would falsify it.", "Connect signals to controls physics without overclaiming causality.", advanced)
        ]
    }

    private static func packagingCell() -> HeroMachineScenario {
        let faults = [
            HeroFaultScenario(id: "pe203-sticky", title: "Sticky transfer photoeye", difficulty: .beginner, symptom: "TransferCmd never turns on after a box arrives.", rootMechanism: "PE203 remains logically true and blocks the State 30 timer path.", capabilities: [.ladderPowerFlow, .causalTracing, .adaptiveTroubleshooting, .sequenceReconstruction], progression: [
                stage("healthy", 0, "Healthy", 0, [], "No fault"), stage("dirty", 14, "Lens contamination", 0.25, ["PE203 clears slightly later"], "Optical margin degrading"), stage("intermittent", 28, "Intermittent sticking", 0.65, ["Occasional long transfer waits"], "Photoeye release becomes intermittent"), stage("failed", 42, "Stuck detected", 1, ["Transfer sequence stops in State 30"], "PE203 remains true")
            ], technicianChecks: ["Check PE203 raw vs logical state", "Inspect sensor alignment/contamination", "Verify TransferDelay enable path"]),
            HeroFaultScenario(id: "short-pulse", title: "Missed short product pulse", difficulty: .intermediate, symptom: "Some fast products are not counted.", rootMechanism: "The physical pulse can occur between PLC observations.", capabilities: [.temporalEvidence, .flightRecorder, .sequenceReconstruction], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("speed",21,"Higher line speed",0.5,["Pulse width shrinking"],"Product dwell at sensor decreases"),stage("miss",35,"Missed pulse",1,["Intermittent count loss"],"Pulse falls between scans")], technicianChecks: ["Compare field edge to controller-visible edge", "Check scan/task execution stamps", "Select faster capture strategy"])
        ]
        return .init(id: .packagingCell, title: "Packaging Cell", application: "Cartoning / transfer conveyor", learningPurpose: "Discrete ladder execution, sequencing, timers, scan timing, causal troubleshooting.", processSignals: ["PE203","State","TransferDelay.ACC","TransferCmd","BoxCount"], healthyPopulation: .init(cycleCount: 300, simulatedWeeks: 6, operatingRegions: ["Normal speed","High speed"], learnedSignals: ["PE203 clear timing","Transfer dwell","cycle sequence"], description: "Healthy discrete-cycle population with normal timing variation and speed-dependent sensor dwell."), faults: faults, guidedPath: commonGuidedPath(advanced: [.sequenceReconstruction, .temporalEvidence]), projectFactory: { try DemoProjectFactory.packagingCell() })
    }

    private static func pressureSkid() -> HeroMachineScenario {
        let faults = [
            HeroFaultScenario(id: "valve-stiction", title: "Control-valve stiction", difficulty: .advanced, symptom: "Pressure oscillates although PID margins and task period look healthy.", rootMechanism: "Valve stem sticks while integral demand builds, then breaks away and overshoots.", capabilities: [.systemIdentification,.stabilityMargins,.sampledPID,.actuatorNonlinearities,.limitCycleFingerprinting,.spectralAnalysis], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("friction",21,"Friction rising",0.25,["Command-position lag grows"],"Packing friction increases"),stage("breakaway",42,"Breakaway emerging",0.6,["Small pressure cycling"],"Static friction exceeds small corrections"),stage("limit-cycle",63,"Sustained limit cycle",1,["Repeatable pressure oscillation"],"Stick-build-release cycle")], technicianChecks: ["Trend ValveCmd vs ValvePosition", "Check breakaway command-position separation", "Verify air supply before retuning PID"]),
            HeroFaultScenario(id: "dead-time-growth", title: "Process dead-time growth", difficulty: .expert, symptom: "Previously stable pressure loop becomes oscillation-prone under a changed process path.", rootMechanism: "Plant dead time increases and consumes phase margin without PID gains changing.", capabilities: [.dynamicResponse,.systemIdentification,.stabilityMargins,.spectralAnalysis], progression: [stage("healthy",0,"Healthy",0,[],"L=42 ms"),stage("drift",30,"Delay drift",0.35,["Response starts later"],"Transport delay increases"),stage("fragile",60,"Low margin",0.7,["Ringing after steps"],"Dead-time phase loss consumes robustness"),stage("unstable",90,"Oscillation-prone",1,["Sustained pressure oscillation"],"Same PID now has poor margin")], technicianChecks: ["Fit current K/L/tau", "Compare healthy/current phase margin", "Verify piping/valve/process changes"])
        ]
        return .init(id: .pressureSkid, title: "Pressure Control Skid", application: "Pneumatic / hydraulic pressure regulation", learningPurpose: "PID dynamics, plant identification, stability, nonlinear valve faults and oscillation mechanisms.", processSignals: ["PressureSP","PressurePV","ValveCmd","ValvePosition","AirSupplyPressure"], healthyPopulation: .init(cycleCount: 500, simulatedWeeks: 12, operatingRegions: ["Low demand","Nominal","High demand"], learnedSignals: ["step response","K/L/tau","ValveCmd→Pressure lag","oscillation spectrum"], description: "Multi-load pressure population with healthy plant and valve dynamics."), faults: faults, guidedPath: commonGuidedPath(advanced: [.systemIdentification,.stabilityMargins,.sampledPID,.actuatorNonlinearities,.limitCycleFingerprinting,.spectralAnalysis]), projectFactory: { try analogProject(name: "Pressure Skid Trainer", program: "Pressure", analogTags: ["PressureSP","PressurePV","ValveCmd","ValvePosition","AirSupplyPressure"]) })
    }

    private static func servoConveyor() -> HeroMachineScenario {
        let faults = [HeroFaultScenario(id: "bearing-resonance", title: "Load-dependent conveyor resonance", difficulty: .advanced, symptom: "Vibration and position error appear only at certain loaded speeds.", rootMechanism: "A mechanical mode is excited near shaft-speed harmonic under load.", capabilities: [.continuousStates,.withinCycleTrajectories,.phaseWarping,.multivariateHealth,.spectralAnalysis], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("wear",28,"Bearing wear",0.3,["Torque ripple rising"],"Mechanical stiffness/damping degrade"),stage("band",56,"Narrow resonance band",0.7,["Vibration only near one speed"],"Mechanical eigenmode excited"),stage("severe",84,"Broad production impact",1,["Tracking error and vibration"],"Resonance grows")], technicianChecks: ["Compare vibration peak to shaft speed harmonics", "Check loaded vs empty operating regions", "Inspect torque→speed phase relationship"])]
        return .init(id: .servoConveyor, title: "Servo Conveyor / Indexer", application: "High-speed indexed motion", learningPurpose: "Load-aware trajectories, phase alignment, cross-signal lag, mechanical resonance and operating-state dependence.", processSignals: ["PositionCmd","PositionFB","Velocity","MotorTorque","LoadEstimate","Vibration"], healthyPopulation: .init(cycleCount: 800, simulatedWeeks: 16, operatingRegions: ["Empty","Light load","Heavy load","High-speed recipe"], learnedSignals: ["trajectory states","torque-speed lag","vibration spectrum","dwell"], description: "Rich motion population across payload and speed regimes."), faults: faults, guidedPath: commonGuidedPath(advanced: [.continuousStates,.withinCycleTrajectories,.phaseWarping,.crossSignalLag,.spectralAnalysis]), projectFactory: { try analogProject(name: "Servo Conveyor Trainer", program: "Motion", analogTags: ["PositionCmd","PositionFB","Velocity","MotorTorque","LoadEstimate","Vibration"]) })
    }

    private static func pumpStation() -> HeroMachineScenario {
        let faults = [HeroFaultScenario(id: "cavitation", title: "Cavitation / suction degradation", difficulty: .advanced, symptom: "Flow becomes noisy and pump current spectrum broadens at high demand.", rootMechanism: "Reduced suction head creates hydraulic instability and broadband vibration rather than a clean controller limit cycle.", capabilities: [.multivariateHealth,.operatingModes,.dynamicResponse,.spectralAnalysis], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("margin",30,"NPSH margin falling",0.3,["High-flow noise rises"],"Suction condition degrades"),stage("incipient",60,"Incipient cavitation",0.65,["Broadband vibration at high demand"],"Vapor formation begins"),stage("severe",90,"Severe cavitation",1,["Flow loss and vibration"],"Hydraulic performance degraded")], technicianChecks: ["Compare suction/discharge pressure", "Check spectrum vs VFD electrical frequency", "Compare high-flow and low-flow regimes"])]
        return .init(id: .pumpStation, title: "VFD Pump Station", application: "Municipal / process-water booster station", learningPurpose: "Operating-mode health, pump curve behavior, cavitation signatures, VFD/process interaction.", processSignals: ["FlowSP","FlowPV","PumpHz","MotorCurrent","SuctionPressure","DischargePressure","Vibration"], healthyPopulation: .init(cycleCount: 650, simulatedWeeks: 20, operatingRegions: ["Night low-flow","Normal","Peak demand","Two-pump overlap"], learnedSignals: ["flow response","current/flow covariance","pressure envelope","vibration spectrum"], description: "Demand-varying pump population suitable for distinguishing load from degradation."), faults: faults, guidedPath: commonGuidedPath(advanced: [.operatingModes,.multivariateHealth,.dynamicResponse,.spectralAnalysis]), projectFactory: { try analogProject(name: "Pump Station Trainer", program: "Pumps", analogTags: ["FlowSP","FlowPV","PumpHz","MotorCurrent","SuctionPressure","DischargePressure","Vibration"]) })
    }

    private static func airHandlingUnit() -> HeroMachineScenario {
        let faults = [HeroFaultScenario(id: "loop-interaction", title: "Temperature / static-pressure loop interaction", difficulty: .expert, symptom: "Two apparently healthy loops develop a slow beating oscillation during occupied high-load periods.", rootMechanism: "Nearby loop dynamics create two strong spectral components and a beat envelope.", capabilities: [.operatingModes,.crossSignalLag,.systemIdentification,.stabilityMargins,.spectralAnalysis], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("season",35,"Seasonal loading",0.2,["Loop bandwidths move closer"],"Plant dynamics change with load"),stage("interaction",70,"Weak interaction",0.6,["Slow comfort oscillation"],"Pressure/temperature loops couple"),stage("beat",105,"Beating visible",1,["Repeating envelope in temperature and fan command"],"Two nearby oscillatory components")], technicianChecks: ["Compare dominant frequencies of pressure and temperature loops", "Check phase relationship", "Repeat under unoccupied/light-load mode"])]
        return .init(id: .airHandlingUnit, title: "Commercial Air Handling Unit", application: "VAV AHU with supply-air temperature and static-pressure control", learningPurpose: "Commercial controls, interacting loops, mode-aware baselines and multivariable spectral reasoning.", processSignals: ["SAT_SP","SAT_PV","StaticSP","StaticPV","FanCmd","CoolingValve","OutdoorAirTemp","DamperPos"], healthyPopulation: .init(cycleCount: 1000, simulatedWeeks: 26, operatingRegions: ["Unoccupied","Morning warmup","Occupied mild","Occupied hot"], learnedSignals: ["temperature response","static-pressure loop","valve/fan spectra","weather/load context"], description: "Seasonal commercial-building population with strongly changing healthy load."), faults: faults, guidedPath: commonGuidedPath(advanced: [.operatingModes,.crossSignalLag,.systemIdentification,.stabilityMargins,.spectralAnalysis]), projectFactory: { try analogProject(name: "AHU Trainer", program: "AHU", analogTags: ["SAT_SP","SAT_PV","StaticSP","StaticPV","FanCmd","CoolingValve","OutdoorAirTemp","DamperPos"]) })
    }

    private static func batchMixingTank() -> HeroMachineScenario {
        let faults = [HeroFaultScenario(id: "agitator-drag", title: "Progressive agitator mechanical drag", difficulty: .intermediate, symptom: "Batch completes, but heat/mix phases stretch and motor current slowly rises.", rootMechanism: "Mechanical drag changes the within-batch trajectory and multivariate signature before a discrete fault occurs.", capabilities: [.healthyEnvelopes,.multivariateHealth,.continuousStates,.withinCycleTrajectories,.phaseWarping], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("drag",21,"Early drag",0.25,["Motor current slightly high"],"Seal/bearing friction rising"),stage("stretch",42,"Phase stretch",0.6,["Mix dwell lengthening"],"Reduced effective agitation"),stage("quality",63,"Quality risk",1,["Long batches and temperature nonuniformity"],"Mixing performance degraded")], technicianChecks: ["Compare current + phase dwell jointly", "Check loaded recipe baseline", "Inspect phase-normalized temperature/mixing shape"])]
        return .init(id: .batchMixingTank, title: "Batch Mixing Tank", application: "Food / chemical batch mixing", learningPurpose: "Recipe phases, multivariate degradation, cycle trajectories and phase-normalized process behavior.", processSignals: ["BatchState","TankTemp","Level","AgitatorCurrent","AgitatorSpeed","SteamValve","RecipeID"], healthyPopulation: .init(cycleCount: 450, simulatedWeeks: 18, operatingRegions: ["Small batch","Large batch","High-viscosity recipe"], learnedSignals: ["phase dwell","temperature trajectory","current/speed covariance","recipe context"], description: "Recipe-aware healthy batch population with phase trajectories."), faults: faults, guidedPath: commonGuidedPath(advanced: [.multivariateHealth,.continuousStates,.withinCycleTrajectories,.phaseWarping]), projectFactory: { try analogProject(name: "Batch Tank Trainer", program: "Batch", analogTags: ["TankTemp","Level","AgitatorCurrent","AgitatorSpeed","SteamValve","RecipeID"]) })
    }

    private static func industrialOven() -> HeroMachineScenario {
        let faults = [HeroFaultScenario(id: "burner-disturbance", title: "Periodic burner / airflow disturbance", difficulty: .advanced, symptom: "Zone temperature oscillates at a repeatable frequency unrelated to PID crossover.", rootMechanism: "A periodic combustion/airflow disturbance injects energy at an external frequency.", capabilities: [.dynamicResponse,.systemIdentification,.stabilityMargins,.spectralAnalysis,.operatingModes], progression: [stage("healthy",0,"Healthy",0,[],"No fault"),stage("fan",30,"Fan imbalance",0.25,["Small airflow ripple"],"Periodic airflow disturbance"),stage("thermal",60,"Thermal modulation",0.65,["Temperature ripple visible"],"Disturbance propagates into zone"),stage("quality",90,"Product quality affected",1,["Repeatable zone-temperature banding"],"External disturbance dominates")], technicianChecks: ["Compare temperature frequency to fan/burner frequency", "Confirm PID linear margin", "Look for matching spectral line in airflow/fuel signal"])]
        return .init(id: .industrialOven, title: "Industrial Dryer / Oven", application: "Continuous thermal process", learningPurpose: "Slow plant identification, transport delay, external periodic disturbances and spectral propagation.", processSignals: ["ZoneTempSP","ZoneTempPV","GasValve","Airflow","FanHz","LineSpeed","ProductTemp"], healthyPopulation: .init(cycleCount: 720, simulatedWeeks: 24, operatingRegions: ["Warmup","Low throughput","Nominal","High throughput"], learnedSignals: ["thermal K/L/tau","zone lag","fan/burner spectrum","throughput context"], description: "Slow thermal population spanning line speed and product load."), faults: faults, guidedPath: commonGuidedPath(advanced: [.dynamicResponse,.systemIdentification,.stabilityMargins,.spectralAnalysis]), projectFactory: { try analogProject(name: "Industrial Oven Trainer", program: "Oven", analogTags: ["ZoneTempSP","ZoneTempPV","GasValve","Airflow","FanHz","LineSpeed","ProductTemp"]) })
    }


    private static func roboticPalletizer() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"vacuum-loss",title:"Intermittent vacuum grip loss",difficulty:.advanced,symptom:"The robot reaches the pick point but occasionally drops or fails to confirm a carton under heavier payloads.",rootMechanism:"Vacuum margin decays until GripOK arrives late or not at all while motion sequencing continues.",capabilities:[.causalTracing,.temporalEvidence,.flightRecorder,.sequenceReconstruction,.multivariateHealth],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("leak",21,"Small vacuum leak",0.3,["Grip confirmation later"],"Vacuum margin falling"),stage("payload",42,"Load-sensitive misses",0.65,["Heavy cartons intermittently fail grip"],"Vacuum threshold crossed under load"),stage("drop",63,"Dropped picks",1,["Pick cycle faults"],"Grip confirmation unreliable")],technicianChecks:["Compare RobotAtPick to GripOK timing","Trend VacuumPV by payload","Verify sequence inhibits motion without confirmed grip"])]
        return .init(id:.roboticPalletizer,title:"Robotic Palletizer",application:"Case handling / end-of-line robotics",learningPurpose:"Robot permissives, pick confirmation, sequence timing, payload-dependent faults and safe motion interlocks.",processSignals:["RobotPosition","VacuumPV","PayloadEstimate","CyclePhase","GripOK","RobotAtPick"],healthyPopulation:.init(cycleCount:900,simulatedWeeks:14,operatingRegions:["Light carton","Nominal payload","Heavy payload"],learnedSignals:["pick timing","vacuum margin","grip confirmation","cycle sequence"],description:"Payload-aware robotic pick population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.sequenceReconstruction,.temporalEvidence,.multivariateHealth]),projectFactory:{ try analogProject(name:"Palletizer Trainer",program:"Robot",analogTags:["RobotPosition","VacuumPV","PayloadEstimate","CyclePhase"]) })
    }

    private static func wastewaterLiftStation() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"check-valve-leak",title:"Leaking discharge check valve",difficulty:.intermediate,symptom:"Wet-well level falls during pumping but rises unusually fast immediately after the pump stops.",rootMechanism:"Reverse flow through a leaking check valve returns discharged water to the wet well.",capabilities:[.healthyEnvelopes,.operatingModes,.temporalEvidence,.flightRecorder,.multivariateHealth],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("seep",30,"Check valve seepage",0.25,["Post-stop level recovery slightly faster"],"Small reverse flow"),stage("cycle",60,"Short cycling",0.65,["Pump starts more often"],"Backflow erodes drawdown"),stage("severe",90,"Severe backflow",1,["High starts/hour and poor net pumping"],"Discharge reverses after stop")],technicianChecks:["Compare level slope before/after stop","Check discharge pressure decay","Calculate net drawdown per run"])]
        return .init(id:.wastewaterLiftStation,title:"Wastewater Lift Station",application:"Municipal wet-well pumping",learningPurpose:"Level control, pump sequencing, starts-per-hour reasoning, backflow and operating-context diagnostics.",processSignals:["WetWellLevel","Inflow","PumpFlow","DischargePressure","BackflowEstimate","HighLevel"],healthyPopulation:.init(cycleCount:700,simulatedWeeks:20,operatingRegions:["Dry weather","Normal inflow","Storm inflow"],learnedSignals:["drawdown rate","post-stop level slope","starts/hour","pressure decay"],description:"Influent-load-aware wet-well population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.healthyEnvelopes,.operatingModes,.multivariateHealth]),projectFactory:{ try analogProject(name:"Lift Station Trainer",program:"LiftStation",analogTags:["WetWellLevel","Inflow","PumpFlow","DischargePressure","BackflowEstimate"]) })
    }

    private static func refrigerationRack() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"condenser-fouling",title:"Condenser fouling",difficulty:.advanced,symptom:"Head pressure and compressor power rise on warm afternoons even though suction control still looks acceptable.",rootMechanism:"Reduced condenser heat rejection raises condensing pressure and electrical demand as ambient/load increase.",capabilities:[.operatingModes,.multivariateHealth,.dynamicResponse,.spectralAnalysis],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("film",35,"Coil film buildup",0.25,["Fan command trends upward"],"Heat-transfer coefficient falling"),stage("head",70,"High head pressure",0.65,["Power rises on hot days"],"Condenser capacity constrained"),stage("alarm",105,"High-head trips",1,["Intermittent high-head alarms"],"Heat rejection inadequate")],technicianChecks:["Compare head pressure to outdoor temperature","Trend fan command vs condensing pressure","Separate load effect from fouling trend"])]
        return .init(id:.refrigerationRack,title:"Refrigeration Rack",application:"Supermarket / cold-storage refrigeration",learningPurpose:"Ambient-normalized health, refrigeration pressure relationships and energy-performance degradation.",processSignals:["SuctionPressure","CondensingPressure","CondenserFanCmd","RackPowerKW","OutdoorTemp","HighHeadAlarm"],healthyPopulation:.init(cycleCount:1200,simulatedWeeks:26,operatingRegions:["Cool ambient","Mild","Hot afternoon","High case load"],learnedSignals:["head-vs-ambient","rack power","fan demand","suction stability"],description:"Ambient- and load-aware refrigeration population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.operatingModes,.multivariateHealth,.dynamicResponse]),projectFactory:{ try analogProject(name:"Refrigeration Rack Trainer",program:"Rack",analogTags:["SuctionPressure","CondensingPressure","CondenserFanCmd","RackPowerKW","OutdoorTemp"]) })
    }

    private static func boilerSteamPlant() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"fuel-air-drift",title:"Fuel / air ratio drift",difficulty:.expert,symptom:"Steam pressure remains mostly normal, but oxygen falls and CO rises as load increases.",rootMechanism:"Combustion air delivery no longer tracks fuel demand, creating a rich condition hidden by the pressure loop.",capabilities:[.multivariateHealth,.operatingModes,.crossSignalLag,.dynamicResponse,.spectralAnalysis],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("trim",28,"Trim drift",0.2,["O2 slightly low at high fire"],"Air/fuel relationship shifting"),stage("rich",56,"Rich at high fire",0.65,["CO increases under load"],"Combustion excess air inadequate"),stage("warning",84,"Combustion warning",1,["High CO / poor efficiency"],"Fuel-air mismatch severe")],technicianChecks:["Compare firing rate, air command, O2 and CO","Repeat at low and high steam demand","Do not infer combustion health from steam pressure alone"])]
        return .init(id:.boilerSteamPlant,title:"Boiler / Steam Plant",application:"Industrial steam generation",learningPurpose:"Combustion cross-checks, multivariable process evidence, load-dependent faults and protective reasoning.",processSignals:["SteamPressure","FiringRate","AirCmd","O2Percent","COppm","SteamDemand","CombustionWarning"],healthyPopulation:.init(cycleCount:850,simulatedWeeks:20,operatingRegions:["Low fire","Normal load","High fire"],learnedSignals:["O2 vs firing","CO envelope","steam pressure response","air/fuel relationship"],description:"Load-aware combustion and steam population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.multivariateHealth,.operatingModes,.crossSignalLag]),projectFactory:{ try analogProject(name:"Boiler Trainer",program:"Boiler",analogTags:["SteamPressure","FiringRate","AirCmd","O2Percent","COppm","SteamDemand"]) })
    }

    private static func cncCoolantCell() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"coolant-restriction",title:"Coolant filter restriction",difficulty:.intermediate,symptom:"Coolant pressure rises while actual flow to the machine falls during heavy cutting.",rootMechanism:"A restricted filter creates excessive differential pressure and starves downstream flow despite normal pump speed.",capabilities:[.healthyEnvelopes,.multivariateHealth,.operatingModes,.dynamicResponse],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("loading",18,"Filter loading",0.25,["Filter DP rising"],"Restriction increasing"),stage("flow",36,"Flow margin low",0.65,["Low-flow events during heavy cuts"],"Downstream flow constrained"),stage("alarm",54,"Low coolant flow",1,["Persistent low-flow alarm"],"Filter severely restricted")],technicianChecks:["Compare pump Hz, pressure, filter DP and flow together","Check fault only under cutting load","Avoid increasing pump speed to hide restriction"])]
        return .init(id:.cncCoolantCell,title:"CNC Coolant / Lube Cell",application:"Machine-tool coolant circulation",learningPurpose:"Auxiliary-system interlocks, flow/pressure diagnosis, maintenance trends and load-aware commissioning.",processSignals:["CoolantFlow","FilterDP","CoolantPressure","PumpHz","CoolantTemp","LowFlow"],healthyPopulation:.init(cycleCount:600,simulatedWeeks:12,operatingRegions:["Idle","Light cut","Heavy cut"],learnedSignals:["flow-pressure relationship","filter DP","coolant temperature","pump demand"],description:"Cut-load-aware coolant system population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.healthyEnvelopes,.multivariateHealth,.operatingModes]),projectFactory:{ try analogProject(name:"CNC Coolant Trainer",program:"Coolant",analogTags:["CoolantFlow","FilterDP","CoolantPressure","PumpHz","CoolantTemp"]) })
    }

    private static func cleanroomPressureSystem() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"door-leak",title:"Intermittent room leakage path",difficulty:.advanced,symptom:"Room differential pressure periodically collapses even as supply-fan command rises.",rootMechanism:"A leakage path opens intermittently and overwhelms the pressure cascade; controller effort is a consequence, not the cause.",capabilities:[.temporalEvidence,.operatingModes,.crossSignalLag,.spectralAnalysis,.adaptiveTroubleshooting],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("seal",25,"Door seal wear",0.25,["Short DP dips"],"Leakage path emerging"),stage("intermittent",50,"Intermittent pressure loss",0.65,["PressureLow during traffic periods"],"Leak opens cyclically"),stage("cascade",75,"Cascade failure",1,["Repeated room-pressure excursions"],"Leak exceeds fan authority")],technicianChecks:["Compare RoomDP to fan command","Correlate dips with door/leak index","Distinguish controller response from initiating disturbance"])]
        return .init(id:.cleanroomPressureSystem,title:"Cleanroom Pressure System",application:"Pharma / semiconductor pressure cascade",learningPurpose:"Building-process pressure control, intermittent disturbances, trend correlation and command-vs-cause reasoning.",processSignals:["RoomDP","DP_SP","SupplyFanCmd","DoorLeakIndex","AirChangeLoad","PressureLow"],healthyPopulation:.init(cycleCount:1000,simulatedWeeks:18,operatingRegions:["Low occupancy","Normal","High traffic"],learnedSignals:["DP envelope","fan response","door-event correlation","pressure recovery"],description:"Occupancy-aware cleanroom pressure population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.temporalEvidence,.crossSignalLag,.spectralAnalysis]),projectFactory:{ try analogProject(name:"Cleanroom Trainer",program:"Cleanroom",analogTags:["RoomDP","DP_SP","SupplyFanCmd","DoorLeakIndex","AirChangeLoad"]) })
    }

    private static func asrsCrane() -> HeroMachineScenario {
        let faults=[HeroFaultScenario(id:"encoder-slip",title:"Encoder coupling slip",difficulty:.advanced,symptom:"The crane reports in-position but physical docking error slowly grows over repeated moves.",rootMechanism:"Encoder feedback accumulates bias relative to physical carriage travel, corrupting closed-loop position truth.",capabilities:[.withinCycleTrajectories,.crossSignalLag,.healthyEnvelopes,.multivariateHealth,.sequenceReconstruction],progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("bias",20,"Small encoder bias",0.25,["Docking correction grows"],"Feedback bias accumulating"),stage("miss",40,"Location misses",0.65,["Occasional transfer misalignment"],"Reported and physical position diverge"),stage("severe",60,"Repeated docking error",1,["InPosition no longer guarantees alignment"],"Encoder reference unreliable")],technicianChecks:["Compare commanded, feedback and independent physical position","Trend bias per move","Verify InPosition is based on trustworthy feedback"])]
        return .init(id:.asrsCrane,title:"Automated Warehouse AS/RS Crane",application:"Storage/retrieval crane and shuttle",learningPurpose:"Position feedback integrity, sequencing, trajectory health and command-vs-physical verification.",processSignals:["CranePositionCmd","CranePositionFB","PhysicalPosition","CraneVelocity","EncoderBias","InPosition"],healthyPopulation:.init(cycleCount:1100,simulatedWeeks:16,operatingRegions:["Near aisle","Mid aisle","Far aisle","Heavy tote"],learnedSignals:["position trajectory","docking error","velocity profile","feedback bias"],description:"Position- and payload-aware warehouse motion population."),faults:faults,guidedPath:commonGuidedPath(advanced:[.withinCycleTrajectories,.crossSignalLag,.multivariateHealth]),projectFactory:{ try analogProject(name:"ASRS Crane Trainer",program:"Crane",analogTags:["CranePositionCmd","CranePositionFB","PhysicalPosition","CraneVelocity","EncoderBias"]) })
    }


    private static func bottlingLine() -> HeroMachineScenario { extendedMachine(.bottlingLine,"Bottling / Filling Line","Beverage filling and inspection","High-speed fill accuracy, rejects, valve response and production-rate effects.",["FillSetpointML","FillVolumeML","FillerSpeedBPM","RejectRate","ValveCommand"],"fill-valve-drift","Fill valve response drift","Fill volume becomes speed-dependent and underfills appear at production rate.","Filler valve flow response has drifted so commanded opening no longer delivers the expected volume.",["Nominal speed","High speed","Large container"],[.healthyEnvelopes,.operatingModes,.dynamicResponse]) }
    private static func cipSkid() -> HeroMachineScenario { extendedMachine(.cipSkid,"CIP Cleaning Skid","Sanitary clean-in-place system","Conductivity, temperature, flow and concentration verification.",["ConductivityPV","TrueConductivity","ReturnTemp","FlowPV","ChemicalValve"],"conductivity-drift","Conductivity transmitter drift","CIP concentration appears acceptable while actual solution strength diverges.","Conductivity measurement drifts away from actual chemical concentration.",["Water rinse","Caustic wash","Acid wash"],[.crossSignalLag,.healthyEnvelopes,.multivariateHealth]) }
    private static func compressedAirPlant() -> HeroMachineScenario { extendedMachine(.compressedAirPlant,"Compressed-Air Plant","Plant utility air generation","Header pressure, compressor duty, leak growth and energy diagnostics.",["HeaderPressure","CompressorLoad","EstimatedLeakCFM","PlantDemandCFM","PowerKW"],"air-leak-growth","Plant air leak growth","Compressor duty and power rise while header pressure reserve disappears.","A growing distribution leak consumes compressed-air capacity independently of productive demand.",["Night","Normal production","Peak demand"],[.healthyEnvelopes,.operatingModes,.multivariateHealth]) }
    private static func reverseOsmosisPlant() -> HeroMachineScenario { extendedMachine(.reverseOsmosisPlant,"Reverse-Osmosis Water Plant","High-purity water production","Membrane DP, permeate quality, recovery and fouling progression.",["FeedPressure","MembraneDP","PermeateFlow","PermeateConductivity","RecoveryPercent"],"membrane-fouling","RO membrane fouling","Differential pressure rises while permeate flow and quality degrade.","Membrane fouling increases hydraulic resistance and reduces separation performance.",["Low demand","Nominal","High recovery"],[.healthyEnvelopes,.multivariateHealth,.dynamicResponse]) }
    private static func dataCenterCooling() -> HeroMachineScenario { extendedMachine(.dataCenterCooling,"Data-Center Cooling Loop","CRAH / chilled-water cooling","Thermal load, cooling-valve movement and command-versus-position diagnostics.",["SupplyAirTemp","CoolingValveCmd","CoolingValvePos","RackLoadPercent","FanCmd"],"cooling-valve-stiction","CRAH cooling-valve stiction","Supply-air temperature oscillates while the valve command moves but stem position sticks.","Cooling valve static friction creates stick-breakaway motion under changing rack load.",["Night load","Nominal IT load","Peak rack load"],[.sampledPID,.actuatorNonlinearities,.limitCycleFingerprinting]) }
    private static func parcelSortation() -> HeroMachineScenario { extendedMachine(.parcelSortation,"Parcel Sortation System","Distribution-center high-speed sorting","Encoder/timing windows, diverter sequence and speed-dependent misroutes.",["BeltSpeed","DiverterTimingErrorMS","ParcelPosition","SortRatePPM"],"diverter-timing","Diverter timing drift","Misroutes occur only at high belt speed despite healthy-looking logic.","Diverter actuation timing has drifted outside the parcel window as line speed increases.",["Low rate","Nominal","Peak sort rate"],[.temporalEvidence,.flightRecorder,.sequenceReconstruction]) }
    private static func automotivePaintBooth() -> HeroMachineScenario { extendedMachine(.automotivePaintBooth,"Automotive Paint Booth","Paint finishing ventilation","Filter loading, booth balance, airflow and fan-energy degradation.",["BoothDP","ExhaustFanCmd","AirVelocityFPM","FilterDP","VOCIndex"],"filter-loading","Paint booth filter loading","Fan command and filter DP rise while booth air velocity falls.","Progressive filter loading increases pressure loss and reduces controlled booth airflow.",["Idle purge","Normal production","High solvent load"],[.healthyEnvelopes,.multivariateHealth,.operatingModes]) }
    private static func injectionMoldingCell() -> HeroMachineScenario { extendedMachine(.injectionMoldingCell,"Injection-Molding Cell","Plastic molding machine","Temperature-zone recovery, cycle timing and process-quality relationships.",["BarrelZone1Temp","BarrelZone2Temp","MoldPressure","CycleTimeSec","Heater2Output"],"heater-failure","Barrel heater-zone degradation","One barrel zone falls behind setpoint even with high heater output.","A failing heater zone loses thermal authority and stretches cycle recovery.",["Warmup","Small shot","Heavy shot"],[.dynamicResponse,.healthyEnvelopes,.withinCycleTrajectories]) }
    private static func crusherConveyor() -> HeroMachineScenario { extendedMachine(.crusherConveyor,"Crusher / Mining Conveyor","Bulk-material crushing and transport","Speed feedback, load, current and belt-slip diagnosis.",["BeltSpeedCmd","BeltSpeedFB","CrusherCurrent","OreLoad","SlipPercent"],"belt-slip","Conveyor belt slip","Motor effort rises while actual belt speed falls behind command under ore load.","Drive-to-belt traction is deteriorating and slip increases with load.",["Empty","Normal ore","Heavy ore"],[.crossSignalLag,.operatingModes,.multivariateHealth]) }
    private static func grainElevator() -> HeroMachineScenario { extendedMachine(.grainElevator,"Grain Elevator","Bucket elevator / grain handling","Bearing health, current, vibration and throughput context.",["BucketSpeed","HeadBearingTemp","ElevatorCurrent","GrainRateTPH","Vibration"],"bearing-drag","Elevator bearing drag","Head bearing temperature, vibration and motor current climb together under throughput.","Mechanical bearing drag increases frictional heat and drive load.",["Empty","Normal grain","Peak harvest"],[.multivariateHealth,.operatingModes,.spectralAnalysis]) }
    private static func htstPasteurizer() -> HeroMachineScenario { extendedMachine(.htstPasteurizer,"HTST Pasteurizer","Food / dairy continuous pasteurization","Holding temperature, forward-flow permissives and sanitary divert verification.",["HoldingTemp","FlowRate","DivertValveCmd","LeakageEstimate","ProductOutletTemp"],"divert-leak","Flow-divert valve leakage","Temperature permissive looks correct but leakage compromises physical isolation.","The flow-divert valve does not fully isolate the forward-flow path in its commanded state.",["Water test","Low flow","Production flow"],[.causalTracing,.crossSignalLag,.sequenceReconstruction]) }
    private static func bioreactor() -> HeroMachineScenario { extendedMachine(.bioreactor,"Bioreactor / Fermentation Vessel","Biopharma / fermentation process","DO control, aeration/agitation effort and oxygen-transfer degradation.",["DissolvedOxygen","AirFlowCmd","AgitatorCmd","BrothTemp","OURIndex"],"oxygen-transfer-loss","Oxygen-transfer efficiency loss","Air and agitation demand rise while dissolved oxygen margin continues to fall.","Gas-liquid oxygen-transfer efficiency has degraded as biological demand increases.",["Low OUR","Growth phase","High OUR"],[.multivariateHealth,.operatingModes,.dynamicResponse]) }
    private static func chilledWaterPlant() -> HeroMachineScenario { extendedMachine(.chilledWaterPlant,"Central Chilled-Water Plant","Campus / commercial cooling utility","Differential pressure, pump energy and sensor-bias reasoning.",["CHW_DP_PV","TrueCHW_DP","PumpCmd","CHW_SupplyTemp","PlantKW"],"dp-bias","Chilled-water DP sensor bias","Pump energy rises because measured differential pressure is biased high relative to the physical loop.","Differential-pressure feedback bias drives unnecessary pumping and masks actual hydraulic state.",["Night","Occupied","Peak cooling"],[.operatingModes,.multivariateHealth,.crossSignalLag]) }
    private static func batteryFormationLine() -> HeroMachineScenario { extendedMachine(.batteryFormationLine,"EV Battery Formation / Test Line","Cell formation and electrical test","Current, voltage, fixture temperature and contact-resistance diagnostics.",["FormationCurrentA","CellVoltageV","ContactResistanceMilliOhm","FixtureTempF","CycleProgress"],"contact-resistance","Formation fixture contact resistance","Voltage drop and localized fixture heating rise during high-current formation.","Electrical contact resistance is increasing at the fixture interface.",["Low current","Nominal formation","High current"],[.healthyEnvelopes,.multivariateHealth,.dynamicResponse]) }

    private static func extendedMachine(_ id: HeroMachineID,_ title:String,_ application:String,_ purpose:String,_ signals:[String],_ faultID:String,_ faultTitle:String,_ symptom:String,_ mechanism:String,_ regions:[String],_ advanced:[ScenarioDiagnosticCapability]) -> HeroMachineScenario {
        let fault=HeroFaultScenario(id:faultID,title:faultTitle,difficulty:.advanced,symptom:symptom,rootMechanism:mechanism,capabilities:advanced,progression:[stage("healthy",0,"Healthy",0,[],"No fault"),stage("early",21,"Early degradation",0.25,["Subtle relationship drift"],mechanism),stage("developing",42,"Developing fault",0.65,[symptom],mechanism),stage("severe",63,"Severe fault",1,[symptom],mechanism)],technicianChecks:["Compare command, feedback, and physical process evidence","Repeat the check in more than one operating region","Verify repair by restoring the healthy signal relationship"])
        return .init(id:id,title:title,application:application,learningPurpose:purpose,processSignals:signals,healthyPopulation:.init(cycleCount:700,simulatedWeeks:16,operatingRegions:regions,learnedSignals:signals,description:"Operating-context healthy population for \(title)."),faults:[fault],guidedPath:commonGuidedPath(advanced:advanced),projectFactory:{ try analogProject(name:"\(title) Trainer",program:"Process",analogTags:signals) })
    }

    private static func analogProject(name: String, program: String, analogTags: [String]) throws -> ControllerProject {
        var tags: [PLCTag] = [
            PLCTag(name: "AutoMode", value: .bool(true), description: "Automatic mode", role: .input),
            PLCTag(name: "RunCmd", value: .bool(false), description: "Process run command", role: .output),
            PLCTag(name: "PermissiveOK", value: .bool(true), description: "Aggregate process permissive", role: .input),
            PLCTag(name: "ProcessState", value: .dint(10), description: "Educational process state")
        ]
        for tag in analogTags {
            tags.append(PLCTag(name: tag, value: .real(0), description: "Scenario analog signal \(tag)"))
        }
        let store = try TagStore(tags: tags)
        let main = LadderRoutine(name: "MainRoutine", rungs: [
            Rung(number: 0, comment: "Scenario process permissive", logic: .series([.instruction(.xic(tag: "AutoMode")), .instruction(.xic(tag: "PermissiveOK")), .instruction(.ote(tag: "RunCmd"))])),
            Rung(number: 10, comment: "Educational running state", logic: .series([.instruction(.xic(tag: "RunCmd")), .instruction(.mov(source: .dint(20), destination: "ProcessState"))]))
        ])
        let controllerProgram = ControllerProgram(name: program, mainRoutineName: "MainRoutine", routines: [main])
        let task = ControllerTask(name: "MainTask", kind: .periodic(periodMilliseconds: 10, priority: 5), watchdogMilliseconds: 100, programs: [controllerProgram])
        return ControllerProject(name: name, controllerTags: store, tasks: [task])
    }
}

public extension HeroMachineID {
    var playableMachineKind: PlayableMachineKind? {
        switch self {
        case .packagingCell: .packagingCell
        case .pressureSkid: .pressureSkid
        case .servoConveyor: .servoConveyor
        case .pumpStation: .pumpStation
        case .airHandlingUnit: .airHandlingUnit
        case .batchMixingTank: .batchMixingTank
        case .industrialOven: .industrialOven
        case .roboticPalletizer: .roboticPalletizer
        case .wastewaterLiftStation: .wastewaterLiftStation
        case .refrigerationRack: .refrigerationRack
        case .boilerSteamPlant: .boilerSteamPlant
        case .cncCoolantCell: .cncCoolantCell
        case .cleanroomPressureSystem: .cleanroomPressureSystem
        case .asrsCrane: .asrsCrane
        case .bottlingLine: .bottlingLine
        case .cipSkid: .cipSkid
        case .compressedAirPlant: .compressedAirPlant
        case .reverseOsmosisPlant: .reverseOsmosisPlant
        case .dataCenterCooling: .dataCenterCooling
        case .parcelSortation: .parcelSortation
        case .automotivePaintBooth: .automotivePaintBooth
        case .injectionMoldingCell: .injectionMoldingCell
        case .crusherConveyor: .crusherConveyor
        case .grainElevator: .grainElevator
        case .htstPasteurizer: .htstPasteurizer
        case .bioreactor: .bioreactor
        case .chilledWaterPlant: .chilledWaterPlant
        case .batteryFormationLine: .batteryFormationLine
        }
    }
}

public extension HeroFaultScenario {
    var playableFaultKind: PlayableFaultKind {
        switch id {
        case "pe203-sticky": .packagingStickyPhotoeye
        case "short-pulse": .packagingShortPulse
        case "valve-stiction": .pressureValveStiction
        case "dead-time-growth": .pressureDeadTimeGrowth
        case "bearing-resonance": .servoBearingResonance
        case "cavitation": .pumpCavitation
        case "loop-interaction": .ahuLoopInteraction
        case "agitator-drag": .batchAgitatorDrag
        case "burner-disturbance": .ovenBurnerDisturbance
        case "vacuum-loss": .palletizerVacuumLoss
        case "check-valve-leak": .liftStationCheckValveLeak
        case "condenser-fouling": .refrigerationCondenserFouling
        case "fuel-air-drift": .boilerFuelAirDrift
        case "coolant-restriction": .cncCoolantRestriction
        case "door-leak": .cleanroomDoorLeak
        case "encoder-slip": .asrsEncoderSlip
        default: .none
        }
    }
}

public enum ScenarioRuntimeFactory {
    public static func makeRuntime(machine: HeroMachineScenario, fault: HeroFaultScenario, day: Int = 0) throws -> PlayableScenarioRuntime? {
        guard let kind = machine.id.playableMachineKind else { return nil }
        let project = try machine.projectFactory()
        let process: HeroProcessModel
        switch kind {
        case .packagingCell: process = .packaging(.init())
        case .pressureSkid: process = .pressure(.init())
        case .servoConveyor: process = .servo(.init())
        case .pumpStation: process = .pump(.init())
        case .airHandlingUnit: process = .ahu(.init())
        case .batchMixingTank: process = .batch(.init())
        case .industrialOven: process = .oven(.init())
        case .roboticPalletizer: process = .palletizer(.init())
        case .wastewaterLiftStation: process = .liftStation(.init())
        case .refrigerationRack: process = .refrigeration(.init())
        case .boilerSteamPlant: process = .boiler(.init())
        case .cncCoolantCell: process = .cnc(.init())
        case .cleanroomPressureSystem: process = .cleanroom(.init())
        case .asrsCrane: process = .asrs(.init())
        case .bottlingLine, .cipSkid, .compressedAirPlant, .reverseOsmosisPlant, .dataCenterCooling, .parcelSortation, .automotivePaintBooth, .injectionMoldingCell, .crusherConveyor, .grainElevator, .htstPasteurizer, .bioreactor, .chilledWaterPlant, .batteryFormationLine:
            process = .extended(.init(kind: kind))
        }
        let stage = fault.progression.last(where: { $0.day <= day }) ?? fault.progression[0]
        var runtime = try PlayableScenarioRuntime(project: project, process: process, fault: .init(kind: fault.playableFaultKind, severity: stage.severity))
        if kind != .packagingCell {
            try runtime.setControllerTagValue("AutoMode", value: .bool(false))
        }
        return runtime
    }
}

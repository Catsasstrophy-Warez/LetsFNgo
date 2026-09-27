import Foundation

public enum CycleMaterialKind: String, Codable, CaseIterable, Sendable {
    case discreteProduct, liquidBatch, gasUtility, thermalProduct, bulkMaterial, motionLoad, biologicalBatch, energyDevice
}

public enum CycleRequirementKind: String, Codable, CaseIterable, Sendable {
    case motion, pumpFlow, valvePosition, pneumatic, heat, servoPosition, pressure, temperature, level, dwell
}

public struct AuthoredCycleRequirement: Codable, Equatable, Sendable {
    public var kind: CycleRequirementKind
    public var minimum: Double
    public var maximum: Double
    public var weight: Double
    public init(_ kind: CycleRequirementKind, minimum: Double = 0, maximum: Double = 100, weight: Double = 1) {
        self.kind = kind; self.minimum = minimum; self.maximum = maximum; self.weight = weight
    }
}

public struct AuthoredCyclePhase: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var purpose: String
    public var nominalSeconds: Double
    public var requirements: [AuthoredCycleRequirement]
    public init(_ id: String, _ name: String, _ purpose: String, _ nominalSeconds: Double, _ requirements: [AuthoredCycleRequirement]) {
        self.id=id; self.name=name; self.purpose=purpose; self.nominalSeconds=nominalSeconds; self.requirements=requirements
    }
}

public struct ProductQualitySpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String { metric }
    public var metric: String
    public var target: Double
    public var tolerance: Double
    public var unit: String
    public var source: CycleRequirementKind
    public init(_ metric:String,_ target:Double,_ tolerance:Double,_ unit:String,_ source:CycleRequirementKind){self.metric=metric;self.target=target;self.tolerance=tolerance;self.unit=unit;self.source=source}
}

public struct MachineCyclePhysicsProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { machine.rawValue }
    public var machine: PlayableMachineKind
    public var productName: String
    public var materialKind: CycleMaterialKind
    public var nominalCycleSeconds: Double
    public var motorInertiaSeconds: Double
    public var pneumaticStrokeSeconds: Double
    public var valveTravelSeconds: Double
    public var tankCapacityLiters: Double
    public var thermalMassKJPerC: Double
    public var pumpShutoffHeadPSI: Double
    public var pumpRatedFlowLPM: Double
    public var pidResponseSeconds: Double
    public var servoMoveSeconds: Double
    public var jamSensitivity: Double
    public var collisionSensitivity: Double
    public var phases: [AuthoredCyclePhase]
    public var qualitySpecs: [ProductQualitySpec]
}

public enum MachineCycleLibrary {
    public static let all: [MachineCyclePhysicsProfile] = PlayableMachineKind.allCases.map(profile)
    public static func profile(for machine: PlayableMachineKind) -> MachineCyclePhysicsProfile {
        let d = descriptor(machine)
        return .init(machine: machine, productName: d.product, materialKind: d.material, nominalCycleSeconds: d.cycle,
                     motorInertiaSeconds: d.inertia, pneumaticStrokeSeconds: d.pneu, valveTravelSeconds: d.valve,
                     tankCapacityLiters: d.tank, thermalMassKJPerC: d.thermal, pumpShutoffHeadPSI: d.head,
                     pumpRatedFlowLPM: d.flow, pidResponseSeconds: d.pid, servoMoveSeconds: d.servo,
                     jamSensitivity: d.jam, collisionSensitivity: d.collision,
                     phases: d.phases.enumerated().map { index, p in .init("P\(index+1)",p.0,p.1,p.2,p.3) }, qualitySpecs: d.quality)
    }

    private typealias D = (product:String,material:CycleMaterialKind,cycle:Double,inertia:Double,pneu:Double,valve:Double,tank:Double,thermal:Double,head:Double,flow:Double,pid:Double,servo:Double,jam:Double,collision:Double,phases:[(String,String,Double,[AuthoredCycleRequirement])],quality:[ProductQualitySpec])
    private static func descriptor(_ m:PlayableMachineKind)->D {
        let motion = AuthoredCycleRequirement(.motion,minimum:25), flow = AuthoredCycleRequirement(.pumpFlow,minimum:20), valve = AuthoredCycleRequirement(.valvePosition,minimum:15), pneu = AuthoredCycleRequirement(.pneumatic,minimum:45), heat = AuthoredCycleRequirement(.heat,minimum:35), servo = AuthoredCycleRequirement(.servoPosition,minimum:20), pressure = AuthoredCycleRequirement(.pressure,minimum:25), temp = AuthoredCycleRequirement(.temperature,minimum:35), level = AuthoredCycleRequirement(.level,minimum:20,maximum:95), dwell = AuthoredCycleRequirement(.dwell,minimum:100)
        func q(_ n:String,_ t:Double,_ tol:Double,_ u:String,_ s:CycleRequirementKind)->ProductQualitySpec{.init(n,t,tol,u,s)}
        switch m {
        case .packagingCell:return ("sealed carton",.discreteProduct,6,0.8,0.35,0.8,0,0,0,0,0.5,0.5,0.8,0.3,[("Index","Move carton into station",1.6,[motion]),("Clamp","Capture carton",0.7,[pneu]),("Process","Seal and verify",2.1,[pneu,dwell]),("Discharge","Release finished carton",1.6,[motion])],[q("seal timing",100,12,"%",.dwell),q("index position",100,8,"%",.motion)])
        case .pressureSkid:return ("regulated process stream",.liquidBatch,12,1.5,0,2.5,180,20,95,180,3.5,0,0.2,0.1,[("Prime","Establish pump flow",2,[flow]),("Pressurize","Build header pressure",3,[flow,pressure]),("Regulate","Hold pressure setpoint",5,[valve,pressure]),("Unload","Return to standby",2,[valve])],[q("pressure",60,3,"psi",.pressure),q("flow",70,7,"%",.pumpFlow)])
        case .servoConveyor:return ("indexed carrier",.motionLoad,4.2,0.5,0.25,0,0,0,0,0,0.3,0.65,0.7,0.9,[("Acquire","Detect carrier",0.6,[motion]),("Accelerate","Servo motion profile",1.0,[servo]),("Settle","Reach index position",0.8,[servo,dwell]),("Transfer","Release carrier",1.8,[motion])],[q("index position",100,1.5,"%",.servoPosition),q("move time",100,8,"%",.motion)])
        case .pumpStation:return ("transferred liquid",.liquidBatch,18,2,0,2.4,900,30,120,420,5,0,0.1,0.1,[("Fill suction","Establish level",3,[level]),("Start pump","Ramp pump",3,[flow]),("Transfer","Move batch",9,[flow,pressure]),("Stop","Controlled stop",3,[dwell])],[q("transfer volume",100,5,"%",.level),q("discharge pressure",65,6,"psi",.pressure)])
        case .airHandlingUnit:return ("conditioned air",.gasUtility,30,3,0,5,0,120,0,0,7,0,0.05,0.05,[("Start fan","Ramp supply fan",5,[motion]),("Establish airflow","Open dampers",5,[valve]),("Condition","Hold temperature/pressure",15,[temp,pressure]),("Stabilize","Verify room response",5,[dwell])],[q("supply temperature",55,2,"F",.temperature),q("duct pressure",100,8,"%",.pressure)])
        case .batchMixingTank:return ("mixed batch",.liquidBatch,45,2.5,0.6,2.2,1200,85,70,250,5,0,0.15,0.1,[("Charge","Fill ingredients",10,[valve,level]),("Mix","Agitate batch",16,[motion]),("Condition","Heat/cool to recipe",10,[temp]),("Transfer","Discharge batch",9,[flow,valve])],[q("blend uniformity",100,4,"%",.motion),q("batch level",75,4,"%",.level)])
        case .industrialOven:return ("cured product",.thermalProduct,55,1.8,0.4,1.5,0,650,0,0,12,0,0.2,0.1,[("Load","Index product",6,[motion]),("Heat","Reach process temperature",18,[heat,temp]),("Soak","Hold thermal profile",24,[temp,dwell]),("Unload","Discharge product",7,[motion])],[q("core temperature",85,3,"%",.temperature),q("soak exposure",100,8,"%",.dwell)])
        case .roboticPalletizer:return ("completed pallet layer",.discreteProduct,8,0.8,0.45,0,0,0,0,0,0,0.7,0.7,0.9,[("Acquire","Grip case",1.5,[pneu]),("Move","Robot transfer",2.5,[servo]),("Place","Set case on pallet",1.2,[servo,pneu]),("Return","Clear placement zone",2.8,[servo])],[q("placement accuracy",100,2,"%",.servoPosition),q("vacuum grip",100,10,"%",.pneumatic)])
        case .wastewaterLiftStation:return ("pumped wet-well volume",.liquidBatch,40,3,0,2,2500,20,80,600,7,0,0.05,0.05,[("Accumulate","Wet well rises",10,[level]),("Lead start","Start lead pump",5,[flow]),("Pump down","Reduce wet-well level",20,[flow,level]),("Stop","Stop at low level",5,[dwell])],[q("pumpdown level",25,5,"%",.level),q("flow capacity",100,10,"%",.pumpFlow)])
        case .refrigerationRack:return ("refrigeration capacity",.thermalProduct,60,4,0,3,0,400,0,0,10,0,0.05,0.05,[("Load detect","Detect suction demand",8,[pressure]),("Stage","Start compressor capacity",10,[motion]),("Regulate","Hold suction pressure",32,[pressure,valve]),("Unload","Reduce capacity",10,[dwell])],[q("suction pressure",45,3,"psi",.pressure),q("temperature pull-down",40,4,"%",.temperature)])
        case .boilerSteamPlant:return ("stable steam header",.thermalProduct,70,3,1,4,800,950,160,300,10,0,0.02,0.05,[("Purge","Prove airflow",12,[motion,dwell]),("Lightoff","Establish flame",8,[valve,heat]),("Warmup","Raise steam pressure",25,[heat,pressure]),("Modulate","Hold header pressure",25,[pressure,valve])],[q("steam pressure",125,4,"psi",.pressure),q("fuel-air balance",100,6,"%",.valvePosition)])
        case .cncCoolantCell:return ("conditioned coolant",.liquidBatch,22,1.5,0.4,1.5,300,25,70,160,4,0,0.15,0.1,[("Prime","Open coolant path",3,[valve]),("Pump","Establish coolant flow",5,[flow]),("Machine","Supply cutting process",10,[flow,pressure]),("Drain","Return coolant",4,[level])],[q("coolant flow",80,8,"%",.pumpFlow),q("filter pressure",55,5,"psi",.pressure)])
        case .cleanroomPressureSystem:return ("qualified room condition",.gasUtility,45,3,0,5,0,150,0,0,8,0,0.03,0.05,[("Fan start","Establish supply",6,[motion]),("Balance","Position dampers",10,[valve]),("Pressurize","Reach room differential",14,[pressure]),("Qualify","Hold stable envelope",15,[pressure,dwell])],[q("room differential",0.05,0.01,"inH2O",.pressure),q("stability",100,5,"%",.dwell)])
        case .asrsCrane:return ("stored pallet",.motionLoad,14,1.2,0.3,0,0,0,0,0,0,1.3,0.5,1.0,[("Acquire","Fork engages load",2,[pneu]),("Travel","Horizontal axis move",4,[servo]),("Lift","Vertical axis position",4,[servo]),("Deposit","Place and retract",4,[servo,pneu])],[q("slot position",100,1,"%",.servoPosition),q("load transfer",100,5,"%",.pneumatic)])
        case .bottlingLine:return ("filled bottle",.discreteProduct,3.2,0.55,0.22,0.35,40,10,30,45,0.7,0.35,0.9,0.4,[("Index","Bottle enters filler",0.8,[motion]),("Fill","Meter product",1.0,[valve,flow]),("Close","Close fill valve",0.4,[pneu]),("Reject/exit","Inspect and discharge",1.0,[motion])],[q("fill volume",100,2,"%",.pumpFlow),q("fill timing",100,5,"%",.valvePosition)])
        case .cipSkid:return ("validated CIP circuit",.liquidBatch,80,2,0.5,2.5,600,180,85,350,8,0,0.05,0.05,[("Pre-rinse","Water circulation",15,[flow]),("Chemical","Dose and circulate",20,[flow,valve]),("Heat/hold","Reach sanitation temperature",30,[temp,dwell]),("Final rinse","Clear chemistry",15,[flow])],[q("conductivity endpoint",100,4,"%",.dwell),q("sanitation temperature",80,3,"C",.temperature)])
        case .compressedAirPlant:return ("compressed-air reserve",.gasUtility,50,4,0,2,1800,120,150,500,9,0,0.02,0.02,[("Load detect","Header pressure falls",8,[pressure]),("Start compressor","Ramp compressor",8,[motion]),("Load","Restore receiver pressure",25,[pressure]),("Unload","Unload and coast",9,[dwell])],[q("header pressure",110,5,"psi",.pressure),q("capacity",100,7,"%",.motion)])
        case .reverseOsmosisPlant:return ("permeate water",.liquidBatch,75,3,0.4,2.8,1000,45,240,220,8,0,0.05,0.05,[("Flush","Low-pressure flush",10,[flow]),("Pressurize","Ramp high-pressure pump",15,[flow,pressure]),("Produce","Make permeate",40,[pressure,flow]),("Shutdown flush","Depressurize/flush",10,[valve])],[q("permeate quality",98,2,"%",.pressure),q("recovery",75,5,"%",.pumpFlow)])
        case .dataCenterCooling:return ("cooling capacity",.thermalProduct,50,3,0,4,700,500,90,400,8,0,0.03,0.03,[("Demand","Detect heat load",5,[temp]),("Flow","Stage pump/fan",10,[motion,flow]),("Control","Modulate chilled water",25,[valve,temp]),("Verify","Hold supply air envelope",10,[temp,dwell])],[q("supply temperature",65,2,"F",.temperature),q("cooling flow",100,7,"%",.pumpFlow)])
        case .parcelSortation:return ("correctly sorted parcel",.discreteProduct,2.4,0.35,0.18,0,0,0,0,0,0,0.25,1.0,0.8,[("Detect","Acquire parcel ID",0.4,[motion]),("Track","Encoder tracking",0.7,[motion]),("Divert","Fire diverter",0.35,[pneu]),("Confirm","Verify chute entry",0.95,[motion])],[q("sort accuracy",100,1,"%",.pneumatic),q("divert timing",100,3,"%",.motion)])
        case .automotivePaintBooth:return ("coated body",.thermalProduct,90,5,0.7,5,0,600,0,0,12,0,0.1,0.1,[("Purge","Establish booth airflow",15,[motion]),("Spray","Maintain pressure/flow",25,[pressure,valve]),("Flash","Solvent flash dwell",20,[dwell]),("Bake","Cure coating",30,[heat,temp])],[q("film cure",100,5,"%",.temperature),q("booth balance",100,7,"%",.pressure)])
        case .injectionMoldingCell:return ("molded part",.thermalProduct,38,1.5,0.4,1,20,350,120,100,5,0.9,0.6,0.9,[("Clamp","Close mold",5,[servo]),("Inject","Fill cavity",6,[pressure,servo]),("Pack/cool","Hold pressure and cool",20,[pressure,temp,dwell]),("Eject","Open/eject part",7,[servo,pneu])],[q("part fill",100,2,"%",.pressure),q("mold temperature",70,3,"%",.temperature)])
        case .crusherConveyor:return ("processed bulk material",.bulkMaterial,35,4,0,0,0,0,0,0,0,0,0.95,0.2,[("Feed","Start feeder",5,[motion]),("Crush","Crusher under load",12,[motion]),("Convey","Move product downstream",13,[motion]),("Clear","Empty machine",5,[motion])],[q("throughput",100,10,"%",.motion),q("belt slip",0,5,"%",.motion)])
        case .grainElevator:return ("elevated grain",.bulkMaterial,40,5,0,0,0,40,0,0,0,0,0.8,0.15,[("Start","Prove elevator speed",7,[motion]),("Feed","Admit grain",8,[motion]),("Elevate","Continuous transfer",20,[motion]),("Empty","Clear buckets",5,[motion])],[q("capacity",100,8,"%",.motion),q("bearing temperature",45,8,"C",.temperature)])
        case .htstPasteurizer:return ("pasteurized product",.liquidBatch,65,2,0.4,1.2,500,400,90,250,5,0,0.03,0.05,[("Balance","Establish flow",10,[flow]),("Heat","Reach legal temperature",18,[temp]),("Hold","Maintain hold-tube exposure",22,[temp,dwell]),("Divert/forward","Quality route selection",15,[valve])],[q("pasteurization temperature",72,1,"C",.temperature),q("hold exposure",100,2,"%",.dwell)])
        case .bioreactor:return ("qualified culture interval",.biologicalBatch,120,3,0.5,3,2000,500,50,120,14,0,0.01,0.02,[("Charge","Establish batch volume",20,[level]),("Agitate","Mix culture",25,[motion]),("Control","Regulate DO/pH/temp",55,[valve,temp]),("Sample","Hold stable sample window",20,[dwell])],[q("DO control",50,5,"%",.valvePosition),q("temperature",37,0.5,"C",.temperature)])
        case .chilledWaterPlant:return ("chilled-water capacity",.thermalProduct,80,5,0,5,5000,900,120,900,12,0,0.02,0.02,[("Demand","Determine load",10,[temp]),("Stage","Start pumps/chiller",15,[motion,flow]),("Pull down","Reduce supply temperature",30,[temp]),("Optimize","Hold DP/temp efficiently",25,[pressure,valve])],[q("supply water temperature",44,1.5,"F",.temperature),q("differential pressure",20,2,"psi",.pressure)])
        case .batteryFormationLine:return ("qualified battery channel",.energyDevice,100,0.8,0.2,0,0,220,0,0,8,0.4,0.05,0.1,[("Connect","Engage test fixture",8,[pneu]),("Charge","Controlled current charge",38,[dwell,temp]),("Rest","Voltage stabilization",20,[dwell]),("Discharge/test","Capacity verification",34,[dwell,temp])],[q("capacity",100,3,"%",.dwell),q("cell temperature",35,4,"C",.temperature)])
        }
    }
}

public struct MachineCycleMaterialState: Codable, Equatable, Sendable {
    public var serial: Int = 1
    public var progressPercent: Double = 0
    public var massOrVolume: Double = 0
    public var temperatureC: Double = 25
    public var pressurePSI: Double = 0
    public var positionPercent: Double = 0
    public var qualityScore: Double = 100
    public var disposition: String = "in process"
}

public struct MachineDynamicState: Codable, Equatable, Sendable {
    public var motorSpeedPercent: Double = 0
    public var pneumaticPositionPercent: Double = 0
    public var valvePositionPercent: Double = 0
    public var tankVolumeLiters: Double = 0
    public var temperatureC: Double = 25
    public var pumpFlowLPM: Double = 0
    public var pumpHeadPSI: Double = 0
    public var servoPositionPercent: Double = 0
    public var processPressurePercent: Double = 0
    public var processLevelPercent: Double = 50
    public var pidResponsePercent: Double = 0
}

public struct ProductionQualityOutcome: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var serial: Int
    public var score: Double
    public var disposition: String
    public var deviations: [String]
}

public struct MachineCycleEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var elapsedSeconds: Double
    public var kind: String
    public var detail: String
}

public struct AuthoredMachineCycleSnapshot: Codable, Equatable, Sendable {
    public var profile: MachineCyclePhysicsProfile
    public var phaseIndex: Int
    public var phaseElapsed: Double
    public var cycleCount: Int
    public var goodCount: Int
    public var rejectCount: Int
    public var reworkCount: Int
    public var material: MachineCycleMaterialState
    public var dynamics: MachineDynamicState
    public var jammed: Bool
    public var collisionInterlock: Bool
    public var phaseCompliance: Double
    public var events: [MachineCycleEvent]
    public var recentQuality: [ProductionQualityOutcome]
    public var currentPhase: AuthoredCyclePhase { profile.phases[min(max(phaseIndex,0),profile.phases.count-1)] }
}

public struct AuthoredMachineCycleRuntime: Codable, Equatable, Sendable {
    public var profile: MachineCyclePhysicsProfile
    public var phaseIndex: Int = 0
    public var phaseElapsed: Double = 0
    public var elapsedSeconds: Double = 0
    public var cycleCount: Int = 0
    public var goodCount: Int = 0
    public var rejectCount: Int = 0
    public var reworkCount: Int = 0
    public var material = MachineCycleMaterialState()
    public var dynamics = MachineDynamicState()
    public var jammed = false
    public var collisionInterlock = false
    public var events: [MachineCycleEvent] = []
    public var recentQuality: [ProductionQualityOutcome] = []
    private var accumulatedCompliance: Double = 0
    private var complianceSamples: Int = 0

    public init(machine:PlayableMachineKind){profile=MachineCycleLibrary.profile(for:machine)}

    @discardableResult public mutating func step(plant:ClosedLoopPlantSnapshot, deltaTime:Double)->AuthoredMachineCycleSnapshot {
        let dt=max(0.001,deltaTime); elapsedSeconds += dt; phaseElapsed += dt
        updateDynamics(plant:plant,dt:dt)
        let phase=profile.phases[phaseIndex]
        let compliance=phaseCompliance(phase)
        accumulatedCompliance += compliance; complianceSamples += 1
        material.progressPercent=min(100,material.progressPercent + dt/profile.nominalCycleSeconds*100*max(0.05,compliance/100))
        material.temperatureC=dynamics.temperatureC; material.pressurePSI=dynamics.pumpHeadPSI; material.positionPercent=dynamics.servoPositionPercent

        let driveDemand = plant.actuators.values.contains{$0.commandPercent > 45 && [.vfd,.servo,.motor,.motorStarter,.pump].contains($0.kind)}
        if driveDemand && dynamics.motorSpeedPercent < 8 && profile.jamSensitivity > 0.4 && phaseElapsed > max(0.5,phase.nominalSeconds*0.45) {
            if !jammed { events.append(.init(elapsedSeconds:elapsedSeconds,kind:"JAM",detail:"Material stopped while motion was commanded during \(phase.name).")) }
            jammed=true
        }
        let servoDemand=plant.actuators.values.contains{$0.kind == .servo && $0.commandPercent > 50}
        let unsafeMotion = servoDemand && dynamics.servoPositionPercent > 92 && profile.collisionSensitivity > 0.65
        if unsafeMotion && !collisionInterlock { collisionInterlock=true; events.append(.init(elapsedSeconds:elapsedSeconds,kind:"INTERLOCK",detail:"Collision envelope reached; physical interlock stopped sequence advancement.")) }

        if !jammed && !collisionInterlock && phaseElapsed >= phase.nominalSeconds && compliance >= 68 {
            events.append(.init(elapsedSeconds:elapsedSeconds,kind:"PHASE",detail:"\(phase.name) completed at \(Int(compliance))% compliance."))
            phaseIndex += 1; phaseElapsed=0
            if phaseIndex >= profile.phases.count { finishCycle(); phaseIndex=0 }
        }
        if events.count>80 { events.removeFirst(events.count-80) }
        return snapshot(compliance)
    }

    public mutating func clearJam(){jammed=false;events.append(.init(elapsedSeconds:elapsedSeconds,kind:"RECOVERY",detail:"Jam cleared; sequence can resume if controls prerequisites are satisfied."))}
    public mutating func resetCollisionInterlock(){collisionInterlock=false;events.append(.init(elapsedSeconds:elapsedSeconds,kind:"RECOVERY",detail:"Collision interlock reset after physical clearance."))}

    private mutating func updateDynamics(plant:ClosedLoopPlantSnapshot,dt:Double){
        let a=Array(plant.actuators.values)
        let motors=a.filter{[.vfd,.motor,.motorStarter,.pump,.contactor].contains($0.kind)}
        let pneu=a.filter{$0.kind == .solenoid}; let valves=a.filter{[.controlValve,.analogActuator].contains($0.kind)}; let servos=a.filter{$0.kind == .servo}; let heaters=a.filter{$0.kind == .heater}
        let motorTarget=avg(motors.map{$0.actualPercent}); dynamics.motorSpeedPercent=lag(dynamics.motorSpeedPercent,motorTarget,tau:profile.motorInertiaSeconds,dt:dt)
        let pneuTarget=avg(pneu.map{$0.actualPercent}); dynamics.pneumaticPositionPercent=lag(dynamics.pneumaticPositionPercent,pneuTarget,tau:profile.pneumaticStrokeSeconds,dt:dt)
        let valveTarget=avg(valves.map{$0.actualPercent}); dynamics.valvePositionPercent=lag(dynamics.valvePositionPercent,valveTarget,tau:profile.valveTravelSeconds,dt:dt)
        let servoTarget=avg(servos.map{$0.positionPercent}); dynamics.servoPositionPercent=lag(dynamics.servoPositionPercent,servoTarget,tau:profile.servoMoveSeconds,dt:dt)
        let speed=dynamics.motorSpeedPercent/100
        dynamics.pumpFlowLPM=profile.pumpRatedFlowLPM*speed*max(0.05,dynamics.valvePositionPercent/100)
        dynamics.pumpHeadPSI=profile.pumpShutoffHeadPSI*speed*speed*max(0.15,1-0.55*dynamics.pumpFlowLPM/max(1,profile.pumpRatedFlowLPM))
        if profile.tankCapacityLiters>0 { dynamics.tankVolumeLiters=min(profile.tankCapacityLiters,max(0,dynamics.tankVolumeLiters+(dynamics.pumpFlowLPM - profile.pumpRatedFlowLPM*dynamics.valvePositionPercent/120)*dt/60)) }
        let heaterPct=avg(heaters.map{$0.actualPercent})
        let heatGain = profile.thermalMassKJPerC > 0 ? heaterPct*4/max(20,profile.thermalMassKJPerC) : 0
        dynamics.temperatureC += (heatGain - (dynamics.temperatureC-25)*0.002)*dt
        dynamics.processPressurePercent=plant.process.pressurePercent
        dynamics.processLevelPercent=profile.tankCapacityLiters > 0 ? 100*dynamics.tankVolumeLiters/profile.tankCapacityLiters : plant.process.levelPercent
        let targetResponse=(plant.process.pressurePercent+plant.process.flowPercent+plant.process.temperaturePercent)/3
        dynamics.pidResponsePercent=lag(dynamics.pidResponsePercent,targetResponse,tau:profile.pidResponseSeconds,dt:dt)
    }

    private func value(_ kind:CycleRequirementKind)->Double { switch kind { case .motion:return dynamics.motorSpeedPercent;case .pumpFlow:return profile.pumpRatedFlowLPM>0 ? min(100,100*dynamics.pumpFlowLPM/profile.pumpRatedFlowLPM):dynamics.motorSpeedPercent;case .valvePosition:return dynamics.valvePositionPercent;case .pneumatic:return dynamics.pneumaticPositionPercent;case .heat:return max(0,min(100,(dynamics.temperatureC-25)*2));case .servoPosition:return dynamics.servoPositionPercent;case .pressure:return max(dynamics.processPressurePercent,profile.pumpShutoffHeadPSI>0 ? min(100,100*dynamics.pumpHeadPSI/profile.pumpShutoffHeadPSI):0);case .temperature:return max(dynamics.pidResponsePercent,min(100,(dynamics.temperatureC-20)*2));case .level:return dynamics.processLevelPercent;case .dwell:return 100 } }
    private func phaseCompliance(_ p:AuthoredCyclePhase)->Double { guard !p.requirements.isEmpty else{return 100};var sum=0.0,w=0.0;for r in p.requirements{let v=value(r.kind);let c=v<r.minimum ? max(0,100-(r.minimum-v)*3):v>r.maximum ? max(0,100-(v-r.maximum)*3):100;sum += c*r.weight;w += r.weight};return w>0 ? sum/w:100 }
    private mutating func finishCycle(){
        cycleCount += 1
        let avgCompliance = complianceSamples>0 ? accumulatedCompliance/Double(complianceSamples):0
        var deviations:[String]=[]; var penalty=max(0,100-avgCompliance)*0.65
        if jammed {penalty += 35;deviations.append("material jam")}; if collisionInterlock {penalty += 45;deviations.append("collision interlock")}
        for spec in profile.qualitySpecs { let measured=value(spec.source); let normalizedTarget = spec.target > 100 ? min(100,spec.target) : spec.target; if abs(measured-normalizedTarget)>max(2,spec.tolerance){penalty += min(18,abs(measured-normalizedTarget)*0.12);deviations.append(spec.metric)} }
        let score=max(0,min(100,100-penalty)); let disposition:String
        if score>=90 {disposition="good";goodCount += 1}else if score>=72{disposition="rework";reworkCount += 1}else{disposition="reject";rejectCount += 1}
        recentQuality.append(.init(id:"\(profile.machine.rawValue)-\(material.serial)",serial:material.serial,score:score,disposition:disposition,deviations:Array(Set(deviations)).sorted()))
        if recentQuality.count>20{recentQuality.removeFirst()}; events.append(.init(elapsedSeconds:elapsedSeconds,kind:"QUALITY",detail:"\(profile.productName) #\(material.serial) → \(disposition.uppercased()) • score \(Int(score))."))
        material = .init(serial:material.serial+1); accumulatedCompliance=0;complianceSamples=0
    }
    private func snapshot(_ compliance:Double)->AuthoredMachineCycleSnapshot{.init(profile:profile,phaseIndex:phaseIndex,phaseElapsed:phaseElapsed,cycleCount:cycleCount,goodCount:goodCount,rejectCount:rejectCount,reworkCount:reworkCount,material:material,dynamics:dynamics,jammed:jammed,collisionInterlock:collisionInterlock,phaseCompliance:compliance,events:events,recentQuality:recentQuality)}
    private func avg(_ x:[Double])->Double{x.isEmpty ? 0:x.reduce(0,+)/Double(x.count)}
    private func lag(_ current:Double,_ target:Double,tau:Double,dt:Double)->Double{guard tau>0.001 else{return target};let a=min(1,dt/tau);return current+(target-current)*a}
}

public extension FullyClosedLoopMachineRuntime {
    mutating func cycleWithAuthoredPhysics(_ authored: inout AuthoredMachineCycleRuntime, elapsedMilliseconds:Int32=100) throws -> (FullyClosedLoopSnapshot, AuthoredMachineCycleSnapshot) {
        let closed = try cycle(elapsedMilliseconds: elapsedMilliseconds)
        let physical = authored.step(plant:closed.physical,deltaTime:Double(elapsedMilliseconds)/1000)
        return (closed,physical)
    }
}

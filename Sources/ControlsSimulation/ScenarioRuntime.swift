import Foundation
import ControlsPLC

public enum PlayableMachineKind: String, Codable, CaseIterable, Sendable {
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

public enum PlayableFaultKind: String, Codable, Sendable {
    case none
    case packagingStickyPhotoeye
    case packagingShortPulse
    case pressureValveStiction
    case pressureDeadTimeGrowth
    case servoBearingResonance
    case pumpCavitation
    case ahuLoopInteraction
    case batchAgitatorDrag
    case ovenBurnerDisturbance
    case palletizerVacuumLoss
    case liftStationCheckValveLeak
    case refrigerationCondenserFouling
    case boilerFuelAirDrift
    case cncCoolantRestriction
    case cleanroomDoorLeak
    case asrsEncoderSlip
    case bottlingFillValveDrift
    case cipConductivityDrift
    case compressedAirLeakGrowth
    case roMembraneFouling
    case dataCenterValveStiction
    case parcelDiverterTimingDrift
    case paintBoothFilterLoading
    case moldingHeaterFailure
    case crusherBeltSlip
    case grainBearingDrag
    case pasteurizerDivertLeak
    case bioreactorOxygenTransferLoss
    case chilledWaterDPBias
    case batteryContactResistance
}

public struct ScenarioFaultComponent: Equatable, Sendable {
    public var kind: PlayableFaultKind
    public var severity: Double

    public init(kind: PlayableFaultKind, severity: Double) {
        self.kind = kind
        self.severity = min(1, max(0, severity))
    }
}

public struct ScenarioFaultInjection: Equatable, Sendable {
    public var components: [ScenarioFaultComponent]

    public init(kind: PlayableFaultKind = .none, severity: Double = 0) {
        self.components = kind == .none || severity <= 0 ? [] : [.init(kind: kind, severity: severity)]
    }

    public init(components: [ScenarioFaultComponent]) {
        var strongest: [PlayableFaultKind: Double] = [:]
        for component in components where component.kind != .none {
            strongest[component.kind] = max(strongest[component.kind] ?? 0, min(1, max(0, component.severity)))
        }
        self.components = strongest.map { .init(kind: $0.key, severity: $0.value) }.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    public var kind: PlayableFaultKind { components.first?.kind ?? .none }
    public var severity: Double { components.first?.severity ?? 0 }
    public func severity(for kind: PlayableFaultKind) -> Double { components.first(where: { $0.kind == kind })?.severity ?? 0 }
    public func contains(_ kind: PlayableFaultKind) -> Bool { severity(for: kind) > 0 }
}

public struct SimulationClock: Equatable, Sendable {
    public private(set) var elapsedSeconds: Double = 0
    public private(set) var tick: UInt64 = 0

    public init() {}

    public mutating func advance(by deltaTime: Double) {
        elapsedSeconds += max(0, deltaTime)
        tick &+= 1
    }
}

public struct ProcessEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timeSeconds: Double
    public let name: String
    public let detail: String

    public init(id: UUID = UUID(), timeSeconds: Double, name: String, detail: String) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.name = name
        self.detail = detail
    }
}

public struct ScenarioProcessSnapshot: Equatable, Sendable {
    public var analog: [String: Double]
    public var discrete: [String: Bool]
    public var events: [ProcessEvent]

    public init(analog: [String: Double] = [:], discrete: [String: Bool] = [:], events: [ProcessEvent] = []) {
        self.analog = analog
        self.discrete = discrete
        self.events = events
    }
}

public struct ScenarioEnvironment: Equatable, Sendable {
    public var load: Double
    public var speed: Double
    public var ambient: Double

    public init(load: Double = 0.5, speed: Double = 0.5, ambient: Double = 0.5) {
        self.load = min(1, max(0, load))
        self.speed = min(1, max(0, speed))
        self.ambient = min(1, max(0, ambient))
    }
}

public struct PackagingCellProcessModel: Equatable, Sendable {
    public private(set) var conveyorPosition: Double = 0.05
    public private(set) var physicalPhotoeye: Bool = false
    public private(set) var productCount: Int = 0
    private var stickyHoldSeconds: Double = 0
    private var lastBeamState = false

    public init() {}

    public mutating func reset() { self = .init() }

    public mutating func step(deltaTime: Double, motorRun: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt = max(0.0001, deltaTime)
        let baseSpeed = 0.16 + 0.34 * environment.speed
        let faultSpeedBoost = 0.35 * fault.severity(for: .packagingShortPulse)
        let speed = motorRun ? baseSpeed + faultSpeedBoost : 0
        conveyorPosition += speed * dt
        var events: [ProcessEvent] = []
        if conveyorPosition >= 1.0 {
            conveyorPosition.formTruncatingRemainder(dividingBy: 1.0)
            productCount += 1
            events.append(.init(timeSeconds: time, name: "Product entered conveyor", detail: "Product \(productCount + 1) began a new pass."))
        }

        let beamCenter = 0.62
        let healthyHalfWidth = 0.032
        let narrowed = healthyHalfWidth * (1 - 0.80 * fault.severity(for: .packagingShortPulse))
        let rawBeam = abs(conveyorPosition - beamCenter) <= max(0.004, narrowed)

        if lastBeamState && !rawBeam && fault.contains(.packagingStickyPhotoeye) {
            stickyHoldSeconds = 0.05 + 1.7 * fault.severity(for: .packagingStickyPhotoeye)
            events.append(.init(timeSeconds: time, name: "PE203 release delayed", detail: "Fault model is holding the field photoeye true after the product clears."))
        }
        if stickyHoldSeconds > 0 {
            stickyHoldSeconds = max(0, stickyHoldSeconds - dt)
            physicalPhotoeye = true
        } else {
            physicalPhotoeye = rawBeam
        }
        if !lastBeamState && rawBeam {
            events.append(.init(timeSeconds: time, name: "PE203 blocked", detail: "Product entered the transfer photoeye beam."))
        }
        if lastBeamState && !physicalPhotoeye {
            events.append(.init(timeSeconds: time, name: "PE203 cleared", detail: "Product physically cleared the transfer photoeye."))
        }
        lastBeamState = rawBeam

        return .init(
            analog: [
                "ConveyorPosition": conveyorPosition,
                "LineSpeed": speed,
                "ProductCountPhysical": Double(productCount)
            ],
            discrete: ["PE203": physicalPhotoeye],
            events: events
        )
    }
}

public struct PressureSkidProcessModel: Equatable, Sendable {
    public private(set) var pressureSP: Double = 60
    public private(set) var pressurePV: Double = 0
    public private(set) var valveCommand: Double = 0
    public private(set) var valvePosition: Double = 0
    public private(set) var integral: Double = 0
    public private(set) var airSupplyPressure: Double = 90
    public private(set) var loadDemand: Double = 0.45
    public private(set) var breakawayCount: Int = 0

    private var stuckAnchorCommand: Double = 0
    private var delayLine: [Double] = Array(repeating: 0, count: 5)
    private var wasStuck = false

    public init() {}

    public mutating func reset() { self = .init() }

    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt = max(0.001, deltaTime)
        loadDemand = 0.30 + 0.55 * environment.load
        var events: [ProcessEvent] = []

        if runCommand {
            let error = pressureSP - pressurePV
            let kp = 1.15
            let ki = 0.90
            integral = min(100, max(-100, integral + ki * error * dt))
            valveCommand = min(100, max(0, kp * error + integral))
        } else {
            valveCommand = 0
            integral *= max(0, 1 - 3 * dt)
        }

        let stictionSeverity = fault.severity(for: .pressureValveStiction)
        let breakaway = stictionSeverity > 0 ? 0.4 + 7.0 * stictionSeverity : 0
        let desired = valveCommand
        var stuck = false
        if breakaway > 0 {
            let separation = abs(desired - valvePosition)
            if separation < breakaway {
                stuck = true
                if !wasStuck { stuckAnchorCommand = desired }
            } else {
                breakawayCount += 1
                events.append(.init(timeSeconds: time, name: "Valve breakaway", detail: String(format: "Stem released after %.1f%% command-position separation.", separation)))
                valvePosition += (desired - valvePosition) * min(1, 10 * dt)
                stuckAnchorCommand = desired
            }
        } else {
            valvePosition += (desired - valvePosition) * min(1, 8 * dt)
        }
        wasStuck = stuck

        let baseDelay = 0.045
        let extraDelay = 0.18 * fault.severity(for: .pressureDeadTimeGrowth)
        let requestedSamples = max(1, Int(((baseDelay + extraDelay) / dt).rounded()))
        if delayLine.count != requestedSamples {
            if delayLine.count < requestedSamples {
                delayLine.insert(contentsOf: Array(repeating: delayLine.first ?? valvePosition, count: requestedSamples - delayLine.count), at: 0)
            } else {
                delayLine = Array(delayLine.suffix(requestedSamples))
            }
        }
        delayLine.append(valvePosition)
        let delayedValve = delayLine.removeFirst()

        let valveEffect = (delayedValve / 100) * 105
        let outflow = 16 + 42 * loadDemand
        let targetPressure = max(0, valveEffect - outflow + 38)
        let tau = 0.32 + 0.10 * loadDemand
        pressurePV += (targetPressure - pressurePV) * min(1, dt / tau)
        pressurePV = max(0, pressurePV)

        if stuck && abs(valveCommand - valvePosition) > max(0.5, breakaway * 0.45) {
            events.append(.init(timeSeconds: time, name: "Valve stuck", detail: "PID demand changed while stem position remained stationary."))
        }

        return .init(
            analog: [
                "PressureSP": pressureSP,
                "PressurePV": pressurePV,
                "ValveCmd": valveCommand,
                "ValvePosition": valvePosition,
                "AirSupplyPressure": airSupplyPressure,
                "LoadDemand": loadDemand,
                "PIDIntegral": integral,
                "BreakawayCount": Double(breakawayCount)
            ],
            discrete: ["ValveStuck": stuck],
            events: events
        )
    }
}


public struct ServoConveyorProcessModel: Equatable, Sendable {
    public private(set) var phase: Double = 0
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt = max(0.001, deltaTime), load = 0.2 + 0.8 * environment.load
        if runCommand { phase = (phase + dt * (0.35 + 0.9 * environment.speed)).truncatingRemainder(dividingBy: 1) }
        let positionCmd = 100 * (0.5 - 0.5 * cos(phase * 2 * .pi))
        let resonance = fault.severity(for: .servoBearingResonance) * load * sin(2 * .pi * (4 + 4 * environment.speed) * time)
        let positionFB = positionCmd + 1.8 * resonance
        let velocity = runCommand ? 35 * sin(phase * 2 * .pi) : 0
        let torque = runCommand ? 18 + 22 * load + 5 * abs(velocity / 35) + 8 * resonance : 0
        return .init(analog:["PositionCmd":positionCmd,"PositionFB":positionFB,"Velocity":velocity,"MotorTorque":torque,"LoadEstimate":100*load,"Vibration":abs(resonance)*10], discrete:[:], events: abs(resonance) > 0.7 ? [.init(timeSeconds: time, name:"Resonance excursion", detail:"Load/speed-dependent vibration mode is exciting position error.")] : [])
    }
}

public struct PumpStationProcessModel: Equatable, Sendable {
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let demand = 25 + 70 * environment.load
        let hz = runCommand ? 25 + 30 * environment.load : 0
        let severity = fault.severity(for: .pumpCavitation)
        let suction = 42 - 15 * environment.load - 16 * severity * environment.load
        let hydraulicNoise = severity * environment.load * (sin(2 * .pi*7.3*time) + 0.55*sin(2 * .pi*11.1*time) + 0.35*sin(2 * .pi*16.4*time))
        let flow = runCommand ? demand * (1 - 0.22 * severity * environment.load) + 3.2 * hydraulicNoise : 0
        let discharge = runCommand ? 35 + hz * 0.9 - 8 * severity * environment.load + hydraulicNoise : 0
        let current = runCommand ? 12 + 0.42 * hz + 7 * environment.load + abs(hydraulicNoise) * 2.3 : 0
        let events = severity > 0.55 && environment.load > 0.55 && abs(hydraulicNoise) > 0.5 ? [ProcessEvent(timeSeconds: time,name:"Cavitation burst",detail:"Low suction margin produced broadband hydraulic vibration and flow disturbance.")] : []
        return .init(analog:["FlowSP":demand,"FlowPV":flow,"PumpHz":hz,"MotorCurrent":current,"SuctionPressure":suction,"DischargePressure":discharge,"Vibration":abs(hydraulicNoise)*8],discrete:[:],events:events)
    }
}

public struct AirHandlingUnitProcessModel: Equatable, Sendable {
    private var sat: Double = 55
    private var staticPV: Double = 1.2
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), severity = fault.severity(for: .ahuLoopInteraction)
        let outdoor = 50 + 45 * environment.ambient
        let beat = severity * (sin(2 * .pi*0.11*time) + sin(2 * .pi*0.135*time))
        let fanCmd = runCommand ? 40 + 40 * environment.load + 7 * beat : 0
        let cooling = runCommand ? max(0,min(100,35 + 55*environment.load + 9*beat)) : 0
        let satTarget = 55 + 0.08*(outdoor-70) - 0.035*cooling + 1.4*beat
        sat += (satTarget-sat)*min(1,dt/1.8)
        let staticTarget = runCommand ? 0.5 + fanCmd/42 + 0.18*beat : 0
        staticPV += (staticTarget-staticPV)*min(1,dt/0.8)
        return .init(analog:["SAT_SP":55,"SAT_PV":sat,"StaticSP":1.8,"StaticPV":staticPV,"FanCmd":fanCmd,"CoolingValve":cooling,"OutdoorAirTemp":outdoor,"DamperPos":runCommand ? 20+35*environment.load:0],discrete:[:],events: severity>0.7 && abs(beat)>1.5 ? [.init(timeSeconds:time,name:"Loop beat envelope",detail:"Nearby pressure and temperature oscillatory components are producing a slow beat envelope.")] : [])
    }
}

public struct BatchMixingTankProcessModel: Equatable, Sendable {
    private var batchTime: Double = 0
    private var temp: Double = 68
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), severity = fault.severity(for: .batchAgitatorDrag)
        if runCommand { batchTime += dt * (1 - 0.28*severity) }
        let cycle = batchTime.truncatingRemainder(dividingBy: 120)
        let state: Double = cycle < 20 ? 10 : cycle < 45 ? 20 : cycle < 90 ? 30 : 40
        let level = state == 10 ? min(100,cycle*5) : state == 40 ? max(0,100-(cycle-90)*3.3) : 100
        let speed = runCommand && state == 30 ? 100*(1-0.16*severity) : 0
        let current = speed > 0 ? 24 + 18*environment.load + 28*severity : 0
        let steam = runCommand && (state == 20 || state == 30) ? 55.0 : 0.0
        let targetTemp = steam > 0 ? 158 - 10*severity : 70
        temp += (targetTemp-temp)*min(1,dt/(12+20*severity))
        return .init(analog:["TankTemp":temp,"Level":level,"AgitatorCurrent":current,"AgitatorSpeed":speed,"SteamValve":steam,"RecipeID":1.0,"BatchState":state],discrete:[:],events: severity>0.55 && state==30 && Int(time*10)%80==0 ? [.init(timeSeconds:time,name:"Mix phase stretching",detail:"Mechanical drag is reducing effective agitation and extending the healthy phase trajectory.")] : [])
    }
}

public struct IndustrialOvenProcessModel: Equatable, Sendable {
    private var zoneTemp: Double = 72
    private var productTemp: Double = 72
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), severity = fault.severity(for: .ovenBurnerDisturbance)
        let sp = 350.0, line = runCommand ? 35 + 45 * environment.speed : 0
        let disturbance = severity * sin(2 * .pi*0.83*time)
        let fanHz = runCommand ? 42 + 4 * disturbance : 0
        let airflow = runCommand ? 75 + 10 * disturbance : 0
        let gas = runCommand ? max(0,min(100,72 + (sp-zoneTemp)*0.12 + 7*disturbance)) : 0
        let target = runCommand ? 85 + 4.0*gas + 2.2*disturbance : 72
        zoneTemp += (target-zoneTemp)*min(1,dt/7.5)
        productTemp += (zoneTemp-productTemp)*min(1,dt/(14+8*environment.load))
        return .init(analog:["ZoneTempSP":sp,"ZoneTempPV":zoneTemp,"GasValve":gas,"Airflow":airflow,"FanHz":fanHz,"LineSpeed":line,"ProductTemp":productTemp],discrete:[:],events: severity>0.6 && abs(disturbance)>0.8 ? [.init(timeSeconds:time,name:"Periodic airflow disturbance",detail:"A repeating fan/burner disturbance is propagating into zone temperature.")] : [])
    }
}


public struct RoboticPalletizerProcessModel: Equatable, Sendable {
    private var cyclePhase: Double = 0
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime); if runCommand { cyclePhase=(cyclePhase+dt*(0.22+0.5*environment.speed)).truncatingRemainder(dividingBy:1) }
        let sev=fault.severity(for:.palletizerVacuumLoss), pickWindow=cyclePhase>0.20 && cyclePhase<0.42
        let vacuum = pickWindow ? max(5, 82 - 55*sev - 8*environment.load) : 4
        let gripOK = !pickWindow || vacuum > 42
        let robotPos = 100*(0.5-0.5*cos(2*Double.pi*cyclePhase))
        let events = pickWindow && !gripOK ? [ProcessEvent(timeSeconds:time,name:"Grip confirmation lost",detail:"Vacuum failed to reach the pick-confirmation threshold before motion continued.")] : []
        return .init(analog:["RobotPosition":robotPos,"VacuumPV":vacuum,"PayloadEstimate":100*environment.load,"CyclePhase":cyclePhase],discrete:["GripOK":gripOK,"RobotAtPick":pickWindow],events:events)
    }
}

public struct WastewaterLiftStationProcessModel: Equatable, Sendable {
    private var level: Double = 42
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), inflow=8+18*environment.load, sev=fault.severity(for:.liftStationCheckValveLeak)
        let pumpFlow = runCommand ? max(0,30-8*sev) : 0
        let backflow = (!runCommand ? 7*sev : 2*sev)
        level += (inflow - pumpFlow + backflow)*dt*0.12; level=max(0,min(100,level))
        let discharge = runCommand ? 28 - 10*sev + 2*sin(time) : 2*sev
        let events = !runCommand && sev>0.55 && backflow>3 ? [ProcessEvent(timeSeconds:time,name:"Backflow after stop",detail:"Wet-well level rises faster after pump stop, consistent with leaking check-valve flow reversal.")] : []
        return .init(analog:["WetWellLevel":level,"Inflow":inflow,"PumpFlow":pumpFlow,"DischargePressure":discharge,"BackflowEstimate":backflow],discrete:["HighLevel":level>82],events:events)
    }
}

public struct RefrigerationRackProcessModel: Equatable, Sendable {
    private var suction: Double = 28; private var condensing: Double = 96
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), sev=fault.severity(for:.refrigerationCondenserFouling), ambient=65+35*environment.ambient
        let headTarget = runCommand ? 105 + 0.55*(ambient-70)+42*sev+15*environment.load : 80
        condensing += (headTarget-condensing)*min(1,dt/2.5)
        let suctionTarget = runCommand ? 30-7*environment.load-5*sev : 42
        suction += (suctionTarget-suction)*min(1,dt/1.4)
        let fan = runCommand ? min(100,35+45*environment.load+35*sev) : 0
        let kw = runCommand ? 18+0.18*condensing+12*environment.load : 0
        return .init(analog:["SuctionPressure":suction,"CondensingPressure":condensing,"CondenserFanCmd":fan,"RackPowerKW":kw,"OutdoorTemp":ambient],discrete:["HighHeadAlarm":condensing>155],events:condensing>150 ? [.init(timeSeconds:time,name:"High head pressure",detail:"Condensing pressure is rising despite increasing condenser-fan command.")] : [])
    }
}

public struct BoilerSteamPlantProcessModel: Equatable, Sendable {
    private var steamPressure: Double = 85; private var oxygen: Double = 3.2
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), sev=fault.severity(for:.boilerFuelAirDrift), demand=0.35+0.55*environment.load
        let firing=runCommand ? 35+55*demand : 0, airCmd=runCommand ? firing*(1.05-0.22*sev) : 0
        let pressureTarget=runCommand ? 80+0.42*firing-18*demand-6*sev : 15
        steamPressure += (pressureTarget-steamPressure)*min(1,dt/4.5)
        oxygen += ((5.0-3.4*demand-3.1*sev)-oxygen)*min(1,dt/2.0)
        let co=max(0,8+180*sev*demand-25*oxygen)
        return .init(analog:["SteamPressure":steamPressure,"FiringRate":firing,"AirCmd":airCmd,"O2Percent":oxygen,"COppm":co,"SteamDemand":100*demand],discrete:["CombustionWarning":co>80],events:co>100 ? [.init(timeSeconds:time,name:"Combustion quality degraded",detail:"Fuel/air relationship is producing elevated CO while steam pressure may still appear acceptable.")] : [])
    }
}

public struct CNCCoolantCellProcessModel: Equatable, Sendable {
    private var pressure: Double = 0; private var temperature: Double = 72
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), sev=fault.severity(for:.cncCoolantRestriction)
        let pumpHz=runCommand ? 38+18*environment.load : 0, flow=runCommand ? max(0,24+0.35*pumpHz-22*sev) : 0
        let targetPressure=runCommand ? 32+0.5*pumpHz+34*sev : 0
        pressure += (targetPressure-pressure)*min(1,dt/0.8); temperature += ((72+18*environment.load+8*sev)-temperature)*min(1,dt/18)
        return .init(analog:["CoolantFlow":flow,"FilterDP":4+34*sev,"CoolantPressure":pressure,"PumpHz":pumpHz,"CoolantTemp":temperature],discrete:["LowFlow":runCommand && flow<24],events:runCommand && flow<24 ? [.init(timeSeconds:time,name:"Coolant flow low",detail:"Filter differential pressure is high while pump command remains normal.")] : [])
    }
}

public struct CleanroomPressureProcessModel: Equatable, Sendable {
    private var dp: Double = 0.05
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), sev=fault.severity(for:.cleanroomDoorLeak)
        let fan=runCommand ? 40+35*environment.load+30*sev : 0
        let doorLeak = sev*(0.5+0.5*sin(2*Double.pi*0.08*time))
        let target=runCommand ? 0.065+fan*0.0012-0.085*doorLeak : 0
        dp += (target-dp)*min(1,dt/1.5)
        return .init(analog:["RoomDP":dp,"DP_SP":0.12,"SupplyFanCmd":fan,"DoorLeakIndex":doorLeak,"AirChangeLoad":100*environment.load],discrete:["PressureLow":dp<0.08],events:dp<0.07 ? [.init(timeSeconds:time,name:"Pressure cascade lost",detail:"Room differential pressure drops when the leakage path opens despite rising fan command.")] : [])
    }
}

public struct ASRSCraneProcessModel: Equatable, Sendable {
    private var position: Double = 0; private var encoderBias: Double = 0
    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt=max(0.001,deltaTime), sev=fault.severity(for:.asrsEncoderSlip), target=runCommand ? 10+85*environment.load : 0
        let velocity=runCommand ? max(-30,min(30,(target-position)*1.6)) : 0; position += velocity*dt
        encoderBias += sev*dt*(0.08+0.12*environment.speed)
        let feedback=position+encoderBias; let error=target-feedback
        return .init(analog:["CranePositionCmd":target,"CranePositionFB":feedback,"PhysicalPosition":position,"CraneVelocity":velocity,"EncoderBias":encoderBias],discrete:["InPosition":abs(error)<0.8],events:abs(encoderBias)>2 ? [.init(timeSeconds:time,name:"Position disagreement",detail:"Encoder feedback is drifting away from physical travel, creating repeatable docking error.")] : [])
    }
}


public struct ExtendedIndustrialProcessModel: Equatable, Sendable {
    public let kind: PlayableMachineKind
    private var state: Double = 0
    private var secondary: Double = 0
    public init(kind: PlayableMachineKind) { self.kind = kind }
    public mutating func reset() { state = 0; secondary = 0 }

    public mutating func step(deltaTime: Double, runCommand: Bool, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        let dt = max(0.001, deltaTime)
        let load = 0.15 + 0.85 * environment.load
        let speed = 0.20 + 0.80 * environment.speed
        func sev(_ k: PlayableFaultKind) -> Double { fault.severity(for: k) }
        var a:[String:Double]=[:], d:[String:Bool]=[:], e:[ProcessEvent]=[]
        switch kind {
        case .bottlingLine:
            let f=sev(.bottlingFillValveDrift); let target=500.0
            let fill = runCommand ? target * (1 - 0.13*f) + 10*sin(time*0.7)*f : 0
            let rejects=max(0, abs(fill-target)-18) * 0.08
            a=["FillSetpointML":target,"FillVolumeML":fill,"FillerSpeedBPM":runCommand ? 120*speed:0,"RejectRate":rejects,"ValveCommand":runCommand ? 62+20*load:0]
            d=["FillLow":runCommand && fill<475]
            if f>0.6 && d["FillLow"]! { e.append(.init(timeSeconds:time,name:"Underfill excursion",detail:"Filler valve response no longer delivers target volume at production speed.")) }
        case .cipSkid:
            let f=sev(.cipConductivityDrift); state += runCommand ? dt : -min(state,dt)
            let trueCond=runCommand ? 7.5+3.0*load : 0.6
            let measured=trueCond*(1-0.28*f)+0.25*f*sin(time*0.4)
            a=["ConductivityPV":measured,"TrueConductivity":trueCond,"ReturnTemp":runCommand ? 145+12*environment.ambient:70,"FlowPV":runCommand ? 85*speed:0,"ChemicalValve":runCommand ? 45+25*load:0]
            d=["ConcentrationOK":measured>6.5]
            if f>0.65 && abs(trueCond-measured)>1.5 { e.append(.init(timeSeconds:time,name:"CIP concentration disagreement",detail:"Conductivity indication is drifting away from actual solution strength.")) }
        case .compressedAirPlant:
            let f=sev(.compressedAirLeakGrowth); let leak=8+35*f
            let demand=25+50*load+leak; let compressor=runCommand ? min(100,demand*1.05):0
            state += (runCommand ? (110 - demand*0.55) : -demand*0.35 - state*0.05) * dt
            state=max(60,min(125,state==0 ? 105:state))
            a=["HeaderPressure":state,"CompressorLoad":compressor,"EstimatedLeakCFM":leak,"PlantDemandCFM":demand-leak,"PowerKW":compressor*0.75]
            d=["LowPressure":state<90]
            if f>0.6 && compressor>85 { e.append(.init(timeSeconds:time,name:"Compressor duty high",detail:"Growing air leakage is consuming reserve capacity and increasing compressor duty.")) }
        case .reverseOsmosisPlant:
            let f=sev(.roMembraneFouling); let feed=runCommand ? 145+25*load:0
            let dp=runCommand ? 18+28*f+5*load:0; let permeate=runCommand ? max(0,110*(1-0.38*f)*(0.85+0.15*speed)):0
            let cond=runCommand ? 12+35*f:0
            a=["FeedPressure":feed,"MembraneDP":dp,"PermeateFlow":permeate,"PermeateConductivity":cond,"RecoveryPercent":runCommand ? permeate/max(1,145*0.9)*100:0]
            d=["QualityAlarm":cond>30]
            if f>0.6 { e.append(.init(timeSeconds:time,name:"RO performance degraded",detail:"Membrane differential pressure is rising while permeate flow and quality deteriorate.")) }
        case .dataCenterCooling:
            let f=sev(.dataCenterValveStiction); let demand=45+45*load
            let cmd=runCommand ? demand:0; let breakaway=6*f
            if abs(cmd-state)>breakaway { state += (cmd-state)*min(1,6*dt) }
            let sat=72 - state*0.18 + 7*load
            a=["SupplyAirTemp":sat,"CoolingValveCmd":cmd,"CoolingValvePos":state,"RackLoadPercent":100*load,"FanCmd":runCommand ? 45+40*load:0]
            d=["ThermalMarginLow":sat>78]
            if f>0.6 && abs(cmd-state)>3 { e.append(.init(timeSeconds:time,name:"Cooling valve stick",detail:"Cooling command changes while valve position remains trapped until breakaway.")) }
        case .parcelSortation:
            let f=sev(.parcelDiverterTimingDrift); state=(state+dt*speed).truncatingRemainder(dividingBy:1)
            let timingError=f*0.22*speed + 0.01*sin(time*2)
            let miss=runCommand && timingError>0.12 && state>0.45 && state<0.50
            a=["BeltSpeed":runCommand ? 420*speed:0,"DiverterTimingErrorMS":timingError*1000,"ParcelPosition":state,"SortRatePPM":runCommand ? 180*speed:0]
            d=["Misroute":miss,"DiverterReady":runCommand]
            if miss { e.append(.init(timeSeconds:time,name:"Parcel misroute",detail:"Diverter actuation drifted outside the timing window at high belt speed.")) }
        case .automotivePaintBooth:
            let f=sev(.paintBoothFilterLoading); let dp=runCommand ? 0.45+1.6*f+0.35*load:0
            let fan=runCommand ? 48+42*f+18*load:0; let velocity=runCommand ? max(20,105-32*f+10*speed):0
            a=["BoothDP":dp,"ExhaustFanCmd":fan,"AirVelocityFPM":velocity,"FilterDP":dp*0.9,"VOCIndex":runCommand ? 20+18*load:0]
            d=["AirflowLow":velocity<82]
            if f>0.65 { e.append(.init(timeSeconds:time,name:"Paint booth airflow degraded",detail:"Filter loading is increasing pressure drop and reducing booth air velocity.")) }
        case .injectionMoldingCell:
            let f=sev(.moldingHeaterFailure); state += ((runCommand ? 430:80)-state)*min(1,dt/8)
            let zone2=state-95*f; let cycle=runCommand ? 28+10*f:0
            a=["BarrelZone1Temp":state,"BarrelZone2Temp":zone2,"MoldPressure":runCommand ? 1200*(1-0.08*f):0,"CycleTimeSec":cycle,"Heater2Output":runCommand ? min(100,55+45*f):0]
            d=["Zone2TempLow":runCommand && zone2<350]
            if f>0.55 && d["Zone2TempLow"]! { e.append(.init(timeSeconds:time,name:"Heater zone recovery lost",detail:"One barrel zone cannot maintain temperature despite high heater command.")) }
        case .crusherConveyor:
            let f=sev(.crusherBeltSlip); let commanded=runCommand ? 100*speed:0; let actual=commanded*(1-0.22*f*load)
            let current=runCommand ? 35+55*load+28*f*load:0
            a=["BeltSpeedCmd":commanded,"BeltSpeedFB":actual,"CrusherCurrent":current,"OreLoad":100*load,"SlipPercent":commanded>0 ? (commanded-actual)/commanded*100:0]
            d=["BeltSlipAlarm":commanded>0 && actual<commanded*0.9]
            if d["BeltSlipAlarm"]! { e.append(.init(timeSeconds:time,name:"Conveyor slip",detail:"Drive speed and belt feedback disagree increasingly under ore load.")) }
        case .grainElevator:
            let f=sev(.grainBearingDrag); let temp=95+55*f+18*load; let current=runCommand ? 18+20*load+15*f:0
            a=["BucketSpeed":runCommand ? 100*speed*(1-0.05*f):0,"HeadBearingTemp":temp,"ElevatorCurrent":current,"GrainRateTPH":runCommand ? 70*load:0,"Vibration":f*(2+5*load)]
            d=["BearingTempHigh":temp>135]
            if f>0.65 { e.append(.init(timeSeconds:time,name:"Elevator bearing degradation",detail:"Head bearing temperature, current, and vibration are rising together under load.")) }
        case .htstPasteurizer:
            let f=sev(.pasteurizerDivertLeak); let temp=runCommand ? 163+3*sin(time*0.12):70
            let leak=f*max(0,165-temp)*0.1 + 8*f
            a=["HoldingTemp":temp,"FlowRate":runCommand ? 52*speed:0,"DivertValveCmd":temp<161 ? 100:0,"LeakageEstimate":leak,"ProductOutletTemp":temp-3-5*f]
            d=["ForwardFlowPermissive":temp>=161,"DivertLeakSuspected":f>0.6]
            if f>0.65 { e.append(.init(timeSeconds:time,name:"Divert isolation degraded",detail:"Valve leakage allows measurable cross-flow despite the commanded divert state.")) }
        case .bioreactor:
            let f=sev(.bioreactorOxygenTransferLoss); let demand=0.35+0.55*load
            let air=runCommand ? min(100,45+55*f+25*demand):0; let agitation=runCommand ? min(100,50+35*f+20*demand):0
            let doPV=runCommand ? max(5,55-32*f*demand+0.08*(air-50)):0
            a=["DissolvedOxygen":doPV,"AirFlowCmd":air,"AgitatorCmd":agitation,"BrothTemp":runCommand ? 98+2*environment.ambient:75,"OURIndex":100*demand]
            d=["DOLow":runCommand && doPV<30]
            if f>0.6 { e.append(.init(timeSeconds:time,name:"Oxygen transfer degraded",detail:"Air and agitation demand rise while dissolved oxygen margin continues to fall.")) }
        case .chilledWaterPlant:
            let f=sev(.chilledWaterDPBias); let trueDP=runCommand ? 12+6*load:0; let measured=trueDP+8*f
            let pump=runCommand ? min(100,40+3*measured+20*load):0
            a=["CHW_DP_PV":measured,"TrueCHW_DP":trueDP,"PumpCmd":pump,"CHW_SupplyTemp":runCommand ? 44+2*load:65,"PlantKW":pump*1.4]
            d=["DPSensorDisagree":abs(measured-trueDP)>4]
            if f>0.6 { e.append(.init(timeSeconds:time,name:"Chilled-water DP bias",detail:"Biased differential-pressure feedback is driving excess pump command and plant energy.")) }
        case .batteryFormationLine:
            let f=sev(.batteryContactResistance); let current=runCommand ? 120*load:0; let resistance=2+14*f
            let drop=current*resistance/1000; let temp=78+drop*18+10*environment.ambient
            a=["FormationCurrentA":current,"CellVoltageV":runCommand ? 3.7-drop:0,"ContactResistanceMilliOhm":resistance,"FixtureTempF":temp,"CycleProgress":runCommand ? (time*speed).truncatingRemainder(dividingBy:100):0]
            d=["ContactTempHigh":temp>105]
            if f>0.6 && runCommand { e.append(.init(timeSeconds:time,name:"Formation contact heating",detail:"Rising fixture contact resistance causes voltage loss and localized heating under formation current.")) }
        default:
            a=["ProcessValue":runCommand ? 50*load:0]
        }
        return .init(analog:a, discrete:d, events:e)
    }
}

public enum HeroProcessModel: Equatable, Sendable {
    case packaging(PackagingCellProcessModel)
    case pressure(PressureSkidProcessModel)
    case servo(ServoConveyorProcessModel)
    case pump(PumpStationProcessModel)
    case ahu(AirHandlingUnitProcessModel)
    case batch(BatchMixingTankProcessModel)
    case oven(IndustrialOvenProcessModel)
    case palletizer(RoboticPalletizerProcessModel)
    case liftStation(WastewaterLiftStationProcessModel)
    case refrigeration(RefrigerationRackProcessModel)
    case boiler(BoilerSteamPlantProcessModel)
    case cnc(CNCCoolantCellProcessModel)
    case cleanroom(CleanroomPressureProcessModel)
    case asrs(ASRSCraneProcessModel)
    case extended(ExtendedIndustrialProcessModel)

    public var kind: PlayableMachineKind {
        switch self {
        case .packaging: .packagingCell
        case .pressure: .pressureSkid
        case .servo: .servoConveyor
        case .pump: .pumpStation
        case .ahu: .airHandlingUnit
        case .batch: .batchMixingTank
        case .oven: .industrialOven
        case .palletizer: .roboticPalletizer
        case .liftStation: .wastewaterLiftStation
        case .refrigeration: .refrigerationRack
        case .boiler: .boilerSteamPlant
        case .cnc: .cncCoolantCell
        case .cleanroom: .cleanroomPressureSystem
        case .asrs: .asrsCrane
        case .extended(let model): model.kind
        }
    }

    public mutating func reset() {
        switch self {
        case .packaging(var model): model.reset(); self = .packaging(model)
        case .pressure(var model): model.reset(); self = .pressure(model)
        case .servo(var model): model.reset(); self = .servo(model)
        case .pump(var model): model.reset(); self = .pump(model)
        case .ahu(var model): model.reset(); self = .ahu(model)
        case .batch(var model): model.reset(); self = .batch(model)
        case .oven(var model): model.reset(); self = .oven(model)
        case .palletizer(var model): model.reset(); self = .palletizer(model)
        case .liftStation(var model): model.reset(); self = .liftStation(model)
        case .refrigeration(var model): model.reset(); self = .refrigeration(model)
        case .boiler(var model): model.reset(); self = .boiler(model)
        case .cnc(var model): model.reset(); self = .cnc(model)
        case .cleanroom(var model): model.reset(); self = .cleanroom(model)
        case .asrs(var model): model.reset(); self = .asrs(model)
        case .extended(var model): model.reset(); self = .extended(model)
        }
    }

    public mutating func step(deltaTime: Double, controller: ControllerRuntime, environment: ScenarioEnvironment, fault: ScenarioFaultInjection, time: Double) -> ScenarioProcessSnapshot {
        switch self {
        case .packaging(var model):
            let run = (try? controller.project.controllerTags.bool("Motor_Run")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, motorRun: run, environment: environment, fault: fault, time: time)
            self = .packaging(model)
            return snapshot
        case .pressure(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time)
            self = .pressure(model); return snapshot
        case .servo(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time)
            self = .servo(model); return snapshot
        case .pump(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time)
            self = .pump(model); return snapshot
        case .ahu(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time)
            self = .ahu(model); return snapshot
        case .batch(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time)
            self = .batch(model); return snapshot
        case .oven(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time)
            self = .oven(model); return snapshot
        case .palletizer(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .palletizer(model); return snapshot
        case .liftStation(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .liftStation(model); return snapshot
        case .refrigeration(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .refrigeration(model); return snapshot
        case .boiler(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .boiler(model); return snapshot
        case .cnc(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .cnc(model); return snapshot
        case .cleanroom(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .cleanroom(model); return snapshot
        case .asrs(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .asrs(model); return snapshot
        case .extended(var model):
            let run = (try? controller.project.controllerTags.bool("RunCmd")) ?? false
            let snapshot = model.step(deltaTime: deltaTime, runCommand: run, environment: environment, fault: fault, time: time); self = .extended(model); return snapshot
        }
    }
}

public struct ScenarioIOBridge: Sendable {
    public init() {}

    public func applyProcessInputs(_ snapshot: ScenarioProcessSnapshot, to controller: inout ControllerRuntime) throws {
        for (name, value) in snapshot.discrete where controller.project.controllerTags.contains(name) {
            if (try? controller.project.controllerTags.dataType(for: name)) == .bool {
                try controller.setControllerTagValue(name, to: .bool(value))
            }
        }
        for (name, value) in snapshot.analog where controller.project.controllerTags.contains(name) {
            if let type = try? controller.project.controllerTags.dataType(for: name), type == .real {
                try controller.setControllerTagValue(name, to: .real(value))
            }
        }
    }
}

public struct PlayableScenarioRuntime: Sendable {
    public private(set) var controller: ControllerRuntime
    public private(set) var process: HeroProcessModel
    public private(set) var clock = SimulationClock()
    public private(set) var snapshot = ScenarioProcessSnapshot()
    public private(set) var eventHistory: [ProcessEvent] = []
    public var environment: ScenarioEnvironment
    public var fault: ScenarioFaultInjection
    public var sensorNoiseFraction: Double = 0
    public var noiseSeed: UInt64 = 0
    private let bridge = ScenarioIOBridge()

    public init(project: ControllerProject, process: HeroProcessModel, environment: ScenarioEnvironment = .init(), fault: ScenarioFaultInjection = .init()) throws {
        self.controller = ControllerRuntime(project: project)
        self.process = process
        self.environment = environment
        self.fault = fault
        try self.controller.setMode(.run)
    }

    public mutating func reset() throws {
        let project = controller.project
        controller = ControllerRuntime(project: project)
        try controller.setMode(.run)
        process.reset()
        clock = .init()
        snapshot = .init()
        eventHistory.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func step(milliseconds: Int32 = 10) throws -> ControllerScanTrace {
        let dt = Double(max(1, milliseconds)) / 1000.0
        // Process evolves from the outputs of the previous PLC execution.
        snapshot = process.step(deltaTime: dt, controller: controller, environment: environment, fault: fault, time: clock.elapsedSeconds)
        if sensorNoiseFraction > 0 { snapshot = applyingSensorNoise(to: snapshot) }
        try bridge.applyProcessInputs(snapshot, to: &controller)
        let trace = try controller.scan(elapsedMilliseconds: milliseconds)
        // Analog outputs generated by educational process controllers are mirrored into the PLC data table for the microscope.
        try bridge.applyProcessInputs(snapshot, to: &controller)
        eventHistory.append(contentsOf: snapshot.events)
        if eventHistory.count > 2_000 { eventHistory.removeFirst(eventHistory.count - 2_000) }
        clock.advance(by: dt)
        return trace
    }

    public mutating func setControllerTagValue(_ name: String, value: TagValue) throws {
        try controller.setControllerTagValue(name, to: value)
    }

    public mutating func setFault(_ newFault: ScenarioFaultInjection) { fault = newFault }

    public mutating func configureSensorNoise(fraction: Double, seed: UInt64) {
        sensorNoiseFraction = min(0.2, max(0, fraction))
        noiseSeed = seed
    }

    private func applyingSensorNoise(to input: ScenarioProcessSnapshot) -> ScenarioProcessSnapshot {
        var output = input
        for (name, value) in input.analog {
            guard isNoiseEligibleSignal(name) else { continue }
            var nameCode: UInt64 = 1469598103934665603
            for byte in name.utf8 { nameCode = (nameCode ^ UInt64(byte)) &* 1099511628211 }
            var x = noiseSeed ^ nameCode ^ (clock.tick &* 0x9E3779B97F4A7C15)
            x ^= x >> 30; x &*= 0xBF58476D1CE4E5B9
            x ^= x >> 27; x &*= 0x94D049BB133111EB
            x ^= x >> 31
            let unit = Double(x >> 11) / Double(1 << 53)
            let signed = unit * 2 - 1
            output.analog[name] = value + signed * max(abs(value), 1) * sensorNoiseFraction
        }
        return output
    }

    private func isNoiseEligibleSignal(_ name: String) -> Bool {
        let excludedTokens = ["SP", "Cmd", "Command", "Integral", "RecipeID", "BatchState", "ProductCountPhysical", "LoadDemand", "LoadEstimate"]
        return !excludedTokens.contains(where: { name.localizedCaseInsensitiveContains($0) })
    }

    public mutating func startMachine() throws {
        switch process.kind {
        case .packagingCell: try controller.setControllerTagValue("Start_PB", to: .bool(true))
        default: try controller.setControllerTagValue("AutoMode", to: .bool(true))
        }
    }

    public mutating func stopMachine() throws {
        switch process.kind {
        case .packagingCell: try controller.setControllerTagValue("Start_PB", to: .bool(false))
        default: try controller.setControllerTagValue("AutoMode", to: .bool(false))
        }
    }

    public mutating func setControllerTagValue(_ name: String, to value: TagValue) throws {
        try controller.setControllerTagValue(name, to: value)
    }

    public func controllerContainsTag(_ name: String) -> Bool {
        controller.project.controllerTags.contains(name)
    }

    public mutating func run(for seconds: Double, stepMilliseconds: Int32 = 10) throws {
        let count = max(0, Int((seconds * 1000 / Double(max(1, stepMilliseconds))).rounded()))
        for _ in 0..<count { _ = try step(milliseconds: stepMilliseconds) }
    }
}

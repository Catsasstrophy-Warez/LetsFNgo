import Foundation
import ControlsPLC

public enum PlantCampaignRole: String, Codable, CaseIterable, Sendable { case technician, instructor }
public enum PlantShift: String, Codable, CaseIterable, Sendable { case day = "Day", evening = "Evening", night = "Night" }
public enum PlantFaultKind: String, Codable, CaseIterable, Sendable {
    case degradingBearing
    case looseTerminal
    case driftingTransmitter
    case dirtyPhotoeye
    case networkIntermittency
    case vfdDegradation
    case remoteIOConnectionLoss
    case analogModuleDrift
    case safetyChannelDiscrepancy
    case ethernetPacketLoss
    case servoFeedbackLoss
    case pneumaticLeak
    case valveStiction
    case pumpCavitation
    case heaterOpenCircuit
    case pidSensorBias
    case encoderSlip
    case contactorFailure
    case motorOverload
}
public enum PlantFaultCondition: String, Codable, CaseIterable, Sendable { case latent, intermittent, degraded, severe, critical, repaired, regression }

public struct ProgressivePlantFault: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: PlantFaultKind
    public var target: String
    public var onsetHour: Double
    public var initialSeverity: Double
    public var growthPerHour: Double
    public var repairedAtHour: Double?
    public var regressionAtHour: Double?
    public var hiddenFromTechnician: Bool

    public init(id: String, kind: PlantFaultKind, target: String, onsetHour: Double, initialSeverity: Double = 0.05, growthPerHour: Double = 0.02, repairedAtHour: Double? = nil, regressionAtHour: Double? = nil, hiddenFromTechnician: Bool = true) {
        self.id = id; self.kind = kind; self.target = target; self.onsetHour = max(0, onsetHour)
        self.initialSeverity = min(1, max(0, initialSeverity)); self.growthPerHour = max(0, growthPerHour)
        self.repairedAtHour = repairedAtHour; self.regressionAtHour = regressionAtHour; self.hiddenFromTechnician = hiddenFromTechnician
    }

    public func severity(at hour: Double) -> Double {
        if let repairedAtHour, hour >= repairedAtHour {
            if let regressionAtHour, hour >= regressionAtHour {
                return min(1, 0.18 + max(0, hour - regressionAtHour) * max(0.01, growthPerHour * 0.65))
            }
            return 0
        }
        guard hour >= onsetHour else { return 0 }
        return min(1, initialSeverity + (hour - onsetHour) * growthPerHour)
    }

    public func condition(at hour: Double) -> PlantFaultCondition {
        if let repairedAtHour, hour >= repairedAtHour {
            if let regressionAtHour, hour >= regressionAtHour { return .regression }
            return .repaired
        }
        let s = severity(at: hour)
        if s <= 0 { return .latent }
        if s < 0.20 { return .intermittent }
        if s < 0.50 { return .degraded }
        if s < 0.75 { return .severe }
        return .critical
    }
}

public struct PlantElectricalSnapshot: Codable, Equatable, Sendable {
    public var controlVoltage: Double = 24
    public var sensorSupplyVoltage: Double = 24
    public var terminalVoltage: Double = 24
    public var plcInputVoltage: Double = 24
    public var networkHealthy: Bool = true
    public var networkStale: Bool = false
    public init() {}
}

public struct PlantDriveSnapshot: Codable, Equatable, Sendable {
    public var commandRun: Bool = false
    public var actualRun: Bool = false
    public var frequencyHz: Double = 0
    public var currentA: Double = 0
    public var torquePercent: Double = 0
    public var temperatureC: Double = 34
    public var faulted: Bool = false
    public init() {}
}

public enum PlantAlarmSeverity: String, Codable, CaseIterable, Sendable { case info, warning, alarm, trip }
public struct PlantAlarmEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var timeSeconds: Double
    public var tag: String
    public var message: String
    public var severity: PlantAlarmSeverity
    public var active: Bool
    public init(id: String = UUID().uuidString, timeSeconds: Double, tag: String, message: String, severity: PlantAlarmSeverity, active: Bool = true) { self.id=id;self.timeSeconds=timeSeconds;self.tag=tag;self.message=message;self.severity=severity;self.active=active }
}

public struct PlantHistorianSample: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var timeSeconds: Double
    public var values: [String: Double]
    public var states: [String: Bool]
    public init(id: String = UUID().uuidString, timeSeconds: Double, values: [String:Double], states:[String:Bool]) { self.id=id;self.timeSeconds=timeSeconds;self.values=values;self.states=states }
}

public struct PlantFlightRecorderRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var timeSeconds: Double
    public var trigger: String
    public var detail: String
    public var values: [String: Double]
    public init(id: String = UUID().uuidString, timeSeconds:Double, trigger:String, detail:String, values:[String:Double]=[:]) { self.id=id;self.timeSeconds=timeSeconds;self.trigger=trigger;self.detail=detail;self.values=values }
}

public struct PlantProductionSnapshot: Codable, Equatable, Sendable {
    public var demandUnitsPerHour: Double = 100
    public var actualUnitsPerHour: Double = 0
    public var cumulativeUnits: Double = 0
    public var lostUnits: Double = 0
    public var cycleTimeSeconds: Double = 0
    public var availabilityPercent: Double = 100
    public init() {}
}

public struct IntegratedPlantSnapshot: Codable, Equatable, Sendable {
    public var timeSeconds: Double
    public var physicalAnalog: [String: Double]
    public var plcObservedAnalog: [String: Double]
    public var physicalDiscrete: [String: Bool]
    public var plcObservedDiscrete: [String: Bool]
    public var electrical: PlantElectricalSnapshot
    public var drive: PlantDriveSnapshot
    public var production: PlantProductionSnapshot
    public var activeAlarms: [PlantAlarmEvent]
    public var activeFaultConditions: [String: PlantFaultCondition]
}

public struct PlantProductionDemand: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var day: Int
    public var shift: PlantShift
    public var targetUnits: Double
    public var maximumDowntimeMinutes: Double
    public init(id:String=UUID().uuidString, day:Int, shift:PlantShift, targetUnits:Double, maximumDowntimeMinutes:Double) { self.id=id;self.day=max(1,day);self.shift=shift;self.targetUnits=max(0,targetUnits);self.maximumDowntimeMinutes=max(0,maximumDowntimeMinutes) }
}

public struct PlantSparePart: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var partNumber: String
    public var description: String
    public var quantityOnHand: Int
    public var leadTimeHours: Double
    public init(id:String=UUID().uuidString, partNumber:String, description:String, quantityOnHand:Int, leadTimeHours:Double) { self.id=id;self.partNumber=partNumber;self.description=description;self.quantityOnHand=max(0,quantityOnHand);self.leadTimeHours=max(0,leadTimeHours) }
}

public enum WorkOrderStatus: String, Codable, CaseIterable, Sendable { case open, inProgress, repaired, retestRequired, closed }
public struct PlantMaintenanceWorkOrder: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var faultID: String
    public var title: String
    public var openedHour: Double
    public var status: WorkOrderStatus
    public var downtimeMinutes: Double
    public var partsUsed: [String:Int]
    public var repairNotes: String
    public var retestPassed: Bool
    public init(id:String=UUID().uuidString, faultID:String, title:String, openedHour:Double, status:WorkOrderStatus = .open, downtimeMinutes:Double=0, partsUsed:[String:Int]=[:], repairNotes:String="", retestPassed:Bool=false) { self.id=id;self.faultID=faultID;self.title=title;self.openedHour=openedHour;self.status=status;self.downtimeMinutes=downtimeMinutes;self.partsUsed=partsUsed;self.repairNotes=repairNotes;self.retestPassed=retestPassed }
}

public struct PlantCrewHandoff: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var day:Int
    public var fromShift:PlantShift
    public var toShift:PlantShift
    public var sourceNotes:[String]
    public var receivedNotes:[String]
    public var fidelityPercent:Double
    public init(id:String=UUID().uuidString,day:Int,fromShift:PlantShift,toShift:PlantShift,sourceNotes:[String],receivedNotes:[String],fidelityPercent:Double){self.id=id;self.day=day;self.fromShift=fromShift;self.toShift=toShift;self.sourceNotes=sourceNotes;self.receivedNotes=receivedNotes;self.fidelityPercent=min(100,max(0,fidelityPercent))}
}

public struct PlantVendorRequest: Identifiable, Codable, Equatable, Sendable {
    public let id:String
    public var vendor:String
    public var specialty:String
    public var requestedHour:Double
    public var responseDelayHours:Double
    public var costCredits:Int
    public var advice:String
    public init(id:String=UUID().uuidString,vendor:String,specialty:String,requestedHour:Double,responseDelayHours:Double,costCredits:Int,advice:String){self.id=id;self.vendor=vendor;self.specialty=specialty;self.requestedHour=requestedHour;self.responseDelayHours=max(0,responseDelayHours);self.costCredits=max(0,costCredits);self.advice=advice}
}

public struct PlantAcceptanceScore: Codable, Equatable, Sendable {
    public var production:Int; public var faultClosure:Int; public var retest:Int; public var downtime:Int; public var evidence:Int; public var handoff:Int; public var regression:Int
    public var overall:Int { (production + faultClosure + retest + downtime + evidence + handoff + regression) / 7 }
    public var accepted:Bool { overall >= 80 && faultClosure >= 90 && retest >= 85 && regression >= 90 }
}

public struct PersistentPlantCampaign: Codable, Equatable, Sendable {
    public var title:String
    public var role:PlantCampaignRole
    public var totalDays:Int
    public var currentDay:Int
    public var currentShift:PlantShift
    public var elapsedCampaignHours:Double
    public var faults:[ProgressivePlantFault]
    public var demands:[PlantProductionDemand]
    public var spares:[PlantSparePart]
    public var workOrders:[PlantMaintenanceWorkOrder]
    public var handoffs:[PlantCrewHandoff]
    public var vendorRequests:[PlantVendorRequest]
    public var historian:[PlantHistorianSample]
    public var flightRecorder:[PlantFlightRecorderRecord]
    public var alarms:[PlantAlarmEvent]
    public var cumulativeProduced:Double
    public var cumulativeLost:Double
    public var downtimeMinutes:Double

    public init(title:String="Seven-Day Plant Acceptance Campaign",role:PlantCampaignRole = .technician,totalDays:Int=7,currentDay:Int=1,currentShift:PlantShift = .day,elapsedCampaignHours:Double=0,faults:[ProgressivePlantFault]=[],demands:[PlantProductionDemand]=[],spares:[PlantSparePart]=[],workOrders:[PlantMaintenanceWorkOrder]=[],handoffs:[PlantCrewHandoff]=[],vendorRequests:[PlantVendorRequest]=[],historian:[PlantHistorianSample]=[],flightRecorder:[PlantFlightRecorderRecord]=[],alarms:[PlantAlarmEvent]=[],cumulativeProduced:Double=0,cumulativeLost:Double=0,downtimeMinutes:Double=0) {
        self.title=title;self.role=role;self.totalDays=max(1,totalDays);self.currentDay=max(1,currentDay);self.currentShift=currentShift;self.elapsedCampaignHours=max(0,elapsedCampaignHours);self.faults=faults;self.demands=demands;self.spares=spares;self.workOrders=workOrders;self.handoffs=handoffs;self.vendorRequests=vendorRequests;self.historian=historian;self.flightRecorder=flightRecorder;self.alarms=alarms;self.cumulativeProduced=cumulativeProduced;self.cumulativeLost=cumulativeLost;self.downtimeMinutes=downtimeMinutes
    }

    public var currentDemand:PlantProductionDemand? { demands.first{$0.day==currentDay && $0.shift==currentShift} }
    public mutating func advanceShift(handoffNotes:[String], fidelityPercent:Double=100) {
        let from=currentShift
        let to:PlantShift
        switch currentShift { case .day: to = .evening; case .evening: to = .night; case .night: to = .day }
        let keptCount = min(handoffNotes.count, Int((Double(handoffNotes.count) * min(1,max(0,fidelityPercent/100))).rounded(.down)))
        handoffs.append(.init(day:currentDay,fromShift:from,toShift:to,sourceNotes:handoffNotes,receivedNotes:Array(handoffNotes.prefix(keptCount)),fidelityPercent:fidelityPercent))
        currentShift=to; elapsedCampaignHours += 8
        if from == .night { currentDay=min(totalDays,currentDay+1) }
    }

    public mutating func consumeSpare(partNumber:String, quantity:Int=1) -> Bool {
        guard quantity>0, let i=spares.firstIndex(where:{$0.partNumber==partNumber}), spares[i].quantityOnHand>=quantity else{return false}
        spares[i].quantityOnHand -= quantity; return true
    }

    @discardableResult public mutating func requestVendor(vendor:String,specialty:String,responseDelayHours:Double,costCredits:Int,advice:String)->String {
        let request=PlantVendorRequest(vendor:vendor,specialty:specialty,requestedHour:elapsedCampaignHours,responseDelayHours:responseDelayHours,costCredits:costCredits,advice:advice)
        vendorRequests.append(request); return request.id
    }

    public mutating func openWorkOrder(for fault:ProgressivePlantFault) -> String {
        if let existing=workOrders.first(where:{$0.faultID==fault.id && $0.status != .closed}) { return existing.id }
        let wo=PlantMaintenanceWorkOrder(faultID:fault.id,title:"Investigate \(fault.kind.rawValue) at \(fault.target)",openedHour:elapsedCampaignHours)
        workOrders.append(wo); return wo.id
    }

    public mutating func repair(workOrderID:String, parts:[String:Int]=[:], downtimeMinutes:Double, notes:String, regressionAfterHours:Double?=nil) -> Bool {
        guard let wi=workOrders.firstIndex(where:{$0.id==workOrderID}), let fi=faults.firstIndex(where:{$0.id==workOrders[wi].faultID}) else{return false}
        for (part,qty) in parts { guard consumeSpare(partNumber:part,quantity:qty) else{return false} }
        self.downtimeMinutes += max(0,downtimeMinutes)
        workOrders[wi].downtimeMinutes += max(0,downtimeMinutes); workOrders[wi].partsUsed=parts; workOrders[wi].repairNotes=notes; workOrders[wi].status = .retestRequired
        faults[fi].repairedAtHour = elapsedCampaignHours
        if let regressionAfterHours { faults[fi].regressionAtHour = elapsedCampaignHours + max(0,regressionAfterHours) }
        return true
    }

    public mutating func recordRetest(workOrderID:String, passed:Bool) {
        guard let i=workOrders.firstIndex(where:{$0.id==workOrderID}) else{return}
        workOrders[i].retestPassed=passed; workOrders[i].status = passed ? .closed : .inProgress
    }

    public func acceptanceScore() -> PlantAcceptanceScore {
        let target=demands.map(\.targetUnits).reduce(0,+), actual=cumulativeProduced
        let production = target <= 0 ? 100 : Int(min(100,actual/target*100).rounded())
        let critical = faults.filter{$0.severity(at:elapsedCampaignHours)>=0.75}
        let faultClosure = critical.isEmpty ? 100 : Int(Double(critical.filter{$0.condition(at:elapsedCampaignHours) == .repaired}.count)/Double(critical.count)*100)
        let needingRetest=workOrders.filter{$0.status == .retestRequired || $0.status == .closed}
        let retest = needingRetest.isEmpty ? 100 : Int(Double(needingRetest.filter{$0.retestPassed}.count)/Double(needingRetest.count)*100)
        let allowed=demands.map(\.maximumDowntimeMinutes).reduce(0,+); let downtime = allowed<=0 ? (downtimeMinutes==0 ? 100:0) : Int(max(0,100-downtimeMinutes/allowed*100).rounded())
        let evidence = historian.isEmpty || flightRecorder.isEmpty ? 50 : 100
        let handoff = handoffs.isEmpty ? 100 : Int(handoffs.map(\.fidelityPercent).reduce(0,+)/Double(handoffs.count))
        let regressionActive = faults.contains{$0.condition(at:elapsedCampaignHours) == .regression}; let regression = regressionActive ? 0:100
        return .init(production:production,faultClosure:faultClosure,retest:retest,downtime:downtime,evidence:evidence,handoff:handoff,regression:regression)
    }
}

public struct PlantFaultPropagationEngine: Sendable {
    private var lastObservedAnalog:[String:Double]=[:]
    private var lastObservedDiscrete:[String:Bool]=[:]
    private var previousAlarmStates:[String:Bool]=[:]
    public init() {}

    public mutating func effectiveEnvironment(_ environment:ScenarioEnvironment, faults:[ProgressivePlantFault], hour:Double) -> ScenarioEnvironment {
        let bearing=maximumSeverity(.degradingBearing,faults,hour), vfd=maximumSeverity(.vfdDegradation,faults,hour)
        let derate=min(0.75,0.30*bearing+0.45*vfd)
        return .init(load:min(1,environment.load+0.15*bearing),speed:max(0.05,environment.speed*(1-derate)),ambient:environment.ambient)
    }

    public mutating func effectiveRun(command:Bool, faults:[ProgressivePlantFault], hour:Double, time:Double) -> (Bool,PlantDriveSnapshot) {
        let vfd=maximumSeverity(.vfdDegradation,faults,hour)
        let motor=max(maximumSeverity(.motorOverload,faults,hour), maximumSeverity(.contactorFailure,faults,hour))
        let servo=maximumSeverity(.servoFeedbackLoss,faults,hour)
        let network=max(maximumSeverity(.networkIntermittency,faults,hour), maximumSeverity(.ethernetPacketLoss,faults,hour))
        let trip = vfd >= 0.85 || motor >= 0.88 || servo >= 0.92 || (network > 0.70 && dropoutPhase(time:time, severity:network, multiplier:1.7))
        let actual=command && !trip
        var d=PlantDriveSnapshot(); d.commandRun=command; d.actualRun=actual; d.frequencyHz=actual ? max(5,60*(1-0.42*vfd-0.18*servo)):0; d.currentA=actual ? 9+23*vfd+18*motor:0; d.torquePercent=actual ? 42+45*vfd+30*motor:0; d.temperatureC=34+42*vfd+35*motor; d.faulted=trip
        return (actual,d)
    }

    public mutating func applySensorPath(physical:ScenarioProcessSnapshot, faults:[ProgressivePlantFault], hour:Double, time:Double) -> (ScenarioProcessSnapshot,PlantElectricalSnapshot) {
        var observed=physical, electrical=PlantElectricalSnapshot()
        let loose=maximumSeverity(.looseTerminal,faults,hour), dirty=maximumSeverity(.dirtyPhotoeye,faults,hour)
        let drift=max(maximumSeverity(.driftingTransmitter,faults,hour), max(maximumSeverity(.analogModuleDrift,faults,hour), maximumSeverity(.pidSensorBias,faults,hour)))
        let network=max(maximumSeverity(.networkIntermittency,faults,hour), max(maximumSeverity(.remoteIOConnectionLoss,faults,hour), maximumSeverity(.ethernetPacketLoss,faults,hour)))
        let safety=maximumSeverity(.safetyChannelDiscrepancy,faults,hour)
        let encoder=max(maximumSeverity(.encoderSlip,faults,hour), maximumSeverity(.servoFeedbackLoss,faults,hour))
        if loose>0 {
            let dropout=dropoutPhase(time:time,severity:loose,multiplier:4.1)
            electrical.terminalVoltage = dropout ? max(0,24*(1-1.25*loose)):24*(1-0.18*loose)
            electrical.plcInputVoltage=electrical.terminalVoltage
            if dropout || electrical.plcInputVoltage < 10 { for key in observed.discrete.keys { if key.localizedCaseInsensitiveContains("PE") || key.localizedCaseInsensitiveContains("Ready") { observed.discrete[key]=false } } }
        }
        if dirty>0, let key=observed.discrete.keys.first(where:{$0.localizedCaseInsensitiveContains("PE") || $0.localizedCaseInsensitiveContains("Photo")}) {
            if observed.discrete[key] == true && dropoutPhase(time:time,severity:dirty,multiplier:7.3) { observed.discrete[key]=false; electrical.sensorSupplyVoltage=max(16,24-5*dirty) }
        }
        if drift>0, let key=preferredAnalogSignal(observed.analog.keys) { let base=observed.analog[key] ?? 0; observed.analog[key]=base + max(abs(base)*0.18,5)*drift }
        if encoder>0 {
            if let key=observed.analog.keys.first(where:{$0.localizedCaseInsensitiveContains("Position") || $0.localizedCaseInsensitiveContains("Speed") || $0.localizedCaseInsensitiveContains("Encoder")}) { observed.analog[key]=(observed.analog[key] ?? 0)*(1-0.22*encoder) }
        }
        if safety>0 && dropoutPhase(time:time,severity:safety,multiplier:3.7) {
            for key in observed.discrete.keys where key.localizedCaseInsensitiveContains("Safe") || key.localizedCaseInsensitiveContains("Permissive") || key.localizedCaseInsensitiveContains("Ready") { observed.discrete[key]=false }
        }
        if network>0 {
            let stale=dropoutPhase(time:time,severity:network,multiplier:2.3); electrical.networkHealthy = !stale; electrical.networkStale=stale
            if stale { if !lastObservedAnalog.isEmpty { observed.analog=lastObservedAnalog }; if !lastObservedDiscrete.isEmpty { observed.discrete=lastObservedDiscrete } }
        }
        if !electrical.networkStale { lastObservedAnalog=observed.analog; lastObservedDiscrete=observed.discrete }
        return (observed,electrical)
    }

    public mutating func addPhysicalDegradation(to physical:inout ScenarioProcessSnapshot, faults:[ProgressivePlantFault], hour:Double, drive:PlantDriveSnapshot) {
        let bearing=maximumSeverity(.degradingBearing,faults,hour)
        if bearing>0 { physical.analog["BearingVibrationMMs"]=1.2+9.5*bearing; physical.analog["BearingTempC"]=42+58*bearing; physical.analog["MotorCurrentA"]=(physical.analog["MotorCurrentA"] ?? drive.currentA)+14*bearing }
        let pneu=maximumSeverity(.pneumaticLeak,faults,hour), heater=maximumSeverity(.heaterOpenCircuit,faults,hour), pump=maximumSeverity(.pumpCavitation,faults,hour)
        if pneu>0 { physical.analog["PneumaticPressurePSI"]=max(28,90-55*pneu); physical.analog["ActuatorResponsePercent"]=max(0,100-70*pneu) }
        if heater>0 { physical.analog["HeaterOutputEffectivePercent"]=max(0,100*(1-heater)); physical.discrete["HeaterCircuitHealthy"]=heater<0.70 }
        if pump>0 { physical.analog["PumpCavitationIndex"]=pump; physical.analog["PumpFlowDeratePercent"]=100*min(0.65,pump*0.65) }
        physical.analog["VFD_FrequencyHz"]=drive.frequencyHz; physical.analog["VFD_CurrentA"]=drive.currentA; physical.analog["VFD_TemperatureC"]=drive.temperatureC; physical.discrete["VFD_Faulted"]=drive.faulted
    }

    public mutating func alarms(physical:ScenarioProcessSnapshot, observed:ScenarioProcessSnapshot, electrical:PlantElectricalSnapshot, drive:PlantDriveSnapshot, time:Double) -> [PlantAlarmEvent] {
        var candidates:[(String,String,PlantAlarmSeverity,Bool)] = []
        let vibration=physical.analog["BearingVibrationMMs"] ?? 0, temp=physical.analog["BearingTempC"] ?? 0
        candidates.append(("ALM_BearingVibration","Bearing vibration above healthy envelope",vibration>7 ? .alarm:.warning,vibration>4.5))
        candidates.append(("ALM_BearingTemp","Bearing temperature high",temp>85 ? .alarm:.warning,temp>72))
        candidates.append(("ALM_ControlVoltage","Field input voltage unstable",.alarm,electrical.plcInputVoltage<18))
        candidates.append(("ALM_Network","Remote I/O data stale",.alarm,electrical.networkStale))
        candidates.append(("ALM_VFD","VFD trip / not following run command",.trip,drive.commandRun && !drive.actualRun))
        var events:[PlantAlarmEvent]=[]
        for c in candidates { let old=previousAlarmStates[c.0] ?? false; if c.3 != old { events.append(.init(timeSeconds:time,tag:c.0,message:c.1,severity:c.2,active:c.3)); previousAlarmStates[c.0]=c.3 } }
        return events
    }

    private func maximumSeverity(_ kind:PlantFaultKind,_ faults:[ProgressivePlantFault],_ hour:Double)->Double { faults.filter{$0.kind==kind}.map{$0.severity(at:hour)}.max() ?? 0 }
    private func dropoutPhase(time:Double,severity:Double,multiplier:Double)->Bool { guard severity>0.08 else{return false}; let wave=(sin(time*multiplier)+1)/2; return wave > max(0.35,1-severity*0.75) }
    private func preferredAnalogSignal(_ keys:Dictionary<String,Double>.Keys)->String? { let list=Array(keys); return list.first{$0.localizedCaseInsensitiveContains("PV")} ?? list.first{$0.localizedCaseInsensitiveContains("Pressure")} ?? list.first{$0.localizedCaseInsensitiveContains("Temp")} ?? list.first }
}

public struct IntegratedPlantRuntime: Sendable {
    public private(set) var controller:ControllerRuntime
    public private(set) var process:HeroProcessModel
    public private(set) var clock=SimulationClock()
    public private(set) var latest:IntegratedPlantSnapshot
    public var environment:ScenarioEnvironment
    public let architecture: HeroMachineArchitecture
    private var propagation=PlantFaultPropagationEngine()
    private let bridge=ScenarioIOBridge()
    private var lastProductCount:Double=0
    private var lastProductTime:Double=0

    public init(project:ControllerProject, process:HeroProcessModel, environment:ScenarioEnvironment = .init(), architecture:HeroMachineArchitecture? = nil) throws {
        self.controller=ControllerRuntime(project:project);self.process=process;self.environment=environment; self.architecture=architecture ?? HeroMachineArchitectureCatalog.profile(for: process.kind)
        self.latest = .init(timeSeconds:0,physicalAnalog:[:],plcObservedAnalog:[:],physicalDiscrete:[:],plcObservedDiscrete:[:],electrical:.init(),drive:.init(),production:.init(),activeAlarms:[],activeFaultConditions:[:])
        try self.controller.setMode(.run)
    }

    @discardableResult public mutating func step(milliseconds:Int32=20,campaign:inout PersistentPlantCampaign) throws -> ControllerScanTrace {
            let dt=Double(max(1,milliseconds))/1000, hour=campaign.elapsedCampaignHours+clock.elapsedSeconds/3600
            let commanded=commandedRun()
            let (effectiveRun,drive)=propagation.effectiveRun(command:commanded,faults:campaign.faults,hour:hour,time:clock.elapsedSeconds)
            try setPhysicalRun(effectiveRun)
            let env=propagation.effectiveEnvironment(environment,faults:campaign.faults,hour:hour)
            let processFault = architecture.processFaultInjection(from:campaign.faults,hour:hour)
            var physical=process.step(deltaTime:dt,controller:controller,environment:env,fault:processFault,time:clock.elapsedSeconds)
            propagation.addPhysicalDegradation(to:&physical,faults:campaign.faults,hour:hour,drive:drive)
            let (observed,electrical)=propagation.applySensorPath(physical:physical,faults:campaign.faults,hour:hour,time:clock.elapsedSeconds)
            try bridge.applyProcessInputs(observed,to:&controller)
            try writeIntegrationTags(observed:observed,electrical:electrical,drive:drive)
            let trace=try controller.scan(elapsedMilliseconds:milliseconds)
            let production=productionSnapshot(physical:physical,drive:drive,dt:dt,demand:campaign.currentDemand)
            let alarmEvents=propagation.alarms(physical:physical,observed:observed,electrical:electrical,drive:drive,time:clock.elapsedSeconds)
            campaign.alarms.append(contentsOf:alarmEvents)
            if campaign.alarms.count>1000 { campaign.alarms.removeFirst(campaign.alarms.count-1000) }
            let states=Dictionary(uniqueKeysWithValues:campaign.faults.map{($0.id,$0.condition(at:hour))})
            latest = .init(timeSeconds:clock.elapsedSeconds,physicalAnalog:physical.analog,plcObservedAnalog:observed.analog,physicalDiscrete:physical.discrete,plcObservedDiscrete:observed.discrete,electrical:electrical,drive:drive,production:production,activeAlarms:currentActiveAlarms(from:campaign.alarms),activeFaultConditions:states)
            if clock.tick % 10 == 0 { campaign.historian.append(.init(timeSeconds:campaign.elapsedCampaignHours*3600+clock.elapsedSeconds,values:observed.analog.merging(["ControlVoltage":electrical.controlVoltage,"PLCInputVoltage":electrical.plcInputVoltage,"VFDHz":drive.frequencyHz,"VFDCurrent":drive.currentA,"ProductionRate":production.actualUnitsPerHour],uniquingKeysWith:{$1}),states:observed.discrete.merging(["NetworkHealthy":electrical.networkHealthy,"VFDRun":drive.actualRun],uniquingKeysWith:{$1}))); if campaign.historian.count>10000 {campaign.historian.removeFirst(campaign.historian.count-10000)} }
            for event in physical.events { campaign.flightRecorder.append(.init(timeSeconds:campaign.elapsedCampaignHours*3600+clock.elapsedSeconds,trigger:event.name,detail:event.detail,values:physical.analog)) }
            for alarm in alarmEvents where alarm.active { campaign.flightRecorder.append(.init(timeSeconds:campaign.elapsedCampaignHours*3600+clock.elapsedSeconds,trigger:alarm.tag,detail:alarm.message,values:["PLCInputVoltage":electrical.plcInputVoltage,"VFDHz":drive.frequencyHz])) }
            if campaign.flightRecorder.count>2500 {campaign.flightRecorder.removeFirst(campaign.flightRecorder.count-2500)}
            campaign.cumulativeProduced += production.actualUnitsPerHour*dt/3600; campaign.cumulativeLost += max(0,production.demandUnitsPerHour-production.actualUnitsPerHour)*dt/3600
            clock.advance(by:dt); return trace
    }

    public mutating func startMachine() throws { if process.kind == .packagingCell { try controller.setControllerTagValue("Start_PB",to:.bool(true)); if controller.project.controllerTags.contains("Stop_OK") {try controller.setControllerTagValue("Stop_OK",to:.bool(true))} } else if controller.project.controllerTags.contains("AutoMode") {try controller.setControllerTagValue("AutoMode",to:.bool(true))} }

    private func commandedRun()->Bool { let tag=process.kind == .packagingCell ? "Motor_Run":"RunCmd"; return (try? controller.project.controllerTags.bool(tag)) ?? false }
    private mutating func setPhysicalRun(_ run:Bool) throws { let tag=process.kind == .packagingCell ? "Motor_Run":"RunCmd"; if controller.project.controllerTags.contains(tag), (try? controller.project.controllerTags.dataType(for:tag)) == .bool {try controller.setControllerTagValue(tag,to:.bool(run))} }
    private mutating func writeIntegrationTags(observed:ScenarioProcessSnapshot,electrical:PlantElectricalSnapshot,drive:PlantDriveSnapshot) throws {
        let values:[String:TagValue]=["Field_24VDC":.real(electrical.controlVoltage),"InputVoltage":.real(electrical.plcInputVoltage),"Network_OK":.bool(electrical.networkHealthy),"VFD_Ready":.bool(!drive.faulted),"VFD_Fault":.bool(drive.faulted),"VFD_Hz":.real(drive.frequencyHz),"VFD_Current":.real(drive.currentA)]
        for (name,value) in values where controller.project.controllerTags.contains(name) { try controller.setControllerTagValue(name,to:value) }
    }

    private func currentActiveAlarms(from history:[PlantAlarmEvent]) -> [PlantAlarmEvent] {
        var latest:[String:PlantAlarmEvent]=[:]
        for event in history { latest[event.tag]=event }
        return latest.values.filter{$0.active}.sorted{$0.tag < $1.tag}
    }

    private mutating func productionSnapshot(physical:ScenarioProcessSnapshot,drive:PlantDriveSnapshot,dt:Double,demand:PlantProductionDemand?)->PlantProductionSnapshot {
        var p=PlantProductionSnapshot(); let target=demand.map{$0.targetUnits/8} ?? 100; p.demandUnitsPerHour=target
        if let count=physical.analog["ProductCountPhysical"] { if count>lastProductCount { let elapsed=max(dt,clock.elapsedSeconds-lastProductTime); p.cycleTimeSeconds=elapsed; lastProductTime=clock.elapsedSeconds; lastProductCount=count }; p.actualUnitsPerHour=p.cycleTimeSeconds>0 ? 3600/p.cycleTimeSeconds : (drive.actualRun ? target*0.9:0) }
        else { let derate=drive.actualRun ? max(0.1,drive.frequencyHz/60):0; p.actualUnitsPerHour=target*derate }
        p.cumulativeUnits=0; p.lostUnits=max(0,p.demandUnitsPerHour-p.actualUnitsPerHour)*dt/3600; p.availabilityPercent=drive.actualRun ? 100:0; return p
    }
}

public enum IntegratedPlantCampaignCatalog {
    public static func sevenDayPackagingCampaign() -> PersistentPlantCampaign {
        var demands:[PlantProductionDemand]=[]
        for day in 1...7 { demands.append(.init(day:day,shift:.day,targetUnits:800+Double(day*20),maximumDowntimeMinutes:35)); demands.append(.init(day:day,shift:.evening,targetUnits:720,maximumDowntimeMinutes:30)); demands.append(.init(day:day,shift:.night,targetUnits:600,maximumDowntimeMinutes:25)) }
        return .init(faults:[
            .init(id:"F-BRG-1",kind:.degradingBearing,target:"MTR-201 drive-end bearing",onsetHour:8,initialSeverity:0.08,growthPerHour:0.018),
            .init(id:"F-TERM-1",kind:.looseTerminal,target:"TB2-14 / PE203 signal",onsetHour:18,initialSeverity:0.10,growthPerHour:0.028),
            .init(id:"F-TX-1",kind:.driftingTransmitter,target:"PT-301",onsetHour:32,initialSeverity:0.05,growthPerHour:0.022),
            .init(id:"F-PE-1",kind:.dirtyPhotoeye,target:"PE203",onsetHour:44,initialSeverity:0.12,growthPerHour:0.026),
            .init(id:"F-NET-1",kind:.networkIntermittency,target:"Remote I/O EN2TR",onsetHour:60,initialSeverity:0.08,growthPerHour:0.024),
            .init(id:"F-VFD-1",kind:.vfdDegradation,target:"VFD-201",onsetHour:78,initialSeverity:0.10,growthPerHour:0.020)
        ],demands:demands,spares:[
            .init(partNumber:"BRG-6205",description:"Drive-end bearing kit",quantityOnHand:1,leadTimeHours:24),
            .init(partNumber:"TB-2.5",description:"2.5 mm² feed-through terminal",quantityOnHand:6,leadTimeHours:4),
            .init(partNumber:"PE-M18",description:"M18 photoelectric sensor",quantityOnHand:1,leadTimeHours:12),
            .init(partNumber:"VFD-5HP",description:"5 HP replacement VFD",quantityOnHand:0,leadTimeHours:36)
        ])
    }
    public static func sevenDayCampaign(for machine: PlayableMachineKind) -> PersistentPlantCampaign {
        if machine == .packagingCell { return sevenDayPackagingCampaign() }
        let profile = HeroMachineArchitectureCatalog.profile(for: machine)
        var demands:[PlantProductionDemand]=[]
        for day in 1...7 {
            demands.append(.init(day:day,shift:.day,targetUnits:760+Double(day*25),maximumDowntimeMinutes:40))
            demands.append(.init(day:day,shift:.evening,targetUnits:680+Double(day*15),maximumDowntimeMinutes:35))
            demands.append(.init(day:day,shift:.night,targetUnits:560+Double(day*10),maximumDowntimeMinutes:30))
        }
        let faults = profile.failureChains.enumerated().map { index, chain in
            ProgressivePlantFault(id:"\(machine.rawValue)-F\(index+1)",kind:chain.faultKind,target:chain.title,onsetHour:Double(8 + index*18),initialSeverity:0.06+Double(index)*0.015,growthPerHour:0.018+Double(index)*0.003)
        }
        let spares:[PlantSparePart] = [
            .init(partNumber:"RIO-MOD",description:"Remote I/O replacement module",quantityOnHand:1,leadTimeHours:18),
            .init(partNumber:"AI-CH",description:"Analog input replacement module",quantityOnHand:1,leadTimeHours:24),
            .init(partNumber:"NET-CBL",description:"Industrial Ethernet cable/connector kit",quantityOnHand:2,leadTimeHours:4),
            .init(partNumber:"ACT-KIT",description:"Machine-specific actuator repair kit",quantityOnHand:1,leadTimeHours:12)
        ]
        var campaign = PersistentPlantCampaign(faults:faults,demands:demands,spares:spares)
        campaign.title = "\(profile.title) — 7-Day Integrated Campaign"
        return campaign
    }

}

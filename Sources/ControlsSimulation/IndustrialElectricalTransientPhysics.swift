import Foundation
import ControlsPLC

// MARK: - Time-domain transient primitives

public enum TransientElementKind: String, Codable, CaseIterable, Sendable {
    case resistor, capacitor, inductor, coil, contact, arcGap, transformerMagnetizing, motorPhase, dcBus, leakage, insulation
}

public struct TransientRCResult: Codable, Equatable, Sendable {
    public var voltage: Double
    public var currentAmps: Double
    public var storedJoules: Double
}

public enum TransientRCModel {
    public static func advanceCapacitor(voltage: Double, sourceVolts: Double, resistanceOhms: Double, capacitanceFarads: Double, dt: Double) -> TransientRCResult {
        let r = max(1e-9, resistanceOhms), c = max(1e-12, capacitanceFarads), step = max(0, dt)
        let alpha = exp(-step / (r * c))
        let next = sourceVolts + (voltage - sourceVolts) * alpha
        let i = (sourceVolts - next) / r
        return .init(voltage: next, currentAmps: i, storedJoules: 0.5 * c * next * next)
    }
}

public struct TransientRLResult: Codable, Equatable, Sendable {
    public var currentAmps: Double
    public var voltageAcrossInductor: Double
    public var storedJoules: Double
}

public enum TransientRLModel {
    public static func advanceInductor(currentAmps: Double, sourceVolts: Double, resistanceOhms: Double, inductanceHenries: Double, dt: Double) -> TransientRLResult {
        let r = max(1e-9, resistanceOhms), l = max(1e-9, inductanceHenries), step = max(0, dt)
        let steady = sourceVolts / r
        let alpha = exp(-r * step / l)
        let next = steady + (currentAmps - steady) * alpha
        let vL = sourceVolts - next * r
        return .init(currentAmps: next, voltageAcrossInductor: vL, storedJoules: 0.5 * l * next * next)
    }
}

// MARK: - Electromagnetic contactor / relay coil

public struct ElectromagneticCoilSpec: Codable, Equatable, Sendable {
    public var nominalVolts: Double
    public var resistanceOhms: Double
    public var inductanceOpenHenries: Double
    public var inductanceClosedHenries: Double
    public var pickupAmpereTurnsEquivalent: Double
    public var dropoutAmpereTurnsEquivalent: Double
    public var armatureTravelSeconds: Double
    public var bounceDurationSeconds: Double
    public var coilThermalMassJPerC: Double
    public var coilThermalResistanceCPerW: Double
    public init(nominalVolts: Double = 24, resistanceOhms: Double = 72, inductanceOpenHenries: Double = 0.08, inductanceClosedHenries: Double = 0.24, pickupAmpereTurnsEquivalent: Double = 0.23, dropoutAmpereTurnsEquivalent: Double = 0.08, armatureTravelSeconds: Double = 0.018, bounceDurationSeconds: Double = 0.006, coilThermalMassJPerC: Double = 60, coilThermalResistanceCPerW: Double = 5) {
        self.nominalVolts=nominalVolts; self.resistanceOhms=resistanceOhms; self.inductanceOpenHenries=inductanceOpenHenries; self.inductanceClosedHenries=inductanceClosedHenries
        self.pickupAmpereTurnsEquivalent=pickupAmpereTurnsEquivalent; self.dropoutAmpereTurnsEquivalent=dropoutAmpereTurnsEquivalent; self.armatureTravelSeconds=armatureTravelSeconds
        self.bounceDurationSeconds=bounceDurationSeconds; self.coilThermalMassJPerC=coilThermalMassJPerC; self.coilThermalResistanceCPerW=coilThermalResistanceCPerW
    }
}

public struct ElectromagneticCoilState: Codable, Equatable, Sendable {
    public var currentAmps: Double = 0
    public var armaturePosition: Double = 0
    public var contactClosed: Bool = false
    public var bounceRemaining: Double = 0
    public var temperatureC: Double = 25
    public var chatterCount: Int = 0
    public var energizedSeconds: Double = 0
    public init() {}
}

public struct ElectromagneticCoilSnapshot: Codable, Equatable, Sendable {
    public var currentAmps: Double
    public var inrushMultiple: Double
    public var armaturePosition: Double
    public var contactClosed: Bool
    public var bouncing: Bool
    public var temperatureC: Double
    public var magneticForceIndex: Double
}

public enum ElectromagneticCoilModel {
    public static func advance(spec: ElectromagneticCoilSpec, state: inout ElectromagneticCoilState, appliedVolts: Double, ambientC: Double = 25, dt: Double) -> ElectromagneticCoilSnapshot {
        let l = spec.inductanceOpenHenries + (spec.inductanceClosedHenries-spec.inductanceOpenHenries)*max(0,min(1,state.armaturePosition))
        let rl = TransientRLModel.advanceInductor(currentAmps: state.currentAmps, sourceVolts: appliedVolts, resistanceOhms: spec.resistanceOhms, inductanceHenries: l, dt: dt)
        state.currentAmps = rl.currentAmps
        let force = abs(state.currentAmps)
        let targetClosed = force >= spec.pickupAmpereTurnsEquivalent || (state.contactClosed && force > spec.dropoutAmpereTurnsEquivalent)
        let direction = targetClosed ? 1.0 : -1.0
        let oldClosed = state.contactClosed
        state.armaturePosition = max(0,min(1,state.armaturePosition + direction*dt/max(0.001,spec.armatureTravelSeconds)))
        state.contactClosed = state.armaturePosition >= 0.98
        if state.contactClosed != oldClosed { state.bounceRemaining = spec.bounceDurationSeconds; state.chatterCount += 1 }
        state.bounceRemaining = max(0,state.bounceRemaining-dt)
        if abs(appliedVolts) > 1 { state.energizedSeconds += dt }
        let p = state.currentAmps*state.currentAmps*spec.resistanceOhms
        let cooling = (state.temperatureC-ambientC)/max(0.001,spec.coilThermalResistanceCPerW)
        state.temperatureC += (p-cooling)*dt/max(0.1,spec.coilThermalMassJPerC)
        let nominalCurrent = spec.nominalVolts/max(1e-9,spec.resistanceOhms)
        return .init(currentAmps:state.currentAmps,inrushMultiple:abs(state.currentAmps)/max(1e-9,nominalCurrent),armaturePosition:state.armaturePosition,contactClosed:state.contactClosed,bouncing:state.bounceRemaining>0,temperatureC:state.temperatureC,magneticForceIndex:force/max(1e-9,spec.pickupAmpereTurnsEquivalent))
    }
}

// MARK: - Contact bounce, arc and erosion

public struct ContactArcSpec: Codable, Equatable, Sendable {
    public var nominalContactResistanceOhms: Double
    public var arcStrikeVolts: Double
    public var arcHoldCurrentAmps: Double
    public var arcResistanceOhms: Double
    public var erosionJoulesToFailure: Double
    public var weldJoulesThreshold: Double
    public init(nominalContactResistanceOhms:Double=0.012,arcStrikeVolts:Double=18,arcHoldCurrentAmps:Double=0.08,arcResistanceOhms:Double=18,erosionJoulesToFailure:Double=180,weldJoulesThreshold:Double=35){self.nominalContactResistanceOhms=nominalContactResistanceOhms;self.arcStrikeVolts=arcStrikeVolts;self.arcHoldCurrentAmps=arcHoldCurrentAmps;self.arcResistanceOhms=arcResistanceOhms;self.erosionJoulesToFailure=erosionJoulesToFailure;self.weldJoulesThreshold=weldJoulesThreshold}
}
public struct ContactArcState: Codable, Equatable, Sendable { public var arcActive=false; public var erosionJoules=0.0; public var welded=false; public var bouncePhase=0.0; public init(){} }
public struct ContactArcSnapshot: Codable, Equatable, Sendable { public var conducting:Bool;public var arcActive:Bool;public var currentAmps:Double;public var voltageDrop:Double;public var powerWatts:Double;public var erosionPercent:Double;public var welded:Bool }
public enum ContactArcModel {
    public static func advance(spec:ContactArcSpec,state:inout ContactArcState,commandClosed:Bool,bouncing:Bool,sourceVolts:Double,loadResistanceOhms:Double,dt:Double)->ContactArcSnapshot {
        let closedEffective = state.welded || (commandClosed && (!bouncing || sin(state.bouncePhase*2*Double.pi)>0))
        state.bouncePhase += dt*1200
        if !closedEffective && abs(sourceVolts)>=spec.arcStrikeVolts && loadResistanceOhms>0 { state.arcActive = state.arcActive || abs(sourceVolts/max(1e-9,loadResistanceOhms))>=spec.arcHoldCurrentAmps }
        if closedEffective { state.arcActive=false }
        let r = closedEffective ? spec.nominalContactResistanceOhms : (state.arcActive ? spec.arcResistanceOhms : 1e12)
        let i = sourceVolts/max(1e-9,loadResistanceOhms+r)
        let vd = i*r; let p=i*i*r
        if state.arcActive { state.erosionJoules += p*dt }
        if closedEffective && p*dt >= spec.weldJoulesThreshold { state.welded=true }
        return .init(conducting:closedEffective || state.arcActive,arcActive:state.arcActive,currentAmps:i,voltageDrop:vd,powerWatts:p,erosionPercent:min(100,100*state.erosionJoules/max(1e-9,spec.erosionJoulesToFailure)),welded:state.welded)
    }
}


// MARK: - Inductive kick and suppression devices

public enum CoilSuppressionKind: String, Codable, CaseIterable, Sendable { case none, flybackDiode, rcSnubber, mov }
public struct CoilSuppressionResult: Codable, Equatable, Sendable { public var peakVolts:Double;public var initialDecayAmpsPerSecond:Double;public var releaseTimeSeconds:Double;public var dissipatedJoules:Double }
public enum CoilSuppressionModel {
    public static func release(currentAmps:Double,inductanceHenries:Double,coilResistanceOhms:Double,suppression:CoilSuppressionKind,clampVolts:Double=48)->CoilSuppressionResult {
        let i=abs(currentAmps),l=max(1e-9,inductanceHenries),r=max(1e-6,coilResistanceOhms);let energy=0.5*l*i*i
        switch suppression {
        case .none:
            let peak=max(100,min(2500,energy/max(1e-6,2e-6*i)));return .init(peakVolts:peak,initialDecayAmpsPerSecond:-peak/l,releaseTimeSeconds:max(0.0001,l/r*0.12),dissipatedJoules:energy)
        case .flybackDiode:
            let peak=1.0+i*r;return .init(peakVolts:peak,initialDecayAmpsPerSecond:-peak/l,releaseTimeSeconds:l/r*3.0,dissipatedJoules:energy)
        case .rcSnubber:
            let peak=max(12,min(clampVolts,120));return .init(peakVolts:peak,initialDecayAmpsPerSecond:-peak/l,releaseTimeSeconds:max(0.0002,l/r*0.7),dissipatedJoules:energy)
        case .mov:
            let peak=max(24,clampVolts);return .init(peakVolts:peak,initialDecayAmpsPerSecond:-peak/l,releaseTimeSeconds:max(0.0001,i*l/peak),dissipatedJoules:energy)
        }
    }
}

// MARK: - Transformer energization / inrush

public struct TransformerTransientSpec: Codable, Equatable, Sendable {
    public var rmsPrimaryVolts:Double;public var frequencyHz:Double;public var magnetizingInductanceHenries:Double;public var windingResistanceOhms:Double;public var coreSaturationFluxWebers:Double;public var saturatedInductanceHenries:Double;public var residualFluxWebers:Double
    public init(rmsPrimaryVolts:Double=480,frequencyHz:Double=60,magnetizingInductanceHenries:Double=8,windingResistanceOhms:Double=1.4,coreSaturationFluxWebers:Double=1.4,saturatedInductanceHenries:Double=0.18,residualFluxWebers:Double=0){self.rmsPrimaryVolts=rmsPrimaryVolts;self.frequencyHz=frequencyHz;self.magnetizingInductanceHenries=magnetizingInductanceHenries;self.windingResistanceOhms=windingResistanceOhms;self.coreSaturationFluxWebers=coreSaturationFluxWebers;self.saturatedInductanceHenries=saturatedInductanceHenries;self.residualFluxWebers=residualFluxWebers}
}
public struct TransformerTransientState: Codable, Equatable, Sendable { public var fluxWebers:Double;public var magnetizingCurrentAmps:Double=0;public var peakInrushAmps:Double=0;public init(residualFluxWebers:Double=0){fluxWebers=residualFluxWebers} }
public struct TransformerTransientSnapshot: Codable, Equatable, Sendable { public var instantaneousVolts:Double;public var magnetizingCurrentAmps:Double;public var fluxWebers:Double;public var saturated:Bool;public var peakInrushAmps:Double }
public enum TransformerTransientModel {
    public static func advance(spec:TransformerTransientSpec,state:inout TransformerTransientState,time:Double,closingAngleRadians:Double=0,dt:Double)->TransformerTransientSnapshot {
        let omega=2*Double.pi*spec.frequencyHz; let vPeak=spec.rmsPrimaryVolts*sqrt(2); let v=vPeak*sin(omega*time+closingAngleRadians)
        state.fluxWebers += v*dt
        let saturated=abs(state.fluxWebers)>spec.coreSaturationFluxWebers
        let l=saturated ? spec.saturatedInductanceHenries:spec.magnetizingInductanceHenries
        let di=(v-spec.windingResistanceOhms*state.magnetizingCurrentAmps)/max(1e-9,l)*dt
        state.magnetizingCurrentAmps += di
        state.peakInrushAmps=max(state.peakInrushAmps,abs(state.magnetizingCurrentAmps))
        return .init(instantaneousVolts:v,magnetizingCurrentAmps:state.magnetizingCurrentAmps,fluxWebers:state.fluxWebers,saturated:saturated,peakInrushAmps:state.peakInrushAmps)
    }
}

// MARK: - Induction motor acceleration, slip and inrush

public struct InductionMotorTransientSpec: Codable, Equatable, Sendable {
    public var ratedLineVolts:Double;public var ratedHz:Double;public var poles:Int;public var ratedHP:Double;public var lockedRotorCurrentMultiple:Double;public var breakdownTorqueMultiple:Double;public var rotorInertiaKgM2:Double;public var loadInertiaKgM2:Double;public var ratedEfficiency:Double;public var ratedPowerFactor:Double;public var statorResistanceOhms:Double;public var thermalMassJPerC:Double
    public init(ratedLineVolts:Double=480,ratedHz:Double=60,poles:Int=4,ratedHP:Double=10,lockedRotorCurrentMultiple:Double=6,breakdownTorqueMultiple:Double=2.4,rotorInertiaKgM2:Double=0.08,loadInertiaKgM2:Double=0.12,ratedEfficiency:Double=0.9,ratedPowerFactor:Double=0.84,statorResistanceOhms:Double=0.35,thermalMassJPerC:Double=18000){self.ratedLineVolts=ratedLineVolts;self.ratedHz=ratedHz;self.poles=poles;self.ratedHP=ratedHP;self.lockedRotorCurrentMultiple=lockedRotorCurrentMultiple;self.breakdownTorqueMultiple=breakdownTorqueMultiple;self.rotorInertiaKgM2=rotorInertiaKgM2;self.loadInertiaKgM2=loadInertiaKgM2;self.ratedEfficiency=ratedEfficiency;self.ratedPowerFactor=ratedPowerFactor;self.statorResistanceOhms=statorResistanceOhms;self.thermalMassJPerC=thermalMassJPerC}
}
public struct InductionMotorTransientState: Codable, Equatable, Sendable { public var speedRPM=0.0;public var temperatureC=25.0;public var peakCurrentAmps=0.0;public var tripIntegral=0.0;public init(){} }
public struct InductionMotorTransientSnapshot: Codable, Equatable, Sendable { public var synchronousRPM:Double;public var speedRPM:Double;public var slip:Double;public var lineCurrentAmps:Double;public var electromagneticTorqueNm:Double;public var loadTorqueNm:Double;public var accelerationRPMPerSecond:Double;public var copperLossWatts:Double;public var temperatureC:Double;public var stalled:Bool }
public enum InductionMotorTransientModel {
    public static func advance(spec:InductionMotorTransientSpec,state:inout InductionMotorTransientState,lineVolts:Double,frequencyHz:Double,loadTorqueFraction:Double,dt:Double)->InductionMotorTransientSnapshot {
        let sync=120*max(0.1,frequencyHz)/Double(max(2,spec.poles));let slip=max(0,min(1,(sync-state.speedRPM)/max(1,sync)))
        let ratedKW=spec.ratedHP*0.7457;let ratedI=ratedKW*1000/max(1,sqrt(3)*spec.ratedLineVolts*spec.ratedEfficiency*spec.ratedPowerFactor)
        let voltageFactor=max(0,lineVolts/max(1,spec.ratedLineVolts));let current=ratedI*(1+(spec.lockedRotorCurrentMultiple-1)*pow(slip,0.75))*voltageFactor
        let ratedOmega=2*Double.pi*(0.96*sync)/60;let ratedTorque=ratedKW*1000/max(1,ratedOmega)
        let torqueCurve = slip<=0 ? 0 : min(spec.breakdownTorqueMultiple, (2.0*spec.breakdownTorqueMultiple*slip)/(0.18 + slip*slip/0.18))
        let motorTorque=ratedTorque*torqueCurve*voltageFactor*voltageFactor
        let loadTorque=ratedTorque*max(0,loadTorqueFraction)*(0.15+0.85*pow(max(0,state.speedRPM/max(1,sync)),2))
        let inertia=max(0.001,spec.rotorInertiaKgM2+spec.loadInertiaKgM2);let accelRad=(motorTorque-loadTorque)/inertia;let accelRPM=accelRad*60/(2*Double.pi)
        state.speedRPM=max(0,min(sync,state.speedRPM+accelRPM*dt));state.peakCurrentAmps=max(state.peakCurrentAmps,current)
        let copper=3*current*current*spec.statorResistanceOhms;let cooling=(state.temperatureC-25)/20;state.temperatureC += (copper-cooling)*dt/max(1,spec.thermalMassJPerC)
        return .init(synchronousRPM:sync,speedRPM:state.speedRPM,slip:slip,lineCurrentAmps:current,electromagneticTorqueNm:motorTorque,loadTorqueNm:loadTorque,accelerationRPMPerSecond:accelRPM,copperLossWatts:copper,temperatureC:state.temperatureC,stalled:state.speedRPM<0.2*sync && loadTorque>motorTorque)
    }
}

// MARK: - VFD DC bus and PWM output

public struct VFDTransientSpec: Codable, Equatable, Sendable {
    public var lineRMSVolts:Double;public var dcBusCapacitanceFarads:Double;public var prechargeResistanceOhms:Double;public var busLeakResistanceOhms:Double;public var carrierHz:Double;public var maxOutputHz:Double;public var undervoltageTripVDC:Double;public var overvoltageTripVDC:Double
    public init(lineRMSVolts:Double=480,dcBusCapacitanceFarads:Double=0.0047,prechargeResistanceOhms:Double=45,busLeakResistanceOhms:Double=30_000,carrierHz:Double=4000,maxOutputHz:Double=90,undervoltageTripVDC:Double=430,overvoltageTripVDC:Double=820){self.lineRMSVolts=lineRMSVolts;self.dcBusCapacitanceFarads=dcBusCapacitanceFarads;self.prechargeResistanceOhms=prechargeResistanceOhms;self.busLeakResistanceOhms=busLeakResistanceOhms;self.carrierHz=carrierHz;self.maxOutputHz=maxOutputHz;self.undervoltageTripVDC=undervoltageTripVDC;self.overvoltageTripVDC=overvoltageTripVDC}
}
public struct VFDTransientState: Codable, Equatable, Sendable { public var dcBusVolts=0.0;public var prechargeComplete=false;public var tripped=false;public var tripReason:String?=nil;public var electricalAngle=0.0;public init(){} }
public struct VFDTransientSnapshot: Codable, Equatable, Sendable { public var dcBusVolts:Double;public var busEnergyJoules:Double;public var rectifierCurrentAmps:Double;public var outputPhaseVolts:[Double];public var commandedHz:Double;public var modulationIndex:Double;public var tripped:Bool;public var tripReason:String? }
public enum VFDTransientModel {
    public static func advance(spec:VFDTransientSpec,state:inout VFDTransientState,lineRMSVolts:Double,commandHz:Double,loadPowerKW:Double,enable:Bool,dt:Double)->VFDTransientSnapshot {
        let targetDC=max(0,lineRMSVolts)*sqrt(2);let r=state.prechargeComplete ? 0.8:spec.prechargeResistanceOhms
        let loadI=(enable && state.prechargeComplete && !state.tripped && state.dcBusVolts>10) ? max(0,loadPowerKW*1000/state.dcBusVolts):0
        let conductance=1/max(0.01,r)+1/max(1,spec.busLeakResistanceOhms)
        let equilibrium=max(0,(targetDC/max(0.01,r)-loadI)/max(1e-12,conductance))
        let alpha=exp(-max(0,dt)*conductance/max(1e-9,spec.dcBusCapacitanceFarads))
        let previous=state.dcBusVolts
        state.dcBusVolts=max(0,equilibrium+(state.dcBusVolts-equilibrium)*alpha)
        let rectifier=max(0,(targetDC-0.5*(previous+state.dcBusVolts))/max(0.01,r))
        if state.dcBusVolts>0.88*targetDC {state.prechargeComplete=true}
        if (enable || commandHz > 0.1) && state.dcBusVolts<spec.undervoltageTripVDC && state.prechargeComplete {state.tripped=true;state.tripReason="DC bus undervoltage"}
        if state.dcBusVolts>spec.overvoltageTripVDC {state.tripped=true;state.tripReason="DC bus overvoltage"}
        let hz=max(0,min(spec.maxOutputHz,commandHz));state.electricalAngle += 2*Double.pi*hz*dt
        let modulation=min(1, hz/max(1,spec.maxOutputHz));let phasePeak=state.tripped || !enable ? 0:state.dcBusVolts*0.5*modulation
        let phases=[0.0,-2*Double.pi/3,2*Double.pi/3].map{ phasePeak*sin(state.electricalAngle+$0) }
        return .init(dcBusVolts:state.dcBusVolts,busEnergyJoules:0.5*spec.dcBusCapacitanceFarads*state.dcBusVolts*state.dcBusVolts,rectifierCurrentAmps:rectifier,outputPhaseVolts:phases,commandedHz:hz,modulationIndex:modulation,tripped:state.tripped,tripReason:state.tripReason)
    }
    public static func pwmSample(dcBusVolts:Double,modulationIndex:Double,electricalAngle:Double,carrierPhase:Double)->Double {
        let reference=max(-1,min(1,modulationIndex*sin(electricalAngle)));let carrier=2*abs(2*(carrierPhase-floor(carrierPhase+0.5)))-1
        return reference>=carrier ? dcBusVolts/2 : -dcBusVolts/2
    }
}

// MARK: - Insulation, leakage and megohmmeter training

public struct InsulationSpec: Codable, Equatable, Sendable { public var initialMegohms:Double;public var capacitanceNanofarads:Double;public var moistureFactor:Double;public var temperatureC:Double;public init(initialMegohms:Double=200,capacitanceNanofarads:Double=25,moistureFactor:Double=0,temperatureC:Double=25){self.initialMegohms=initialMegohms;self.capacitanceNanofarads=capacitanceNanofarads;self.moistureFactor=moistureFactor;self.temperatureC=temperatureC} }
public struct InsulationState: Codable, Equatable, Sendable { public var degradation=0.0;public var absorbedChargeCoulombs=0.0;public init(){} }
public struct MegohmmeterSnapshot: Codable, Equatable, Sendable { public var appliedVolts:Double;public var leakageMicroamps:Double;public var apparentMegohms:Double;public var polarizationIndex:Double;public var unsafeEnergizedTestBlocked:Bool;public var dischargeRequired:Bool }
public enum InsulationMeggerModel {
    public static func advance(spec:InsulationSpec,state:inout InsulationState,testVolts:Double,testSeconds:Double,equipmentEnergized:Bool)->MegohmmeterSnapshot {
        if equipmentEnergized { return .init(appliedVolts:0,leakageMicroamps:0,apparentMegohms:0,polarizationIndex:0,unsafeEnergizedTestBlocked:true,dischargeRequired:false) }
        let tempFactor=pow(0.5,(spec.temperatureC-20)/10);let moisture=max(0.03,1-0.85*spec.moistureFactor);let degrade=max(0.01,1-state.degradation)
        let baseM=max(0.01,spec.initialMegohms*tempFactor*moisture*degrade)
        let absorption=1+0.7*(1-exp(-max(0,testSeconds)/45));let apparent=baseM*absorption
        let leakage=abs(testVolts)/(apparent*1_000_000)*1_000_000
        state.absorbedChargeCoulombs += abs(testVolts)*spec.capacitanceNanofarads*1e-9*(1-exp(-max(0,testSeconds)/8))
        let oneMin=baseM*(1+0.7*(1-exp(-60/45)));let tenMin=baseM*(1+0.7*(1-exp(-600/45)));let pi=tenMin/max(1e-9,oneMin)
        return .init(appliedVolts:testVolts,leakageMicroamps:leakage,apparentMegohms:apparent,polarizationIndex:pi,unsafeEnergizedTestBlocked:false,dischargeRequired:state.absorbedChargeCoulombs>1e-6)
    }
}


public struct InsulationDegradationResult: Codable, Equatable, Sendable { public var degradation:Double;public var estimatedMegohms:Double;public var leakageMicroampsAt500V:Double }
public extension InsulationMeggerModel {
    static func advanceDegradation(spec:InsulationSpec,state:inout InsulationState,elapsedHours:Double,electricalStressPerUnit:Double=1,thermalCycles:Double=0)->InsulationDegradationResult {
        let tempAcceleration=pow(2,max(0,(spec.temperatureC-40)/10));let moistureAcceleration=1+8*max(0,spec.moistureFactor);let stressAcceleration=max(0.1,electricalStressPerUnit*electricalStressPerUnit)
        let increment=max(0,elapsedHours)/100_000*tempAcceleration*moistureAcceleration*stressAcceleration + max(0,thermalCycles)/250_000
        state.degradation=min(0.9999,state.degradation+increment)
        let meg=max(0.01,spec.initialMegohms*(1-state.degradation)*max(0.03,1-0.85*spec.moistureFactor))
        return .init(degradation:state.degradation,estimatedMegohms:meg,leakageMicroampsAt500V:500/meg)
    }
}

// MARK: - Ground / earth fault path

public struct GroundFaultPathSpec: Codable, Equatable, Sendable { public var lineToGroundVolts:Double;public var sourceImpedanceOhms:Double;public var equipmentBondOhms:Double;public var faultResistanceOhms:Double;public var parallelLeakageOhms:Double?;public init(lineToGroundVolts:Double=277,sourceImpedanceOhms:Double=0.1,equipmentBondOhms:Double=0.05,faultResistanceOhms:Double=1,parallelLeakageOhms:Double?=nil){self.lineToGroundVolts=lineToGroundVolts;self.sourceImpedanceOhms=sourceImpedanceOhms;self.equipmentBondOhms=equipmentBondOhms;self.faultResistanceOhms=faultResistanceOhms;self.parallelLeakageOhms=parallelLeakageOhms} }
public struct GroundFaultPathResult: Codable, Equatable, Sendable { public var faultCurrentAmps:Double;public var bondVoltageRise:Double;public var leakageCurrentAmps:Double;public var sourceVoltageCollapse:Double }
public enum GroundFaultPathModel {
    public static func solve(_ spec:GroundFaultPathSpec)->GroundFaultPathResult {
        let series=max(1e-9,spec.sourceImpedanceOhms+spec.equipmentBondOhms+spec.faultResistanceOhms);let fault=abs(spec.lineToGroundVolts)/series
        let leak=spec.parallelLeakageOhms.map{abs(spec.lineToGroundVolts)/max(1e-9,$0)} ?? 0
        return .init(faultCurrentAmps:fault,bondVoltageRise:fault*spec.equipmentBondOhms,leakageCurrentAmps:leak,sourceVoltageCollapse:fault*spec.sourceImpedanceOhms)
    }
}

// MARK: - Short-circuit transient and selective coordination

public struct FaultCurrentSourceSpec: Codable, Equatable, Sendable { public var rmsVolts:Double;public var sourceImpedanceOhms:Double;public var xToR:Double;public var frequencyHz:Double;public init(rmsVolts:Double=480,sourceImpedanceOhms:Double=0.08,xToR:Double=4,frequencyHz:Double=60){self.rmsVolts=rmsVolts;self.sourceImpedanceOhms=sourceImpedanceOhms;self.xToR=xToR;self.frequencyHz=frequencyHz} }
public struct FaultCurrentSnapshot: Codable, Equatable, Sendable { public var symmetricalRMSAmps:Double;public var peakAsymmetricalAmps:Double;public var instantaneousAmps:Double;public var i2t:Double }
public enum ShortCircuitTransientModel {
    public static func sample(spec:FaultCurrentSourceSpec,time:Double,closingAngle:Double=0)->FaultCurrentSnapshot {
        let rms=spec.rmsVolts/max(1e-9,spec.sourceImpedanceOhms);let peak=sqrt(2)*rms*(1+exp(-Double.pi/max(0.01,spec.xToR)))
        let omega=2*Double.pi*spec.frequencyHz;let tau=spec.xToR/omega;let ac=sqrt(2)*rms*sin(omega*time+closingAngle);let dc=sqrt(2)*rms*sin(closingAngle)*exp(-time/max(1e-6,tau));let inst=ac+dc
        return .init(symmetricalRMSAmps:rms,peakAsymmetricalAmps:peak,instantaneousAmps:inst,i2t:rms*rms*max(0,time))
    }
}

public struct CoordinationDevice: Identifiable, Codable, Equatable, Sendable { public var id:String;public var ratedAmps:Double;public var instantaneousMultiple:Double;public var i2tCapacity:Double;public var upstream:Bool;public init(id:String,ratedAmps:Double,instantaneousMultiple:Double=8,i2tCapacity:Double,upstream:Bool=false){self.id=id;self.ratedAmps=ratedAmps;self.instantaneousMultiple=instantaneousMultiple;self.i2tCapacity=i2tCapacity;self.upstream=upstream} }
public struct CoordinationResult: Codable, Equatable, Sendable { public var firstTripDeviceID:String?;public var selective:Bool;public var tripTimes:[String:Double] }
public enum SelectiveCoordinationModel {
    public static func evaluate(devices:[CoordinationDevice],faultRMSAmps:Double)->CoordinationResult {
        var times:[String:Double]=[:]
        for d in devices { let multiple=faultRMSAmps/max(0.001,d.ratedAmps);let t:Double;if multiple>=d.instantaneousMultiple{t=0.008}else if multiple>1{t=d.i2tCapacity/max(1e-9,faultRMSAmps*faultRMSAmps-d.ratedAmps*d.ratedAmps)}else{t=Double.infinity};times[d.id]=t }
        let finite=devices.compactMap{d->(CoordinationDevice,Double)? in guard let t=times[d.id],t.isFinite else{return nil};return(d,t)}.sorted{$0.1<$1.1}
        let first=finite.first?.0;let selective = first.map{!$0.upstream} ?? true
        return .init(firstTripDeviceID:first?.id,selective:selective,tripTimes:times)
    }
}

// MARK: - Oscilloscope / transient recorder

public struct OscilloscopeSample: Codable, Equatable, Sendable { public var time:Double;public var channels:[String:Double] }
public struct OscilloscopeCapture: Codable, Equatable, Sendable {
    public var sampleRateHz:Double;public var triggerChannel:String?;public var triggerLevel:Double?;public var samples:[OscilloscopeSample]
    public init(sampleRateHz:Double=10_000,triggerChannel:String?=nil,triggerLevel:Double?=nil,samples:[OscilloscopeSample]=[]){self.sampleRateHz=sampleRateHz;self.triggerChannel=triggerChannel;self.triggerLevel=triggerLevel;self.samples=samples}
    public func peak(_ channel:String)->Double?{samples.compactMap{$0.channels[channel]}.map(abs).max()}
    public func rms(_ channel:String)->Double?{let v=samples.compactMap{$0.channels[channel]};guard !v.isEmpty else{return nil};return sqrt(v.reduce(0){$0+$1*$1}/Double(v.count))}
}

public struct IndustrialTransientRuntime: Codable, Equatable, Sendable {
    public var elapsedSeconds=0.0
    public var coilSpec=ElectromagneticCoilSpec();public var coilState=ElectromagneticCoilState()
    public var contactSpec=ContactArcSpec();public var contactState=ContactArcState()
    public var motorSpec=InductionMotorTransientSpec();public var motorState=InductionMotorTransientState()
    public var vfdSpec=VFDTransientSpec();public var vfdState=VFDTransientState()
    public var lastCoil:ElectromagneticCoilSnapshot?
    public var lastContact:ContactArcSnapshot?
    public var lastMotor:InductionMotorTransientSnapshot?
    public var lastVFD:VFDTransientSnapshot?
    public var capture=OscilloscopeCapture(sampleRateHz:10_000)
    public init(){}
    public mutating func advance(controlVolts:Double,lineVolts:Double,commandHz:Double,loadTorqueFraction:Double,dt:Double)->OscilloscopeSample {
        elapsedSeconds += dt
        let coil=ElectromagneticCoilModel.advance(spec:coilSpec,state:&coilState,appliedVolts:controlVolts,dt:dt)
        let contact=ContactArcModel.advance(spec:contactSpec,state:&contactState,commandClosed:coil.contactClosed,bouncing:coil.bouncing,sourceVolts:controlVolts,loadResistanceOhms:coilSpec.resistanceOhms,dt:dt)
        let vfd=VFDTransientModel.advance(spec:vfdSpec,state:&vfdState,lineRMSVolts:lineVolts,commandHz:commandHz,loadPowerKW:motorSpec.ratedHP*0.7457*loadTorqueFraction,enable:coil.contactClosed,dt:dt)
        let effectiveLine = vfd.tripped ? 0 : min(lineVolts,max(0,vfd.dcBusVolts/sqrt(2)))
        let motor=InductionMotorTransientModel.advance(spec:motorSpec,state:&motorState,lineVolts:effectiveLine,frequencyHz:vfd.commandedHz,loadTorqueFraction:loadTorqueFraction,dt:dt)
        lastCoil=coil;lastContact=contact;lastMotor=motor;lastVFD=vfd
        let s=OscilloscopeSample(time:elapsedSeconds,channels:["controlV":controlVolts,"coilA":coil.currentAmps,"contactV":contact.voltageDrop,"dcBusV":vfd.dcBusVolts,"motorA":motor.lineCurrentAmps,"motorRPM":motor.speedRPM])
        capture.samples.append(s);if capture.samples.count>20_000{capture.samples.removeFirst(capture.samples.count-20_000)}
        return s
    }
}

// MARK: - Topology-driven transient bridge

public struct TopologyTransientSnapshot: Codable, Equatable, Sendable {
    public var steadyState:CircuitCoupledElectricalSnapshot
    public var transientSample:OscilloscopeSample
    public var scope:OscilloscopeCapture
    public var motorSpeedRPM:Double
    public var dcBusVolts:Double
    public var coilCurrentAmps:Double
}

public struct TopologyTransientElectricalRuntime: Codable, Equatable, Sendable {
    public var circuitRuntime:CircuitCoupledElectricalScenarioRuntime
    public var transient=IndustrialTransientRuntime()
    public init(scenario:TopologyGeneratedScenario){circuitRuntime = .init(scenario:scenario)}
    public mutating func advance(seconds:Double,to machine:inout FullyClosedLoopMachineRuntime,substepSeconds:Double=0.001,commandHz:Double=60,loadTorqueFraction:Double=0.75)->TopologyTransientSnapshot {
        let steady=circuitRuntime.advanceAndApply(seconds:seconds,to:&machine)
        var controlV=0.0
        for (circuitID,snapshot) in steady.circuitSnapshots {
            let net=TopologyCircuitNetlistBuilder.build(scenario:circuitRuntime.scenario,circuitID:circuitID)
            if let coil=net.branches.first(where:{$0.kind == .coil}),let solved=snapshot.solution.branch(coil.id) { controlV=max(controlV,abs(solved.voltageDrop)) }
            else if let source=net.sources.first { controlV=max(controlV,source.nominalVolts*(snapshot.dynamicState.sourceVoltageScale[source.id] ?? 1)) }
        }
        let lineV=480.0
        var remaining=max(0,seconds);var last=OscilloscopeSample(time:transient.elapsedSeconds,channels:[:])
        while remaining>1e-12 {let dt=min(substepSeconds,remaining);last=transient.advance(controlVolts:controlV,lineVolts:lineV,commandHz:commandHz,loadTorqueFraction:loadTorqueFraction,dt:dt);remaining-=dt}
        if let binding=machine.executable.bindings.first(where:{$0.direction == .output}),let circuitID=circuitRuntime.scenario.topology.bindingCircuitIDs[binding.ioTag],let node=circuitRuntime.scenario.topology.circuit(for:binding.ioTag).first {
            func apply(_ kind:AdvancedElectricalFaultKind,_ suffix:String,_ explanation:String) {
                machine.injectTopologyFault(.init(id:"TRANSIENT|\(suffix)|\(binding.ioTag)",kind:kind,machine:circuitRuntime.scenario.machine,circuitID:circuitID,targetNodeID:node.id,targetEdgeID:nil,ioTag:binding.ioTag,fieldDeviceTag:binding.fieldDeviceTag,magnitude:1,intermittent:false,explanation:explanation))
            }
            if transient.lastVFD?.tripped == true { apply(.defaultedVFDParameters,"VFD-TRIP","Transient DC-bus behavior produced a drive trip consequence.") }
            if transient.lastMotor?.stalled == true { apply(.mechanicalOverload,"MOTOR-STALL","Transient torque/slip behavior produced a stalled-motor overload consequence.") }
            if transient.lastContact?.welded == true { apply(.weldedRelay,"CONTACT-WELD","Transient contact energy produced a welded-contact consequence.") }
        }
        return .init(steadyState:steady,transientSample:last,scope:transient.capture,motorSpeedRPM:transient.motorState.speedRPM,dcBusVolts:transient.vfdState.dcBusVolts,coilCurrentAmps:transient.coilState.currentAmps)
    }
}

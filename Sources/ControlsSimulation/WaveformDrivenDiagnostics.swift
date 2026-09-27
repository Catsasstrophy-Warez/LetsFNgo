import Foundation

public struct WaveformSeries: Codable, Equatable, Sendable {
    public var sampleRateHz: Double
    public var samples: [Double]
    public init(sampleRateHz: Double, samples: [Double]) { self.sampleRateHz = sampleRateHz; self.samples = samples }
    public var duration: Double { samples.isEmpty ? 0 : Double(samples.count) / sampleRateHz }
    public var rms: Double { guard !samples.isEmpty else { return 0 }; return sqrt(samples.reduce(0) { $0 + $1*$1 } / Double(samples.count)) }
    public var peak: Double { samples.map(abs).max() ?? 0 }
}

public struct SpectrumBin: Codable, Equatable, Sendable { public var frequencyHz: Double; public var magnitudeRMS: Double; public var phaseRadians: Double }
public struct SpectrumResult: Codable, Equatable, Sendable { public var bins:[SpectrumBin]; public var fundamentalHz:Double; public var fundamentalRMS:Double; public var thdPercent:Double }

public enum WaveformFFTAnalyzer {
    public static func analyze(_ waveform: WaveformSeries, fundamentalHintHz: Double = 60, maxHz: Double? = nil) -> SpectrumResult {
        let n = waveform.samples.count
        guard n > 3 else { return .init(bins:[], fundamentalHz:fundamentalHintHz, fundamentalRMS:0, thdPercent:0) }
        let mean = waveform.samples.reduce(0,+) / Double(n)
        let centered = waveform.samples.map { $0 - mean }
        let nyquist = waveform.sampleRateHz / 2
        let limit = min(maxHz ?? nyquist, nyquist)
        let maxK = min(n/2, Int(floor(limit * Double(n) / waveform.sampleRateHz)))
        var bins:[SpectrumBin] = []
        bins.reserveCapacity(maxK)
        for k in 1...max(1,maxK) {
            var re=0.0, im=0.0
            for i in 0..<n {
                let a = -2 * Double.pi * Double(k*i) / Double(n)
                re += centered[i] * cos(a); im += centered[i] * sin(a)
            }
            let peak = 2 * hypot(re,im) / Double(n)
            bins.append(.init(frequencyHz:Double(k)*waveform.sampleRateHz/Double(n), magnitudeRMS:peak/sqrt(2), phaseRadians:atan2(im,re)))
        }
        let fundamental = bins.min { abs($0.frequencyHz-fundamentalHintHz) < abs($1.frequencyHz-fundamentalHintHz) }
        let f0 = fundamental?.frequencyHz ?? fundamentalHintHz
        let fmag = fundamental?.magnitudeRMS ?? 0
        var harmonicSq=0.0
        if fmag > 1e-12 {
            for h in 2...25 {
                let target=f0*Double(h); if target > limit { break }
                if let b=bins.min(by:{abs($0.frequencyHz-target)<abs($1.frequencyHz-target)}) { harmonicSq += b.magnitudeRMS*b.magnitudeRMS }
            }
        }
        return .init(bins:bins,fundamentalHz:f0,fundamentalRMS:fmag,thdPercent:fmag > 0 ? sqrt(harmonicSq)/fmag*100 : 0)
    }
}

public enum PowerQualityEventKind: String, Codable, CaseIterable, Sendable { case normal, sag, swell, interruption, phaseAngleJump, harmonicDistortion, transient }
public struct PowerQualityEvent: Identifiable, Codable, Equatable, Sendable { public var id:String; public var kind:PowerQualityEventKind; public var startSeconds:Double; public var durationSeconds:Double; public var magnitudePercent:Double; public var phaseAngleDegrees:Double; public var description:String }

public enum PowerQualityAnalyzer {
    public static func detect(rmsWindows:[Double], nominalRMS:Double, windowSeconds:Double, phaseAnglesDegrees:[Double]=[]) -> [PowerQualityEvent] {
        var result:[PowerQualityEvent]=[]
        var active:(PowerQualityEventKind,Int,Double)?
        for i in rmsWindows.indices {
            let pu = nominalRMS > 0 ? rmsWindows[i]/nominalRMS : 0
            let kind:PowerQualityEventKind = pu < 0.1 ? .interruption : pu < 0.9 ? .sag : pu > 1.1 ? .swell : .normal
            if kind != .normal {
                if active == nil { active=(kind,i,pu) }
                else if active!.0 != kind { let a=active!; result.append(event(a.0,a.1,i,a.2,windowSeconds)); active=(kind,i,pu) }
            } else if let a=active { result.append(event(a.0,a.1,i,a.2,windowSeconds)); active=nil }
            if i > 0 && i < phaseAnglesDegrees.count {
                let jump = wrapDegrees(phaseAnglesDegrees[i]-phaseAnglesDegrees[i-1])
                if abs(jump) >= 10 { result.append(.init(id:"ANGLE-\(i)",kind:.phaseAngleJump,startSeconds:Double(i)*windowSeconds,durationSeconds:windowSeconds,magnitudePercent:100,phaseAngleDegrees:jump,description:"Phase-angle jump of \(String(format:"%.1f",jump))°")) }
            }
        }
        if let a=active { result.append(event(a.0,a.1,rmsWindows.count,a.2,windowSeconds)) }
        return result
    }
    private static func event(_ kind:PowerQualityEventKind,_ s:Int,_ e:Int,_ pu:Double,_ dt:Double)->PowerQualityEvent { .init(id:"PQ-\(kind.rawValue)-\(s)",kind:kind,startSeconds:Double(s)*dt,durationSeconds:Double(e-s)*dt,magnitudePercent:pu*100,phaseAngleDegrees:0,description:"\(kind.rawValue) at \(String(format:"%.1f",pu*100))% nominal") }
    private static func wrapDegrees(_ x:Double)->Double { var v=x; while v>180{v-=360}; while v < -180{v+=360}; return v }
}

public struct VFDCommonModeResult: Codable, Equatable, Sendable { public var commonModeVolts:Double; public var dvdtVoltsPerMicrosecond:Double; public var estimatedBearingCurrentAmps:Double; public var cableChargingCurrentAmps:Double }
public enum VFDCommonModeModel {
    public static func evaluate(dcBusVolts:Double, switchingEdgeMicroseconds:Double, motorCableMeters:Double, cableCapacitancePFPerMeter:Double=100, bearingCapacitancePF:Double=100) -> VFDCommonModeResult {
        let cm = dcBusVolts/3
        let dvdt = switchingEdgeMicroseconds > 0 ? dcBusVolts/switchingEdgeMicroseconds : 0
        let cCable = motorCableMeters*cableCapacitancePFPerMeter*1e-12
        let cBearing = bearingCapacitancePF*1e-12
        let dvdts = dvdt*1e6
        return .init(commonModeVolts:cm,dvdtVoltsPerMicrosecond:dvdt,estimatedBearingCurrentAmps:cBearing*dvdts,cableChargingCurrentAmps:cCable*dvdts)
    }
}

public struct ReflectedWaveResult: Codable, Equatable, Sendable { public var reflectionCoefficient:Double; public var motorTerminalPeakVolts:Double; public var roundTripMicroseconds:Double; public var riskIndex:Double }
public enum ReflectedWaveModel {
    public static func evaluate(dcBusVolts:Double,cableMeters:Double,cableImpedanceOhms:Double=50,motorHighFrequencyImpedanceOhms:Double=300,propagationMetersPerMicrosecond:Double=150,riseTimeMicroseconds:Double=0.2)->ReflectedWaveResult {
        let gamma=(motorHighFrequencyImpedanceOhms-cableImpedanceOhms)/(motorHighFrequencyImpedanceOhms+cableImpedanceOhms)
        let rt=2*cableMeters/max(1e-9,propagationMetersPerMicrosecond)
        let overlap=max(0,min(1,1-riseTimeMicroseconds/max(1e-9,rt)))
        let peak=dcBusVolts*(1+gamma*overlap)
        return .init(reflectionCoefficient:gamma,motorTerminalPeakVolts:peak,roundTripMicroseconds:rt,riskIndex:max(0,(peak/dcBusVolts)-1))
    }
}

public struct EMCCouplingResult: Codable, Equatable, Sendable { public var inducedPeakVolts:Double; public var commonModeMilliAmps:Double; public var estimatedSNRdB:Double }
public enum EMCCouplingModel {
    public static func evaluate(aggressorDvdtVPerUs:Double, mutualCapacitancePF:Double, victimImpedanceOhms:Double, signalRMSVolts:Double, shieldEffectivenessDB:Double=0)->EMCCouplingResult {
        let i=mutualCapacitancePF*1e-12*aggressorDvdtVPerUs*1e6
        let attenuation=pow(10,-shieldEffectivenessDB/20)
        let noisePeak=i*victimImpedanceOhms*attenuation
        let noiseRMS=noisePeak/sqrt(2)
        let snr = noiseRMS > 0 ? 20*log10(max(1e-12,signalRMSVolts)/noiseRMS) : 200
        return .init(inducedPeakVolts:noisePeak,commonModeMilliAmps:i*1000,estimatedSNRdB:snr)
    }
}

public struct PulseDistortionResult: Codable, Equatable, Sendable { public var riseTimeMicroseconds:Double; public var thresholdCrossingDelayMicroseconds:Double; public var pulseWidthErrorPercent:Double; public var missedPulse:Bool }
public enum SensorPulseDistortionModel {
    public static func evaluate(sourceResistanceOhms:Double,cableCapacitanceNF:Double,inputThresholdFraction:Double,pulseWidthMicroseconds:Double)->PulseDistortionResult {
        let tauUs=sourceResistanceOhms*cableCapacitanceNF*1e-3
        let rise=2.2*tauUs
        let threshold=max(0.001,min(0.999,inputThresholdFraction))
        let crossing = -tauUs * log(1 - threshold)
        let effective=max(0,pulseWidthMicroseconds-crossing)
        let err=pulseWidthMicroseconds > 0 ? (pulseWidthMicroseconds-effective)/pulseWidthMicroseconds*100 : 100
        return .init(riseTimeMicroseconds:rise,thresholdCrossingDelayMicroseconds:crossing,pulseWidthErrorPercent:err,missedPulse:effective <= 0)
    }
}

public struct SignatureFeatureVector: Codable, Equatable, Sendable { public var rms:Double; public var peak:Double; public var crestFactor:Double; public var thdPercent:Double; public var dominantHz:Double; public var sidebandEnergyRatio:Double; public var transientCount:Int }
public enum SignatureExtractor {
    public static func extract(_ waveform:WaveformSeries,fundamentalHz:Double=60,sidebandAroundHz:Double?=nil)->SignatureFeatureVector {
        let spec=WaveformFFTAnalyzer.analyze(waveform,fundamentalHintHz:fundamentalHz)
        let dominant=spec.bins.max(by:{$0.magnitudeRMS<$1.magnitudeRMS})?.frequencyHz ?? 0
        let side:Double
        if let center=sidebandAroundHz {
            let total=spec.bins.reduce(0){$0+$1.magnitudeRMS*$1.magnitudeRMS}
            let band=spec.bins.filter{abs($0.frequencyHz-center)<=fundamentalHz}.reduce(0){$0+$1.magnitudeRMS*$1.magnitudeRMS}
            side=total > 0 ? band/total : 0
        } else { side=0 }
        let rms=waveform.rms
        let transients=waveform.samples.indices.dropFirst().filter{abs(waveform.samples[$0]-waveform.samples[$0-1]) > max(1e-9,3*rms)}.count
        return .init(rms:rms,peak:waveform.peak,crestFactor:rms>0 ? waveform.peak/rms:0,thdPercent:spec.thdPercent,dominantHz:dominant,sidebandEnergyRatio:side,transientCount:transients)
    }
}

public enum WaveformFaultClass: String, Codable, CaseIterable, Sendable { case healthy, voltageSag, voltageSwell, phaseLoss, harmonicDistortion, bearingDefect, rotorBarDefect, contactBounce, coilChatter, reflectedWave, emcNoise, sensorPulseDistortion, vfdCommonMode, unknown }
public struct WaveformClassification: Codable, Equatable, Sendable { public var faultClass:WaveformFaultClass; public var confidence:Double; public var evidence:[String] }
public enum WaveformFaultClassifier {
    public static func classify(voltage:SignatureFeatureVector,current:SignatureFeatureVector?=nil,nominalVoltageRMS:Double?=nil)->WaveformClassification {
        if let nominal=nominalVoltageRMS, nominal > 0 {
            if voltage.rms < nominal*0.9 { return .init(faultClass:.voltageSag,confidence:min(1,(nominal-voltage.rms)/(nominal*0.2)),evidence:["RMS voltage below 90% nominal"]) }
            if voltage.rms > nominal*1.1 { return .init(faultClass:.voltageSwell,confidence:min(1,(voltage.rms-nominal)/(nominal*0.2)),evidence:["RMS voltage above 110% nominal"]) }
        }
        if voltage.thdPercent > 8 { return .init(faultClass:.harmonicDistortion,confidence:min(1,voltage.thdPercent/20),evidence:["Voltage THD \(String(format:"%.1f",voltage.thdPercent))%"] ) }
        if voltage.transientCount > 8 { return .init(faultClass:.emcNoise,confidence:min(1,Double(voltage.transientCount)/30),evidence:["High impulsive transient count"]) }
        if let c=current, c.sidebandEnergyRatio > 0.2 { return .init(faultClass:.bearingDefect,confidence:min(1,c.sidebandEnergyRatio*2),evidence:["Elevated current-spectrum sideband energy"]) }
        return .init(faultClass:.healthy,confidence:0.8,evidence:["No configured waveform signature exceeded training thresholds"])
    }
}

public struct WaveformComparison: Codable, Equatable, Sendable { public var normalizedRMSError:Double; public var rmsChangePercent:Double; public var thdChangePoints:Double; public var spectralDistance:Double; public var annotations:[String] }
public enum HealthyFaultedWaveformComparator {
    public static func compare(healthy:WaveformSeries,faulted:WaveformSeries,fundamentalHz:Double=60)->WaveformComparison {
        let n=min(healthy.samples.count,faulted.samples.count)
        guard n>0 else{return .init(normalizedRMSError:0,rmsChangePercent:0,thdChangePoints:0,spectralDistance:0,annotations:[])}
        let scale=max(1e-9,healthy.rms)
        let e=sqrt((0..<n).reduce(0){$0+pow(faulted.samples[$1]-healthy.samples[$1],2)}/Double(n))/scale
        let hs=WaveformFFTAnalyzer.analyze(healthy,fundamentalHintHz:fundamentalHz); let fs=WaveformFFTAnalyzer.analyze(faulted,fundamentalHintHz:fundamentalHz)
        let m=min(hs.bins.count,fs.bins.count)
        let sd=m>0 ? sqrt((0..<m).reduce(0){$0+pow(fs.bins[$1].magnitudeRMS-hs.bins[$1].magnitudeRMS,2)}/Double(m))/max(1e-9,hs.fundamentalRMS) : 0
        var notes:[String]=[]; if e>0.1{notes.append("Time-domain waveform materially changed")}; if abs(fs.thdPercent-hs.thdPercent)>2{notes.append("Harmonic content changed")}; if sd>0.1{notes.append("Spectrum differs from healthy baseline")}
        return .init(normalizedRMSError:e,rmsChangePercent:(faulted.rms/scale-1)*100,thdChangePoints:fs.thdPercent-hs.thdPercent,spectralDistance:sd,annotations:notes)
    }
}

public enum TriggerSlope: String, Codable, Sendable { case rising, falling, either }
public struct WaveformTrigger: Codable, Equatable, Sendable { public var channel:String; public var level:Double; public var slope:TriggerSlope; public var pretriggerSamples:Int; public var posttriggerSamples:Int; public init(channel:String,level:Double,slope: TriggerSlope = .rising,pretriggerSamples:Int=100,posttriggerSamples:Int=500){self.channel=channel;self.level=level;self.slope=slope;self.pretriggerSamples=pretriggerSamples;self.posttriggerSamples=posttriggerSamples} }
public enum TransientTriggerEngine {
    public static func capture(from scope:OscilloscopeCapture, trigger:WaveformTrigger)->OscilloscopeCapture? {
        guard scope.samples.count>1 else{return nil}
        for i in 1..<scope.samples.count {
            guard let a=scope.samples[i-1].channels[trigger.channel],let b=scope.samples[i].channels[trigger.channel] else{continue}
            let hit=(trigger.slope == .rising && a<trigger.level && b>=trigger.level)||(trigger.slope == .falling && a>trigger.level && b<=trigger.level)||(trigger.slope == .either && ((a<trigger.level && b>=trigger.level)||(a>trigger.level && b<=trigger.level)))
            if hit { let lo=max(0,i-trigger.pretriggerSamples); let hi=min(scope.samples.count,i+trigger.posttriggerSamples); return .init(sampleRateHz:scope.sampleRateHz,triggerChannel:trigger.channel,triggerLevel:trigger.level,samples:Array(scope.samples[lo..<hi])) }
        }
        return nil
    }
}

public struct MachineWaveformDiagnosticSnapshot: Codable, Equatable, Sendable { public var machine:PlayableMachineKind; public var voltageFeatures:SignatureFeatureVector; public var currentFeatures:SignatureFeatureVector; public var classification:WaveformClassification; public var scope:OscilloscopeCapture }
public enum MachineWaveformDiagnosticEngine {
    public static func synthesize(machine:PlayableMachineKind,seconds:Double=0.2,sampleRateHz:Double=2_000,fault: WaveformFaultClass = .healthy)->MachineWaveformDiagnosticSnapshot {
        let n=max(32,Int(seconds*sampleRateHz)); var v:[Double]=[]; var c:[Double]=[]; v.reserveCapacity(n); c.reserveCapacity(n)
        let nominal=277.0*sqrt(2); let currentPeak=12.0*sqrt(2)
        for i in 0..<n { let t=Double(i)/sampleRateHz; var vv=nominal*sin(2*Double.pi*60*t); var ii=currentPeak*sin(2*Double.pi*60*t-0.25)
            switch fault { case .voltageSag: vv*=0.65; case .voltageSwell: vv*=1.2; case .harmonicDistortion: vv += nominal*0.12*sin(2*Double.pi*180*t)+nominal*0.08*sin(2*Double.pi*300*t); case .bearingDefect: ii += currentPeak*0.3*sin(2*Double.pi*90*t); case .emcNoise: if i%37==0{vv += nominal*0.8}; case .contactBounce: if t>0.05 && t<0.06 { vv *= (i%3==0 ? 0:1) }; default: break }
            v.append(vv); c.append(ii) }
        let vw=WaveformSeries(sampleRateHz:sampleRateHz,samples:v), cw=WaveformSeries(sampleRateHz:sampleRateHz,samples:c)
        let vf=SignatureExtractor.extract(vw), cf=SignatureExtractor.extract(cw,sidebandAroundHz:90)
        let cls=WaveformFaultClassifier.classify(voltage:vf,current:cf,nominalVoltageRMS:277)
        let scope=OscilloscopeCapture(sampleRateHz:sampleRateHz,samples:(0..<n).map{OscilloscopeSample(time:Double($0)/sampleRateHz,channels:["lineV":v[$0],"motorA":c[$0]])})
        return .init(machine:machine,voltageFeatures:vf,currentFeatures:cf,classification:cls,scope:scope)
    }
}

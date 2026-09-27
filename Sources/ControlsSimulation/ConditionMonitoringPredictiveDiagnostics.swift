import Foundation

// MARK: - Persistent condition-monitoring identities and baselines

public enum ConditionOperatingState: String, Codable, CaseIterable, Sendable {
    case stopped, idle, starting, lowLoad, normalProduction, highLoad, changeover, cleaning, degradedProduction
}

public struct ConditionFeatureVector: Codable, Equatable, Sendable {
    public var voltageRMS: Double
    public var currentRMS: Double
    public var voltageTHDPercent: Double
    public var currentTHDPercent: Double
    public var powerFactor: Double
    public var negativeSequencePercent: Double
    public var crestFactor: Double
    public var bearingEnvelopeEnergy: Double
    public var brokenBarSidebandRatio: Double
    public var eccentricitySidebandRatio: Double
    public var temperatureC: Double

    public init(voltageRMS: Double, currentRMS: Double, voltageTHDPercent: Double, currentTHDPercent: Double, powerFactor: Double, negativeSequencePercent: Double, crestFactor: Double, bearingEnvelopeEnergy: Double, brokenBarSidebandRatio: Double, eccentricitySidebandRatio: Double, temperatureC: Double) {
        self.voltageRMS = voltageRMS; self.currentRMS = currentRMS; self.voltageTHDPercent = voltageTHDPercent; self.currentTHDPercent = currentTHDPercent
        self.powerFactor = powerFactor; self.negativeSequencePercent = negativeSequencePercent; self.crestFactor = crestFactor
        self.bearingEnvelopeEnergy = bearingEnvelopeEnergy; self.brokenBarSidebandRatio = brokenBarSidebandRatio; self.eccentricitySidebandRatio = eccentricitySidebandRatio; self.temperatureC = temperatureC
    }

    public var values: [Double] { [voltageRMS,currentRMS,voltageTHDPercent,currentTHDPercent,powerFactor,negativeSequencePercent,crestFactor,bearingEnvelopeEnergy,brokenBarSidebandRatio,eccentricitySidebandRatio,temperatureC] }
}

public struct ConditionBaselineKey: Hashable, Codable, Sendable {
    public var machine: PlayableMachineKind
    public var state: ConditionOperatingState
    public init(machine: PlayableMachineKind, state: ConditionOperatingState) { self.machine = machine; self.state = state }
}

public struct ConditionBaseline: Codable, Equatable, Sendable {
    public var key: ConditionBaselineKey
    public var sampleCount: Int
    public var mean: ConditionFeatureVector
    public var standardDeviation: ConditionFeatureVector
    public var learnedAtHours: Double
    public var lastUpdatedHours: Double
}

public struct BaselineAccumulator: Codable, Equatable, Sendable {
    public var key: ConditionBaselineKey
    public var count: Int = 0
    public var sums: [Double] = Array(repeating: 0, count: 11)
    public var sumSquares: [Double] = Array(repeating: 0, count: 11)
    public var firstHours: Double = 0
    public var lastHours: Double = 0

    public mutating func add(_ f: ConditionFeatureVector, atHours: Double) {
        if count == 0 { firstHours = atHours }
        lastHours = atHours; count += 1
        for i in f.values.indices { sums[i] += f.values[i]; sumSquares[i] += f.values[i] * f.values[i] }
    }

    public func baseline() -> ConditionBaseline? {
        guard count > 0 else { return nil }
        let n = Double(count)
        let mean = sums.map { $0 / n }
        let sd = zip(sums,sumSquares).map { s,q in max(1e-9, q/n - pow(s/n,2)).squareRoot() }
        return .init(key:key,sampleCount:count,mean:Self.vector(mean),standardDeviation:Self.vector(sd),learnedAtHours:firstHours,lastUpdatedHours:lastHours)
    }

    private static func vector(_ v:[Double]) -> ConditionFeatureVector {
        .init(voltageRMS:v[0],currentRMS:v[1],voltageTHDPercent:v[2],currentTHDPercent:v[3],powerFactor:v[4],negativeSequencePercent:v[5],crestFactor:v[6],bearingEnvelopeEnergy:v[7],brokenBarSidebandRatio:v[8],eccentricitySidebandRatio:v[9],temperatureC:v[10])
    }
}

public struct PersistentConditionBaselineStore: Codable, Equatable, Sendable {
    public var accumulators: [ConditionBaselineKey: BaselineAccumulator] = [:]
    public init() {}
    public mutating func learn(machine:PlayableMachineKind,state:ConditionOperatingState,features:ConditionFeatureVector,atHours:Double) {
        let key=ConditionBaselineKey(machine:machine,state:state)
        var a=accumulators[key] ?? .init(key:key)
        a.add(features,atHours:atHours); accumulators[key]=a
    }
    public func baseline(machine:PlayableMachineKind,state:ConditionOperatingState)->ConditionBaseline? { accumulators[.init(machine:machine,state:state)]?.baseline() }
    public var baselines:[ConditionBaseline] { accumulators.values.compactMap{$0.baseline()}.sorted{ $0.key.machine.rawValue+$0.key.state.rawValue < $1.key.machine.rawValue+$1.key.state.rawValue } }
}

// MARK: - Envelope spectrum and order tracking

public struct EnvelopeSpectrumResult: Codable, Equatable, Sendable {
    public var envelope: WaveformSeries
    public var spectrum: SpectrumResult
    public var bandEnergy: Double
}

public enum EnvelopeSpectrumAnalyzer {
    public static func analyze(_ waveform: WaveformSeries, smoothingSamples:Int = 8, maxHz:Double? = nil) -> EnvelopeSpectrumResult {
        guard !waveform.samples.isEmpty else { return .init(envelope:.init(sampleRateHz:waveform.sampleRateHz,samples:[]),spectrum:.init(bins:[],fundamentalHz:0,fundamentalRMS:0,thdPercent:0),bandEnergy:0) }
        let mean=waveform.samples.reduce(0,+)/Double(waveform.samples.count)
        let rectified=waveform.samples.map{abs($0-mean)}
        let w=max(1,smoothingSamples)
        var smooth=[Double](repeating:0,count:rectified.count); var running=0.0
        for i in rectified.indices { running += rectified[i]; if i>=w { running -= rectified[i-w] }; smooth[i]=running/Double(min(i+1,w)) }
        let env=WaveformSeries(sampleRateHz:waveform.sampleRateHz,samples:smooth)
        let spec=WaveformFFTAnalyzer.analyze(env,fundamentalHintHz:max(1,waveform.sampleRateHz/Double(max(4,w))),maxHz:maxHz)
        let energy=spec.bins.reduce(0){$0+$1.magnitudeRMS*$1.magnitudeRMS}
        return .init(envelope:env,spectrum:spec,bandEnergy:energy)
    }
}

public struct OrderSpectrumBin: Codable, Equatable, Sendable { public var order:Double; public var frequencyHz:Double; public var magnitudeRMS:Double }
public struct OrderTrackingResult: Codable, Equatable, Sendable { public var shaftHz:Double; public var bins:[OrderSpectrumBin]; public var dominantOrder:Double }
public enum OrderTracker {
    public static func analyze(_ waveform:WaveformSeries,rpm:Double,maxOrder:Double=20)->OrderTrackingResult {
        let shaft=max(1e-9,rpm/60)
        let spec=WaveformFFTAnalyzer.analyze(waveform,fundamentalHintHz:shaft,maxHz:shaft*maxOrder)
        let bins=spec.bins.map{OrderSpectrumBin(order:$0.frequencyHz/shaft,frequencyHz:$0.frequencyHz,magnitudeRMS:$0.magnitudeRMS)}
        let dominant=bins.max(by:{$0.magnitudeRMS<$1.magnitudeRMS})?.order ?? 0
        return .init(shaftHz:shaft,bins:bins,dominantOrder:dominant)
    }
}

// MARK: - Bearing and motor-current diagnostic frequencies

public struct BearingGeometry: Codable, Equatable, Sendable {
    public var rollingElements:Int; public var ballDiameterMM:Double; public var pitchDiameterMM:Double; public var contactAngleDegrees:Double
    public init(rollingElements:Int=8,ballDiameterMM:Double=10,pitchDiameterMM:Double=50,contactAngleDegrees:Double=0){self.rollingElements=rollingElements;self.ballDiameterMM=ballDiameterMM;self.pitchDiameterMM=pitchDiameterMM;self.contactAngleDegrees=contactAngleDegrees}
}
public struct BearingDefectFrequencies: Codable, Equatable, Sendable { public var shaftHz:Double; public var ftfHz:Double; public var bpfoHz:Double; public var bpfiHz:Double; public var bsfHz:Double }
public enum BearingFrequencyCalculator {
    public static func calculate(rpm:Double,geometry:BearingGeometry)->BearingDefectFrequencies {
        let fr=rpm/60, n=Double(max(1,geometry.rollingElements)), ratio=geometry.ballDiameterMM/max(1e-9,geometry.pitchDiameterMM), c=cos(geometry.contactAngleDegrees*Double.pi/180)
        return .init(shaftHz:fr,ftfHz:0.5*fr*(1-ratio*c),bpfoHz:0.5*n*fr*(1-ratio*c),bpfiHz:0.5*n*fr*(1+ratio*c),bsfHz:0.5*geometry.pitchDiameterMM/max(1e-9,geometry.ballDiameterMM)*fr*(1-pow(ratio*c,2)))
    }
}

public struct MotorSidebandFrequencies: Codable, Equatable, Sendable { public var synchronousRPM:Double; public var slip:Double; public var rotationalHz:Double; public var brokenBarLowerHz:Double; public var brokenBarUpperHz:Double; public var eccentricityLowerHz:Double; public var eccentricityUpperHz:Double }
public enum MotorCurrentSignatureFrequencies {
    public static func calculate(lineHz:Double,poles:Int,rpm:Double)->MotorSidebandFrequencies {
        let sync=120*lineHz/Double(max(2,poles)); let slip=max(0,min(1,(sync-rpm)/sync)); let rot=rpm/60
        return .init(synchronousRPM:sync,slip:slip,rotationalHz:rot,brokenBarLowerHz:lineHz*(1-2*slip),brokenBarUpperHz:lineHz*(1+2*slip),eccentricityLowerHz:max(0,lineHz-rot),eccentricityUpperHz:lineHz+rot)
    }
}

// MARK: - Phasors, symmetrical components, and power

public struct ComplexPhasor: Codable, Equatable, Sendable {
    public var re:Double; public var im:Double
    public init(re:Double,im:Double){self.re=re;self.im=im}
    public init(magnitude:Double,angleDegrees:Double){let a=angleDegrees*Double.pi/180;self.re=magnitude*cos(a);self.im=magnitude*sin(a)}
    public var magnitude:Double{hypot(re,im)}; public var angleDegrees:Double{atan2(im,re)*180/Double.pi}
    public static func +(l:Self,r:Self)->Self{.init(re:l.re+r.re,im:l.im+r.im)}
    public static func -(l:Self,r:Self)->Self{.init(re:l.re-r.re,im:l.im-r.im)}
    public static func *(l:Self,r:Self)->Self{.init(re:l.re*r.re-l.im*r.im,im:l.re*r.im+l.im*r.re)}
    public static func /(l:Self,r:Double)->Self{.init(re:l.re/r,im:l.im/r)}
}

public struct SequenceComponentResult: Codable, Equatable, Sendable { public var zero:ComplexPhasor; public var positive:ComplexPhasor; public var negative:ComplexPhasor; public var negativeSequencePercent:Double; public var zeroSequencePercent:Double }
public enum SymmetricalComponentAnalyzer {
    public static func analyze(a:ComplexPhasor,b:ComplexPhasor,c:ComplexPhasor)->SequenceComponentResult {
        let alpha=ComplexPhasor(magnitude:1,angleDegrees:120), alpha2=ComplexPhasor(magnitude:1,angleDegrees:240)
        let zero=(a+b+c)/3, positive=(a + alpha*b + alpha2*c)/3, negative=(a + alpha2*b + alpha*c)/3
        return .init(zero:zero,positive:positive,negative:negative,negativeSequencePercent:positive.magnitude>0 ? negative.magnitude/positive.magnitude*100:0,zeroSequencePercent:positive.magnitude>0 ? zero.magnitude/positive.magnitude*100:0)
    }
}

public struct ThreePhasePowerResult: Codable, Equatable, Sendable { public var realKW:Double; public var reactiveKVAR:Double; public var apparentKVA:Double; public var powerFactor:Double; public var displacementPowerFactor:Double; public var distortionPowerKVA:Double }
public enum ElectricalPowerAnalyzer {
    public static func threePhase(voltageRMS:Double,currentRMS:Double,phaseAngleDegrees:Double,voltageTHDPercent:Double=0,currentTHDPercent:Double=0)->ThreePhasePowerResult {
        let s=sqrt(3)*voltageRMS*currentRMS/1000, dpf=cos(phaseAngleDegrees*Double.pi/180)
        let distortion=s*sqrt(max(0,pow(voltageTHDPercent/100,2)+pow(currentTHDPercent/100,2)))
        let p=s*dpf/max(1,sqrt((1+pow(voltageTHDPercent/100,2))*(1+pow(currentTHDPercent/100,2))))
        let q=(max(0,s*s-p*p-distortion*distortion)).squareRoot()
        return .init(realKW:p,reactiveKVAR:q,apparentKVA:s,powerFactor:s>0 ? p/s:0,displacementPowerFactor:dpf,distortionPowerKVA:distortion)
    }
}

public struct HarmonicPowerBin: Codable, Equatable, Sendable { public var harmonic:Int; public var frequencyHz:Double; public var realWatts:Double; public var reactiveVAR:Double; public var apparentVA:Double; public var direction:String }
public enum HarmonicPowerFlowAnalyzer {
    public static func analyze(voltage:SpectrumResult,current:SpectrumResult,maxHarmonic:Int=25)->[HarmonicPowerBin] {
        guard voltage.fundamentalHz>0 else{return[]}; var out:[HarmonicPowerBin]=[]
        for h in 1...maxHarmonic { let target=voltage.fundamentalHz*Double(h); guard let v=voltage.bins.min(by:{abs($0.frequencyHz-target)<abs($1.frequencyHz-target)}),let i=current.bins.min(by:{abs($0.frequencyHz-target)<abs($1.frequencyHz-target)}) else{continue}; let phi=i.phaseRadians-v.phaseRadians; let s=v.magnitudeRMS*i.magnitudeRMS; let p=s*cos(phi),q=s*sin(phi); out.append(.init(harmonic:h,frequencyHz:target,realWatts:p,reactiveVAR:q,apparentVA:s,direction:p>=0 ? "source-to-load":"load-to-source")) }
        return out
    }
}

// MARK: - Historian, events, degradation, anomaly detection

public enum ConditionEventSeverity: String, Codable, CaseIterable, Sendable { case information, advisory, warning, alarm, critical }
public struct ConditionHistorianRecord: Identifiable, Codable, Equatable, Sendable {
    public var id:String; public var machine:PlayableMachineKind; public var state:ConditionOperatingState; public var simulatedDay:Double; public var rpm:Double; public var features:ConditionFeatureVector; public var anomalyScore:Double; public var classification:String; public var severity:ConditionEventSeverity
}

public struct ConditionTrendPoint: Codable, Equatable, Sendable { public var simulatedDay:Double; public var value:Double }
public struct DegradationTrajectory: Codable, Equatable, Sendable { public var slopePerDay:Double; public var intercept:Double; public var rSquared:Double; public var projectedThresholdDay:Double?; public var direction:String }
public enum DegradationAnalyzer {
    public static func fit(_ points:[ConditionTrendPoint],threshold:Double?=nil)->DegradationTrajectory {
        guard points.count>=2 else{return .init(slopePerDay:0,intercept:points.first?.value ?? 0,rSquared:0,projectedThresholdDay:nil,direction:"stable")}
        let n=Double(points.count), sx=points.reduce(0){$0+$1.simulatedDay}, sy=points.reduce(0){$0+$1.value}, sxx=points.reduce(0){$0+$1.simulatedDay*$1.simulatedDay}, sxy=points.reduce(0){$0+$1.simulatedDay*$1.value}
        let den=max(1e-12,n*sxx-sx*sx), m=(n*sxy-sx*sy)/den, b=(sy-m*sx)/n, mean=sy/n
        let ssTot=points.reduce(0){$0+pow($1.value-mean,2)}, ssRes=points.reduce(0){$0+pow($1.value-(m*$1.simulatedDay+b),2)}, r2=ssTot>0 ? max(0,1-ssRes/ssTot):1
        var projected:Double?=nil; if let t=threshold,abs(m)>1e-12 { let d=(t-b)/m; if d >= (points.last?.simulatedDay ?? 0) { projected=d } }
        return .init(slopePerDay:m,intercept:b,rSquared:r2,projectedThresholdDay:projected,direction:abs(m)<1e-6 ? "stable":(m>0 ? "increasing":"decreasing"))
    }
}

public struct ConditionAnomalyResult: Codable, Equatable, Sendable { public var score:Double; public var isAnomaly:Bool; public var strongestFeatures:[String]; public var standardizedResiduals:[Double] }
public enum ConditionAnomalyDetector {
    private static let names=["voltage RMS","current RMS","voltage THD","current THD","power factor","negative sequence","crest factor","bearing envelope","broken-bar sideband","eccentricity sideband","temperature"]
    public static func evaluate(features:ConditionFeatureVector,baseline:ConditionBaseline,threshold:Double=3)->ConditionAnomalyResult {
        let x=features.values,m=baseline.mean.values,s=baseline.standardDeviation.values
        let z=x.indices.map{abs(x[$0]-m[$0])/max(s[$0],Self.floorSD(index:$0,mean:m[$0]))}
        let score=(z.map{$0*$0}.reduce(0,+)/Double(z.count)).squareRoot()
        let ranked=z.indices.sorted{z[$0]>z[$1]}.prefix(3).map{names[$0]}
        return .init(score:score,isAnomaly:score>=threshold,strongestFeatures:ranked,standardizedResiduals:z)
    }
    private static func floorSD(index:Int,mean:Double)->Double { max(0.01,abs(mean)*0.01) }
}

// MARK: - Lightweight waveform clustering / operating-regime discovery

public struct ConditionCluster: Identifiable, Codable, Equatable, Sendable { public var id:Int; public var centroid:[Double]; public var memberIndices:[Int] }
public enum ConditionWaveformClusterer {
    public static func cluster(_ features:[ConditionFeatureVector],k:Int,iterations:Int=12)->[ConditionCluster] {
        guard !features.isEmpty else{return[]}; let kk=max(1,min(k,features.count)); let data=features.map{$0.values}; var centroids=(0..<kk).map{data[$0*data.count/kk]}; var assignments=[Int](repeating:0,count:data.count)
        for _ in 0..<iterations { for i in data.indices { assignments[i]=(0..<kk).min(by:{distance(data[i],centroids[$0])<distance(data[i],centroids[$1])}) ?? 0 }; for c in 0..<kk { let members=data.indices.filter{assignments[$0]==c}; if !members.isEmpty { centroids[c]=(0..<data[0].count).map{j in members.reduce(0){$0+data[$1][j]}/Double(members.count)} } } }
        return (0..<kk).map{c in .init(id:c,centroid:centroids[c],memberIndices:data.indices.filter{assignments[$0]==c})}
    }
    private static func distance(_ a:[Double],_ b:[Double])->Double{sqrt(zip(a,b).reduce(0){$0+pow($1.0-$1.1,2)})}
}

// MARK: - Compressed multi-month predictive campaign

public enum PredictiveFaultFamily: String, Codable, CaseIterable, Sendable { case bearingWear, brokenRotorBar, eccentricity, supplyUnbalance, harmonicContamination, insulationAging, looseConnection }
public struct PredictiveCampaignConfiguration: Codable, Equatable, Sendable { public var months:Int; public var samplesPerMonth:Int; public var startingSeverity:Double; public var endingSeverity:Double; public init(months:Int=12,samplesPerMonth:Int=8,startingSeverity:Double=0,endingSeverity:Double=1){self.months=months;self.samplesPerMonth=samplesPerMonth;self.startingSeverity=startingSeverity;self.endingSeverity=endingSeverity} }
public struct PredictiveCampaignSnapshot: Codable, Equatable, Sendable { public var machine:PlayableMachineKind; public var records:[ConditionHistorianRecord]; public var baselines:[ConditionBaseline]; public var firstAdvisoryDay:Double?; public var firstAlarmDay:Double?; public var finalAnomalyScore:Double; public var trajectory:DegradationTrajectory }

public struct ConditionMonitoringRuntime: Codable, Equatable, Sendable {
    public var baselineStore=PersistentConditionBaselineStore()
    public var historian:[ConditionHistorianRecord]=[]
    public init(){}
    public mutating func ingest(machine:PlayableMachineKind,state:ConditionOperatingState,simulatedDay:Double,rpm:Double,features:ConditionFeatureVector,learnHealthy:Bool=false)->ConditionHistorianRecord {
        if learnHealthy { baselineStore.learn(machine:machine,state:state,features:features,atHours:simulatedDay*24) }
        let baseline = baselineStore.baseline(machine: machine, state: state) ?? baselineStore.baseline(machine: machine, state: .normalProduction)
        let anomaly = baseline.map { ConditionAnomalyDetector.evaluate(features: features, baseline: $0) }
        let score=anomaly?.score ?? 0; let severity:ConditionEventSeverity = score>=8 ? .critical : score>=5 ? .alarm : score>=3 ? .warning : score>=2 ? .advisory : .information
        let classification=Self.classify(features:features,anomaly:anomaly)
        let rec=ConditionHistorianRecord(id:"\(machine.rawValue)-\(Int(simulatedDay*1000))-\(historian.count)",machine:machine,state:state,simulatedDay:simulatedDay,rpm:rpm,features:features,anomalyScore:score,classification:classification,severity:severity)
        historian.append(rec); return rec
    }
    public func records(machine:PlayableMachineKind)->[ConditionHistorianRecord]{historian.filter{$0.machine==machine}.sorted{$0.simulatedDay<$1.simulatedDay}}
    private static func classify(features:ConditionFeatureVector,anomaly:ConditionAnomalyResult?)->String {
        if features.bearingEnvelopeEnergy>0.3{return "Bearing defect progression"}; if features.brokenBarSidebandRatio>0.18{return "Broken rotor-bar sidebands"}; if features.eccentricitySidebandRatio>0.18{return "Rotor eccentricity signature"}; if features.negativeSequencePercent>3{return "Supply/current unbalance"}; if features.currentTHDPercent>10 || features.voltageTHDPercent>8{return "Harmonic contamination"}; if let a=anomaly,a.isAnomaly{return "Multivariate anomaly"}; return "Normal for learned operating state"
    }
}

public enum PredictiveConditionCampaign {
    public static func run(machine:PlayableMachineKind,fault:PredictiveFaultFamily,configuration:PredictiveCampaignConfiguration = .init(),seed:UInt64 = 1)->PredictiveCampaignSnapshot {
        var runtime=ConditionMonitoringRuntime(), rng = SeededElectricalRNG(state:seed == 0 ? 1 : seed)
        let state:ConditionOperatingState = .normalProduction
        // Learn a stable operating-state baseline first.
        for i in 0..<24 { let f=features(machine:machine,severity:0,fault:fault,noise:(rng.double()-0.5)*0.02); _=runtime.ingest(machine:machine,state:state,simulatedDay:Double(i)/24,rpm:1760,features:f,learnHealthy:true) }
        let total=max(1,configuration.months*configuration.samplesPerMonth)
        for i in 0..<total { let frac=Double(i)/Double(max(1,total-1)); let sev=configuration.startingSeverity+(configuration.endingSeverity-configuration.startingSeverity)*frac; let day=1+frac*Double(configuration.months)*30; let stateAt:ConditionOperatingState = sev>0.75 ? .degradedProduction : state; let f=features(machine:machine,severity:sev,fault:fault,noise:(rng.double()-0.5)*0.03); _=runtime.ingest(machine:machine,state:stateAt,simulatedDay:day,rpm:1760-sev*40,features:f,learnHealthy:false) }
        let records=runtime.records(machine:machine); let trend=records.filter{$0.simulatedDay>=1}.map{ConditionTrendPoint(simulatedDay:$0.simulatedDay,value:$0.features.bearingEnvelopeEnergy+$0.features.brokenBarSidebandRatio+$0.features.eccentricitySidebandRatio+$0.features.negativeSequencePercent/10+$0.features.currentTHDPercent/50)}
        return .init(machine:machine,records:records,baselines:runtime.baselineStore.baselines,firstAdvisoryDay:records.first(where:{$0.severity == .advisory || $0.severity == .warning || $0.severity == .alarm || $0.severity == .critical})?.simulatedDay,firstAlarmDay:records.first(where:{$0.severity == .alarm || $0.severity == .critical})?.simulatedDay,finalAnomalyScore:records.last?.anomalyScore ?? 0,trajectory:DegradationAnalyzer.fit(trend,threshold:1.2))
    }

    public static func features(machine:PlayableMachineKind,severity:Double,fault:PredictiveFaultFamily,noise:Double=0)->ConditionFeatureVector {
        let s=max(0,min(1,severity)); let machineBias=Double(PlayableMachineKind.allCases.firstIndex(of:machine) ?? 0)/100
        var v=277*(1+noise*0.2), i=11.5*(1+noise), vthd=2.0+abs(noise)*2, ithd=4.0+abs(noise)*2, pf=0.91-noise*0.02, neg=0.5+abs(noise), crest=1.45+abs(noise)*0.1, bearing=0.04+machineBias, broken=0.02, ecc=0.02, temp=42+machineBias*20
        switch fault {
        case .bearingWear: bearing += 0.75*pow(s,1.7); crest += 0.7*s; temp += 22*s
        case .brokenRotorBar: broken += 0.55*pow(s,1.4); i *= 1+0.12*s; temp += 16*s
        case .eccentricity: ecc += 0.6*pow(s,1.5); i *= 1+0.08*s
        case .supplyUnbalance: neg += 9*s; i *= 1+0.18*s; temp += 20*s
        case .harmonicContamination: vthd += 14*s; ithd += 24*s; pf -= 0.18*s
        case .insulationAging: temp += 18*s; crest += 0.25*s; ithd += 6*s
        case .looseConnection: v *= 1-0.08*s; i *= 1-0.05*s; temp += 35*s; vthd += 5*s
        }
        return .init(voltageRMS:v,currentRMS:i,voltageTHDPercent:vthd,currentTHDPercent:ithd,powerFactor:max(0,pf),negativeSequencePercent:neg,crestFactor:crest,bearingEnvelopeEnergy:bearing,brokenBarSidebandRatio:broken,eccentricitySidebandRatio:ecc,temperatureC:temp)
    }
}

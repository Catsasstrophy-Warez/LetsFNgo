import XCTest
@testable import ControlsSimulation

final class ConditionMonitoringPredictiveDiagnosticsTests: XCTestCase {
    func testPersistentBaselineIsOperatingStateSpecific() {
        var store=PersistentConditionBaselineStore()
        let f=PredictiveConditionCampaign.features(machine:.packagingCell,severity:0,fault:.bearingWear)
        for i in 0..<20 { store.learn(machine:.packagingCell,state:.normalProduction,features:f,atHours:Double(i)) }
        XCTAssertNotNil(store.baseline(machine:.packagingCell,state:.normalProduction))
        XCTAssertNil(store.baseline(machine:.packagingCell,state:.highLoad))
        XCTAssertEqual(store.baseline(machine:.packagingCell,state:.normalProduction)?.sampleCount,20)
    }

    func testEnvelopeSpectrumFindsModulationEnergy() {
        let fs=4000.0, n=4000
        let samples=(0..<n).map { i -> Double in let t=Double(i)/fs; return (1+0.45*sin(2*Double.pi*30*t))*sin(2*Double.pi*700*t) }
        let result=EnvelopeSpectrumAnalyzer.analyze(.init(sampleRateHz:fs,samples:samples),smoothingSamples:4,maxHz:200)
        XCTAssertGreaterThan(result.bandEnergy,0)
        let near30=result.spectrum.bins.min(by:{abs($0.frequencyHz-30)<abs($1.frequencyHz-30)})
        XCTAssertGreaterThan(near30?.magnitudeRMS ?? 0,0.01)
    }

    func testOrderTrackingNormalizesFrequencyByRPM() {
        let fs=2000.0, rpm=1800.0, shaft=rpm/60
        let w=WaveformSeries(sampleRateHz:fs,samples:(0..<2000).map{sin(2*Double.pi*(3*shaft)*Double($0)/fs)})
        let o=OrderTracker.analyze(w,rpm:rpm,maxOrder:8)
        XCTAssertEqual(o.dominantOrder,3,accuracy:0.1)
    }

    func testBearingDefectFrequenciesArePhysicallyOrdered() {
        let f=BearingFrequencyCalculator.calculate(rpm:1800,geometry:.init(rollingElements:8,ballDiameterMM:10,pitchDiameterMM:50))
        XCTAssertGreaterThan(f.bpfiHz,f.bpfoHz)
        XCTAssertGreaterThan(f.bpfoHz,f.shaftHz)
        XCTAssertLessThan(f.ftfHz,f.shaftHz)
        XCTAssertGreaterThan(f.bsfHz,f.shaftHz)
    }

    func testBrokenBarSidebandsStraddleLineFrequency() {
        let s=MotorCurrentSignatureFrequencies.calculate(lineHz:60,poles:4,rpm:1710)
        XCTAssertLessThan(s.brokenBarLowerHz,60)
        XCTAssertGreaterThan(s.brokenBarUpperHz,60)
        XCTAssertEqual(s.slip,0.05,accuracy:0.002)
    }

    func testSymmetricalComponentsRecognizeBalancedSystem() {
        let r=SymmetricalComponentAnalyzer.analyze(a:.init(magnitude:277,angleDegrees:0),b:.init(magnitude:277,angleDegrees:-120),c:.init(magnitude:277,angleDegrees:120))
        XCTAssertGreaterThan(r.positive.magnitude,270)
        XCTAssertLessThan(r.negativeSequencePercent,0.01)
        XCTAssertLessThan(r.zeroSequencePercent,0.01)
    }

    func testNegativeSequenceRisesWithPhaseMagnitudeError() {
        let r=SymmetricalComponentAnalyzer.analyze(a:.init(magnitude:277,angleDegrees:0),b:.init(magnitude:220,angleDegrees:-120),c:.init(magnitude:277,angleDegrees:120))
        XCTAssertGreaterThan(r.negativeSequencePercent,2)
    }

    func testPowerAnalyzerSeparatesRealReactiveAndDistortionPower() {
        let p=ElectricalPowerAnalyzer.threePhase(voltageRMS:480,currentRMS:20,phaseAngleDegrees:30,voltageTHDPercent:5,currentTHDPercent:18)
        XCTAssertGreaterThan(p.apparentKVA,p.realKW)
        XCTAssertGreaterThan(p.reactiveKVAR,0)
        XCTAssertGreaterThan(p.distortionPowerKVA,0)
        XCTAssertLessThan(p.powerFactor,p.displacementPowerFactor)
    }

    func testHarmonicPowerFlowCreatesPerHarmonicBins() {
        let fs=6000.0,n=6000
        let v=WaveformSeries(sampleRateHz:fs,samples:(0..<n).map{let t=Double($0)/fs; return 100*sin(2*Double.pi*60*t)+15*sin(2*Double.pi*180*t)})
        let i=WaveformSeries(sampleRateHz:fs,samples:(0..<n).map{let t=Double($0)/fs; return 10*sin(2*Double.pi*60*t-0.2)+3*sin(2*Double.pi*180*t+0.4)})
        let bins=HarmonicPowerFlowAnalyzer.analyze(voltage:WaveformFFTAnalyzer.analyze(v),current:WaveformFFTAnalyzer.analyze(i),maxHarmonic:5)
        XCTAssertGreaterThanOrEqual(bins.count,5)
        XCTAssertGreaterThan(bins.first(where:{$0.harmonic==3})?.apparentVA ?? 0,1)
    }

    func testAnomalyDetectorUsesLearnedBaseline() {
        var store=PersistentConditionBaselineStore()
        for i in 0..<30 { let f=PredictiveConditionCampaign.features(machine:.pumpStation,severity:0,fault:.bearingWear,noise:Double(i%3-1)*0.003); store.learn(machine:.pumpStation,state:.normalProduction,features:f,atHours:Double(i)) }
        let b=store.baseline(machine:.pumpStation,state:.normalProduction)!
        let bad=PredictiveConditionCampaign.features(machine:.pumpStation,severity:0.9,fault:.bearingWear)
        let a=ConditionAnomalyDetector.evaluate(features:bad,baseline:b)
        XCTAssertTrue(a.isAnomaly)
        XCTAssertTrue(a.strongestFeatures.contains("bearing envelope"))
    }

    func testClusteringSeparatesHealthyAndDegradedPopulations() {
        let healthy=(0..<8).map{PredictiveConditionCampaign.features(machine:.packagingCell,severity:0,fault:.bearingWear,noise:Double($0)*0.001)}
        let bad=(0..<8).map{PredictiveConditionCampaign.features(machine:.packagingCell,severity:0.9,fault:.bearingWear,noise:Double($0)*0.001)}
        let c=ConditionWaveformClusterer.cluster(healthy+bad,k:2)
        XCTAssertEqual(c.count,2)
        XCTAssertTrue(c.allSatisfy{$0.memberIndices.count>=6})
    }

    func testDegradationTrajectoryProjectsThreshold() {
        let pts=(0..<10).map{ConditionTrendPoint(simulatedDay:Double($0)*10,value:0.1+Double($0)*0.08)}
        let t=DegradationAnalyzer.fit(pts,threshold:1.0)
        XCTAssertGreaterThan(t.slopePerDay,0)
        XCTAssertGreaterThan(t.rSquared,0.99)
        XCTAssertNotNil(t.projectedThresholdDay)
    }

    func testCompressedMonthsHistorianDetectsDeterioration() {
        let c=PredictiveConditionCampaign.run(machine:.servoConveyor,fault:.bearingWear,configuration:.init(months:12,samplesPerMonth:8),seed:9)
        XCTAssertGreaterThan(c.records.count,100)
        XCTAssertNotNil(c.firstAdvisoryDay)
        XCTAssertGreaterThan(c.finalAnomalyScore,3)
        XCTAssertGreaterThan(c.trajectory.slopePerDay,0)
    }

    func testAll28MachinesCanRunPredictiveCampaigns() {
        XCTAssertEqual(PlayableMachineKind.allCases.count,28)
        for (i,m) in PlayableMachineKind.allCases.enumerated() {
            let fault=PredictiveFaultFamily.allCases[i % PredictiveFaultFamily.allCases.count]
            let c=PredictiveConditionCampaign.run(machine:m,fault:fault,configuration:.init(months:3,samplesPerMonth:3),seed:UInt64(i+1))
            XCTAssertFalse(c.records.isEmpty,m.rawValue)
            XCTAssertEqual(c.baselines.first?.key.machine,m)
            XCTAssertGreaterThanOrEqual(c.finalAnomalyScore,0)
        }
    }

    func testConditionRuntimeCodableRoundTripPreservesHistorianAndBaselines() throws {
        var r=ConditionMonitoringRuntime(); let f=PredictiveConditionCampaign.features(machine:.chilledWaterPlant,severity:0,fault:.harmonicContamination)
        _=r.ingest(machine:.chilledWaterPlant,state:.normalProduction,simulatedDay:0,rpm:1750,features:f,learnHealthy:true)
        _=r.ingest(machine:.chilledWaterPlant,state:.normalProduction,simulatedDay:30,rpm:1750,features:PredictiveConditionCampaign.features(machine:.chilledWaterPlant,severity:0.7,fault:.harmonicContamination))
        let data=try JSONEncoder().encode(r); let back=try JSONDecoder().decode(ConditionMonitoringRuntime.self,from:data)
        XCTAssertEqual(back,r)
    }
}

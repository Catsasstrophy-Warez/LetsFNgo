import Foundation
import ControlsPLC

// MARK: - Compact industrial circuit state solver

public enum CircuitBranchKind: String, Codable, CaseIterable, Sendable {
    case conductor, resistor, coil, contact, heater, sensorInput, leakage, groundFault, loopLoad, motorWinding
}

public struct CircuitNodeSpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var fixedPotential: Double?
    public var isGround: Bool
    public init(id: String, label: String, fixedPotential: Double? = nil, isGround: Bool = false) {
        self.id = id; self.label = label; self.fixedPotential = fixedPotential; self.isGround = isGround
    }
}

public struct CircuitBranchSpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var fromNodeID: String
    public var toNodeID: String
    public var kind: CircuitBranchKind
    public var baseResistanceOhms: Double
    public var enabled: Bool
    public var temperatureCoefficientPerC: Double
    public init(id: String, fromNodeID: String, toNodeID: String, kind: CircuitBranchKind = .conductor, baseResistanceOhms: Double, enabled: Bool = true, temperatureCoefficientPerC: Double = 0.00393) {
        self.id=id; self.fromNodeID=fromNodeID; self.toNodeID=toNodeID; self.kind=kind
        self.baseResistanceOhms=max(1e-9,baseResistanceOhms); self.enabled=enabled; self.temperatureCoefficientPerC=temperatureCoefficientPerC
    }
}

public struct CircuitVoltageSource: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var positiveNodeID: String
    public var negativeNodeID: String
    public var nominalVolts: Double
    public var internalResistanceOhms: Double
    public var currentLimitAmps: Double?
    public var foldbackVolts: Double
    public init(id: String, positiveNodeID: String, negativeNodeID: String, nominalVolts: Double, internalResistanceOhms: Double = 0.08, currentLimitAmps: Double? = nil, foldbackVolts: Double = 2) {
        self.id=id; self.positiveNodeID=positiveNodeID; self.negativeNodeID=negativeNodeID; self.nominalVolts=nominalVolts
        self.internalResistanceOhms=max(1e-6,internalResistanceOhms); self.currentLimitAmps=currentLimitAmps; self.foldbackVolts=foldbackVolts
    }
}

public struct CircuitThermalSpec: Codable, Equatable, Sendable {
    public var branchID: String
    public var thermalMassJPerC: Double
    public var thermalResistanceCPerW: Double
    public var warningTemperatureC: Double
    public var failureTemperatureC: Double
    public init(branchID: String, thermalMassJPerC: Double = 18, thermalResistanceCPerW: Double = 12, warningTemperatureC: Double = 75, failureTemperatureC: Double = 125) {
        self.branchID=branchID; self.thermalMassJPerC=max(0.1,thermalMassJPerC); self.thermalResistanceCPerW=max(0.01,thermalResistanceCPerW)
        self.warningTemperatureC=warningTemperatureC; self.failureTemperatureC=failureTemperatureC
    }
}

public enum ProtectionDeviceKind: String, Codable, CaseIterable, Sendable { case fuse, thermalMagneticBreaker }

public struct ProtectionDeviceSpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var branchID: String
    public var kind: ProtectionDeviceKind
    public var ratedAmps: Double
    public var magneticPickupMultiple: Double
    public var i2tCapacity: Double
    public init(id: String, branchID: String, kind: ProtectionDeviceKind = .fuse, ratedAmps: Double, magneticPickupMultiple: Double = 8, i2tCapacity: Double? = nil) {
        self.id=id; self.branchID=branchID; self.kind=kind; self.ratedAmps=max(0.01,ratedAmps); self.magneticPickupMultiple=max(1.1,magneticPickupMultiple)
        self.i2tCapacity=i2tCapacity ?? max(0.02, ratedAmps * ratedAmps * 4)
    }
}

public struct CircuitNetlist: Codable, Equatable, Sendable {
    public var nodes: [CircuitNodeSpec]
    public var branches: [CircuitBranchSpec]
    public var sources: [CircuitVoltageSource]
    public var thermal: [CircuitThermalSpec]
    public var protection: [ProtectionDeviceSpec]
    public init(nodes:[CircuitNodeSpec],branches:[CircuitBranchSpec],sources:[CircuitVoltageSource]=[],thermal:[CircuitThermalSpec]=[],protection:[ProtectionDeviceSpec]=[]) {
        self.nodes=nodes; self.branches=branches; self.sources=sources; self.thermal=thermal; self.protection=protection
    }
}

public struct CircuitThermalState: Codable, Equatable, Sendable {
    public var temperatureC: Double
    public var damage: Double
    public var failed: Bool
    public init(temperatureC:Double=25,damage:Double=0,failed:Bool=false){self.temperatureC=temperatureC;self.damage=damage;self.failed=failed}
}

public struct ProtectionDeviceState: Codable, Equatable, Sendable {
    public var accumulatedI2t: Double
    public var tripped: Bool
    public var tripReason: String?
    public init(accumulatedI2t:Double=0,tripped:Bool=false,tripReason:String?=nil){self.accumulatedI2t=accumulatedI2t;self.tripped=tripped;self.tripReason=tripReason}
}

public struct CircuitDynamicState: Codable, Equatable, Sendable {
    public var thermalByBranch: [String:CircuitThermalState]
    public var protectionByID: [String:ProtectionDeviceState]
    public var sourceVoltageScale: [String:Double]
    public init(thermalByBranch:[String:CircuitThermalState]=[:],protectionByID:[String:ProtectionDeviceState]=[:],sourceVoltageScale:[String:Double]=[:]) {
        self.thermalByBranch=thermalByBranch;self.protectionByID=protectionByID;self.sourceVoltageScale=sourceVoltageScale
    }
}

public struct CircuitSolvedBranch: Codable, Equatable, Sendable {
    public var id:String; public var currentAmps:Double; public var voltageDrop:Double; public var resistanceOhms:Double; public var powerWatts:Double
}

public struct CircuitSolution: Codable, Equatable, Sendable {
    public var nodeVoltages:[String:Double]
    public var branches:[CircuitSolvedBranch]
    public var sourceCurrents:[String:Double]
    public var sourceLimited:[String:Bool]
    public var converged:Bool
    public func voltage(_ id:String)->Double?{nodeVoltages[id]}
    public func branch(_ id:String)->CircuitSolvedBranch?{branches.first{$0.id==id}}
}

public enum IndustrialCircuitSolver {
    public static func solve(_ netlist:CircuitNetlist,state:CircuitDynamicState = .init(),maxIterations:Int=12)->CircuitSolution {
        var scales=state.sourceVoltageScale
        for s in netlist.sources where scales[s.id] == nil { scales[s.id]=1 }
        var last = CircuitSolution(nodeVoltages:[:],branches:[],sourceCurrents:[:],sourceLimited:[:],converged:false)
        for _ in 0..<maxIterations {
            last = solveLinear(netlist,state:state,sourceScales:scales)
            var changed=false
            for source in netlist.sources {
                guard let limit=source.currentLimitAmps, let i=last.sourceCurrents[source.id], abs(i)>limit*1.0001 else { continue }
                let old=scales[source.id] ?? 1
                let ratio=max(source.foldbackVolts/max(0.001,source.nominalVolts), min(1,limit/max(abs(i),1e-9)))
                let next=max(source.foldbackVolts/max(0.001,source.nominalVolts),old*ratio)
                if abs(next-old)>1e-5 { scales[source.id]=next;changed=true }
            }
            if !changed { last.converged=true; break }
        }
        var limited:[String:Bool]=[:]
        for s in netlist.sources { limited[s.id] = (scales[s.id] ?? 1) < 0.999 }
        last.sourceLimited=limited
        return last
    }

    private static func solveLinear(_ netlist:CircuitNetlist,state:CircuitDynamicState,sourceScales:[String:Double])->CircuitSolution {
        let groundIDs=Set(netlist.nodes.filter{$0.isGround}.map(\.id))
        let fixed=Dictionary(uniqueKeysWithValues:netlist.nodes.compactMap{ n -> (String,Double)? in
            if n.isGround { return (n.id,0) }; if let v=n.fixedPotential{return(n.id,v)};return nil
        })
        let unknown=netlist.nodes.map(\.id).filter{fixed[$0]==nil}
        let index=Dictionary(uniqueKeysWithValues:unknown.enumerated().map{($1,$0)})
        let n=unknown.count
        var A=Array(repeating:Array(repeating:0.0,count:n),count:n);var z=Array(repeating:0.0,count:n)
        func stampConductance(_ a:String,_ b:String,_ g:Double) {
            if let ia=index[a] { A[ia][ia]+=g; if let ib=index[b]{A[ia][ib]-=g}else if let vb=fixed[b]{z[ia]+=g*vb} }
            if let ib=index[b] { A[ib][ib]+=g; if let ia=index[a]{A[ib][ia]-=g}else if let va=fixed[a]{z[ib]+=g*va} }
        }
        var effectiveR:[String:Double]=[:]
        for b in netlist.branches {
            let failed=state.thermalByBranch[b.id]?.failed ?? false
            let protectedOpen=netlist.protection.filter{$0.branchID==b.id}.contains{state.protectionByID[$0.id]?.tripped ?? false}
            guard b.enabled && !failed && !protectedOpen else { effectiveR[b.id]=1e12; continue }
            let temp=state.thermalByBranch[b.id]?.temperatureC ?? 25
            let r=max(1e-9,b.baseResistanceOhms*(1+b.temperatureCoefficientPerC*(temp-25)))
            effectiveR[b.id]=r;stampConductance(b.fromNodeID,b.toNodeID,1/r)
        }
        // Voltage sources use a Norton equivalent; this supports finite source impedance and current-limit foldback.
        for s in netlist.sources {
            let g=1/s.internalResistanceOhms; stampConductance(s.positiveNodeID,s.negativeNodeID,g)
            let volts=s.nominalVolts*(sourceScales[s.id] ?? 1); let current=volts*g
            if let ip=index[s.positiveNodeID]{z[ip]+=current};if let im=index[s.negativeNodeID]{z[im]-=current}
        }
        for i in 0..<n where abs(A[i][i])<1e-15 { A[i][i]=1e-12 }
        let x=gaussian(A,z)
        var voltages=fixed;for (id,i) in index{voltages[id]=x[i]}
        for id in groundIDs {voltages[id]=0}
        var solved:[CircuitSolvedBranch]=[]
        for b in netlist.branches {
            let r=effectiveR[b.id] ?? 1e12; let dv=(voltages[b.fromNodeID] ?? 0)-(voltages[b.toNodeID] ?? 0);let i=dv/r
            solved.append(.init(id:b.id,currentAmps:i,voltageDrop:dv,resistanceOhms:r,powerWatts:i*i*r))
        }
        var sourceI:[String:Double]=[:]
        for s in netlist.sources {
            let vp=voltages[s.positiveNodeID] ?? 0, vn=voltages[s.negativeNodeID] ?? 0
            let internalV=s.nominalVolts*(sourceScales[s.id] ?? 1); sourceI[s.id]=(internalV-(vp-vn))/s.internalResistanceOhms
        }
        return .init(nodeVoltages:voltages,branches:solved,sourceCurrents:sourceI,sourceLimited:[:],converged:true)
    }

    private static func gaussian(_ matrix:[[Double]],_ rhs:[Double])->[Double] {
        var a=matrix; var b=rhs; let n=b.count; if n==0{return[]}
        for k in 0..<n {
            var pivot=k;for i in k..<n where abs(a[i][k])>abs(a[pivot][k]){pivot=i}
            if pivot != k {a.swapAt(pivot,k);b.swapAt(pivot,k)}
            let p=a[k][k];if abs(p)<1e-18{continue}
            for i in (k+1)..<n {let f=a[i][k]/p;if abs(f)<1e-20{continue};for j in k..<n{a[i][j]-=f*a[k][j]};b[i]-=f*b[k]}
        }
        var x=Array(repeating:0.0,count:n)
        for i in stride(from:n-1,through:0,by:-1){var sum=b[i];if i+1<n{for j in (i+1)..<n{sum-=a[i][j]*x[j]}};x[i]=abs(a[i][i])<1e-18 ? 0:sum/a[i][i]}
        return x
    }

    public static func advance(_ netlist:CircuitNetlist,state:inout CircuitDynamicState,dtSeconds:Double,ambientC:Double=25)->CircuitSolution {
        let solution=solve(netlist,state:state)
        for spec in netlist.thermal {
            guard let branch=solution.branch(spec.branchID) else{continue}
            var t=state.thermalByBranch[spec.branchID] ?? .init(temperatureC:ambientC)
            let cooling=(t.temperatureC-ambientC)/spec.thermalResistanceCPerW
            t.temperatureC += (branch.powerWatts-cooling)*dtSeconds/spec.thermalMassJPerC
            if t.temperatureC>spec.warningTemperatureC { t.damage=min(1,t.damage + (t.temperatureC-spec.warningTemperatureC)/max(1,spec.failureTemperatureC-spec.warningTemperatureC)*dtSeconds/120) }
            if t.temperatureC>=spec.failureTemperatureC || t.damage>=1 {t.failed=true}
            state.thermalByBranch[spec.branchID]=t
        }
        for spec in netlist.protection {
            guard let branch=solution.branch(spec.branchID) else{continue};var p=state.protectionByID[spec.id] ?? .init();if p.tripped{continue}
            let amps=abs(branch.currentAmps),multiple=amps/spec.ratedAmps
            if spec.kind == .thermalMagneticBreaker && multiple>=spec.magneticPickupMultiple {p.tripped=true;p.tripReason="Magnetic pickup"}
            else if multiple>1 {p.accumulatedI2t += max(0,amps*amps-spec.ratedAmps*spec.ratedAmps)*dtSeconds;if p.accumulatedI2t>=spec.i2tCapacity{p.tripped=true;p.tripReason=spec.kind == .fuse ? "Fuse I²t exceeded":"Thermal trip"}}
            else {p.accumulatedI2t=max(0,p.accumulatedI2t-dtSeconds*spec.ratedAmps*spec.ratedAmps*0.05)}
            state.protectionByID[spec.id]=p
        }
        return solve(netlist,state:state)
    }
}

// MARK: - Transformer and three-phase behavior

public struct TransformerStateResult: Codable, Equatable, Sendable {
    public var secondaryVolts:Double;public var secondaryCurrentAmps:Double;public var loadVA:Double;public var loadingPercent:Double;public var copperLossWatts:Double;public var overloaded:Bool
}

public enum TransformerModel {
    public static func solve(primaryVolts:Double,ratioPrimaryToSecondary:Double,ratedVA:Double,secondaryLoadOhms:Double,windingResistanceOhms:Double=0.35)->TransformerStateResult {
        let open=primaryVolts/max(1e-9,ratioPrimaryToSecondary);let current=open/max(1e-9,secondaryLoadOhms+windingResistanceOhms);let v=current*secondaryLoadOhms;let va=abs(v*current)
        return .init(secondaryVolts:v,secondaryCurrentAmps:current,loadVA:va,loadingPercent:100*va/max(1e-9,ratedVA),copperLossWatts:current*current*windingResistanceOhms,overloaded:va>ratedVA)
    }
}

public struct ThreePhaseMotorSpec: Codable, Equatable, Sendable {
    public var ratedLineVolts:Double;public var ratedHP:Double;public var efficiency:Double;public var powerFactor:Double;public var lockedRotorMultiple:Double;public var phaseResistanceOhms:Double
    public init(ratedLineVolts:Double=480,ratedHP:Double,efficiency:Double=0.9,powerFactor:Double=0.85,lockedRotorMultiple:Double=6,phaseResistanceOhms:Double=0.7){self.ratedLineVolts=ratedLineVolts;self.ratedHP=ratedHP;self.efficiency=efficiency;self.powerFactor=powerFactor;self.lockedRotorMultiple=lockedRotorMultiple;self.phaseResistanceOhms=phaseResistanceOhms}
}
public struct ThreePhaseMotorState: Codable, Equatable, Sendable {
    public var phaseCurrents:[Double];public var averageCurrent:Double;public var voltageImbalancePercent:Double;public var currentImbalancePercent:Double;public var inputKW:Double;public var copperLossWatts:Double;public var torqueFraction:Double;public var phaseLoss:Bool;public var thermalStress:Double
}
public enum ThreePhaseMotorModel {
    public static func solve(spec:ThreePhaseMotorSpec,lineToLineVolts:[Double],loadFraction:Double=1,phaseOpen:Int?=nil)->ThreePhaseMotorState {
        let volts=Array((lineToLineVolts + Array(repeating:spec.ratedLineVolts,count:3)).prefix(3));let avgV=volts.reduce(0,+)/3
        let vimb=avgV==0 ? 100:100*(volts.map{abs($0-avgV)}.max() ?? 0)/avgV
        let ratedKW=spec.ratedHP*0.7457;let ratedI=ratedKW*1000/max(1,sqrt(3)*spec.ratedLineVolts*spec.efficiency*spec.powerFactor)
        var currents=volts.map{ratedI*max(0.05,loadFraction)*spec.ratedLineVolts/max(1,$0)}
        if let p=phaseOpen,p>=0,p<3 {currents[p]=0;for i in 0..<3 where i != p{currents[i]*=1.73}}
        let avgI=currents.reduce(0,+)/3;let iimb=avgI==0 ? 100:100*(currents.map{abs($0-avgI)}.max() ?? 0)/avgI
        let phaseLoss=currents.contains{$0<0.1*max(0.001,currents.max() ?? 0)}
        let torque=max(0,min(1.3,pow(avgV/spec.ratedLineVolts,2)*(phaseLoss ? 0.45:1)*loadFraction))
        let input=sqrt(3)*avgV*avgI*spec.powerFactor/1000;let copper=currents.reduce(0){$0+$1*$1*spec.phaseResistanceOhms};let stress=max(0,(avgI/max(0.001,ratedI)-1))+vimb/100+(phaseLoss ? 1:0)
        return .init(phaseCurrents:currents,averageCurrent:avgI,voltageImbalancePercent:vimb,currentImbalancePercent:iimb,inputKW:input,copperLossWatts:copper,torqueFraction:torque,phaseLoss:phaseLoss,thermalStress:stress)
    }
}

// MARK: - Instrumentation and analog loop physics

public struct CurrentLoopResult: Codable, Equatable, Sendable {
    public var requestedMilliamps:Double;public var actualMilliamps:Double;public var requiredComplianceVolts:Double;public var availableComplianceVolts:Double;public var transmitterHeadroomVolts:Double;public var inCompliance:Bool;public var receiverVolts:Double
}
public enum CurrentLoopModel {
    public static func solve(supplyVolts:Double,requestedMilliamps:Double,receiverOhms:Double=250,wireOhms:Double=10,barrierDropVolts:Double=0,minimumTransmitterVolts:Double=10)->CurrentLoopResult {
        let requested=max(0,requestedMilliamps)/1000;let fixed=barrierDropVolts+minimumTransmitterVolts;let resist=receiverOhms+wireOhms;let required=fixed+requested*resist
        let possible=max(0,(supplyVolts-fixed)/max(1e-9,resist));let actual=min(requested,possible);let head=supplyVolts-barrierDropVolts-actual*resist
        return .init(requestedMilliamps:requestedMilliamps,actualMilliamps:actual*1000,requiredComplianceVolts:required,availableComplianceVolts:supplyVolts,transmitterHeadroomVolts:head,inCompliance:required<=supplyVolts+1e-9,receiverVolts:actual*receiverOhms)
    }
}

public struct AnalogInputResult: Codable, Equatable, Sendable {
    public var sensedVolts:Double;public var commonModeVolts:Double;public var loadedSourceVolts:Double;public var commonModeValid:Bool;public var isolationValid:Bool;public var saturated:Bool
}
public enum AnalogInputModel {
    public static func solve(signalVolts:Double,sourceResistanceOhms:Double,inputImpedanceOhms:Double=1_000_000,commonModeVolts:Double=0,commonModeLimitVolts:Double=10,isolationRatingVolts:Double=50)->AnalogInputResult {
        let loaded=signalVolts*inputImpedanceOhms/max(1e-9,inputImpedanceOhms+sourceResistanceOhms);let cmOK=abs(commonModeVolts)<=commonModeLimitVolts;let isoOK=abs(commonModeVolts)<=isolationRatingVolts
        let sensed=(cmOK && isoOK) ? loaded : (commonModeVolts.sign == .minus ? -10_000:10_000)
        return .init(sensedVolts:sensed,commonModeVolts:commonModeVolts,loadedSourceVolts:loaded,commonModeValid:cmOK,isolationValid:isoOK,saturated:!cmOK || !isoOK)
    }
}

// MARK: - Topology netlist bridge

public struct TopologyCircuitSnapshot: Codable, Equatable, Sendable {
    public var circuitID:String;public var solution:CircuitSolution;public var dynamicState:CircuitDynamicState;public var nodeOrder:[String]
}

public enum TopologyCircuitNetlistBuilder {
    public static func build(scenario:TopologyGeneratedScenario,circuitID:String) -> CircuitNetlist {
        let t=scenario.topology;let nodes=t.nodes.filter{$0.circuitID==circuitID};let edges=t.edges(in:circuitID)
        guard let source=nodes.first(where:{$0.kind == .source}),let common=nodes.first(where:{$0.kind == .common || $0.kind == .ground}) else {
            return .init(nodes:nodes.map{.init(id:$0.id,label:$0.label,fixedPotential:$0.kind == .ground ? 0:nil,isGround:$0.kind == .ground)},branches:edges.map{.init(id:$0.id,fromNodeID:$0.fromNodeID,toNodeID:$0.toNodeID,baseResistanceOhms:max(1e-6,$0.nominalResistanceOhms))})
        }
        var branchSpecs:[CircuitBranchSpec]=[]
        let ioNode=nodes.first(where:{$0.kind == .ioChannel})
        let deviceNode=nodes.first(where:{ $0.kind == .fieldDevice || $0.kind == .load })
        let isInputCircuit=(ioNode?.order ?? 0) > (deviceNode?.order ?? 99)
        let authoredLoadR=edges.compactMap(\.loadResistanceOhms).first ?? 1_800
        for e in edges {
            let to=t.node(e.toNodeID)
            let isReturnEdge = to?.kind == .common || to?.kind == .ground
            let r:Double
            let kind:CircuitBranchKind
            if isInputCircuit && isReturnEdge {
                r=max(1e-6,authoredLoadR); kind = .sensorInput
            } else if isInputCircuit && e.loadResistanceOhms != nil {
                r=max(1e-6,e.nominalResistanceOhms); kind = .conductor
            } else {
                r=max(1e-6,e.loadResistanceOhms ?? e.nominalResistanceOhms)
                kind=(e.loadResistanceOhms != nil ? .coil : (to?.kind == .shield || to?.kind == .ground ? .leakage:.conductor))
            }
            branchSpecs.append(.init(id:e.id,fromNodeID:e.fromNodeID,toNodeID:e.toNodeID,kind:kind,baseResistanceOhms:r))
        }
        // Apply generated faults to the physical netlist.
        for fault in scenario.faults where fault.circuitID==circuitID {
            if let edgeID=fault.targetEdgeID,let i=branchSpecs.firstIndex(where:{$0.id==edgeID}) {
                switch fault.kind {
                case .looseHighResistanceTerminal,.corrodedConnection: branchSpecs[i].baseResistanceOhms += fault.magnitude
                case .blownFuse,.vibrationIntermittentOpen,.positionDependentCableOpen,.safetyChannelOpen,.outputChannelFailure,.inputChannelFailure,.failedSolenoidCoil: branchSpecs[i].enabled=false
                case .downstreamShort:
                    branchSpecs.append(.init(id:"\(fault.id)|SHORT",fromNodeID:fault.targetNodeID,toNodeID:common.id,kind:.groundFault,baseResistanceOhms:0.01,temperatureCoefficientPerC:0))
                default:break
                }
            }
            if [.missingDCCommon,.floatingCommon,.groundLoop,.shieldGroundFault,.moistureLeakage].contains(fault.kind) {
                let target=fault.targetNodeID
                branchSpecs.append(.init(id:"\(fault.id)|LEAK",fromNodeID:target,toNodeID:common.id,kind:fault.kind == .moistureLeakage ? .leakage:.groundFault,baseResistanceOhms:max(50,10_000/max(0.1,fault.magnitude))))
            }
        }
        // Very high impedance parasitic coupling lets a normal DMM see floating/ghost potential; a LoZ meter collapses it naturally.
        for coupled in nodes where coupled.id != source.id && coupled.id != common.id {
            branchSpecs.append(.init(id:"\(circuitID)|PARASITIC|\(coupled.id)",fromNodeID:source.id,toNodeID:coupled.id,kind:.leakage,baseResistanceOhms:8_000_000,temperatureCoefficientPerC:0))
        }
        let nodeSpecs:[CircuitNodeSpec]=nodes.map{CircuitNodeSpec(id:$0.id,label:$0.label,isGround:$0.id==common.id)}
        let voltage=source.nominalPotential
        let supply=CircuitVoltageSource(id:"\(circuitID)|SUPPLY",positiveNodeID:source.id,negativeNodeID:common.id,nominalVolts:voltage,internalResistanceOhms:voltage<=30 ? 0.12:0.35,currentLimitAmps:voltage<=30 ? 5:15)
        var thermal:[CircuitThermalSpec]=[]
        for b in branchSpecs where b.kind == .conductor || b.kind == .coil {thermal.append(.init(branchID:b.id,thermalMassJPerC:b.kind == .coil ? 80:12,thermalResistanceCPerW:b.kind == .coil ? 4:18))}
        let protection=branchSpecs.filter{$0.id.contains("|SRC->") || $0.id.contains("|FU")}.prefix(1).map{ProtectionDeviceSpec(id:"\(circuitID)|FU-PROT",branchID:$0.id,kind:.fuse,ratedAmps:voltage<=30 ? 2:10)}
        return .init(nodes:nodeSpecs,branches:branchSpecs,sources:[supply],thermal:thermal,protection:Array(protection))
    }

    public static func solve(scenario:TopologyGeneratedScenario,circuitID:String,state:inout CircuitDynamicState,dtSeconds:Double=0) -> TopologyCircuitSnapshot {
        let net=build(scenario:scenario,circuitID:circuitID);let sol=dtSeconds>0 ? IndustrialCircuitSolver.advance(net,state:&state,dtSeconds:dtSeconds):IndustrialCircuitSolver.solve(net,state:state)
        let order=scenario.topology.nodes.filter{$0.circuitID==circuitID}.sorted{$0.order<$1.order}.map(\.id)
        return .init(circuitID:circuitID,solution:sol,dynamicState:state,nodeOrder:order)
    }
}


// MARK: - Stateful circuit-to-machine coupling

public struct CircuitCoupledElectricalSnapshot: Codable, Equatable, Sendable {
    public var scenarioID:String
    public var circuitSnapshots:[String:TopologyCircuitSnapshot]
    public var trippedProtectionIDs:[String]
    public var thermallyFailedBranchIDs:[String]
    public var minimumControlVoltage:Double
    public var totalElectricalLossWatts:Double
}

public struct CircuitCoupledElectricalScenarioRuntime: Codable, Equatable, Sendable {
    public var scenario:TopologyGeneratedScenario
    public var stateByCircuit:[String:CircuitDynamicState]
    public var elapsedSeconds:Double
    public init(scenario:TopologyGeneratedScenario){self.scenario=scenario;self.stateByCircuit=[:];self.elapsedSeconds=0}

    public mutating func advance(seconds:Double) -> CircuitCoupledElectricalSnapshot {
        elapsedSeconds += max(0,seconds)
        let ids=Set(scenario.faults.map(\.circuitID))
        var snaps:[String:TopologyCircuitSnapshot]=[:];var trips:[String]=[];var thermal:[String]=[];var minV=Double.greatestFiniteMagnitude;var losses=0.0
        for cid in ids {
            var state=stateByCircuit[cid] ?? .init()
            let snap=TopologyCircuitNetlistBuilder.solve(scenario:scenario,circuitID:cid,state:&state,dtSeconds:max(0,seconds))
            stateByCircuit[cid]=state;snaps[cid]=snap
            trips += state.protectionByID.filter{$0.value.tripped}.map(\.key)
            thermal += state.thermalByBranch.filter{$0.value.failed}.map(\.key)
            let circuitNodes=scenario.topology.nodes.filter{$0.circuitID==cid && ![.common,.ground,.shield].contains($0.kind)}
            for n in circuitNodes { if let v=snap.solution.voltage(n.id){minV=min(minV,abs(v))} }
            losses += snap.solution.branches.reduce(0){$0+$1.powerWatts}
        }
        if minV == Double.greatestFiniteMagnitude {minV=0}
        return .init(scenarioID:scenario.id,circuitSnapshots:snaps,trippedProtectionIDs:trips.sorted(),thermallyFailedBranchIDs:thermal.sorted(),minimumControlVoltage:minV,totalElectricalLossWatts:losses)
    }

    public mutating func advanceAndApply(seconds:Double,to machine:inout FullyClosedLoopMachineRuntime) -> CircuitCoupledElectricalSnapshot {
        let snap=advance(seconds:seconds)
        machine.injectTopologyScenario(scenario)
        // Protection or thermal opening becomes a real open circuit at the machine I/O boundary.
        if !snap.trippedProtectionIDs.isEmpty || !snap.thermallyFailedBranchIDs.isEmpty {
            for original in scenario.faults {
                var consequence=original
                consequence.id="SOLVED-CONSEQUENCE|\\(original.id)"
                consequence.kind = original.ioTag.flatMap { tag in machine.executable.bindings.first(where:{$0.ioTag==tag})?.direction == .output ? AdvancedElectricalFaultKind.outputChannelFailure : .inputChannelFailure } ?? .blownFuse
                consequence.magnitude=1
                machine.injectTopologyFault(consequence)
            }
        }
        return snap
    }
}

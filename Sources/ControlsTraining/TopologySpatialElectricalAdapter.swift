import Foundation
import ControlsSimulation

public enum TopologySpatialElectricalAdapter {
    public static func document(from scenario:TopologyGeneratedScenario)->SpatialSchematicDocument {
        let circuits=Dictionary(grouping:scenario.topology.nodes,by:\.circuitID)
        var symbols:[SpatialSchematicSymbol]=[]
        var conductors:[RoutedConductor]=[]
        let sortedCircuits=circuits.keys.sorted()
        for (row,cid) in sortedCircuits.enumerated() {
            let branch=(circuits[cid] ?? []).filter{![$0.kind == .shield,$0.kind == .ground].contains(true)}.sorted{$0.order<$1.order}
            for (column,node) in branch.enumerated() {
                let kind: SchematicComponentKind
                switch node.kind {
                case .source: kind = .powerSource
                case .protection: kind = .fuse
                case .ioChannel: kind = node.tag.lowercased().contains("o") ? .plcOutput:.plcInput
                case .fieldDevice: kind = .sensorPNP
                case .load: kind = .relayCoil
                default: kind = .terminal
                }
                let tIn=SpatialTerminal(id:"\(node.id)|IN",label:"IN",relativePosition:.init(x:0,y:0.5),role:node.kind == .source ? .source:.passive,nodeID:"\(node.id)|IN",terminalNumber:"1")
                let tOut=SpatialTerminal(id:"\(node.id)|OUT",label:"OUT",relativePosition:.init(x:1,y:0.5),role:node.kind == .common ? .common:.passive,nodeID:"\(node.id)|OUT",terminalNumber:"2")
                symbols.append(.init(id:node.id,kind:kind,tag:node.tag,label:node.label,position:.init(x:30+Double(column)*150,y:30+Double(row)*95),size:.init(width:110,height:55),terminals:[tIn,tOut]))
            }
        }
        let openEdges=Set(scenario.faults.compactMap(\.targetEdgeID))
        for edge in scenario.topology.edges where symbols.contains(where:{$0.id==edge.fromNodeID}) && symbols.contains(where:{$0.id==edge.toNodeID}) {
            conductors.append(.init(id:edge.id,from:.init(symbolID:edge.fromNodeID,terminalID:"\(edge.fromNodeID)|OUT"),to:.init(symbolID:edge.toNodeID,terminalID:"\(edge.toNodeID)|IN"),wireNumber:edge.wireNumber ?? edge.conductorID ?? edge.id,color:.blue,gauge:.awg18,function:edge.kind == "EtherNet/IP" ? .network:.dcControl,ferruleFrom:"\(edge.fromNodeID)-OUT",ferruleTo:"\(edge.toNodeID)-IN",state:openEdges.contains(edge.id) ? .open:.deenergized))
        }
        return .init(title:"\(scenario.machine.rawValue) • generated topology \(scenario.seed)",symbols:symbols,conductors:conductors,canvasSize:.init(width:1400,height:max(700,Double(sortedCircuits.count)*100)),energized:true,selectedFaultWireID:scenario.faults.compactMap(\.targetEdgeID).first)
    }
}

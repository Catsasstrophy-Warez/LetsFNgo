import Foundation
import ControlsPLC
import ControlsSimulation

public enum EndToEndSpatialAdapter {
    public static func document(for binding: MachineIOBinding) -> SpatialSchematicDocument {
        let analog = !isDiscrete(binding.signalType)
        let fieldKind: SchematicComponentKind = analog ? .analogTransmitter : .sensorPNP
        let moduleKind: SchematicComponentKind = analog ? .analogInput : .plcInput
        let field = SpatialSchematicSymbol(
            id: "FIELD_\(binding.fieldDeviceTag)", kind: fieldKind, tag: binding.fieldDeviceTag,
            label: binding.fieldDeviceDescription, position: .init(x: 60, y: 180),
            terminals: [
                .init(id: "OUT", label: analog ? "+ / signal" : "OUT", relativePosition: .init(x: 1, y: 0.5), role: analog ? .analogPositive : .source, nodeID: "N_FIELD_\(binding.ioTag)", terminalNumber: binding.fieldTerminal)
            ])
        let terminal = SpatialSchematicSymbol(
            id: "TERM_\(binding.terminalStrip)_\(binding.terminalNumber)", kind: .terminal, tag: binding.terminalStrip,
            label: "Terminal \(binding.terminalNumber)", position: .init(x: 350, y: 180), size: .init(width: 115, height: 70), terminals: [
                .init(id: "F", label: "Field", relativePosition: .init(x: 0, y: 0.5), role: .passive, nodeID: "N_TERM_F_\(binding.ioTag)", terminalNumber: binding.terminalNumber),
                .init(id: "P", label: "Panel", relativePosition: .init(x: 1, y: 0.5), role: .passive, nodeID: "N_TERM_P_\(binding.ioTag)", terminalNumber: binding.terminalNumber)
            ])
        let module = SpatialSchematicSymbol(
            id: "IO_\(binding.rack)_\(binding.slot)_\(binding.channel)", kind: moduleKind, tag: "\(binding.rack) S\(binding.slot)",
            label: "\(binding.moduleCatalog) Ch \(binding.channel)", position: .init(x: 660, y: 180), terminals: [
                .init(id: "CH", label: "CH\(binding.channel)", relativePosition: .init(x: 0, y: 0.5), role: analog ? .analogPositive : .digitalInput, nodeID: "N_IO_\(binding.ioTag)", terminalNumber: binding.moduleTerminal)
            ])
        let cable = RoutedConductor(id: binding.cableID, from: .init(symbolID: field.id, terminalID: "OUT"), to: .init(symbolID: terminal.id, terminalID: "F"), route: [.init(x: 190, y: 215), .init(x: 300, y: 215)], wireNumber: binding.wireNumber, color: analog ? .blue : .black, gauge: .awg18, function: analog ? .analog : .dcControl, ferruleFrom: "\(binding.wireNumber)-F", ferruleTo: "\(binding.wireNumber)-TB")
        let panelWire = RoutedConductor(id: "PW-\(binding.wireNumber)", from: .init(symbolID: terminal.id, terminalID: "P"), to: .init(symbolID: module.id, terminalID: "CH"), route: [.init(x: 465, y: 215), .init(x: 610, y: 215)], wireNumber: "\(binding.wireNumber)A", color: analog ? .blue : .black, gauge: .awg18, function: analog ? .analog : .dcControl, ferruleFrom: "\(binding.wireNumber)-TB2", ferruleTo: "\(binding.wireNumber)-IO")
        return .init(title: "\(binding.drawingSheet) • \(binding.fieldDeviceTag) to \(binding.rack) Slot \(binding.slot) Channel \(binding.channel)", symbols: [field, terminal, module], conductors: [cable, panelWire], canvasSize: .init(width: 860, height: 420), energized: true)
    }

    public static func electricalNodes(for binding: MachineIOBinding, snapshot: EndToEndMachineSnapshot?) -> [SpatialElectricalNode] {
        let discrete = isDiscrete(binding.signalType)
        let plcBool = snapshot?.plcValues[binding.ioTag]?.boolValue ?? false
        let raw = binding.rawTag.flatMap { snapshot?.rawSignals[$0] }
        return [
            .init(id: "FIELD", label: "\(binding.fieldDeviceTag) output", position: .init(x: 185,y:215), node: .init(id:"FIELD",label:"Field output",dcVoltage: discrete ? (plcBool ? 24:0) : 24,acVoltage:nil,connectedGroup:"SIG",currentMilliamps:raw,safeToProbe:true)),
            .init(id: "TB", label: "\(binding.terminalStrip):\(binding.terminalNumber)", position: .init(x: 405,y:215), node: .init(id:"TB",label:"Terminal",dcVoltage:discrete ? (plcBool ? 24:0):24,acVoltage:nil,connectedGroup:"SIG",currentMilliamps:raw,safeToProbe:true)),
            .init(id: "IO", label: "\(binding.rack) S\(binding.slot) Ch\(binding.channel)", position: .init(x: 660,y:215), node: .init(id:"IO",label:"I/O channel",dcVoltage:discrete ? (plcBool ? 24:0):24,acVoltage:nil,connectedGroup:"SIG",currentMilliamps:raw,safeToProbe:true)),
            .init(id: "COM", label: "DC common", position: .init(x: 660,y:300), node: .init(id:"COM",label:"DC common",dcVoltage:0,acVoltage:nil,connectedGroup:"COM",currentMilliamps:nil,safeToProbe:true))
        ]
    }

    private static func isDiscrete(_ type: ProjectIOSignalType) -> Bool {
        switch type { case .digital24VDC,.digital120VAC,.safetyDualChannel,.networkProduced,.networkConsumed: true; default: false }
    }
}

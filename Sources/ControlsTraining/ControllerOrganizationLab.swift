import Foundation

public enum ControllerOrganizationFocus: String, Codable, CaseIterable, Sendable {
    case basics
    case structuredData
    case remoteIO

    public var title: String {
        switch self {
        case .basics: "Basic Organization"
        case .structuredData: "Structured Data"
        case .remoteIO: "Remote I/O"
        }
    }
}

public enum ControllerTagScope: String, Codable, Sendable { case controller, program }
public enum TeachingModuleKind: String, Codable, Sendable { case controller, digitalInput, digitalOutput, analogInput, analogOutput, ethernetAdapter }

public struct TeachingIOModule: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var slot: Int
    public var name: String
    public var kind: TeachingModuleKind
    public var channelCount: Int
    public init(id:String = UUID().uuidString, slot:Int, name:String, kind:TeachingModuleKind, channelCount:Int) { self.id=id; self.slot=slot; self.name=name; self.kind=kind; self.channelCount=channelCount }
}

public struct TeachingChassis: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var isRemote: Bool
    public var rpiMilliseconds: Int?
    public var modules: [TeachingIOModule]
    public init(id:String = UUID().uuidString, name:String, isRemote:Bool, rpiMilliseconds:Int? = nil, modules:[TeachingIOModule]) { self.id=id; self.name=name; self.isRemote=isRemote; self.rpiMilliseconds=rpiMilliseconds; self.modules=modules }
}

public struct TeachingTagDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var dataType: String
    public var scope: ControllerTagScope
    public var aliasTarget: String?
    public init(id:String = UUID().uuidString, name:String, dataType:String, scope:ControllerTagScope, aliasTarget:String? = nil) { self.id=id; self.name=name; self.dataType=dataType; self.scope=scope; self.aliasTarget=aliasTarget }
}

public struct TeachingRoutineDefinition: Identifiable, Codable, Equatable, Sendable { public let id:String; public var name:String; public init(id:String=UUID().uuidString,name:String){self.id=id;self.name=name} }
public struct TeachingProgramDefinition: Identifiable, Codable, Equatable, Sendable { public let id:String; public var name:String; public var routines:[TeachingRoutineDefinition]; public init(id:String=UUID().uuidString,name:String,routines:[TeachingRoutineDefinition]){self.id=id;self.name=name;self.routines=routines} }
public struct TeachingTaskDefinition: Identifiable, Codable, Equatable, Sendable { public let id:String; public var name:String; public var kind:String; public var periodMilliseconds:Int?; public var programs:[TeachingProgramDefinition]; public init(id:String=UUID().uuidString,name:String,kind:String,periodMilliseconds:Int?=nil,programs:[TeachingProgramDefinition]){self.id=id;self.name=name;self.kind=kind;self.periodMilliseconds=periodMilliseconds;self.programs=programs} }

public struct ControllerOrganizationLabModel: Codable, Equatable, Sendable {
    public var chassis: [TeachingChassis]
    public var tags: [TeachingTagDefinition]
    public var tasks: [TeachingTaskDefinition]
    public var conceptualDataTypes: [String]

    public static let training = ControllerOrganizationLabModel(
        chassis:[
            .init(name:"Local 1756 Chassis", isRemote:false, modules:[
                .init(slot:0,name:"ControlLogix Controller",kind:.controller,channelCount:0),
                .init(slot:1,name:"16-point Digital Input",kind:.digitalInput,channelCount:16),
                .init(slot:2,name:"16-point Digital Output",kind:.digitalOutput,channelCount:16),
                .init(slot:3,name:"Analog Input",kind:.analogInput,channelCount:8)
            ]),
            .init(name:"Remote EtherNet/IP Rack", isRemote:true, rpiMilliseconds:20, modules:[
                .init(slot:0,name:"EtherNet/IP Adapter",kind:.ethernetAdapter,channelCount:0),
                .init(slot:1,name:"Remote Digital Input",kind:.digitalInput,channelCount:16),
                .init(slot:2,name:"Remote Analog Input",kind:.analogInput,channelCount:8)
            ])
        ],
        tags:[
            .init(name:"Plant_Enable",dataType:"BOOL",scope:.controller),
            .init(name:"Motor_Run",dataType:"BOOL",scope:.program),
            .init(name:"RemoteAI_0",dataType:"REAL",scope:.controller,aliasTarget:"RemoteRack:2:I.Ch0Data")
        ],
        tasks:[.init(name:"MainTask",kind:"Continuous",programs:[.init(name:"MachineProgram",routines:[.init(name:"MainRoutine"),.init(name:"ConveyorLogic")])]), .init(name:"FastPID",kind:"Periodic",periodMilliseconds:20,programs:[.init(name:"ProcessControl",routines:[.init(name:"PressureLoop")])])],
        conceptualDataTypes:["MotorStatus[4] : BOOL array", "PumpStatus : UDT { RunCmd, RunningFB, Faulted, Speed }", "Local_Start aliases a base I/O tag"]
    )

    public func visibleSummary(focus: ControllerOrganizationFocus) -> [String] {
        switch focus {
        case .basics:
            return ["Local chassis slots", "Task → Program → Routine hierarchy", "Controller vs program tag scope"]
        case .structuredData:
            return conceptualDataTypes
        case .remoteIO:
            let remote = chassis.filter(\.isRemote)
            return remote.flatMap { rack in ["\(rack.name)", "RPI: \(rack.rpiMilliseconds ?? 0) ms"] + rack.modules.map { "Slot \($0.slot): \($0.name)" } }
        }
    }
}

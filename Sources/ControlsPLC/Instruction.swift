import Foundation

public enum NumericOperand: Codable, Equatable, Sendable {
    case tag(String)
    case dint(Int32)
    case real(Double)

    public var displayName: String {
        switch self {
        case let .tag(name): name
        case let .dint(value): String(value)
        case let .real(value): String(value)
        }
    }
}

public enum Instruction: Codable, Equatable, Sendable {
    case xic(tag: String)
    case xio(tag: String)
    case ote(tag: String)
    case otl(tag: String)
    case otu(tag: String)
    case ons(storageTag: String)

    case ton(timer: String)
    case tof(timer: String)
    case rto(timer: String)
    case ctu(counter: String)
    case ctd(counter: String)
    case res(tag: String)

    case equ(NumericOperand, NumericOperand)
    case neq(NumericOperand, NumericOperand)
    case les(NumericOperand, NumericOperand)
    case leq(NumericOperand, NumericOperand)
    case grt(NumericOperand, NumericOperand)
    case geq(NumericOperand, NumericOperand)
    case lim(low: NumericOperand, test: NumericOperand, high: NumericOperand)

    case mov(source: NumericOperand, destination: String)
    case add(NumericOperand, NumericOperand, destination: String)
    case sub(NumericOperand, NumericOperand, destination: String)
    case mul(NumericOperand, NumericOperand, destination: String)
    case div(NumericOperand, NumericOperand, destination: String)

    case jsr(routine: String)
    case ret

    public var mnemonic: String {
        switch self {
        case .xic: "XIC"; case .xio: "XIO"; case .ote: "OTE"; case .otl: "OTL"; case .otu: "OTU"; case .ons: "ONS"
        case .ton: "TON"; case .tof: "TOF"; case .rto: "RTO"; case .ctu: "CTU"; case .ctd: "CTD"; case .res: "RES"
        case .equ: "EQU"; case .neq: "NEQ"; case .les: "LES"; case .leq: "LEQ"; case .grt: "GRT"; case .geq: "GEQ"; case .lim: "LIM"
        case .mov: "MOV"; case .add: "ADD"; case .sub: "SUB"; case .mul: "MUL"; case .div: "DIV"
        case .jsr: "JSR"; case .ret: "RET"
        }
    }

    public var displayReference: String {
        switch self {
        case let .xic(tag), let .xio(tag), let .ote(tag), let .otl(tag), let .otu(tag), let .res(tag): tag
        case let .ons(storageTag): storageTag
        case let .ton(timer), let .tof(timer), let .rto(timer): timer
        case let .ctu(counter), let .ctd(counter): counter
        case let .mov(source, destination): "\(source.displayName) → \(destination)"
        case let .add(a, b, destination), let .sub(a, b, destination), let .mul(a, b, destination), let .div(a, b, destination):
            "\(a.displayName), \(b.displayName) → \(destination)"
        case let .equ(a, b), let .neq(a, b), let .les(a, b), let .leq(a, b), let .grt(a, b), let .geq(a, b):
            "\(a.displayName), \(b.displayName)"
        case let .lim(low, test, high): "\(low.displayName) ≤ \(test.displayName) ≤ \(high.displayName)"
        case let .jsr(routine): routine
        case .ret: ""
        }
    }
}


public extension NumericOperand {
    var tagName: String? {
        if case let .tag(name) = self { return name }
        return nil
    }
}

public extension Instruction {
    /// Tags whose values can affect this instruction's result or destination state.
    /// These are topology-level dependencies; execution-time values remain in TraceObservation.
    var readTagNames: [String] {
        switch self {
        case let .xic(tag), let .xio(tag): return [tag]
        case let .ons(storageTag): return [storageTag]
        case let .ton(timer), let .tof(timer), let .rto(timer): return [timer]
        case let .ctu(counter), let .ctd(counter): return [counter]
        case let .res(tag): return [tag]
        case let .equ(a,b), let .neq(a,b), let .les(a,b), let .leq(a,b), let .grt(a,b), let .geq(a,b):
            return [a.tagName, b.tagName].compactMap { $0 }
        case let .lim(low,test,high): return [low.tagName, test.tagName, high.tagName].compactMap { $0 }
        case let .mov(source, _): return [source.tagName].compactMap { $0 }
        case let .add(a,b,_), let .sub(a,b,_), let .mul(a,b,_), let .div(a,b,_): return [a.tagName, b.tagName].compactMap { $0 }
        case .ote, .otl, .otu, .jsr, .ret: return []
        }
    }

    /// Tags this instruction can write when its execution conditions permit. This includes
    /// attempted destructive writes such as an OTE whose rung is false and therefore writes false.
    var writeTagNames: [String] {
        switch self {
        case let .ote(tag), let .otl(tag), let .otu(tag): return [tag]
        case let .ons(storageTag): return [storageTag]
        case let .ton(timer), let .tof(timer), let .rto(timer): return [timer]
        case let .ctu(counter), let .ctd(counter): return [counter]
        case let .res(tag): return [tag]
        case let .mov(_, destination), let .add(_,_,destination), let .sub(_,_,destination), let .mul(_,_,destination), let .div(_,_,destination): return [destination]
        case .xic, .xio, .equ, .neq, .les, .leq, .grt, .geq, .lim, .jsr, .ret: return []
        }
    }
}

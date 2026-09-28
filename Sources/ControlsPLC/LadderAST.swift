import Foundation

public indirect enum LogicNode: Codable, Equatable, Sendable {
    case instruction(Instruction)
    case series([LogicNode])
    case parallel([LogicNode])
}

public struct Rung: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var number: Int
    public var comment: String
    public var logic: LogicNode

    public init(id: UUID = UUID(), number: Int, comment: String = "", logic: LogicNode) {
        self.id = id
        self.number = number
        self.comment = comment
        self.logic = logic
    }
}

public struct LadderRoutine: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rungs: [Rung]

    public init(id: UUID = UUID(), name: String = "MainRoutine", rungs: [Rung] = []) {
        self.id = id
        self.name = name
        self.rungs = rungs.sorted { $0.number < $1.number }
    }
}

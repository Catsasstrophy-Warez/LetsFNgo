import Foundation

public enum InstructionScanMode: String, Codable, Sendable {
    case normal
    case prescan
    case postscan
}

public struct LifecycleTrace: Codable, Equatable, Sendable {
    public let mode: InstructionScanMode
    public let routineNames: [String]
    public let changes: [TagChange]

    public init(mode: InstructionScanMode, routineNames: [String], changes: [TagChange]) {
        self.mode = mode
        self.routineNames = routineNames
        self.changes = changes
    }
}

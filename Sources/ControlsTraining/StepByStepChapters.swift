import Foundation

public enum StepByStepChapter: Int, Codable, CaseIterable, Sendable, Identifiable {
    case foundations = 1
    case digitalMachineControl = 2
    case sequencing = 3
    case analogProcessControl = 4
    case architectureNetworking = 5
    case supervisoryData = 6
    case commissioningCapstone = 7

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .foundations: "PLC Foundations"
        case .digitalMachineControl: "Digital Machine Control"
        case .sequencing: "Sequencing & Program Structure"
        case .analogProcessControl: "Analog Process Control"
        case .architectureNetworking: "Controller Architecture & Networking"
        case .supervisoryData: "HMI, SCADA & Historian"
        case .commissioningCapstone: "Advanced Commissioning & Capstone"
        }
    }
    public var subtitle: String {
        switch self {
        case .foundations: "Learn the scan, tags, instruction truth, and where ladder lives."
        case .digitalMachineControl: "Build commands, feedback, seal-ins, interlocks, and faults."
        case .sequencing: "Organize routines and make machines advance through time and state."
        case .analogProcessControl: "Scale signals, create alarms, command analog outputs, and add deadband."
        case .architectureNetworking: "Structure data, remote I/O, RPI, controller sharing, and MSG transactions."
        case .supervisoryData: "Design trustworthy HMI data contracts and long-term evidence collection."
        case .commissioningCapstone: "Integrate the complete controls stack and prove it under troubleshooting pressure."
        }
    }
    public var expectedDifficulty: String {
        switch self {
        case .foundations, .digitalMachineControl: "Beginner"
        case .sequencing, .analogProcessControl: "Intermediate"
        case .architectureNetworking: "Intermediate → Advanced"
        case .supervisoryData, .commissioningCapstone: "Advanced"
        }
    }
}

public extension StepByStepCatalog {
    static func chapter(for lessonID:String) -> StepByStepChapter {
        switch lessonID {
        case "foundation-scan", "foundation-logix-tasks", "foundation-tags", "foundation-first-rung", "foundation-controller-organization", "foundation-instruction-families", "digital-xic-xio": .foundations
        case "digital-command-feedback", "digital-one-shots", "digital-motor-seal", "digital-interlocks": .digitalMachineControl
        case "sequence-routine-jsr", "sequence-timer-counter", "sequence-retentive-timers": .sequencing
        case "analog-input-scaling", "analog-alarms", "analog-output-command", "analog-level-hysteresis": .analogProcessControl
        case "foundation-structured-data", "comm-remote-io-tree", "comm-io-catalog", "comm-io-rpi", "comm-produced-consumed", "comm-msg-read", "comm-msg-write": .architectureNetworking
        case "comm-hmi-scada", "historian-points-scan": .supervisoryData
        default: .commissioningCapstone
        }
    }
    static func lessons(in chapter:StepByStepChapter) -> [StepByStepLesson] { all.filter { self.chapter(for:$0.id) == chapter } }
    static func lessons(at difficulty:StepByStepDifficulty) -> [StepByStepLesson] { all.filter { $0.difficulty == difficulty } }
}

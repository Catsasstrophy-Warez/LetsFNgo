import Foundation

public enum TrainerResumeArea: String, Codable, Sendable {
    case home
    case learn
    case machines
    case tools
    case profile
    case reference
    case plant
}

public struct TrainerLearningState: Codable, Equatable, Sendable {
    public var progress: StepByStepProgressProfile
    public var activeLessonID: String
    public var sessions: [String: StepByStepLessonSession]

    public init(progress: StepByStepProgressProfile = .init(), activeLessonID: String = StepByStepCatalog.all.first?.id ?? "", sessions: [String: StepByStepLessonSession] = [:]) {
        self.progress = progress
        self.activeLessonID = activeLessonID
        self.sessions = sessions
    }

    public var activeSession: StepByStepLessonSession {
        sessions[activeLessonID] ?? .init(lessonID: activeLessonID)
    }

    public mutating func saveSession(_ session: StepByStepLessonSession) {
        activeLessonID = session.lessonID
        sessions[session.lessonID] = session
    }
}

public struct TrainerResumeState: Codable, Equatable, Sendable {
    public var lastArea: TrainerResumeArea
    public var lastToolID: String?
    public var scenarioTranscript: ScenarioTranscript?

    public init(lastArea: TrainerResumeArea = .home, lastToolID: String? = nil, scenarioTranscript: ScenarioTranscript? = nil) {
        self.lastArea = lastArea
        self.lastToolID = lastToolID
        self.scenarioTranscript = scenarioTranscript
    }

    public var continueTitle: String {
        switch lastArea {
        case .home: "Start training"
        case .learn: "Continue lesson"
        case .machines: scenarioTranscript == nil ? "Open machines" : "Resume diagnosis"
        case .tools: "Return to tools"
        case .profile: "Review progress"
        case .reference: "Open reference library"
        case .plant: "Return to plant & electrical"
        }
    }
}

public enum TrainerAppPersistence {
    public static let learningKey = "ControlsTechTrainer.LearningState.v1"
    public static let resumeKey = "ControlsTechTrainer.ResumeState.v1"

    public static func loadLearning(defaults: UserDefaults = .standard) -> TrainerLearningState {
        decode(TrainerLearningState.self, key: learningKey, defaults: defaults) ?? .init()
    }

    public static func saveLearning(_ state: TrainerLearningState, defaults: UserDefaults = .standard) {
        encode(state, key: learningKey, defaults: defaults)
    }

    public static func loadResume(defaults: UserDefaults = .standard) -> TrainerResumeState {
        decode(TrainerResumeState.self, key: resumeKey, defaults: defaults) ?? .init()
    }

    public static func saveResume(_ state: TrainerResumeState, defaults: UserDefaults = .standard) {
        encode(state, key: resumeKey, defaults: defaults)
    }

    public static func markArea(_ area: TrainerResumeArea, toolID: String? = nil, defaults: UserDefaults = .standard) {
        var state = loadResume(defaults: defaults)
        state.lastArea = area
        if let toolID { state.lastToolID = toolID }
        saveResume(state, defaults: defaults)
    }

    public static func saveScenario(_ transcript: ScenarioTranscript, defaults: UserDefaults = .standard) {
        var state = loadResume(defaults: defaults)
        state.lastArea = .machines
        state.scenarioTranscript = transcript
        saveResume(state, defaults: defaults)
    }

    public static func resumableScenario(machineID: HeroMachineID, faultID: String, mode: ScenarioRunMode, defaults: UserDefaults = .standard) -> ScenarioTranscript? {
        guard let transcript = loadResume(defaults: defaults).scenarioTranscript,
              transcript.machineID == machineID,
              transcript.faultID == faultID,
              transcript.mode == mode else { return nil }
        return transcript
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

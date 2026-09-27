#if canImport(SwiftUI)
import Foundation
import NexusCore
import NexusMeetings
import NexusModel
import NexusPersistence
import NexusSearch
import NexusUI

// MARK: Spotlight

#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers

/// Keeps Spotlight in step with the store through the change feed. Deleted
/// objects are removed; everything else is (re)indexed with its truth class.
@MainActor
final class SpotlightIndexer {
    private let env: NexusEnvironment
    private var observation: ChangeObservation?

    init(env: NexusEnvironment) {
        self.env = env
    }

    func start() {
        observation = env.store.observeChanges { [weak self] changes in
            let ids = Array(Set(changes.map(\.object)))
            Task { @MainActor in await self?.index(ids) }
        }
        Task { await indexAll() }
    }

    private func indexAll() async {
        let types: [ObjectType] = [.project, .equipment, .component, .sensor, .testPoint, .document, .investigation, .procedure, .task]
        let ids = types.flatMap { (try? env.store.objects(ofType: $0).map(\.id)) ?? [] }
        await index(ids)
    }

    private func index(_ ids: [ObjectID]) async {
        let records = env.objects(ids)
        let deleted = records.filter { $0.lifecycle == .deleted }.map(\.id.description)
        let items = records.filter { $0.lifecycle != .deleted && $0.type != .measurement }.map(Self.item(for:))
        let index = CSSearchableIndex.default()
        if !items.isEmpty { try? await index.indexSearchableItems(items) }
        if !deleted.isEmpty { try? await index.deleteSearchableItems(withIdentifiers: deleted) }
    }

    static func item(for record: ObjectRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = record.title
        attributes.contentDescription = "\(record.type.rawValue) · \(record.provenance.truth.rawValue)"
        attributes.keywords = [record.type.rawValue] + record.attributes.compactMap { key, attribute in
            if case .string(let text) = attribute.value, key == "tag" || key == "serial" { return text }
            return nil
        }
        return CSSearchableItem(uniqueIdentifier: record.id.description, domainIdentifier: record.type.rawValue, attributeSet: attributes)
    }
}

/// The ObjectID behind a Spotlight result the person opened.
public func objectID(fromSpotlightActivity activity: NSUserActivity) -> ObjectID? {
    guard activity.activityType == CSSearchableItemActionType,
          let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    else { return nil }
    return ObjectID(identifier)
}
#endif

// MARK: Nameplates (Vision OCR in-app, Visual Intelligence system-wide)

#if canImport(Vision)
import CoreGraphics
import ImageIO
import Vision

public enum NameplateReader {
    /// Text lines read on device from a photo of a nameplate or tag.
    public static func read(_ image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Reads a photo and returns the equipment it most likely shows.
    @MainActor
    public static func identify(_ image: CGImage, in env: NexusEnvironment) async throws -> [NameplateMatcher.Match] {
        let lines = try await read(image)
        return try NameplateMatcher(engine: env.search).match(lines: lines, scope: env.context.activeProject ?? env.demo?.project)
    }

    /// `identify` for encoded image bytes (a photo from the picker or camera).
    @MainActor
    public static func identify(imageData data: Data, in env: NexusEnvironment) async throws -> [ObjectID] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppleIntelligenceError.unavailable("Reading that image")
        }
        return try await identify(image, in: env).map(\.object)
    }
}
#endif

#if canImport(VisualIntelligence) && canImport(AppIntents) && os(iOS)
import AppIntents
import VisualIntelligence

/// When someone points Visual Intelligence at a nameplate, offer the
/// matching Nexus equipment.
public struct NameplateValueQuery: IntentValueQuery {
    public init() {}

    public func values(for input: SemanticContentDescriptor) async throws -> [NexusObjectEntity] {
        try await MainActor.run {
            let env = try AppleIntelligence.requireEnvironment()
            return try NameplateMatcher(engine: env.search).match(lines: input.labels).map { match in
                NexusObjectEntity(id: match.object.description, title: match.title, kind: "equipment")
            }
        }
    }
}
#endif

// MARK: Speech → structured notes

#if canImport(Speech)
import Speech

public enum SpeechNotes {
    /// Asks for speech permission if needed, then transcribes on device.
    public static func authorizeAndTranscribe(_ url: URL) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw AppleIntelligenceError.unavailable("Speech recognition permission") }
        return try await transcribe(url)
    }

    /// Transcribes a recording on device when the recognizer supports it.
    public static func transcribe(_ url: URL, locale: Locale = .current) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppleIntelligenceError.unavailable("Speech recognition")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.run { continuation.resume(throwing: error) }
                } else if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    once.run { continuation.resume(returning: text) }
                }
            }
        }
    }

    /// Transcribes and promotes decisions, tasks, claims and questions into the store.
    @MainActor
    public static func capture(_ url: URL, title: String, about subjects: [ObjectID], in env: NexusEnvironment) async throws -> ObjectID {
        let transcript = try await transcribe(url)
        return try NotePromotion.promote(transcript: transcript, title: title, in: env.store, by: env.user, at: Date(), about: subjects).meeting
    }
}

/// Guards a continuation that a callback API may try to resume twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
#endif

// MARK: Live Activities

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// A running agent, shown on the Lock Screen and in the Dynamic Island.
public struct AgentRunActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: String
        public var summary: String
        public var steps: Int

        public init(phase: String, summary: String, steps: Int) {
            self.phase = phase
            self.summary = summary
            self.steps = steps
        }
    }

    public var goal: String

    public init(goal: String) {
        self.goal = goal
    }
}

/// Not main-actor isolated: ActivityKit's `update` and `end` run concurrently,
/// and `Activity` isn't Sendable, so the calls stay in the caller's task.
public enum AgentRunActivity {
    public static func start(goal: String) -> Activity<AgentRunActivityAttributes>? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let state = AgentRunActivityAttributes.ContentState(phase: "goal", summary: goal, steps: 0)
        return try? Activity.request(attributes: AgentRunActivityAttributes(goal: goal), content: .init(state: state, staleDate: nil))
    }

    public static func update(_ activity: Activity<AgentRunActivityAttributes>?, phase: String, summary: String, steps: Int) async {
        let state = AgentRunActivityAttributes.ContentState(phase: phase, summary: summary, steps: steps)
        await activity?.update(.init(state: state, staleDate: nil))
    }

    public static func end(_ activity: Activity<AgentRunActivityAttributes>?, summary: String) async {
        let state = AgentRunActivityAttributes.ContentState(phase: "done", summary: summary, steps: 0)
        await activity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .default)
    }
}
#endif
#endif

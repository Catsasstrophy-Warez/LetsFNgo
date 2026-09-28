#if canImport(SwiftUI)
import Foundation
import NexusAgents
import NexusUI

/// Wires Apple Intelligence surfaces to the app's environment: Siri and
/// Shortcuts entities and intents, Spotlight, Visual Intelligence, and the
/// on-device model for the agent runtime.
@MainActor
public enum AppleIntelligence {
    /// The environment that intents, queries and indexers read from.
    public private(set) static var environment: NexusEnvironment?
    private static var spotlight: SpotlightIndexer?

    public static func configure(_ env: NexusEnvironment) {
        environment = env
        #if canImport(CoreSpotlight)
        let indexer = SpotlightIndexer(env: env)
        indexer.start()
        spotlight = indexer
        #endif
        #if canImport(FoundationModels)
        env.reinstallModels = { [weak env] in
            guard let env else { return }
            await ModelProviders.install(into: env)
        }
        Task { await ModelProviders.install(into: env) }
        #endif
        #if canImport(Speech)
        env.transcribe = { url in try await SpeechNotes.authorizeAndTranscribe(url) }
        #endif
        #if canImport(Vision)
        env.identifyNameplate = { [weak env] data in
            guard let env else { return [] }
            return try await NameplateReader.identify(imageData: data, in: env)
        }
        #endif
        #if canImport(ActivityKit) && os(iOS)
        env.runMirror = { goal, events in
            // All ActivityKit calls stay in this one task (Activity isn't Sendable).
            let activity = AgentRunActivity.start(goal: goal)
            var steps = 0
            var last = goal
            for await event in events {
                if case .step(let phase, let summary) = event {
                    steps += 1
                    last = summary
                    await AgentRunActivity.update(activity, phase: phase.rawValue, summary: summary, steps: steps)
                }
            }
            await AgentRunActivity.end(activity, summary: last)
        }
        #endif
    }

    static func requireEnvironment() throws -> NexusEnvironment {
        guard let environment else { throw AppleIntelligenceError.notConfigured }
        return environment
    }
}

public enum AppleIntelligenceError: Error, LocalizedError {
    case notConfigured
    case notFound(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Nexus is still starting."
        case .notFound(let what): "Couldn't find \(what)."
        case .unavailable(let what): "\(what) isn't available on this device."
        }
    }
}
#endif

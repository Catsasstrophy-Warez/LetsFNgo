#if canImport(SwiftUI)
import Foundation
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
        Task { await ModelProviders.install(into: env) }
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

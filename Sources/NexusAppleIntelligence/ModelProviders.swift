#if canImport(FoundationModels) && canImport(SwiftUI)
import FoundationModels
import NexusUI

/// Chooses and installs the language models available on this device.
@MainActor
enum ModelProviders {
    static func install(into env: NexusEnvironment) {
        // Filled in with the Foundation Models provider once the agent
        // runtime's tool-handler interface lands.
    }
}
#endif

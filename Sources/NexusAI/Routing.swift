import Foundation
import NexusCore

/// Where the data in a task may go.
public enum PrivacyRequirement: Int, Sendable, Hashable, Comparable {
    /// Must stay on this device.
    case onDeviceOnly = 1
    /// May use Private Cloud Compute, never a third party.
    case privateCloudAllowed = 3
    /// May leave Apple's infrastructure (still gated by P4 permission).
    case thirdPartyAllowed = 4

    public static func < (lhs: PrivacyRequirement, rhs: PrivacyRequirement) -> Bool { lhs.rawValue < rhs.rawValue }

    func permits(_ tier: ModelTier) -> Bool {
        switch self {
        case .onDeviceOnly: tier.isLocal
        case .privateCloudAllowed: tier <= .privateCloud
        case .thirdPartyAllowed: true
        }
    }
}

public struct TaskProfile: Sendable, Hashable {
    public var estimatedContextTokens: Int
    public var needsTools: Bool
    public var needsImages: Bool
    public var privacy: PrivacyRequirement

    public init(estimatedContextTokens: Int, needsTools: Bool = true, needsImages: Bool = false, privacy: PrivacyRequirement = .onDeviceOnly) {
        self.estimatedContextTokens = estimatedContextTokens
        self.needsTools = needsTools
        self.needsImages = needsImages
        self.privacy = privacy
    }
}

/// Picks the most local model that can do the job. Local first is the
/// default; a task only leaves the device when it doesn't fit locally and
/// its privacy requirement allows it.
public struct ModelRouter: Sendable {
    public var providers: [any LanguageModelProvider]

    public init(providers: [any LanguageModelProvider]) {
        self.providers = providers
    }

    public func choose(for task: TaskProfile) throws -> any LanguageModelProvider {
        let eligible = providers.filter { provider in
            let model = provider.descriptor
            return task.privacy.permits(model.tier)
                && model.contextTokens >= task.estimatedContextTokens
                && (!task.needsTools || model.supportsTools)
                && (!task.needsImages || model.supportsImages)
        }
        guard let best = eligible.min(by: { ($0.descriptor.tier, $0.descriptor.contextTokens) < ($1.descriptor.tier, $1.descriptor.contextTokens) }) else {
            throw AIError.noEligibleModel
        }
        return best
    }
}

/// A deterministic model for tests and offline development: it replays a
/// script of responses, or answers through a closure that sees each request.
public final class ScriptedModel: LanguageModelProvider, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    private let lock = NSLock()
    private var script: [ModelResponse]
    private let responder: (@Sendable (GenerationRequest) throws -> ModelResponse)?
    public private(set) var requests: [GenerationRequest] = []

    public init(descriptor: ModelDescriptor = ScriptedModel.defaultDescriptor, script: [ModelResponse]) {
        self.descriptor = descriptor
        self.script = script
        self.responder = nil
    }

    public init(descriptor: ModelDescriptor = ScriptedModel.defaultDescriptor, responder: @escaping @Sendable (GenerationRequest) throws -> ModelResponse) {
        self.descriptor = descriptor
        self.script = []
        self.responder = responder
    }

    public static let defaultDescriptor = ModelDescriptor(
        ref: ModelRef(provider: "nexus.scripted", modelID: "scripted-1"), tier: .onDevice, contextTokens: 8_192
    )

    public func respond(to request: GenerationRequest) async throws -> ModelResponse {
        try lock.withLock {
            requests.append(request)
            if let responder { return try responder(request) }
            guard !script.isEmpty else { throw AIError.scriptExhausted }
            return script.removeFirst()
        }
    }
}

/// Stable, non-cryptographic fingerprint (FNV-1a 64) of a prompt, recorded in
/// `ModelRef.promptHash` so an output can be tied to the exact prompt.
public func promptFingerprint(_ messages: [ChatMessage]) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for message in messages {
        for byte in "\(message.role.rawValue)\u{1F}\(message.text)\u{1E}".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
    }
    return String(hash, radix: 16)
}

import NexusCore
import Testing
@testable import NexusAI

private func model(_ id: String, _ tier: ModelTier, context: Int, tools: Bool = true, images: Bool = false) -> ScriptedModel {
    ScriptedModel(
        descriptor: ModelDescriptor(ref: ModelRef(provider: "test", modelID: id), tier: tier, contextTokens: context, supportsTools: tools, supportsImages: images),
        script: []
    )
}

@Suite struct RouterTests {
    let router = ModelRouter(providers: [
        model("cloud", .thirdPartyCloud, context: 1_000_000, images: true),
        model("pcc", .privateCloud, context: 128_000),
        model("mlx", .localLarge, context: 32_000),
        model("system", .onDevice, context: 4_096, images: true),
    ])

    @Test func prefersTheMostLocalModelThatFits() throws {
        #expect(try router.choose(for: TaskProfile(estimatedContextTokens: 2_000)).descriptor.ref.modelID == "system")
        #expect(try router.choose(for: TaskProfile(estimatedContextTokens: 20_000)).descriptor.ref.modelID == "mlx")
        #expect(try router.choose(for: TaskProfile(estimatedContextTokens: 20_000, needsImages: true, privacy: .thirdPartyAllowed)).descriptor.ref.modelID == "cloud")
    }

    @Test func privacyBoundsHowFarATaskMayTravel() throws {
        #expect(throws: AIError.noEligibleModel) { try router.choose(for: TaskProfile(estimatedContextTokens: 100_000)) }
        #expect(try router.choose(for: TaskProfile(estimatedContextTokens: 100_000, privacy: .privateCloudAllowed)).descriptor.ref.modelID == "pcc")
        #expect(try router.choose(for: TaskProfile(estimatedContextTokens: 500_000, privacy: .thirdPartyAllowed)).descriptor.ref.modelID == "cloud")
    }

    @Test func scriptedModelReplaysAndRecords() async throws {
        let scripted = ScriptedModel(script: [ModelResponse(message: ChatMessage(role: .assistant, text: "hi"), stopReason: .endTurn)])
        let request = GenerationRequest(messages: [.user("hello")])
        #expect(try await scripted.respond(to: request).message.text == "hi")
        #expect(scripted.requests == [request])
        await #expect(throws: AIError.scriptExhausted) { try await scripted.respond(to: request) }
    }

    @Test func promptFingerprintIsStableAndSensitive() {
        let a = promptFingerprint([.system("s"), .user("u")])
        #expect(a == promptFingerprint([.system("s"), .user("u")]))
        #expect(a != promptFingerprint([.system("s"), .user("v")]))
        #expect(a != promptFingerprint([.system("su"), .user("")]))
    }
}

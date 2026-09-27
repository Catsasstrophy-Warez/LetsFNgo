import NexusAppleIntelligence
import NexusUI
import SwiftUI

@main
struct NexusApp: App {
    @State private var env: NexusEnvironment

    init() {
        // UI tests and demos launch with `-demo` for a fresh in-memory world.
        let demoOnly = ProcessInfo.processInfo.arguments.contains("-demo")
        let env = demoOnly ? NexusEnvironment.preview() : ((try? NexusEnvironment.live(seedDemo: true)) ?? NexusEnvironment.preview())
        AppleIntelligence.configure(env)
        _env = State(initialValue: env)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .approvalAlerts()
                .onContinueUserActivity("com.apple.corespotlightitem") { activity in
                    if let id = objectID(fromSpotlightActivity: activity) {
                        try? env.context.open(id, from: .search)
                    }
                }
        }
    }
}

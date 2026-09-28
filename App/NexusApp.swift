import NexusAppleIntelligence
import NexusUI
import SwiftUI

#if NEXUS_CLOUDKIT
import NexusSync
#endif

@main
struct NexusApp: App {
    @State private var env: NexusEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // UI tests and demos launch with `-demo` for a fresh in-memory world.
        let demoOnly = ProcessInfo.processInfo.arguments.contains("-demo")
        let env = demoOnly ? NexusEnvironment.preview() : ((try? NexusEnvironment.live(seedDemo: true)) ?? NexusEnvironment.preview())
        AppleIntelligence.configure(env)
        #if NEXUS_CLOUDKIT
        // Only builds signed with the iCloud entitlement (App/NexusCloud.entitlements)
        // may touch CloudKit: creating a container without it traps.
        if !demoOnly {
            let container = "iCloud." + (Bundle.main.bundleIdentifier ?? "")
            env.sync.makeTransport = {
                CloudKitSyncTransport(containerIdentifier: container, cipher: try PayloadCipher(keyData: try SyncKeychain.loadOrCreateKey()))
            }
        }
        #endif
        env.sync.startIfEnabled()
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { env.sync.appBecameActive() }
        }
    }
}

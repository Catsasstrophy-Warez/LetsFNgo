import AppIntents
import NexusAppleIntelligence

/// Includes the package's intents in the app's App Intents metadata.
struct NexusAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [NexusIntentsPackage.self] }
}

/// Phrases Siri and Spotlight offer without any setup.
struct NexusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskNexusIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask Nexus", systemImageName: "sparkles")
        AppShortcut(intent: OpenObjectIntent(), phrases: ["Open \(\.$object) in \(.applicationName)"],
                    shortTitle: "Open", systemImageName: "cube")
        AppShortcut(intent: StartInvestigationIntent(), phrases: ["Start an investigation in \(.applicationName)"],
                    shortTitle: "Investigate", systemImageName: "stethoscope")
        AppShortcut(intent: CreateTaskIntent(), phrases: ["Add a task in \(.applicationName)"],
                    shortTitle: "New Task", systemImageName: "checklist")
    }
}

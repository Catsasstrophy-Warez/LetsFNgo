import SwiftUI

/// Named, individually-mutable alert subscriptions — the Benzinga Pro
/// "Signals" idea applied to the day-trade engine's own existing
/// `SignalComponent`s rather than a new taxonomy. Every row here already
/// exists as a scored, weighted, explained component; this just gives each
/// one its own on/off switch for whether it's allowed to be the reason an
/// alert fires.
struct SignalAlertTypesView: View {
    @Environment(Settings.self) private var settings

    /// Hazard components score negative and are never the "reason" an alert
    /// fires the way a positive-scoring component is — muting them here
    /// wouldn't map to anything a user would recognize as a signal type.
    private var subscribableComponents: [SignalComponent] {
        SignalComponent.allCases.filter { !$0.isHazard }
    }

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                ForEach(subscribableComponents) { component in
                    let isMuted = settings.mutedSignalComponents.contains(component)
                    Toggle(isOn: Binding(
                        get: { !isMuted },
                        set: { subscribed in
                            if subscribed {
                                settings.mutedSignalComponents.remove(component)
                            } else {
                                settings.mutedSignalComponents.insert(component)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.displayName).font(.subheadline)
                            Text(component.explanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Turning a signal off doesn't hide setups driven by it from the scan list — it only stops that signal from triggering a notification or audio squawk. A candidate whose top driver is muted still ranks and shows up normally, it just alerts silently.")
            }
        }
        .navigationTitle("Alert types")
        .navigationBarTitleDisplayMode(.inline)
    }
}

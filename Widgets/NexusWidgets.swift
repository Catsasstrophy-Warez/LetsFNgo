import AppIntents
import NexusAppleIntelligence
import SwiftUI
import WidgetKit

@main
struct NexusWidgets: WidgetBundle {
    var body: some Widget {
        AgentRunLiveActivity()
        InvestigationsControl()
    }
}

/// A running agent on the Lock Screen and in the Dynamic Island.
struct AgentRunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentRunActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 4) {
                Label(context.attributes.goal, systemImage: "sparkles").font(.headline)
                Text(context.state.summary).font(.caption).lineLimit(2)
                Text("Step \(context.state.steps) · \(context.state.phase)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.summary).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
            } compactTrailing: {
                Text(context.state.phase).font(.caption2)
            } minimal: {
                Image(systemName: "sparkles")
            }
        }
    }
}

/// Control Center / Lock Screen control that jumps to open investigations.
struct InvestigationsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.catsasstrophy.nexus.investigations") {
            ControlWidgetButton(action: OpenInvestigationsIntent()) {
                Label("Investigations", systemImage: "stethoscope")
            }
        }
        .displayName("Nexus Investigations")
    }
}

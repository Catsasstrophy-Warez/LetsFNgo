import ActivityKit
import WidgetKit
import SwiftUI

/// Lock Screen and Dynamic Island rendering for an open options paper
/// position's Live Activity. `PositionActivityAttributes` (shared source
/// file, same pattern as `WidgetSharedStore.swift`) is defined once and
/// compiled into both the main app and this extension.
struct PositionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PositionActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.underlying).font(.headline.monospaced())
                        Text(context.attributes.strategyName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    pnlText(context.state).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.legCount) leg\(context.attributes.legCount == 1 ? "" : "s") · updated \(context.state.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text(context.attributes.underlying).font(.caption2.weight(.semibold))
            } compactTrailing: {
                pnlText(context.state).font(.caption2.monospacedDigit())
            } minimal: {
                pnlDot(context.state)
            }
        }
    }

    private func lockScreenView(_ context: ActivityViewContext<PositionActivityAttributes>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.underlying).font(.headline.monospaced()).foregroundStyle(.white)
                Text(context.attributes.strategyName).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                pnlText(context.state).font(.title3.monospacedDigit().weight(.semibold))
                if let percent = context.state.profitAndLossPercent {
                    Text(String(format: "%+.0f%%", percent * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding()
    }

    private func pnlText(_ state: PositionActivityAttributes.ContentState) -> Text {
        Text(String(format: "%+.2f", state.profitAndLoss))
            .foregroundStyle(state.profitAndLoss >= 0 ? .green : .red)
    }

    private func pnlDot(_ state: PositionActivityAttributes.ContentState) -> some View {
        Image(systemName: state.profitAndLoss >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
            .foregroundStyle(state.profitAndLoss >= 0 ? .green : .red)
    }
}

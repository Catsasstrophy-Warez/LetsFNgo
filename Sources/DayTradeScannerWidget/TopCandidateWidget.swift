import WidgetKit
import SwiftUI

/// A small/medium home-screen widget showing whatever the scanner currently
/// ranks first, read from the App Group snapshot `ScannerEngine` writes
/// after every scoring pass. This is the widget extension's entire job —
/// it never talks to Alpaca or any other data source itself, since a widget
/// process runs on a strict, infrequent refresh budget the app's own
/// engines would blow straight through.
struct TopCandidateEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSharedStore.TopCandidateSnapshot?
}

struct TopCandidateProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopCandidateEntry {
        TopCandidateEntry(date: Date(), snapshot: WidgetSharedStore.TopCandidateSnapshot(
            symbol: "AAPL", score: 0.72, changePercent: 0.034, reason: "3.2× normal volume, reclaimed VWAP", updatedAt: Date()
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (TopCandidateEntry) -> Void) {
        completion(TopCandidateEntry(date: Date(), snapshot: WidgetSharedStore.readTopCandidate()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopCandidateEntry>) -> Void) {
        let entry = TopCandidateEntry(date: Date(), snapshot: WidgetSharedStore.readTopCandidate())
        // The app itself calls WidgetCenter.reloadTimelines on every scoring
        // pass while it's running in the foreground/background, so this
        // policy just guards against staleness if the app hasn't run in a
        // while (market closed overnight, app not opened).
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct TopCandidateWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TopCandidateEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(snapshot.symbol)
                        .font(.headline.monospaced())
                    Spacer()
                    Text(String(format: "%+.1f%%", snapshot.changePercent * 100))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(snapshot.changePercent >= 0 ? .green : .red)
                }
                Text(String(format: "score %.0f", snapshot.score * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if family != .systemSmall {
                    Text(snapshot.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(snapshot.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                Text("Open the app to start scanning")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct TopCandidateWidget: Widget {
    let kind: String = TopCandidateWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopCandidateProvider()) { entry in
            TopCandidateWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Top Candidate")
        .description("The scanner's current highest-ranked setup.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct DayTradeScannerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TopCandidateWidget()
        PositionLiveActivity()
    }
}

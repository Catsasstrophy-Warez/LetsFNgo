import SwiftUI

/// A mobile-friendly "bar replay" over data the app already holds — scrub
/// or step through a symbol's bar history and watch the chart build up to
/// that point, the same idea TradingView's replay mode covers on desktop.
///
/// Deliberately doesn't touch `ChartMetalCoordinator`/`CandleChartView`
/// internals: `CandleChartView.updateUIView` already re-calls
/// `coordinator.update(bars:vwaps:)` on every SwiftUI body re-evaluation, so
/// simply passing a shorter prefix of the same bars each time the cursor
/// moves reuses the exact live-chart rendering path for free.
struct ChartReplayView: View {
    let bars: [MinuteBar]
    let vwaps: [Double]

    @State private var cursor: Int
    @State private var isPlaying = false
    @State private var playTask: Task<Void, Never>?

    init(bars: [MinuteBar], vwaps: [Double]) {
        self.bars = bars
        self.vwaps = vwaps
        _cursor = State(initialValue: max(bars.count - 1, 0))
    }

    private var visibleBars: [MinuteBar] {
        guard !bars.isEmpty else { return [] }
        return Array(bars.prefix(cursor + 1))
    }

    private var visibleVWAPs: [Double] {
        guard vwaps.count == bars.count else { return [] }
        return Array(vwaps.prefix(cursor + 1))
    }

    var body: some View {
        VStack(spacing: 8) {
            if bars.count > 2 {
                let chart = CandleChartView(bars: visibleBars, vwaps: visibleVWAPs)
                chart
                    .frame(height: 220)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Replay, \(chart.accessibilitySummary)")

                if let bar = bars[safe: cursor] {
                    HStack {
                        Text(bar.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.price(bar.close))
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                }

                Slider(value: Binding(
                    get: { Double(cursor) },
                    set: { cursor = Int($0.rounded()) }
                ), in: 0...Double(max(bars.count - 1, 0)), step: 1)
                .onChange(of: cursor) { _, _ in stopPlaying() }

                HStack(spacing: 20) {
                    Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                        .disabled(cursor <= 0)
                        .accessibilityLabel("Step back one bar")
                    Button {
                        isPlaying ? stopPlaying() : startPlaying()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(cursor >= bars.count - 1 && !isPlaying)
                    .accessibilityLabel(isPlaying ? "Pause replay" : "Play replay")
                    Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                        .disabled(cursor >= bars.count - 1)
                        .accessibilityLabel("Step forward one bar")
                    Spacer()
                    Button("Jump to live") { cursor = bars.count - 1 }
                        .font(.caption)
                        .disabled(cursor >= bars.count - 1)
                }
                .font(.title3)
            } else {
                Text("Not enough bars to replay yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopPlaying() }
    }

    private func step(_ delta: Int) {
        cursor = min(max(cursor + delta, 0), bars.count - 1)
    }

    private func startPlaying() {
        guard cursor < bars.count - 1 else { return }
        isPlaying = true
        playTask = Task {
            while !Task.isCancelled, cursor < bars.count - 1 {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { break }
                cursor += 1
            }
            isPlaying = false
        }
    }

    private func stopPlaying() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

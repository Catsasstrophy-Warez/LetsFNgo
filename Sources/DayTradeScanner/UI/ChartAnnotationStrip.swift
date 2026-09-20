import SwiftUI

/// Annotates the chart directly above it with the moments that actually
/// produced the candidate's score, rather than leaving the reader to eyeball
/// a candlestick chart and guess which bar was "the signal." Drawn as a
/// horizontal strip of timestamped chips rather than overlaid markers on the
/// Metal canvas itself, since `CandleChartView` owns its own pan/zoom state
/// internally and isn't set up to report back which bars are on screen —
/// pixel-aligning an overlay to that would be fragile where a simple,
/// always-correct strip underneath is not.
struct ChartAnnotationStrip: View {
    let candidate: Candidate
    let state: SymbolState

    private struct Marker: Identifiable {
        let id = UUID()
        let time: Date
        let label: String
        let systemImage: String
        let tint: Color
    }

    private var markers: [Marker] {
        var result: [Marker] = []
        let bars = state.recentBars
        guard let firstBar = bars.first, let lastBar = bars.last else { return result }

        let gapPercent = candidate.snapshot.gapPercent
        if abs(gapPercent) >= 0.02 {
            result.append(Marker(
                time: firstBar.timestamp,
                label: "Gap \(Fmt.percent(gapPercent))",
                systemImage: gapPercent >= 0 ? "arrow.up.right.circle" : "arrow.down.right.circle",
                tint: Palette.direction(gapPercent)
            ))
        }

        // Most recent bar where close crossed VWAP — the moment the vwapEvent
        // the score is keying off actually happened, not just "sometime
        // today."
        let vwaps = state.recentVWAPs
        if candidate.snapshot.vwapEvent != .none, bars.count == vwaps.count, bars.count > 1 {
            for index in stride(from: bars.count - 1, to: 0, by: -1) {
                let prevAbove = bars[index - 1].close >= vwaps[index - 1]
                let currAbove = bars[index].close >= vwaps[index]
                if prevAbove != currAbove {
                    result.append(Marker(
                        time: bars[index].timestamp,
                        label: candidate.snapshot.vwapEvent == .reclaim ? "VWAP reclaim" : "VWAP loss",
                        systemImage: currAbove ? "arrow.up.forward" : "arrow.down.forward",
                        tint: currAbove ? Palette.up : Palette.down
                    ))
                    break
                }
            }
        }

        if let newsAge = candidate.snapshot.newsAgeMinutes, newsAge <= 120 {
            let newsTime = lastBar.timestamp.addingTimeInterval(-newsAge * 60)
            result.append(Marker(time: newsTime, label: "News", systemImage: "newspaper", tint: .yellow))
        }

        result.append(Marker(
            time: lastBar.timestamp,
            label: "Now — \(Fmt.score(candidate.score))",
            systemImage: "star.circle.fill",
            tint: Palette.cyan
        ))

        return result.sorted { $0.time < $1.time }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(markers) { marker in
                    HStack(spacing: 4) {
                        Image(systemName: marker.systemImage)
                        Text(marker.label)
                        Text(marker.time.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(marker.tint.opacity(0.15)))
                    .foregroundStyle(marker.tint)
                }
            }
        }
        .padding(.top, 2)
    }
}

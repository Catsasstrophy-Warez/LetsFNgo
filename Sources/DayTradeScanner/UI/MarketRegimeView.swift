import SwiftUI

/// A compact, always-visible strip showing whether the tape itself is
/// worth trading right now — separate from any single symbol's score.
/// Tapping it expands into a full sector-breadth treemap.
struct MarketRegimeBanner: View {
    @Environment(MarketRegimeEngine.self) private var regime
    @State private var showSectors = false

    var body: some View {
        Button { showSectors = true } label: {
            HStack(spacing: 10) {
                if let index = regime.indexReading {
                    Image(systemName: index.isRisingTrend ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(Palette.direction(index.changePercent))
                        .font(.caption.weight(.bold))
                    Text("S&P")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(Fmt.percent(index.changePercent))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Palette.direction(index.changePercent))
                } else {
                    Text("Market regime")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !regime.sectorReadings.isEmpty {
                    Divider().frame(height: 10)
                    let leading = regime.sectorReadings.prefix(3)
                    ForEach(leading) { sector in
                        Text(sector.symbol)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(Palette.direction(sector.changePercent))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .sheet(isPresented: $showSectors) {
            SectorBreadthView()
        }
    }
}

/// Full sector-ETF breadth view — a treemap approximated with a
/// proportionally-sized grid, since UIKit/SwiftUI has no built-in treemap
/// layout and a hand-rolled squarified-treemap algorithm would be a lot of
/// geometry code for eleven rows that read just as clearly as a sorted list
/// with area-scaled tiles.
struct SectorBreadthView: View {
    @Environment(MarketRegimeEngine.self) private var regime
    @Environment(\.dismiss) private var dismiss

    private var maxMagnitude: Double {
        max(regime.sectorReadings.map { abs($0.changePercent) }.max() ?? 0.01, 0.01)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if let index = regime.indexReading {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("S&P 500").font(.headline)
                                Spacer()
                                Text(Fmt.percent(index.changePercent))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(Palette.direction(index.changePercent))
                            }
                            if let vs50 = index.vsSMA50Percent {
                                Text("\(Fmt.percent(vs50, signed: true)) vs 50-day average")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
                        .padding(.horizontal)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(regime.sectorReadings) { sector in
                            sectorTile(sector)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Sector breadth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .refreshable { await regime.refresh() }
        }
    }

    private func sectorTile(_ sector: MarketRegimeEngine.Reading) -> some View {
        let intensity = min(abs(sector.changePercent) / maxMagnitude, 1.0)
        let color = Palette.direction(sector.changePercent)
        return VStack(alignment: .leading, spacing: 4) {
            Text(sector.symbol)
                .font(.caption.weight(.bold))
            Text(sector.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Fmt.percent(sector.changePercent))
                .font(.footnote.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.15 + intensity * 0.35)))
        .foregroundStyle(color)
    }
}

import SwiftUI

/// A trend sparkline over a rolling TTM series (revenue or net income) —
/// turns a single snapshot number into a shape, the same way Stock Rover's
/// trend charts do, without any new data fetch: `SECFloatClient` already
/// walks the full quarterly XBRL series to compute the current TTM figure,
/// this just keeps more of that series instead of collapsing it to one
/// number.
struct FundamentalSparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let low = values.min() ?? 0
                let high = values.max() ?? 1
                let span = max(high - low, 1)

                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let normalized = (value - low) / span
                        let y = geo.size.height * (1 - CGFloat(normalized))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Pass/fail balance-sheet and profitability badges — a discrete read of
/// the same fields `LongTermScoringModel` already weighs continuously, for
/// someone who wants "is this healthy, yes or no" rather than a 0-1 score.
struct FundamentalHealthBadges: View {
    let snapshot: FundamentalSnapshot

    private struct Badge: Identifiable {
        var id: String { label }
        let label: String
        let pass: Bool
    }

    private var badges: [Badge] {
        var result: [Badge] = []
        if let margin = snapshot.netMarginTTM {
            result.append(Badge(label: "Profitable", pass: margin > 0))
        }
        if let growth = snapshot.revenueGrowthYoY {
            result.append(Badge(label: "Revenue growing", pass: growth > 0))
        }
        if let trend = snapshot.marginTrend {
            result.append(Badge(label: "Margins expanding", pass: trend >= 0))
        }
        if let leverage = snapshot.leverageRatio {
            result.append(Badge(label: "Leverage under control", pass: leverage <= 0.6))
        }
        if let category = snapshot.floatCategory {
            result.append(Badge(label: "Float not elevated risk", pass: !category.carriesElevatedRisk))
        }
        return result
    }

    var body: some View {
        if !badges.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(badges) { badge in
                    HStack(spacing: 4) {
                        Image(systemName: badge.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(badge.label)
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill((badge.pass ? Palette.up : Palette.down).opacity(0.15)))
                    .foregroundStyle(badge.pass ? Palette.up : Palette.down)
                }
            }
        }
    }
}

/// A minimal wrapping horizontal-then-vertical layout for a set of chips
/// whose combined width isn't known ahead of time — SwiftUI's `HStack` has
/// no wrap behavior, and this is the smallest custom `Layout` that gets it.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

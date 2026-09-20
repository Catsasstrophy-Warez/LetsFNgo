import SwiftUI

/// A radar/"snowflake" chart of a long-term candidate's normalized
/// component scores — the same visual idiom Simply Wall St popularized for
/// fundamentals, drawn with plain SwiftUI `Path` rather than a chart
/// library, since it's eight fixed axes with no need for interactivity.
struct SnowflakeChartView: View {
    let breakdown: LongTermScoreBreakdown

    private var axes: [LongTermComponent] { LongTermComponent.allCases }

    /// `LongTermScoreBreakdown.normalized` isn't on a single scale: most
    /// components already sit in 0...1, but valuation ranges -1...1 and the
    /// two risk axes (leverage, float) are 0 when clean and negative when
    /// risky. Each case here maps its own native range onto 0...1 so every
    /// axis reads consistently as "further out from center is better,"
    /// which is what makes a snowflake chart legible at a glance.
    private func axisValue(_ component: LongTermComponent) -> Double {
        let raw = breakdown.normalized[component] ?? 0
        switch component {
        case .valuation:
            return ((raw + 1) / 2).clampedUnit()
        case .leverageRisk:
            return (raw + 1).clampedUnit()
        case .floatRisk:
            return (1 + raw / 0.5).clampedUnit()
        default:
            return raw.clampedUnit()
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - 28

            ZStack {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    ringPath(center: center, radius: radius * fraction)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
                ForEach(Array(axes.enumerated()), id: \.offset) { index, component in
                    spokeLine(center: center, radius: radius, index: index)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    Text(shortLabel(component))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .position(labelPosition(center: center, radius: radius + 14, index: index))
                }
                shapePath(center: center, radius: radius)
                    .fill(Palette.cyan.opacity(0.25))
                shapePath(center: center, radius: radius)
                    .stroke(Palette.cyan, lineWidth: 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var axisCount: Int { axes.count }

    private func angle(for index: Int) -> Double {
        // Start at the top, go clockwise.
        -.pi / 2 + (2 * .pi * Double(index) / Double(axisCount))
    }

    private func point(center: CGPoint, radius: CGFloat, index: Int, fraction: Double) -> CGPoint {
        let a = angle(for: index)
        return CGPoint(
            x: center.x + radius * fraction * cos(a),
            y: center.y + radius * fraction * sin(a)
        )
    }

    private func labelPosition(center: CGPoint, radius: CGFloat, index: Int) -> CGPoint {
        point(center: center, radius: radius, index: index, fraction: 1)
    }

    private func ringPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for index in 0..<axisCount {
            let p = point(center: center, radius: radius, index: index, fraction: 1)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private func spokeLine(center: CGPoint, radius: CGFloat, index: Int) -> Path {
        var path = Path()
        path.move(to: center)
        path.addLine(to: point(center: center, radius: radius, index: index, fraction: 1))
        return path
    }

    private func shapePath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for (index, component) in axes.enumerated() {
            let value = axisValue(component)
            let p = point(center: center, radius: radius, index: index, fraction: max(value, 0.03))
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private func shortLabel(_ component: LongTermComponent) -> String {
        switch component {
        case .revenueGrowth: return "Growth"
        case .profitability: return "Profit"
        case .marginTrend: return "Margins"
        case .valuation: return "Value"
        case .priceTrend: return "Trend"
        case .insiderConviction: return "Insiders"
        case .leverageRisk: return "Balance sheet"
        case .floatRisk: return "Float"
        }
    }
}

private extension Double {
    func clampedUnit() -> Double { min(max(self, 0), 1) }
}

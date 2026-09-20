import SwiftUI

// MARK: - Formatting

/// Numbers in a scanner are read at a glance under time pressure. Every one of
/// them is monospaced-digit so columns don't jitter as prices tick.
enum Fmt {
    static func price(_ value: Double) -> String {
        value >= 100 ? String(format: "%.2f", value) : String(format: "%.3f", value).trimmedZeros()
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        String(format: signed ? "%+.2f%%" : "%.2f%%", value * 100)
    }

    static func multiple(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    static func sigma(_ value: Double) -> String {
        String(format: "%+.2fσ", value)
    }

    static func compactVolume(_ value: Double) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.0fK", value / 1_000)
        default: return String(format: "%.0f", value)
        }
    }

    static func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func minutes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 1 ? "just now" : "\(Int(value))m ago"
    }
}

private extension String {
    func trimmedZeros() -> String {
        guard contains(".") else { return self }
        var result = self
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }
}

// MARK: - Color

enum Palette {
    static let canvas = Color(red: 0.035, green: 0.047, blue: 0.065)
    static let surface = Color(red: 0.070, green: 0.086, blue: 0.112)
    static let surfaceRaised = Color(red: 0.095, green: 0.116, blue: 0.150)
    static let border = Color.white.opacity(0.09)
    static let cyan = Color(red: 0.21, green: 0.78, blue: 0.90)
    static let amber = Color(red: 0.98, green: 0.67, blue: 0.23)
    static let up = Color(red: 0.11, green: 0.62, blue: 0.42)
    static let down = Color(red: 0.78, green: 0.24, blue: 0.24)
    static let neutral = Color.secondary

    static func direction(_ value: Double) -> Color {
        if value > 0.0005 { return up }
        if value < -0.0005 { return down }
        return neutral
    }

    /// Score intensity. Deliberately a single hue ramping in saturation rather
    /// than a red-to-green rainbow — the score is a magnitude, not a verdict,
    /// and colouring it green would imply a recommendation the app isn't making.
    static func score(_ value: Double) -> Color {
        cyan.opacity(0.25 + min(value, 1.0) * 0.75)
    }
}

struct ThemePalette {
    let canvas: Color
    let surface: Color
    let accent: Color
    let positive: Color
    let warning: Color
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case outrun, miamiVice, arcade, synthwave, neonTokyo
    case terminal, matrix, cyberdeck, vaporwave, grunge
    case aqua, y2k, chrome, blueprint, bubblegum
    case stealth, amberCRT, gameboy, cobalt, midnight

    var id: String { rawValue }
    var name: String {
        switch self {
        case .outrun: return "Outrun 1986"; case .miamiVice: return "Miami Vice"
        case .arcade: return "Arcade Cabinet"; case .synthwave: return "Synthwave"
        case .neonTokyo: return "Neon Tokyo"; case .terminal: return "Green Terminal"
        case .matrix: return "Matrix Rain"; case .cyberdeck: return "Cyberdeck"
        case .vaporwave: return "Vaporwave"; case .grunge: return "Seattle Grunge"
        case .aqua: return "Aqua Glass"; case .y2k: return "Y2K Future"
        case .chrome: return "Chrome OS"; case .blueprint: return "Blueprint"
        case .bubblegum: return "Bubblegum Tech"; case .stealth: return "Stealth Desk"
        case .amberCRT: return "Amber CRT"; case .gameboy: return "Game Boy"
        case .cobalt: return "Cobalt 2001"; case .midnight: return "Midnight Pro"
        }
    }
    var era: String { switch self { case .outrun, .miamiVice, .arcade, .synthwave, .neonTokyo: return "80s"; case .terminal, .matrix, .cyberdeck, .vaporwave, .grunge: return "90s"; default: return "2000s" } }
    var palette: ThemePalette {
        switch self {
        case .outrun: return .init(canvas: .init(hex: "140A2E"), surface: .init(hex: "25104D"), accent: .init(hex: "FF4FD8"), positive: .init(hex: "39F5C2"), warning: .init(hex: "FFE66D"))
        case .miamiVice: return .init(canvas: .init(hex: "071B33"), surface: .init(hex: "102B4C"), accent: .init(hex: "FF6FB5"), positive: .init(hex: "46E0D1"), warning: .init(hex: "FFD166"))
        case .arcade: return .init(canvas: .init(hex: "120D18"), surface: .init(hex: "2A1738"), accent: .init(hex: "FF3B30"), positive: .init(hex: "00FF66"), warning: .init(hex: "FFFF00"))
        case .synthwave: return .init(canvas: .init(hex: "180A28"), surface: .init(hex: "32104A"), accent: .init(hex: "B967FF"), positive: .init(hex: "00F5D4"), warning: .init(hex: "FEE440"))
        case .neonTokyo: return .init(canvas: .init(hex: "07131F"), surface: .init(hex: "102635"), accent: .init(hex: "FF2E97"), positive: .init(hex: "00F0FF"), warning: .init(hex: "FFB000"))
        case .terminal: return .init(canvas: .init(hex: "050A07"), surface: .init(hex: "0D1A12"), accent: .init(hex: "39FF88"), positive: .init(hex: "8CFF00"), warning: .init(hex: "D8FF00"))
        case .matrix: return .init(canvas: .init(hex: "020804"), surface: .init(hex: "081C0E"), accent: .init(hex: "00FF41"), positive: .init(hex: "B6FF00"), warning: .init(hex: "F0FF00"))
        case .cyberdeck: return .init(canvas: .init(hex: "0A0D12"), surface: .init(hex: "171D27"), accent: .init(hex: "00D4FF"), positive: .init(hex: "7CFF6B"), warning: .init(hex: "FFB000"))
        case .vaporwave: return .init(canvas: .init(hex: "17132B"), surface: .init(hex: "292047"), accent: .init(hex: "FF71CE"), positive: .init(hex: "01CDFE"), warning: .init(hex: "FFFB96"))
        case .grunge: return .init(canvas: .init(hex: "161616"), surface: .init(hex: "282828"), accent: .init(hex: "D0A85C"), positive: .init(hex: "83C5BE"), warning: .init(hex: "E76F51"))
        case .aqua: return .init(canvas: .init(hex: "061B24"), surface: .init(hex: "0E3440"), accent: .init(hex: "5DE2E7"), positive: .init(hex: "79F2C0"), warning: .init(hex: "FFD166"))
        case .y2k: return .init(canvas: .init(hex: "0D1726"), surface: .init(hex: "1B324D"), accent: .init(hex: "8BD3FF"), positive: .init(hex: "A7F3D0"), warning: .init(hex: "FDE68A"))
        case .chrome: return .init(canvas: .init(hex: "111827"), surface: .init(hex: "263445"), accent: .init(hex: "C0D8E8"), positive: .init(hex: "75E6DA"), warning: .init(hex: "F5C26B"))
        case .blueprint: return .init(canvas: .init(hex: "071B3A"), surface: .init(hex: "0D2B59"), accent: .init(hex: "7DD3FC"), positive: .init(hex: "86EFAC"), warning: .init(hex: "FDE047"))
        case .bubblegum: return .init(canvas: .init(hex: "21142B"), surface: .init(hex: "3B1F46"), accent: .init(hex: "FF8CC6"), positive: .init(hex: "8BF5D2"), warning: .init(hex: "FFE08A"))
        case .stealth: return .init(canvas: .init(hex: "0B0D0F"), surface: .init(hex: "181C20"), accent: .init(hex: "A8B3BF"), positive: .init(hex: "78D6B0"), warning: .init(hex: "D9A441"))
        case .amberCRT: return .init(canvas: .init(hex: "120C04"), surface: .init(hex: "291A08"), accent: .init(hex: "FFB000"), positive: .init(hex: "FFD35A"), warning: .init(hex: "FF6B35"))
        case .gameboy: return .init(canvas: .init(hex: "0F380F"), surface: .init(hex: "306230"), accent: .init(hex: "9BBC0F"), positive: .init(hex: "C4D72E"), warning: .init(hex: "8BAC0F"))
        case .cobalt: return .init(canvas: .init(hex: "071A3A"), surface: .init(hex: "0D2E63"), accent: .init(hex: "4DA3FF"), positive: .init(hex: "65E6B8"), warning: .init(hex: "FFD166"))
        case .midnight: return .init(canvas: .init(hex: "05070D"), surface: .init(hex: "111827"), accent: .init(hex: "9CA3FF"), positive: .init(hex: "5EEAD4"), warning: .init(hex: "FBBF24"))
        }
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct TraderCardModifier: ViewModifier {
    var emphasized = false
    @Environment(Settings.self) private var settings

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(emphasized ? settings.theme.palette.surface.opacity(0.96) : settings.theme.palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(emphasized ? settings.theme.palette.accent.opacity(0.32) : Palette.border, lineWidth: 1)
            )
    }
}

extension View {
    func traderCard(emphasized: Bool = false) -> some View {
        modifier(TraderCardModifier(emphasized: emphasized))
    }
}

// MARK: - Score bar

/// The one loud element in the interface. Everything else stays quiet so this
/// reads first when you're scanning a list under pressure.
struct ScoreBar: View {
    let score: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.cyan, Palette.score(score)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geometry.size.width * min(score, 1.0), height))
            }
        }
        .frame(height: height)
        .accessibilityLabel("Score \(Fmt.score(score)) out of 1")
    }
}

struct SignalBadge: View {
    let title: String
    let value: String
    var tint: Color = Palette.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18), lineWidth: 1))
    }
}

struct SetupStateBadge: View {
    let state: SetupState

    private var tint: Color {
        switch state {
        case .ready: return Palette.up
        case .avoid, .invalidated: return Palette.down
        case .triggerForming: return Palette.amber
        case .watch: return Palette.cyan
        }
    }

    var body: some View {
        Label(state.rawValue, systemImage: state.systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Sparkline

/// Price against VWAP for the last two hours. No axes, no grid — the only
/// question it answers is "which side of VWAP has this been on".
///
/// Retained as a lightweight fallback for contexts where standing up the
/// Metal chart pipeline (`Rendering/CandleChartRenderer.swift`) isn't worth
/// it — a small badge or a list-row preview. `SymbolDetailView` and the
/// swing/long-term detail screens use the Metal candlestick renderer instead.
struct VWAPSparkline: View {
    let prices: [Double]
    let vwaps: [Double]
    var height: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let combined = prices + vwaps
            let low = combined.min() ?? 0
            let high = combined.max() ?? 1
            let span = max(high - low, 0.0001)

            let point: ([Double], Int) -> CGPoint = { values, index in
                let x = values.count > 1
                    ? geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    : 0
                let y = geometry.size.height * (1 - CGFloat((values[index] - low) / span))
                return CGPoint(x: x, y: y)
            }

            ZStack {
                if vwaps.count > 1 {
                    Path { path in
                        path.move(to: point(vwaps, 0))
                        for index in 1..<vwaps.count { path.addLine(to: point(vwaps, index)) }
                    }
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if prices.count > 1 {
                    Path { path in
                        path.move(to: point(prices, 0))
                        for index in 1..<prices.count { path.addLine(to: point(prices, index)) }
                    }
                    .stroke(Color.primary.opacity(0.75), lineWidth: 1.5)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Advanced disclosure

/// Wraps content that only exists in advanced mode.
///
/// The rule this enforces: advanced mode adds *machinery*, never *results*.
/// If a symbol qualifies in advanced mode it qualifies in simple mode too —
/// the difference is whether you can see how the sausage was made.
struct AdvancedOnly<Content: View>: View {
    @Environment(Settings.self) private var settings
    @ViewBuilder var content: Content

    var body: some View {
        if settings.interfaceMode == .advanced {
            content
        }
    }
}

/// A section that stays collapsed in simple mode but can be opened in place,
/// so you can inspect one thing without switching the whole app over.
struct RevealSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @State private var isExpanded = false
    @Environment(Settings.self) private var settings
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let subtitle, !isExpanded {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // Advanced mode opens these by default; simple mode leaves them shut
            // but reachable, which is the whole point of the local toggle.
            isExpanded = settings.interfaceMode == .advanced
        }
        .onChange(of: settings.interfaceMode) { _, mode in
            isExpanded = mode == .advanced
        }
    }
}

// MARK: - Narrative

/// Renders a `NarrativeGenerator.Narrative` as a headline plus bull/bear
/// bullet lists — the shared presentation for the plain-language "why"
/// summary across all three horizon detail views.
struct NarrativeSectionView: View {
    let narrative: NarrativeGenerator.Narrative

    var body: some View {
        if !narrative.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(narrative.headline)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    if !narrative.bullish.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(narrative.bullish, id: \.self) { line in
                                Label(line, systemImage: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(Palette.up)
                            }
                        }
                    }
                    if !narrative.bearish.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(narrative.bearish, id: \.self) { line in
                                Label(line, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(Palette.down)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("In plain language")
            }
        }
    }
}

// MARK: - Small building blocks

struct MetricRow: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

struct StatusDot: View {
    let status: StreamStatus

    private var color: Color {
        switch status {
        case .subscribed: return Palette.up
        case .connecting, .authenticating, .reconnecting: return .orange
        case .failed: return Palette.down
        case .idle: return .secondary
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(status.label)
    }
}

/// Empty states are an instruction, not an apology.
struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "chart.line.uptrend.xyaxis"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

// MARK: - Trading guide

struct TradingGuideView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DAY TRADING PLAYBOOK")
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(Palette.cyan)
                        Text("Read the chart in layers")
                            .font(.largeTitle.weight(.bold))
                        Text("Use price and volume first. Indicators organize the evidence; they do not predict the next candle.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .traderCard(emphasized: true)

                    GuideCard(title: "VWAP", subtitle: "The session’s fair value") {
                        GuideText("VWAP = cumulative price × volume ÷ cumulative volume. It resets each session and tells you where the average traded dollar volume occurred.")
                        GuideBullet("Above VWAP: buyers are controlling the average entry price.")
                        GuideBullet("Below VWAP: sellers have control of the average entry price.")
                        GuideBullet("Best use: wait for a reclaim or rejection with volume, then define risk near the level.")
                        GuideTrap("A VWAP cross alone is noise in a choppy tape. Pair it with a higher high/lower low and expanding volume.")
                    }

                    GuideCard(title: "RSI", subtitle: "Momentum pressure, not a reversal alarm") {
                        GuideText("RSI measures the balance of recent up closes and down closes on a 0–100 scale. A common day-trading setting is 14 periods; 2–5 periods reacts faster but creates more noise.")
                        GuideBullet("Above 50: momentum has a bullish bias; below 50: bearish bias.")
                        GuideBullet("70 and 30 identify strong conditions, not automatic short and long entries.")
                        GuideBullet("Use divergence only after price establishes a clear swing high or low.")
                        GuideTrap("An overbought stock can stay overbought during a trend. Never fade strength without a failed breakout or risk-defined trigger.")
                    }

                    GuideCard(title: "Volume", subtitle: "The fuel behind the move") {
                        GuideText("Compare current volume with the stock’s normal volume at the same time of day. Relative volume (RVOL) is more useful than raw shares because opening and midday volume are different.")
                        GuideBullet("Breakouts need participation: price expansion plus rising volume is stronger evidence.")
                        GuideBullet("A pullback on lighter volume can show supply is drying up.")
                        GuideBullet("Use dollar volume to confirm liquidity and realistic fills.")
                        GuideTrap("One large print can distort a bar. Confirm the next bar and watch spread, slippage, and halts.")
                    }

                    GuideCard(title: "Momentum", subtitle: "Speed, direction, and persistence") {
                        GuideText("Momentum is the rate and quality of price movement. Read it from higher highs, higher lows, range expansion, relative volume, and how quickly price responds at key levels.")
                        GuideBullet("Strong momentum holds above prior breakout levels and VWAP.")
                        GuideBullet("Weak momentum produces long wicks, failed pushes, and declining volume.")
                        GuideBullet("Enter on a defined trigger; do not chase an extended candle without a stop plan.")
                    }

                    GuideCard(title: "SMA", subtitle: "Context across time") {
                        GuideText("A simple moving average is the average closing price over a chosen number of periods. For intraday charts, 9/20 SMAs show short-term rhythm; 50/200 add broader context when using higher timeframes.")
                        GuideBullet("Rising averages with price above them support trend continuation.")
                        GuideBullet("A flat, tangled group of averages signals compression and lower edge.")
                        GuideBullet("Use the 5-minute or 15-minute SMA for context, then execute from the 1-minute only when liquidity supports it.")
                    }

                    GuideCard(title: "Chart setup", subtitle: "A repeatable layout for the trading day") {
                        GuideStep("1", "Pre-market", "Mark prior day high/low, pre-market high/low, gap direction, major news, and the stock’s float and liquidity.")
                        GuideStep("2", "Layout", "Use a 15-minute chart for structure, a 5-minute chart for setup, and a 1-minute chart for execution. Add VWAP, volume, RSI 14, and 9/20 SMA.")
                        GuideStep("3", "Opening read", "Let the first 5–15 minutes establish range and liquidity. Decide whether price is accepting above VWAP, below it, or rotating around it.")
                        GuideStep("4", "Trigger", "Choose one: opening-range break, VWAP reclaim, pullback to a rising SMA, or breakdown with confirmation. Define entry, invalidation, and target before clicking.")
                        GuideStep("5", "Manage", "Risk a fixed account amount, reduce size when spreads widen, take partials at planned levels, and stop trading after your daily loss limit.")
                    }

                    Text("Educational material only. Test settings in paper trading and account for spreads, slippage, halts, and delayed data.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(Palette.canvas)
            .navigationTitle("Trading Guide")
        }
    }
}

private struct GuideCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.title3.weight(.bold))
            Text(subtitle.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Palette.cyan)
            content
        }
        .traderCard()
    }
}

private func GuideText(_ text: String) -> some View {
    Text(text).font(.subheadline).foregroundStyle(.secondary)
}

private func GuideBullet(_ text: String) -> some View {
    Label(text, systemImage: "arrow.right").font(.subheadline).foregroundStyle(.primary)
}

private func GuideTrap(_ text: String) -> some View {
    Text("TRAP  " + text).font(.caption).foregroundStyle(Palette.amber)
}

private func GuideStep(_ number: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Text(number).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Palette.cyan).frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

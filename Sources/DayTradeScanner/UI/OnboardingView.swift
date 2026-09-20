import SwiftUI

/// First-run walkthrough — this app has no tutorial or explanation between
/// "open it" and "here's a blank credentials field," and given how much of
/// its own design philosophy is honest disclosure (paper-only, free-tier
/// data, no guarantees, self-computed rather than licensed signals), that
/// disclosure belongs here too rather than being scattered across footer
/// text a person only reads if they go looking.
struct OnboardingView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let systemImage: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(
            systemImage: "waveform.path.ecg",
            title: "Three horizons, one scanner",
            body: "Day-trade and scalp setups scored minute by minute, swing setups from daily trend, and long-term fundamentals from SEC filings — all in one app, all free data."
        ),
        Page(
            systemImage: "shield.checkerboard",
            title: "Paper trading only",
            body: "This app only ever talks to Alpaca's paper-trading endpoint. There is no order-submission code anywhere in it, on any host — nothing here can touch real money, by construction, not just by promise."
        ),
        Page(
            systemImage: "antenna.radiowaves.left.and.right",
            title: "Free data, self-computed signals",
            body: "Alpaca's free IEX feed, SEC EDGAR filings, Nasdaq halts, and StockTwits — no paid data license, anywhere. Options flow, gamma exposure, and IV rank are all computed from that same free data, not licensed from a vendor. That means some things (Level 2 depth, dark pool prints, signed options flow) simply aren't available here, on purpose."
        ),
        Page(
            systemImage: "key",
            title: "Connect a free paper account",
            body: "Generate keys at alpaca.markets under Paper Trading, add them in Settings, then tap \"Verify paper account\" to confirm before scanning starts. No credit card, no live account needed."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: item.systemImage)
                            .font(.system(size: 56))
                            .foregroundStyle(Palette.cyan)
                        Text(item.title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(item.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                Button {
                    if page < pages.count - 1 {
                        page += 1
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Continue" : "Get started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if page < pages.count - 1 {
                    Button("Skip") { finish() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        dismiss()
    }
}

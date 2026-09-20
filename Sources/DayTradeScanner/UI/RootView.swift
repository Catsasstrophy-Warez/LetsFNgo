import SwiftUI

struct RootView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @State private var selectedTab: Tab = .scan
    #if DEBUG
    @State private var testSizer = ProcessInfo.processInfo.arguments.contains("--test-position-sizer")
    #endif

    enum Tab: Hashable { case scan, discover, halts, options, log, tuning, guide, settings }

    var body: some View {
        @Bindable var settings = settings

        TabView(selection: $selectedTab) {
            ScanView()
                .tabItem { Label("Scan", systemImage: "waveform.path.ecg") }
                .tag(Tab.scan)

            DiscoveryView()
                .tabItem { Label("Discover", systemImage: "scope") }
                .tag(Tab.discover)

            HaltsView()
                .tabItem { Label("Halts", systemImage: "pause.circle") }
                .tag(Tab.halts)

            OptionsView()
                .tabItem { Label("Options", systemImage: "chart.xyaxis.line") }
                .tag(Tab.options)

            PaperLogView()
                .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
                .tag(Tab.log)

            TuningView()
                .tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }
                .tag(Tab.tuning)

            TradingGuideView()
                .tabItem { Label("Guide", systemImage: "book.pages") }
                .tag(Tab.guide)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Palette.cyan)
        .preferredColorScheme(.dark)
        .tint(settings.theme.palette.accent)
        .background(settings.theme.palette.canvas.ignoresSafeArea())
        #if DEBUG
        .sheet(isPresented: $testSizer) {
            PositionSizerView(entryPrice: 50, stopPrice: 48)
        }
        #endif
    }
}

/// The global mode switch. Lives in the toolbar of every screen so switching
/// never costs a navigation step — the whole design assumes you flip into
/// advanced mode to answer one question and flip straight back.
struct ModeToggle: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Picker("Interface", selection: $settings.interfaceMode) {
            ForEach(InterfaceMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
        .accessibilityLabel("Interface detail level")
    }
}

/// Session state and connection health, condensed to one line.
/// Simple mode gets the phase and a live dot; advanced mode gets throughput.
struct SessionHeader: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: engine.diagnostics.barStreamStatus)

            Text(engine.phase.label)
                .font(.subheadline.weight(.medium))

            if engine.phase == .regular, let minute = MarketClock.minuteOfSession() {
                Text("· minute \(minute) of 390")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Alert slots are shown in both modes. Knowing the budget is full
            // explains a quiet phone during a busy session, which is otherwise
            // indistinguishable from the scanner being broken.
            HStack(spacing: 3) {
                Image(systemName: "bell")
                    .font(.caption2)
                Text("\(engine.slotsRemaining)/\(engine.slotsCapacity)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(engine.slotsRemaining == 0 ? Palette.down : .secondary)

            if !engine.activeHalts.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption2)
                    Text("\(engine.activeHalts.count)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.orange)
            }

            AdvancedOnly {
                HStack(spacing: 10) {
                    Text("\(Int(engine.diagnostics.barsPerMinute)) bars/min")
                    Text("\(engine.candidates.count)/\(engine.diagnostics.subscribedSymbols)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Palette.surface.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: 1)
        }
    }
}

/// Shown while baselines build on a cold start. Honest about what it's doing,
/// because the first run genuinely takes a few minutes and a spinner with no
/// explanation reads as a hang.
struct PreparationView: View {
    @Environment(ScannerEngine.self) private var engine

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: engine.preparationProgress)
                .frame(maxWidth: 240)
            Text(engine.preparationMessage)
                .font(.subheadline)
            Text("Volume baselines are built once per trading day. Each symbol needs 20 sessions of minute bars, so the first run of the day takes a few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

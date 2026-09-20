import SwiftUI

struct RootView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: Tab = .scan
    #if DEBUG
    @State private var testSizer = ProcessInfo.processInfo.arguments.contains("--test-position-sizer")
    #endif

    enum Tab: Hashable, CaseIterable, Identifiable {
        case scan, discover, halts, options, portfolio, log, tuning, guide, settings
        var id: Self { self }

        /// Wired through `String(localized:)` against `Localizable.strings`
        /// as the demonstrated pattern for this app's localization
        /// scaffolding — see the comment at the top of
        /// Resources/en.lproj/Localizable.strings for scope/rationale.
        /// `Text("Scan")` would only auto-localize for a string *literal*
        /// passed directly to `Text`; going through a `String` property
        /// like this one needs the explicit lookup instead.
        var label: String {
            switch self {
            case .scan: return String(localized: "tab.scan", defaultValue: "Scan")
            case .discover: return String(localized: "tab.discover", defaultValue: "Discover")
            case .halts: return String(localized: "tab.halts", defaultValue: "Halts")
            case .options: return String(localized: "tab.options", defaultValue: "Options")
            case .portfolio: return String(localized: "tab.portfolio", defaultValue: "Portfolio")
            case .log: return String(localized: "tab.journal", defaultValue: "Journal")
            case .tuning: return String(localized: "tab.tuning", defaultValue: "Tuning")
            case .guide: return String(localized: "tab.guide", defaultValue: "Guide")
            case .settings: return String(localized: "tab.settings", defaultValue: "Settings")
            }
        }

        var systemImage: String {
            switch self {
            case .scan: return "waveform.path.ecg"
            case .discover: return "scope"
            case .halts: return "pause.circle"
            case .options: return "chart.xyaxis.line"
            case .portfolio: return "briefcase"
            case .log: return "list.bullet.rectangle"
            case .tuning: return "slider.horizontal.3"
            case .guide: return "book.pages"
            case .settings: return "gearshape"
            }
        }
    }

    @ViewBuilder
    private func destination(for tab: Tab) -> some View {
        switch tab {
        case .scan: ScanView()
        case .discover: DiscoveryView()
        case .halts: HaltsView()
        case .options: OptionsView()
        case .portfolio: PortfolioView()
        case .log: PaperLogView()
        case .tuning: TuningView()
        case .guide: TradingGuideView()
        case .settings: SettingsView()
        }
    }

    var body: some View {
        @Bindable var settings = settings

        Group {
            // iPad (and any other regular-width environment) gets a proper
            // sidebar rather than a stretched-out iPhone tab bar — the
            // original ask was "for iPhone and iPad," and every screen in
            // this app already builds its own NavigationStack internally,
            // which drops straight into a NavigationSplitView's detail
            // column exactly the way Apple's own split-view pattern expects.
            if horizontalSizeClass == .regular {
                // `List(selection:)` needs an optional binding; `selectedTab`
                // itself stays non-optional so the TabView branch below (and
                // every `.tag(tab)` match) keeps working unchanged. This
                // bridges the two without ever actually going nil — the
                // setter simply ignores a nil (a row being deselected).
                let sidebarSelection = Binding<Tab?>(
                    get: { selectedTab },
                    set: { if let newTab = $0 { selectedTab = newTab } }
                )
                NavigationSplitView {
                    List(Tab.allCases, selection: sidebarSelection) { tab in
                        Label(tab.label, systemImage: tab.systemImage).tag(tab)
                    }
                    .navigationTitle("DayTradeScanner")
                } detail: {
                    destination(for: selectedTab)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        destination(for: tab)
                            .tabItem { Label(tab.label, systemImage: tab.systemImage) }
                            .tag(tab)
                    }
                }
            }
        }
        .tint(Palette.cyan)
        .preferredColorScheme(.dark)
        .tint(settings.theme.palette.accent)
        .background(settings.theme.palette.canvas.ignoresSafeArea())
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { isPresented in if !isPresented { settings.hasCompletedOnboarding = true } }
        )) {
            OnboardingView()
        }
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

import SwiftUI
import SwiftData
import UIKit

@main
struct DayTradeScannerApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    @State private var settings = Settings.shared
    @State private var paperLog: PaperTradeLog
    @State private var engine: ScannerEngine
    @State private var swingEngine: SwingEngine
    @State private var longTermEngine: LongTermEngine
    @State private var optionsEngine: OptionsEngine
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: PaperTrade.self)
        } catch {
            // A corrupt store shouldn't brick the app. Fall back to in-memory
            // so the scanner still runs; the log is rebuilt from the next alert.
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: PaperTrade.self, configurations: configuration)
        }
        self.container = container

        let log = PaperTradeLog()
        _paperLog = State(initialValue: log)
        _engine = State(initialValue: ScannerEngine(paperLog: log))

        // Swing, long-term, and options share the same free/paper-account
        // data sources — Alpaca REST and SEC EDGAR — but need no websocket
        // and no minute-bar engine, so they get their own lightweight
        // clients rather than reaching into the day-trade engine's private
        // state.
        let sharedREST = AlpacaREST()
        let sharedSECFloat = SECFloatClient(contactEmail: Settings.shared.secContactEmail)
        _swingEngine = State(initialValue: SwingEngine(rest: sharedREST, secFloat: sharedSECFloat))
        _longTermEngine = State(initialValue: LongTermEngine(rest: sharedREST, secFloat: sharedSECFloat))
        _optionsEngine = State(initialValue: OptionsEngine(rest: sharedREST))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .environment(swingEngine)
                .environment(longTermEngine)
                .environment(optionsEngine)
                .environment(settings)
                .environment(paperLog)
                .modelContainer(container)
                .task {
                    paperLog.attach(context: container.mainContext)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #endif
                    await Notifier.requestAuthorization()
                    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
                    if settings.hasCredentials {
                        await engine.start()
                    }
                    // Swing, long-term, and options run on their own slow
                    // timers regardless of day-trade credentials — all three
                    // read only free/paper-account sources that need the same
                    // keys, but none needs a live streaming connection.
                    if settings.hasCredentials {
                        swingEngine.start()
                        longTermEngine.start()
                        optionsEngine.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #endif
                    Task {
                        switch phase {
                        case .active:
                            // Streams are torn down on background, so coming
                            // back needs a reconnect rather than a resume.
                            if settings.hasCredentials, !engine.isRunning {
                                await engine.start()
                            }
                            if settings.hasCredentials, !swingEngine.isRunning {
                                swingEngine.start()
                            }
                            if settings.hasCredentials {
                                longTermEngine.start()
                                optionsEngine.start()
                            }
                        case .background:
                            // iOS will suspend the websocket anyway. Closing it
                            // cleanly avoids a 406 on the next connect, since
                            // the free plan allows one connection per feed.
                            await engine.stop()
                            swingEngine.stop()
                            optionsEngine.stop()
                            // Long-term keeps polling in the background where
                            // iOS allows it — a multi-hour cadence has nothing
                            // to lose by continuing, unlike a websocket.
                        default:
                            break
                        }
                    }
                }
        }
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        NotificationCenter.default.post(name: .apnsTokenUpdated, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .apnsRegistrationFailed, object: error)
    }
}

extension Notification.Name {
    static let apnsTokenUpdated = Notification.Name("DayTradeScanner.apnsTokenUpdated")
    static let apnsRegistrationFailed = Notification.Name("DayTradeScanner.apnsRegistrationFailed")
}

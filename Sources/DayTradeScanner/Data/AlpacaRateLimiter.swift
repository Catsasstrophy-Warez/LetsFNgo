import Foundation

/// Coordinates request pacing across every `AlpacaREST` instance in the app.
///
/// There isn't just one: `ScannerEngine` owns its own private instance,
/// `SwingEngine`/`LongTermEngine`/`OptionsEngine`/`MarketRegimeEngine` share
/// one created in `DayTradeScannerApp`, and `BacktestView` creates a fresh
/// one each time its sheet opens. Alpaca's rate limit is per API key,
/// account-wide — it doesn't know or care how many `AlpacaREST` objects the
/// app happens to have instantiated. Without a shared limiter, five engines
/// starting up at once (the common case: app launch with credentials
/// already saved) can each independently believe they have the full
/// 200-requests-per-minute budget to themselves and collectively blow
/// through it, leaning on `AlpacaREST.fetch`'s per-request 429 retry to
/// paper over what a little proactive pacing would have avoided outright.
///
/// A process-wide singleton actor is the smallest fix that coordinates
/// every instance without threading one shared `AlpacaREST` through every
/// call site (`ScannerEngine`'s own instance and `BacktestView`'s ad-hoc one
/// both predate this and are lower-risk left alone than restructured).
actor AlpacaRateLimiter {
    static let shared = AlpacaRateLimiter()

    /// Free tier is 200 requests/minute. Stay comfortably under it so a
    /// normal multi-engine startup burst never even approaches a 429,
    /// rather than relying entirely on the reactive retry-after-throttling
    /// path in `AlpacaREST.fetch`.
    private let maxRequestsPerWindow = 170
    private let windowSeconds: TimeInterval = 60
    private var requestTimestamps: [Date] = []

    private init() {}

    /// Suspends until a request is safe to send, then reserves the slot.
    /// Called immediately before every outbound Alpaca request.
    func waitForSlot() async {
        while true {
            let now = Date()
            requestTimestamps.removeAll { now.timeIntervalSince($0) > windowSeconds }

            if requestTimestamps.count < maxRequestsPerWindow {
                requestTimestamps.append(now)
                return
            }

            let oldest = requestTimestamps.first ?? now
            let waitSeconds = max(windowSeconds - now.timeIntervalSince(oldest) + 0.05, 0.1)
            try? await Task.sleep(for: .seconds(waitSeconds))
            // Loop rather than assume the wait was sufficient — another
            // instance may have reserved a slot while this one was asleep.
        }
    }
}

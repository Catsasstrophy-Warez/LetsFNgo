import AVFoundation

/// A trading-desk "squawk box": reads halts, fresh filings, and top setups
/// aloud so a trader can keep their eyes on a chart instead of a scrolling
/// alert list. One shared synthesizer, since AVSpeechSynthesizer queues
/// utterances serially on its own — callers don't need to think about
/// overlapping speech.
@MainActor
final class AudioSquawk {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenAt: [String: Date] = [:]

    /// Same symbol/event class won't be re-spoken inside this window, so a
    /// flapping halt/resume pair or a repeat scoring pass doesn't talk over
    /// itself.
    private let repeatSuppressionWindow: TimeInterval = 20

    func speak(_ text: String, dedupeKey: String? = nil) {
        if let dedupeKey {
            if let last = lastSpokenAt[dedupeKey], Date().timeIntervalSince(last) < repeatSuppressionWindow {
                return
            }
            lastSpokenAt[dedupeKey] = Date()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func speakHalt(_ event: HaltMonitor.HaltEvent) {
        let text: String
        if event.isResumed {
            text = "\(Self.spelled(event.symbol)) resumed trading."
        } else {
            text = "\(Self.spelled(event.symbol)) halted. \(event.code.displayName)."
        }
        speak(text, dedupeKey: "halt-\(event.symbol)-\(event.isResumed)")
    }

    func speakFiling(_ event: EDGARFilingStream.FilingEvent) {
        guard let symbol = event.symbol else { return }
        let kind = event.family == .insiderTransaction ? "insider filing" : "8-K filing"
        speak("New \(kind) for \(Self.spelled(symbol)).", dedupeKey: "filing-\(symbol)-\(event.family)")
    }

    func speakTopSetup(_ candidate: Candidate) {
        let direction = candidate.snapshot.changePercent >= 0 ? "up" : "down"
        let percent = abs(candidate.snapshot.changePercent * 100)
        let text = String(format: "%@, %@ %.1f percent. %@.", Self.spelled(candidate.symbol), direction, percent, candidate.plainReason)
        speak(text, dedupeKey: "setup-\(candidate.symbol)")
    }

    /// Ticker symbols read as run-together letters sound like noise —
    /// "N V D A" is far more intelligible aloud than "NVDA".
    private static func spelled(_ symbol: String) -> String {
        symbol.map(String.init).joined(separator: " ")
    }
}

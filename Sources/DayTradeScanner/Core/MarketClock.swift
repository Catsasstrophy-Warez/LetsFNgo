import Foundation

/// All session math happens in Eastern time regardless of where the phone is.
/// Everything downstream keys off `minuteOfSession`, so getting this wrong
/// silently corrupts every baseline.
enum MarketClock {
    static let eastern = TimeZone(identifier: "America/New_York")!
    static let regularSessionMinutes = 390   // 9:30 to 16:00

    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        return cal
    }()

    enum Phase: String {
        case closed, premarket, regular, afterHours

        var label: String {
            switch self {
            case .closed: return "Closed"
            case .premarket: return "Pre-market"
            case .regular: return "Open"
            case .afterHours: return "After hours"
            }
        }
    }

    static func minutesSinceMidnightET(_ date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func isWeekend(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    static func phase(at date: Date = Date()) -> Phase {
        if isWeekend(date) { return .closed }
        let minutes = minutesSinceMidnightET(date)
        switch minutes {
        case 240..<570: return .premarket      // 04:00–09:30
        case 570..<960: return .regular        // 09:30–16:00
        case 960..<1200: return .afterHours    // 16:00–20:00
        default: return .closed
        }
    }

    /// Minutes since the 9:30 open. Negative before the open, clamped at 389.
    /// Returns nil outside 4:00–20:00 ET, when there is no session to index into.
    static func minuteOfSession(_ date: Date = Date()) -> Int? {
        guard !isWeekend(date) else { return nil }
        let minutes = minutesSinceMidnightET(date)
        guard minutes >= 240 && minutes < 1200 else { return nil }
        return min(minutes - 570, regularSessionMinutes - 1)
    }

    /// The 9:30 ET open on the calendar day containing `date`.
    static func sessionOpen(on date: Date = Date()) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 30
        components.second = 0
        return calendar.date(from: components)
    }

    static func startOfTradingDay(on date: Date = Date()) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 4
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    static func isSameTradingDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = eastern
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

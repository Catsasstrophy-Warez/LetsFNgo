import Foundation

/// How an oscilloscope-style view picks its time zero.
public enum TriggerMode: Codable, Sendable, Hashable {
    /// The signal crosses `level` going up. It must first be at or below
    /// `level - hysteresis`, so noise riding on the level doesn't retrigger.
    case risingEdge(level: Double, hysteresis: Double = 0)
    /// The signal crosses `level` going down, after being at or above `level + hysteresis`.
    case fallingEdge(level: Double, hysteresis: Double = 0)
    /// The signal is at or above `level` (no crossing needed): fires on the
    /// first such sample, like a scope's level/"normal" trigger on a steady signal.
    case level(Double)
}

/// A trigger found in a sampled signal.
public struct TriggerPoint: Codable, Sendable, Hashable {
    /// Index of the first sample at or past the trigger condition.
    public var index: Int
    /// Trigger time. For edges it is interpolated between the two samples
    /// either side of the crossing, so it is sub-sample accurate.
    public var time: Double
}

/// A window of samples re-timed so the trigger is at t = 0.
public struct ScopeCapture: Codable, Sendable, Hashable {
    public var trigger: TriggerPoint
    public var points: [DataPoint]
}

public enum ScopeTrigger {
    /// Every trigger in `samples` (sorted by x). After a trigger, the next is
    /// ignored until `holdoff` seconds have passed, as on a real scope.
    public static func triggers(in samples: [DataPoint], mode: TriggerMode, holdoff: Double = 0) -> [TriggerPoint] {
        var found: [TriggerPoint] = []
        var armed: Bool
        switch mode {
        case .risingEdge(let level, let hysteresis):
            armed = false
            for index in samples.indices {
                let y = samples[index].y
                if y <= level - hysteresis { armed = true }
                // The crossing is the first sample above the level: a signal
                // resting exactly on the level has not yet risen through it.
                guard armed, index > 0, y > level, samples[index - 1].y <= level else { continue }
                let time = crossing(samples[index - 1], samples[index], level)
                if let last = found.last, time - last.time < holdoff { continue }
                found.append(TriggerPoint(index: index, time: time))
                armed = false
            }
        case .fallingEdge(let level, let hysteresis):
            armed = false
            for index in samples.indices {
                let y = samples[index].y
                if y >= level + hysteresis { armed = true }
                guard armed, index > 0, y < level, samples[index - 1].y >= level else { continue }
                let time = crossing(samples[index - 1], samples[index], level)
                if let last = found.last, time - last.time < holdoff { continue }
                found.append(TriggerPoint(index: index, time: time))
                armed = false
            }
        case .level(let level):
            var wasAbove = false
            for index in samples.indices {
                let above = samples[index].y >= level
                defer { wasAbove = above }
                // Fires when the condition becomes true, including on the first sample.
                guard above, !wasAbove else { continue }
                let time = samples[index].x
                if let last = found.last, time - last.time < holdoff { continue }
                found.append(TriggerPoint(index: index, time: time))
            }
        }
        return found
    }

    /// The first trigger, or nil if the condition never occurs.
    public static func first(in samples: [DataPoint], mode: TriggerMode) -> TriggerPoint? {
        triggers(in: samples, mode: mode).first
    }

    /// Samples from `pre` seconds before to `post` seconds after the first
    /// trigger, re-timed so the trigger is t = 0. Nil when nothing triggers.
    public static func capture(_ samples: [DataPoint], mode: TriggerMode, pre: Double, post: Double) -> ScopeCapture? {
        guard let trigger = first(in: samples, mode: mode) else { return nil }
        let window = samples.filter { $0.x >= trigger.time - pre && $0.x <= trigger.time + post }
        return ScopeCapture(trigger: trigger, points: window.map { DataPoint($0.x - trigger.time, $0.y) })
    }

    private static func crossing(_ a: DataPoint, _ b: DataPoint, _ level: Double) -> Double {
        guard b.y != a.y else { return b.x }
        let fraction = (level - a.y) / (b.y - a.y)
        return a.x + min(1, max(0, fraction)) * (b.x - a.x)
    }
}

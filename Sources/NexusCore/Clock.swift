import Foundation

/// Source of wall-clock time. Injected everywhere a timestamp is minted so
/// tests and simulations stay deterministic.
public protocol NexusClock: Sendable {
    func now() -> Date
}

public struct SystemClock: NexusClock {
    public init() {}

    public func now() -> Date { Date() }
}

/// A manually advanced clock for tests and replay.
public final class ManualClock: NexusClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        current = start
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += seconds
    }
}

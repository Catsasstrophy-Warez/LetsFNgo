import Foundation

/// Inspectable progress for long work, replacing indefinite spinners: named
/// stages ("sources checked", "tests complete", "topology built"), completed
/// and total units, and the item being worked on right now.
///
/// The worker mutates it; any number of observers read `snapshot` or iterate
/// `updates()`. It is thread-safe, so a background task can report while the
/// UI observes.
public final class WorkProgress: @unchecked Sendable {
    public enum StageState: String, Codable, Sendable, Hashable {
        case pending
        case running
        case completed
        case failed
        case cancelled
    }

    public struct Stage: Codable, Sendable, Hashable {
        public var name: String
        public var completedUnits: Int
        /// Nil when the size of the stage isn't known yet.
        public var totalUnits: Int?
        public var state: StageState

        public init(name: String, completedUnits: Int = 0, totalUnits: Int? = nil, state: StageState = .pending) {
            self.name = name
            self.completedUnits = completedUnits
            self.totalUnits = totalUnits
            self.state = state
        }

        /// 0...1, or nil when the total is unknown.
        public var fraction: Double? {
            if state == .completed { return 1 }
            guard let totalUnits, totalUnits > 0 else { return nil }
            return min(1, Double(completedUnits) / Double(totalUnits))
        }
    }

    /// An immutable view of the progress at one moment.
    public struct Snapshot: Codable, Sendable, Hashable {
        public var title: String
        public var stages: [Stage]
        /// Index of the running stage, if any.
        public var currentStage: Int?
        /// What is being worked on now: "Checking TB-4", "tick 1200".
        public var currentItem: String?
        public var isFinished: Bool
        /// Set when the work stopped early; `stages` shows where.
        public var failure: String?

        /// Overall completion, weighting stages equally. Stages with an
        /// unknown total count as half done while running.
        public var fractionCompleted: Double {
            guard !stages.isEmpty else { return isFinished ? 1 : 0 }
            let sum = stages.reduce(0.0) { total, stage in
                switch stage.state {
                case .completed: total + 1
                case .pending: total
                case .running, .failed, .cancelled: total + (stage.fraction ?? 0.5)
                }
            }
            return sum / Double(stages.count)
        }

        public var isCancelled: Bool { stages.contains { $0.state == .cancelled } }
    }

    private let lock = NSLock()
    private var state: Snapshot
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// `stages` pairs each stage name with its unit count, if known.
    public init(title: String, stages: [(name: String, total: Int?)]) {
        state = Snapshot(
            title: title, stages: stages.map { Stage(name: $0.name, totalUnits: $0.total) }, currentStage: nil,
            currentItem: nil, isFinished: false, failure: nil
        )
    }

    public convenience init(title: String, stageNames: [String]) {
        self.init(title: title, stages: stageNames.map { (name: $0, total: nil) })
    }

    public var snapshot: Snapshot { lock.withLock { state } }

    /// A stream that yields the current snapshot immediately, then every
    /// change, and finishes when the work finishes, fails or is cancelled.
    /// Slow consumers see only the newest snapshot.
    public func updates() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        // Yield under the lock so a concurrent change can't overtake this first value.
        let finished = lock.withLock { () -> Bool in
            continuation.yield(state)
            if !state.isFinished { continuations[id] = continuation }
            return state.isFinished
        }
        if finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    // MARK: Reporting

    /// Marks stage `index` running, completing any earlier running stage.
    public func begin(stage index: Int, total: Int? = nil, item: String? = nil) {
        mutate { state in
            guard state.stages.indices.contains(index) else { return }
            if let current = state.currentStage, current != index, state.stages[current].state == .running {
                state.stages[current].state = .completed
            }
            state.stages[index].state = .running
            if let total { state.stages[index].totalUnits = total }
            state.currentStage = index
            state.currentItem = item
        }
    }

    /// Begins the stage with this name.
    public func begin(_ name: String, total: Int? = nil, item: String? = nil) {
        guard let index = snapshot.stages.firstIndex(where: { $0.name == name }) else { return }
        begin(stage: index, total: total, item: item)
    }

    /// Adds completed units to the running stage and names the current item.
    public func advance(by units: Int = 1, item: String? = nil) {
        mutate { state in
            guard let index = state.currentStage else { return }
            state.stages[index].completedUnits += units
            if let item { state.currentItem = item }
        }
    }

    /// Sets the running stage's completed units outright.
    public func setCompleted(_ units: Int, item: String? = nil) {
        mutate { state in
            guard let index = state.currentStage else { return }
            state.stages[index].completedUnits = units
            if let item { state.currentItem = item }
        }
    }

    /// Completes the running stage.
    public func completeStage() {
        mutate { state in
            guard let index = state.currentStage else { return }
            state.stages[index].state = .completed
            if let total = state.stages[index].totalUnits {
                state.stages[index].completedUnits = max(state.stages[index].completedUnits, total)
            }
            state.currentStage = nil
            state.currentItem = nil
        }
    }

    /// Completes every unfinished stage and ends the updates.
    public func finish() {
        mutate(finishing: true) { state in
            for index in state.stages.indices where state.stages[index].state != .completed {
                state.stages[index].state = .completed
                if let total = state.stages[index].totalUnits {
                    state.stages[index].completedUnits = max(state.stages[index].completedUnits, total)
                }
            }
            state.currentStage = nil
            state.currentItem = nil
        }
    }

    /// Records a failure in the running stage and ends the updates.
    public func fail(_ reason: String) {
        mutate(finishing: true) { state in
            if let index = state.currentStage { state.stages[index].state = .failed }
            state.failure = reason
        }
    }

    /// Records cancellation in the running stage and ends the updates.
    public func cancel() {
        mutate(finishing: true) { state in
            if let index = state.currentStage { state.stages[index].state = .cancelled }
            state.failure = "Cancelled"
        }
    }

    private func mutate(finishing: Bool = false, _ body: (inout Snapshot) -> Void) {
        // Yield under the lock to keep order; finish outside it, because
        // finishing runs `onTermination`, which takes the lock.
        let finished = lock.withLock { () -> [AsyncStream<Snapshot>.Continuation] in
            guard !state.isFinished else { return [] }
            body(&state)
            if finishing { state.isFinished = true }
            for continuation in continuations.values {
                continuation.yield(state)
            }
            guard finishing else { return [] }
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in finished {
            continuation.finish()
        }
    }
}

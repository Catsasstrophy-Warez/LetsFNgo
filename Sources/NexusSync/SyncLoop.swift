import Foundation
import NexusPersistence

/// What the sync loop has done, for Settings.
public struct SyncStatus: Sendable, Equatable {
    public var isSyncing = false
    public var lastAttempt: Date?
    /// When the last sync finished without an error.
    public var lastSuccess: Date?
    /// The last sync's error, cleared by the next success.
    public var lastError: String?
    /// Whether trying again later may clear `lastError` by itself.
    public var errorIsRetryable = false
    /// `syncConflict` events in the store: values TruthPolicy kept for review.
    public var conflictCount = 0
    /// Blobs whose bytes haven't arrived yet.
    public var blobsPending = 0
    /// Successful syncs since the loop started.
    public var completedSyncs = 0

    public init() {}
}

/// Runs a `SyncEngine` when it's worth it: on start (launch), when the app
/// comes to the foreground, every `interval`, and `debounce` after the local
/// store changes. One sync runs at a time; a request during a sync runs one
/// more afterwards.
///
/// Changes seen while a sync runs include the sync's own writes, so they
/// schedule one debounced follow-up rather than an immediate one. That
/// follow-up pushes nothing new from other replicas' echoes of this one and
/// pulls nothing, so the loop settles.
public actor SyncLoop {
    public enum Trigger: String, Sendable {
        case launch, foreground, timer, localChange, manual
    }

    public let engine: SyncEngine
    public let interval: Duration
    public let debounce: Duration
    private let onStatus: @Sendable (SyncStatus) -> Void

    public private(set) var status = SyncStatus()
    private var running = false
    private var observation: ChangeObservation?
    private var timer: Task<Void, Never>?
    private var debounced: Task<Void, Never>?
    private var current: Task<Void, Never>?
    private var again = false
    private var changedDuringSync = false

    public init(
        engine: SyncEngine, interval: Duration = .seconds(300), debounce: Duration = .seconds(5),
        onStatus: @escaping @Sendable (SyncStatus) -> Void = { _ in }
    ) {
        self.engine = engine
        self.interval = interval
        self.debounce = debounce
        self.onStatus = onStatus
    }

    public var isRunning: Bool { running }

    /// Starts watching the store and the clock, and syncs once.
    public func start() {
        guard !running else { return }
        running = true
        observation = engine.store.observeChanges { [weak self] _ in
            guard let self else { return }
            Task { await self.trigger(.localChange) }
        }
        let interval = interval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.trigger(.timer)
            }
        }
        trigger(.launch)
    }

    /// Stops watching. A sync already under way finishes.
    public func stop() {
        running = false
        observation?.cancel()
        observation = nil
        timer?.cancel()
        timer = nil
        debounced?.cancel()
        debounced = nil
    }

    /// Asks for a sync. Local changes wait for `debounce` of quiet; anything
    /// else syncs now (or right after the sync that's running).
    public func trigger(_ trigger: Trigger) {
        guard running || trigger == .manual else { return }
        switch trigger {
        case .localChange:
            if status.isSyncing {
                changedDuringSync = true
            } else {
                scheduleDebounced()
            }
        case .launch, .foreground, .timer, .manual:
            debounced?.cancel()
            debounced = nil
            startSync()
        }
    }

    /// Syncs now (or waits for the sync under way and runs one more), and
    /// returns the status afterwards.
    @discardableResult
    public func syncNow() async -> SyncStatus {
        startSync()
        while let task = current { await task.value }
        return status
    }

    private func scheduleDebounced() {
        debounced?.cancel()
        let debounce = debounce
        debounced = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.startSync()
        }
    }

    private func startSync() {
        guard current == nil else {
            again = true
            return
        }
        status.isSyncing = true
        status.lastAttempt = Date()
        changedDuringSync = false
        publish()
        current = Task { await self.runOnce() }
    }

    private func runOnce() async {
        do {
            let report = try await engine.sync()
            status.lastSuccess = Date()
            status.lastError = nil
            status.errorIsRetryable = false
            status.blobsPending = report.blobsPending
            status.completedSyncs += 1
        } catch let error as CloudSyncError {
            status.lastError = error.message
            status.errorIsRetryable = error.isRetryable
        } catch {
            status.lastError = String(describing: error)
            status.errorIsRetryable = false
        }
        status.conflictCount = (try? await engine.store.perform { try $0.syncConflictCount() }) ?? status.conflictCount
        status.isSyncing = false
        current = nil
        publish()
        if again {
            again = false
            startSync()
        } else if changedDuringSync && running {
            changedDuringSync = false
            scheduleDebounced()
        }
    }

    private func publish() {
        onStatus(status)
    }
}

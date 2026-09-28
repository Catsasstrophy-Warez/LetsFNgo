#if canImport(SwiftUI)
import Foundation
import NexusPersistence
import NexusSync
import Observation
import SwiftUI

/// Sync for the app: off by default. When on, a `SyncLoop` runs the
/// `SyncEngine` on launch, on foreground, every few minutes and shortly after
/// local changes (decision 0001).
///
/// The transport comes from the app. Builds compiled with `NEXUS_CLOUDKIT`
/// set `makeTransport` to a CloudKit transport; other builds (for example,
/// signed with a free Apple ID, which can't use iCloud) leave it nil, and
/// Settings explains how to enable it.
@MainActor
@Observable
public final class SyncController {
    public static let enabledKey = "nexus.sync.enabled"

    /// Builds the transport. May throw (no Keychain key, for instance).
    @ObservationIgnored public var makeTransport: (@Sendable () throws -> any SyncTransport)?
    public private(set) var isEnabled: Bool
    public private(set) var status = SyncStatus()
    /// Why sync couldn't start, if it couldn't.
    public private(set) var setupError: String?
    /// Whether this build can sync at all.
    public var isAvailable: Bool { makeTransport != nil }

    private let store: NexusStore
    @ObservationIgnored private var loop: SyncLoop?

    public init(store: NexusStore) {
        self.store = store
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Starts the loop if sync is on and available. Call once at launch,
    /// after setting `makeTransport`.
    public func startIfEnabled() {
        guard isEnabled, isAvailable, loop == nil else { return }
        do {
            guard let makeTransport else { return }
            let engine = SyncEngine(store: store, transport: try makeTransport())
            let loop = SyncLoop(engine: engine, interval: .seconds(300), debounce: .seconds(5)) { [weak self] status in
                Task { @MainActor in self?.status = status }
            }
            self.loop = loop
            setupError = nil
            Task { await loop.start() }
        } catch {
            setupError = "Sync couldn't start: \(error)"
        }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startIfEnabled()
        } else if let loop {
            self.loop = nil
            Task { await loop.stop() }
        }
    }

    /// The app came to the foreground.
    public func appBecameActive() {
        guard let loop else { return }
        Task { await loop.trigger(.foreground) }
    }

    public func syncNow() {
        guard let loop else { return }
        Task { await loop.trigger(.manual) }
    }
}

/// Settings → Sync.
struct SyncSettingsSection: View {
    @Environment(NexusEnvironment.self) private var env

    var body: some View {
        let sync = env.sync
        Section {
            if sync.isAvailable {
                Toggle("Sync with iCloud", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                if sync.isEnabled {
                    LabeledContent("Last sync") {
                        if sync.status.isSyncing {
                            ProgressView().controlSize(.small)
                        } else if let last = sync.status.lastSuccess {
                            Text(last, style: .relative)
                        } else {
                            Text("Not yet")
                        }
                    }
                    LabeledContent("Conflicts kept for review", value: "\(sync.status.conflictCount)")
                    if sync.status.blobsPending > 0 {
                        LabeledContent("Files still downloading", value: "\(sync.status.blobsPending)")
                    }
                    if let error = sync.setupError ?? sync.status.lastError {
                        Label(error, systemImage: "exclamationmark.icloud").font(.caption).foregroundStyle(.red)
                    }
                    Button("Sync now") { sync.syncNow() }.disabled(sync.status.isSyncing)
                }
            } else {
                Text(
                    "This build doesn't include iCloud sync. It needs a paid Apple Developer account, because free Apple IDs can't use iCloud. Build with NEXUS_CLOUDKIT_ENABLED=YES (docs/DEVICE.md → iCloud sync)."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            DiskEncryptionRow()
            #endif
        } header: {
            Text("Sync")
        } footer: {
            Text(
                "Off by default. Everything is encrypted on this device before it goes to your private iCloud database, with a key that only your devices hold (iCloud Keychain). Turn sync on here first on one device, then on the others."
            )
        }
    }
}

#if os(macOS)
/// Decision 0001: on a Mac the store relies on FileVault; say when it's off.
private struct DiskEncryptionRow: View {
    @State private var encryption = DiskEncryption.unknown

    var body: some View {
        Group {
            switch encryption {
            case .encrypted: LabeledContent("Disk encryption", value: "On")
            case .unknown: LabeledContent("Disk encryption", value: "Unknown")
            case .notEncrypted:
                Label(
                    "FileVault is off, so Nexus data on this Mac isn't encrypted at rest. Turn it on in System Settings → Privacy & Security.",
                    systemImage: "lock.open"
                )
                .font(.caption).foregroundStyle(.orange)
            }
        }
        .task {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            encryption = DiskEncryption.status(of: url)
        }
    }
}
#endif
#endif

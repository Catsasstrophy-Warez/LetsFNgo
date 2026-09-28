#if canImport(SwiftUI)
import Foundation
import NexusAI
import SwiftUI

#if canImport(Security)
import Security
#endif

/// Credentials for opt-in cloud models, kept in the Keychain (never in the
/// store, which syncs and backs up).
public enum CloudCredentials {
    private static let service = "com.nexus.cloud-models"

    public static func key(for provider: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: provider, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func setKey(_ key: String?, for provider: String) -> Bool {
        #if canImport(Security)
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider]
        SecItemDelete(match as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = match
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }
}

/// How far a question may travel. The router never goes past this tier, and
/// third-party models still ask before any data leaves (P4).
public enum ModelPrivacy: String, CaseIterable, Identifiable {
    case onDevice
    case privateCloud
    case thirdParty

    public static let storageKey = "nexus.modelPrivacy"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice: "On device only"
        case .privateCloud: "Allow Private Cloud Compute"
        case .thirdParty: "Allow third-party cloud (asks each time)"
        }
    }

    public var requirement: PrivacyRequirement {
        switch self {
        case .onDevice: .onDeviceOnly
        case .privateCloud: .privateCloudAllowed
        case .thirdParty: .thirdPartyAllowed
        }
    }

    public static var current: ModelPrivacy {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ModelPrivacy.init(rawValue:)) ?? .onDevice
    }
}

/// Settings → Models: which models are installed, how far questions may go,
/// and the opt-in Claude key.
struct ModelSettingsSection: View {
    @Environment(NexusEnvironment.self) private var env
    @AppStorage(ModelPrivacy.storageKey) private var privacy = ModelPrivacy.onDevice
    @State private var key = ""
    @State private var hasKey = CloudCredentials.key(for: "anthropic") != nil
    @State private var status: String?

    var body: some View {
        Section("Models") {
            if env.installedModels.isEmpty {
                Text("No language model is installed. Apple Intelligence needs a device that supports it (iPhone 15 Pro or later) with Apple Intelligence turned on; Claude needs a key below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(env.installedModels, id: \.self) { Label($0, systemImage: "cpu") }
            Picker("Questions may use", selection: $privacy) {
                ForEach(ModelPrivacy.allCases) { Text($0.title).tag($0) }
            }
        }
        Section {
            SecureField(hasKey ? "Key saved (enter a new one to replace)" : "Anthropic API key", text: $key)
                .textContentType(.password)
            HStack {
                Button("Save key") { save(key) }.disabled(key.isEmpty)
                if hasKey { Button("Remove key", role: .destructive) { save(nil) } }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Claude (opt-in)")
        } footer: {
            Text("Used only when third-party cloud is allowed above, and every run asks before data leaves the device. The key stays in this device's Keychain.")
        }
    }

    private func save(_ newKey: String?) {
        if CloudCredentials.setKey(newKey, for: "anthropic") {
            hasKey = newKey != nil
            key = ""
            status = newKey == nil ? "Key removed." : "Key saved."
            Task { await env.reinstallModels?() }
        } else {
            status = "The Keychain refused the key. Nothing was saved; try again."
        }
    }
}
#endif

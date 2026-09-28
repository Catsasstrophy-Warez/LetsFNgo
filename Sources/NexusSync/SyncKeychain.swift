#if canImport(Security)
import Foundation
import Security

public enum SyncKeychainError: Error, Equatable, Sendable {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(Int32)
    /// The stored item isn't a 32-byte key.
    case invalidKey
}

/// The `PayloadCipher` key in the Keychain (decision 0001).
///
/// A generic password with `kSecAttrSynchronizable`, so iCloud Keychain
/// (end-to-end encrypted) carries it to the owner's other devices and Apple
/// never holds it beside the ciphertext, and `AfterFirstUnlock`, so a sync
/// can run while the device is locked. Apple-only; no Linux fallback.
public enum SyncKeychain {
    static let service = "com.nexus.sync"
    static let account = "payload-key.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            // The modern keychain on macOS too; synchronizable items need it.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The key, or nil if neither this device nor iCloud Keychain has one yet.
    public static func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncKeychainError.keychain(status) }
        guard let data = item as? Data, data.count == PayloadCipher.keyByteCount else { throw SyncKeychainError.invalidKey }
        return data
    }

    /// The existing key, or a new random one stored for all the owner's devices.
    ///
    /// Turn sync on first on one device and let iCloud Keychain bring the key
    /// to the others: a second device that creates its own key before the
    /// first one arrives syncs with records it can't open, which surfaces as
    /// `CloudSyncError.keyMismatch`.
    public static func loadOrCreateKey() throws -> Data {
        if let key = try loadKey() { return key }
        let key = PayloadCipher.generateKeyData()
        var add = baseQuery
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Nexus sync key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try loadKey() { return existing }
        guard status == errSecSuccess else { throw SyncKeychainError.keychain(status) }
        return key
    }

    /// Removes the key from this device and, through iCloud Keychain, from
    /// the others. Synced data can't be read afterwards.
    public static func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncKeychainError.keychain(status) }
    }
}
#endif

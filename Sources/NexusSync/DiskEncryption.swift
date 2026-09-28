import Foundation

/// Whether the volume holding the store is encrypted (decision 0001: on
/// macOS the store relies on FileVault, and the app says when it's off).
public enum DiskEncryption: String, Sendable {
    case encrypted
    case notEncrypted
    case unknown

    /// Best effort and sandbox-safe: reads the volume's `volumeIsEncrypted`
    /// resource value (no `fdesetup`, which the sandbox forbids). On Apple
    /// silicon the volume may report encryption from the hardware alone, so
    /// `.encrypted` doesn't prove FileVault is on; `.notEncrypted` does
    /// prove it's off. Other platforms, and any failure, give `.unknown`.
    public static func status(of url: URL) -> DiskEncryption {
        #if os(macOS)
        guard let values = try? url.resourceValues(forKeys: [.volumeIsEncryptedKey]), let encrypted = values.volumeIsEncrypted else {
            return .unknown
        }
        return encrypted ? .encrypted : .notEncrypted
        #else
        return .unknown
        #endif
    }
}

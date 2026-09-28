import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

public enum PayloadCipherError: Error, Equatable, Sendable {
    /// A key must be exactly 32 bytes (AES-256).
    case invalidKeyLength(Int)
    /// The payload is too short or has an unknown format version.
    case malformedPayload
    /// Wrong key, wrong associated data, or the bytes were altered.
    case authenticationFailed
}

/// Transport-side payload encryption: AES-256-GCM, via CryptoKit on Apple
/// platforms and swift-crypto (the same API) elsewhere.
///
/// Encrypts a change set or blob before it leaves the device, so a sync
/// service (a CloudKit container, a file share) stores only ciphertext. The
/// key never travels with the data; on Apple platforms it lives in the
/// Keychain (see docs/decisions/0001-sync-backup-encryption.md).
///
/// Sealed format: one version byte (1), then the 12-byte nonce, the
/// ciphertext and the 16-byte tag. `associatedData` (for example a record
/// name or a blob's SHA-256) is authenticated but not stored, so a payload
/// cannot be swapped onto another record undetected.
public struct PayloadCipher: Sendable {
    public static let keyByteCount = 32
    static let formatVersion: UInt8 = 1
    static let overhead = 1 + 12 + 16

    /// Raw key bytes. `SymmetricKey` is not `Sendable` in every swift-crypto
    /// release, so the key is rebuilt for each operation.
    private let keyData: Data

    public init(keyData: Data) throws {
        guard keyData.count == Self.keyByteCount else { throw PayloadCipherError.invalidKeyLength(keyData.count) }
        self.keyData = keyData
    }

    private var key: SymmetricKey { SymmetricKey(data: keyData) }

    /// A short, public fingerprint of the key: 16 hex characters of a
    /// domain-separated SHA-256. Records carry it, so a device holding a
    /// different key reports a clear mismatch instead of a decryption failure.
    public var keyID: String {
        let digest = SHA256.hash(data: Data("nexus.sync.key-id.v1".utf8) + keyData)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 random bytes for a new key, from the system's secure generator.
    public static func generateKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public func seal(_ plaintext: Data, associatedData: Data = Data()) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let combined = box.combined else { throw PayloadCipherError.malformedPayload }
        return Data([Self.formatVersion]) + combined
    }

    public func open(_ sealed: Data, associatedData: Data = Data()) throws -> Data {
        guard sealed.count >= Self.overhead, sealed.first == Self.formatVersion else { throw PayloadCipherError.malformedPayload }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
        } catch {
            throw PayloadCipherError.malformedPayload
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            throw PayloadCipherError.authenticationFailed
        }
    }
}

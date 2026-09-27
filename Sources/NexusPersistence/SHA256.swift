import Foundation

/// SHA-256 (FIPS 180-4) in pure Swift.
///
/// CryptoKit is Apple-only, and blob identity must be computed identically on
/// every platform, so the store carries its own small implementation. It is
/// used for content addressing, not for anything security-sensitive.
public enum ContentHash {
    /// Lowercase hex SHA-256 digest of `data`.
    public static func sha256(_ data: Data) -> String {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex SHA-256 digest of the UTF-8 bytes of `text`.
    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// Whether `text` looks like a digest produced by `sha256(_:)`.
    public static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// Incremental SHA-256 state.
struct SHA256Hasher {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0
    private var schedule = [UInt32](repeating: 0, count: 64)

    init() {
        buffer.reserveCapacity(64)
    }

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            if !buffer.isEmpty {
                let take = min(64 - buffer.count, bytes.count)
                buffer.append(contentsOf: bytes[0..<take])
                index = take
                if buffer.count == 64 {
                    let block = buffer
                    block.withUnsafeBufferPointer { compress($0, at: 0) }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            while index + 64 <= bytes.count {
                compress(bytes, at: index)
                index += 64
            }
            if index < bytes.count {
                buffer.append(contentsOf: bytes[index...])
            }
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        tail.withUnsafeBufferPointer { pointer in
            for offset in stride(from: 0, to: pointer.count, by: 64) {
                compress(pointer, at: offset)
            }
        }
        buffer.removeAll()
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) } }
    }

    private mutating func compress(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) {
        for t in 0..<16 {
            let base = offset + 4 * t
            schedule[t] = UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16
                | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
        }
        for t in 16..<64 {
            let s0 = schedule[t - 15].rotatedRight(7) ^ schedule[t - 15].rotatedRight(18) ^ (schedule[t - 15] >> 3)
            let s1 = schedule[t - 2].rotatedRight(17) ^ schedule[t - 2].rotatedRight(19) ^ (schedule[t - 2] >> 10)
            schedule[t] = schedule[t - 16] &+ s0 &+ schedule[t - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for t in 0..<64 {
            let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choice &+ Self.k[t] &+ schedule[t]
            let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }
}

private extension UInt32 {
    func rotatedRight(_ count: UInt32) -> UInt32 {
        (self >> count) | (self << (32 - count))
    }
}

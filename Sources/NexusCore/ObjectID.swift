import Foundation

/// Stable identity for every canonical object.
///
/// IDs are UUIDv7 (RFC 9562): the leading 48 bits are a Unix-millisecond
/// timestamp, so IDs sort by creation time both as bytes and as their
/// lowercase string form. That keeps SQLite primary-key inserts append-mostly
/// and makes timelines cheap to order.
public struct ObjectID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID) {
        self.uuid = uuid
    }

    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    /// A new time-ordered ID from the shared generator.
    public static func make() -> ObjectID {
        ObjectID(uuid: IDGenerator.shared.next())
    }

    public var description: String { uuid.uuidString.lowercased() }

    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = ObjectID(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ObjectID: \(string)")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Identity of one revision of a mutable object or artifact.
public struct RevisionID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let raw: ObjectID

    public init(raw: ObjectID) {
        self.raw = raw
    }

    public init?(_ string: String) {
        guard let raw = ObjectID(string) else { return nil }
        self.raw = raw
    }

    public static func make() -> RevisionID {
        RevisionID(raw: .make())
    }

    public var description: String { raw.description }

    public static func < (lhs: RevisionID, rhs: RevisionID) -> Bool {
        lhs.raw < rhs.raw
    }

    public init(from decoder: Decoder) throws {
        raw = try ObjectID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}

/// Monotonic UUIDv7 generator.
///
/// Within one millisecond the 12-bit `rand_a` field is used as a counter
/// (RFC 9562 §6.2, method 1), so IDs from one generator are strictly
/// increasing even when many are minted per millisecond.
public final class IDGenerator: @unchecked Sendable {
    public static let shared = IDGenerator()

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var lastMillis: UInt64 = 0
    private var counter: UInt16 = 0

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }

        var millis = UInt64(max(0, now().timeIntervalSince1970 * 1000))
        if millis <= lastMillis {
            millis = lastMillis
            counter += 1
            if counter > 0x0FFF {
                millis += 1
                counter = 0
            }
        } else {
            // Start low in the counter space to leave room for a burst.
            counter = UInt16.random(in: 0...0x03FF)
        }
        lastMillis = millis

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - index)))
        }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: counter >> 8) & 0x0F
        bytes[7] = UInt8(truncatingIfNeeded: counter)
        var rng = SystemRandomNumberGenerator()
        for index in 8..<16 {
            bytes[index] = rng.next()
        }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

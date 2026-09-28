import Foundation

/// How an adapter is reached.
public enum OBDTransportKind: String, Codable, Sendable, CaseIterable {
    case bluetoothLE
    case wifi
    case serial
    case mock

    public var title: String {
        switch self {
        case .bluetoothLE: "Bluetooth LE"
        case .wifi: "Wi-Fi"
        case .serial: "Serial"
        case .mock: "Simulated adapter"
        }
    }
}

/// Which adapter a transport talks to. `identifier` is stable for the same
/// physical adapter (a BLE peripheral UUID, "host:port"), so readings from it
/// keep one instrument identity across drives.
public struct OBDAdapterDescriptor: Hashable, Codable, Sendable {
    public var kind: OBDTransportKind
    public var identifier: String
    public var name: String

    public init(kind: OBDTransportKind, identifier: String, name: String) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
    }
}

/// A byte stream to and from an ELM327-compatible adapter.
///
/// The transport only moves bytes. Framing on the `>` prompt, echo, retries
/// and timeouts belong to `ELM327Session`, so every link (Bluetooth LE,
/// Wi-Fi TCP, a serial port, a scripted mock) behaves the same above it.
public protocol OBDTransport: AnyObject, Sendable {
    var descriptor: OBDAdapterDescriptor { get }
    /// Bytes from the adapter in arrival order, in whatever chunks the link
    /// delivers them. It finishes when the link closes.
    var received: AsyncStream<[UInt8]> { get }
    /// Opens the link. Throws `OBDLinkError.transport` when it can't.
    func open() async throws
    func send(_ bytes: [UInt8]) async throws
    func close() async
}

// MARK: Mock

/// What a scripted adapter does with one command.
public enum MockAdapterReply: Sendable, Hashable {
    /// Prints `text` (lines separated by "\r" or "\n"), then the `>` prompt.
    case text(String)
    /// Prints exactly these bytes, with no prompt added.
    case raw([UInt8])
    /// Says nothing: the session must time out.
    case silence
}

/// A transport that replays scripted adapter responses, for tests and demos.
///
/// It behaves like a real ELM327 in the ways sessions must cope with: echo is
/// on after power-up and `ATZ`, and off after `ATE0` (unless the clone
/// ignores it); linefeeds follow `ATL`; replies arrive in small chunks; and a
/// clone may emit junk bytes after a reset.
public final class MockOBDTransport: OBDTransport, @unchecked Sendable {
    public let descriptor: OBDAdapterDescriptor
    public let received: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let lock = NSLock()
    private var script: [(command: String, reply: MockAdapterReply)]
    private let responder: (@Sendable (String) -> MockAdapterReply?)?
    private var echo = true
    private var linefeeds = true
    private var sentCommands: [String] = []
    private var unexpected: [String] = []
    private var pending: [UInt8] = []
    private var isOpen = false
    /// Bytes per delivered chunk; a real BLE link delivers 20 at a time.
    public let chunkSize: Int
    /// True for clones that keep echoing after `ATE0`.
    public let ignoresEchoOff: Bool
    /// Bytes a clone prints after `ATZ` before its banner.
    public let resetNoise: [UInt8]
    /// When set, `open()` throws this.
    public let openFailure: String?

    /// - Parameters:
    ///   - script: Exchanges in order. Each command is matched ignoring case
    ///     and spaces; a command out of turn gets `?` and is recorded in
    ///     `unexpectedCommands`.
    ///   - responder: Answers any command the script doesn't hold, like a
    ///     simulated car. Returning nil answers `?`.
    public init(
        script: [(String, MockAdapterReply)] = [], responder: (@Sendable (String) -> MockAdapterReply?)? = nil,
        descriptor: OBDAdapterDescriptor = OBDAdapterDescriptor(kind: .mock, identifier: "mock", name: "Scripted ELM327"),
        chunkSize: Int = 20, ignoresEchoOff: Bool = false, resetNoise: [UInt8] = [], openFailure: String? = nil
    ) {
        self.script = script.map { (Self.normalize($0.0), $0.1) }
        self.responder = responder
        self.descriptor = descriptor
        self.chunkSize = max(1, chunkSize)
        self.ignoresEchoOff = ignoresEchoOff
        self.resetNoise = resetNoise
        self.openFailure = openFailure
        (received, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    /// Every command received, normalized ("010C", "ATZ").
    public var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentCommands
    }

    /// Commands that arrived out of script order and had no responder answer.
    public var unexpectedCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return unexpected
    }

    /// Scripted exchanges not yet used.
    public var remainingScript: Int {
        lock.lock()
        defer { lock.unlock() }
        return script.count
    }

    static func normalize(_ command: String) -> String {
        command.uppercased().filter { !$0.isWhitespace }
    }

    public func open() async throws {
        if let openFailure { throw OBDLinkError.transport(openFailure) }
        lock.withLock { isOpen = true }
    }

    public func close() async {
        lock.withLock { isOpen = false }
        continuation.finish()
    }

    public func send(_ bytes: [UInt8]) async throws {
        let output: [[UInt8]]? = lock.withLock {
            guard isOpen else { return nil }
            pending += bytes
            var output: [[UInt8]] = []
            // An ELM327 acts on a carriage return; anything before it is the command.
            while let end = pending.firstIndex(of: 0x0D) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                output.append(respond(to: line))
            }
            return output
        }
        guard let output else { throw OBDLinkError.notConnected }
        for bytes in output where !bytes.isEmpty {
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                continuation.yield(Array(bytes[start..<min(start + chunkSize, bytes.count)]))
            }
        }
    }

    /// Must be called with the lock held.
    private func respond(to line: String) -> [UInt8] {
        let command = Self.normalize(line)
        sentCommands.append(command)
        let reply: MockAdapterReply
        if let next = script.first, next.command == command {
            script.removeFirst()
            reply = next.reply
        } else if let answer = responder?(command) {
            reply = answer
        } else {
            unexpected.append(command)
            reply = .text("?")
        }
        let newline = linefeeds ? "\r\n" : "\r"
        var prefix: [UInt8] = []
        if echo { prefix = Array((line + newline).utf8) }
        // A setting the adapter refused ("?") doesn't change its behaviour.
        switch reply == .text("?") ? "" : command {
        case "ATZ", "ATWS", "ATD":
            echo = true
            linefeeds = true
            if command == "ATZ" { prefix += resetNoise }
        case "ATE0":
            if !ignoresEchoOff { echo = false }
        case "ATE1":
            echo = true
        case "ATL0":
            linefeeds = false
        case "ATL1":
            linefeeds = true
        default:
            break
        }
        switch reply {
        case .silence:
            return []
        case .raw(let bytes):
            return prefix + bytes
        case .text(let text):
            let lines = text.split(whereSeparator: \.isNewline).joined(separator: newline)
            return prefix + Array((lines + newline + newline + ">").utf8)
        }
    }
}

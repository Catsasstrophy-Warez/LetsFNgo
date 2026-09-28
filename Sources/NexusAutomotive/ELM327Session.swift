import Foundation

/// The vehicle protocol an ELM327 settled on (`ATDPN`), SAE J1979 / ISO 15765-4.
public struct OBDProtocol: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The ELM327 protocol number, "1"…"9", "A"…"C"; "?" when unknown.
    public var number: String
    public var name: String
    /// Chosen by the adapter's automatic search (`ATSP0`).
    public var automatic: Bool

    public init(number: String, name: String? = nil, automatic: Bool = false) {
        self.number = number.uppercased()
        self.name = name ?? Self.names[self.number] ?? "Unknown protocol"
        self.automatic = automatic
    }

    /// Parses an `ATDPN` reply: "A6" is protocol 6 found automatically.
    public init?(describeProtocolNumber reply: String) {
        var text = reply.uppercased().filter { !$0.isWhitespace }
        let automatic = text.count == 2 && text.hasPrefix("A")
        if automatic { text.removeFirst() }
        guard text.count == 1, Self.names[text] != nil else { return nil }
        self.init(number: text, automatic: automatic)
    }

    /// ISO 15765-4 CAN (and J1939): trouble-code replies carry a count byte.
    public var isCAN: Bool { ["6", "7", "8", "9", "A", "B", "C"].contains(number) }

    public var description: String { name }

    static let names: [String: String] = [
        "1": "SAE J1850 PWM (41.6 kbaud)",
        "2": "SAE J1850 VPW (10.4 kbaud)",
        "3": "ISO 9141-2 (5 baud init)",
        "4": "ISO 14230-4 KWP (5 baud init)",
        "5": "ISO 14230-4 KWP (fast init)",
        "6": "ISO 15765-4 CAN (11 bit, 500 kbaud)",
        "7": "ISO 15765-4 CAN (29 bit, 500 kbaud)",
        "8": "ISO 15765-4 CAN (11 bit, 250 kbaud)",
        "9": "ISO 15765-4 CAN (29 bit, 250 kbaud)",
        "A": "SAE J1939 CAN (29 bit, 250 kbaud)",
        "B": "User1 CAN (11 bit, 125 kbaud)",
        "C": "User2 CAN (11 bit, 50 kbaud)",
    ]
}

/// What the session learned while connecting.
public struct ELM327Identity: Hashable, Sendable {
    public var adapter: OBDAdapterDescriptor
    /// The `ATZ` banner, e.g. "ELM327 v1.5".
    public var version: String
    public var vehicleProtocol: OBDProtocol
    /// Headers on (`ATH1`) was accepted.
    public var headers: Bool
    /// The adapter's own reading at pin 16 (`ATRV`), when it supports it.
    public var voltage: Double?
    /// Control modules that answered the first request ("7E8", "7E9"), when headers are on.
    public var modules: [String]
}

/// A conversation with an ELM327-compatible adapter over any `OBDTransport`.
///
/// Every command is a line ending in a carriage return; every reply ends at the
/// adapter's `>` prompt. The session frames replies on that prompt, strips
/// echoes and junk bytes, times out a reply that never finishes, retries
/// timeouts and transient bus errors (`STOPPED`, `BUS BUSY`, `CAN ERROR`…),
/// and turns `NO DATA`, `UNABLE TO CONNECT`, `?` and ECU negative responses
/// into typed errors. Replies are parsed with `ELM327.parse`.
///
/// `connect()` runs the standard initialisation: `ATZ` (reset), `ATE0`
/// (echo off), `ATL0` (linefeeds off), `ATS0` (spaces off), `ATH1` (headers
/// on, so replies name their module), `ATSP0` (automatic protocol), then
/// `ATRV`, `0100` (which starts the protocol search) and `ATDPN`/`ATDP`.
/// Clones that ignore a setting still work: echo and spaces are handled in
/// parsing, and a refused `ATH1` switches parsing to headers off.
public actor ELM327Session {
    public struct Configuration: Sendable {
        /// How long a normal command may take to reach the prompt.
        public var commandTimeout: Duration
        /// `ATZ` resets the chip; clones can take a few seconds.
        public var resetTimeout: Duration
        /// The first OBD request makes the adapter try each protocol in turn.
        public var searchTimeout: Duration
        /// Extra attempts after a timeout or transient bus error.
        public var retries: Int
        public var retryDelay: Duration

        public init(
            commandTimeout: Duration = .seconds(2), resetTimeout: Duration = .seconds(5), searchTimeout: Duration = .seconds(15),
            retries: Int = 2, retryDelay: Duration = .milliseconds(150)
        ) {
            self.commandTimeout = commandTimeout
            self.resetTimeout = resetTimeout
            self.searchTimeout = searchTimeout
            self.retries = max(0, retries)
            self.retryDelay = retryDelay
        }
    }

    public nonisolated let transport: any OBDTransport
    public let configuration: Configuration
    public private(set) var identity: ELM327Identity?
    /// Headers on; set by `connect()`.
    public private(set) var headers = true
    /// Every command and raw reply, newest last (up to 200), for diagnostics.
    public private(set) var log: [(command: String, reply: String)] = []

    private var buffer: [UInt8] = []
    private var responses: [String] = []
    private var waiter: (token: Int, continuation: CheckedContinuation<String, Error>)?
    private var timer: Task<Void, Never>?
    private var nextToken = 0
    private var reader: Task<Void, Never>?
    private var isOpen = false
    private var exchanging = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    static let transient = [
        "STOPPED", "BUS BUSY", "CAN ERROR", "BUFFER FULL", "DATA ERROR", "<DATA ERROR", "RX ERROR", "<RX ERROR", "FB ERROR", "BUS ERROR",
        "LP ALERT", "LV RESET",
    ]

    public init(transport: any OBDTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: Connecting

    /// Opens the link, initialises the adapter and finds the vehicle's protocol.
    @discardableResult
    public func connect() async throws -> ELM327Identity {
        if let identity, isOpen { return identity }
        try await transport.open()
        isOpen = true
        startReading()

        let banner = try await command("ATZ", timeout: configuration.resetTimeout)
        let version = banner.first { $0.contains("ELM") || $0.contains("OBD") || $0.contains("STN") } ?? banner.last ?? "ELM327"
        _ = try? await command("ATE0")
        _ = try? await command("ATL0")
        _ = try? await command("ATS0")
        headers = (try? await command("ATH1"))?.contains("OK") ?? false
        _ = try? await command("ATSP0")
        let voltage = (try? await command("ATRV")).flatMap { ELM327.parseVoltage($0.joined()) }

        // The first request starts the protocol search ("SEARCHING...").
        let first: [ECUMessage]
        do {
            first = try await request("0100", timeout: configuration.searchTimeout)
        } catch let error as OBDLinkError {
            switch error {
            case .noData, .bus, .noVehicleResponse, .negativeResponse, .malformed:
                throw OBDLinkError.noVehicleResponse(String(describing: error))
            default:
                throw error
            }
        }
        var vehicleProtocol = (try? await command("ATDPN")).flatMap { $0.last.flatMap(OBDProtocol.init(describeProtocolNumber:)) }
        if vehicleProtocol == nil {
            // Infer from the reply layout when the clone doesn't know ATDPN.
            let header = first.compactMap(\.ecu).first ?? ""
            vehicleProtocol = OBDProtocol(number: header.count == 3 ? "6" : header.count == 8 ? "7" : "?", automatic: true)
        }
        if var named = vehicleProtocol, let described = (try? await command("ATDP"))?.last, !described.isEmpty, described != "?" {
            named.name = described.hasPrefix("AUTO, ") ? String(described.dropFirst(6)) : described
            vehicleProtocol = named
        }
        let identity = ELM327Identity(
            adapter: transport.descriptor, version: version, vehicleProtocol: vehicleProtocol!, headers: headers, voltage: voltage,
            modules: Array(Set(first.compactMap(\.ecu))).sorted()
        )
        self.identity = identity
        return identity
    }

    /// Closes the link. Any waiting request fails with `notConnected`.
    public func disconnect() async {
        isOpen = false
        identity = nil
        fail(OBDLinkError.notConnected)
        reader?.cancel()
        reader = nil
        await transport.close()
    }

    public var isConnected: Bool { isOpen && identity != nil }

    // MARK: Commands

    /// Sends an AT command and returns its reply lines (echo removed).
    /// Throws `unsupportedCommand` for `?`.
    @discardableResult
    public func command(_ text: String, timeout: Duration? = nil) async throws -> [String] {
        let lines = try await exchange(text, timeout: timeout ?? configuration.commandTimeout)
        if lines.contains("?") { throw OBDLinkError.unsupportedCommand(text) }
        return lines
    }

    /// Sends an OBD request ("010C", "03", "0902") and returns each module's
    /// reassembled reply. Negative responses (`7F`) are dropped when another
    /// module answered positively, and thrown otherwise.
    public func request(_ text: String, timeout: Duration? = nil) async throws -> [ECUMessage] {
        let lines = try await exchange(text, timeout: timeout ?? configuration.commandTimeout)
        if lines.contains("?") { throw OBDLinkError.unsupportedCommand(text) }
        if let line = lines.first(where: { $0.hasPrefix("UNABLE TO CONNECT") || $0.hasPrefix("NO CONNECT") }) {
            throw OBDLinkError.noVehicleResponse(line)
        }
        if let line = lines.first(where: { $0.contains("ERROR") }) { throw OBDLinkError.bus(line) }
        let messages: [ECUMessage]
        do {
            messages = try ELM327.parse(lines.joined(separator: "\n"), headers: headers ? .on : .off, command: text)
        } catch ELM327Error.noData {
            throw OBDLinkError.noData(command: text)
        } catch ELM327Error.adapter(let line) {
            throw OBDLinkError.bus(line)
        } catch ELM327Error.malformed(let line) {
            throw OBDLinkError.malformed(line)
        }
        let positive = messages.filter { $0.bytes.first != 0x7F }
        if positive.isEmpty, let refusal = messages.first(where: { $0.bytes.count >= 3 }) {
            throw OBDLinkError.negativeResponse(service: refusal.bytes[1], code: refusal.bytes[2])
        }
        if positive.isEmpty { throw OBDLinkError.noData(command: text) }
        return positive.sorted { ($0.ecu ?? "") < ($1.ecu ?? "") }
    }

    /// One command with retries: returns cleaned reply lines. Commands run one
    /// at a time: the adapter handles a single request until its prompt, so a
    /// code read started during live polling waits for the current PID.
    private func exchange(_ text: String, timeout: Duration) async throws -> [String] {
        if exchanging {
            await withCheckedContinuation { queued.append($0) }
        }
        exchanging = true
        defer {
            if queued.isEmpty {
                exchanging = false
            } else {
                queued.removeFirst().resume()  // Hand the turn straight to the next command.
            }
        }
        var attempt = 0
        while true {
            do {
                let reply = try await roundTrip(text, timeout: timeout)
                let lines = Self.lines(reply, command: text)
                if let transient = lines.first(where: { line in Self.transient.contains { line.hasPrefix($0) } }) {
                    throw OBDLinkError.bus(transient)
                }
                return lines
            } catch let error as OBDLinkError where error.isRetryable && attempt < configuration.retries {
                attempt += 1
                try await Task.sleep(for: configuration.retryDelay)
            }
        }
    }

    /// Reply lines without the echo, blanks and the prompt, upper-cased.
    static func lines(_ reply: String, command: String) -> [String] {
        let echo = command.uppercased().filter { !$0.isWhitespace }
        // `isNewline`, not a comparison with "\r": with linefeeds on, "\r\n" is one Character.
        return reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && $0.filter { !$0.isWhitespace } != echo }
    }

    // MARK: Framing

    private func roundTrip(_ text: String, timeout: Duration) async throws -> String {
        guard isOpen else { throw OBDLinkError.notConnected }
        // Drop anything left from an earlier reply that arrived late.
        buffer.removeAll()
        responses.removeAll()
        let command = text.uppercased().filter { !$0.isWhitespace }
        do {
            try await transport.send(Array((command + "\r").utf8))
        } catch let error as OBDLinkError {
            throw error
        } catch {
            throw OBDLinkError.transport(String(describing: error))
        }
        let reply = try await nextResponse(timeout: timeout, command: command)
        log.append((command, reply))
        if log.count > 200 { log.removeFirst(log.count - 200) }
        return reply
    }

    private func nextResponse(timeout: Duration, command: String) async throws -> String {
        if !responses.isEmpty { return responses.removeFirst() }
        nextToken += 1
        let token = nextToken
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                waiter = (token, continuation)
                timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(token, OBDLinkError.timeout(command: command))
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.expire(token, CancellationError()) }
        }
    }

    private func expire(_ token: Int, _ error: any Error) {
        guard let waiter, waiter.token == token else { return }
        self.waiter = nil
        timer?.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func fail(_ error: any Error) {
        guard let waiter else { return }
        self.waiter = nil
        timer?.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func startReading() {
        reader?.cancel()
        let stream = transport.received
        reader = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.deliver(chunk)
            }
            await self?.linkClosed()
        }
    }

    private func linkClosed() {
        isOpen = false
        fail(OBDLinkError.notConnected)
    }

    /// Appends printable bytes and completes a reply at each `>` prompt.
    /// Clones print NULs and other junk after a reset; those are dropped.
    private func deliver(_ chunk: [UInt8]) {
        buffer += chunk.filter { (0x20...0x7E).contains($0) || $0 == 0x0D || $0 == 0x0A }
        while let prompt = buffer.firstIndex(of: UInt8(ascii: ">")) {
            let text = String(decoding: buffer[..<prompt], as: UTF8.self)
            buffer.removeSubrange(...prompt)
            if let waiter {
                self.waiter = nil
                timer?.cancel()
                waiter.continuation.resume(returning: text)
            } else {
                responses.append(text)
            }
        }
    }
}

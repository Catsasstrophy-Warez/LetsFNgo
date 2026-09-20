import Foundation

/// Anything the streams emit, funnelled into one sequence so the engine has
/// a single inbox rather than two racing callbacks.
enum StreamEvent: Sendable {
    case bar(MinuteBar)
    case news(NewsItem)
    case status(StreamStatus, stream: StreamKind)
    case error(String)
}

enum StreamKind: String, Sendable { case bars, news }

/// Long-lived websocket connection to Alpaca.
///
/// Two facts about the free plan shape this class:
/// 1. Only one concurrent connection per feed is allowed, so this is a single
///    task that owns the socket, not a pool.
/// 2. Trades and quotes are capped at 30 channels, but minute bars are not
///    capped at all — so the engine subscribes to `bars` only and never
///    touches `trades`/`quotes`. That is the whole reason the design is
///    bar-driven rather than tick-driven.
actor AlpacaStream {
    private let kind: StreamKind
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var symbols: [String] = []
    private var continuation: AsyncStream<StreamEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isStopping = false

    private let decoder: JSONDecoder

    // See AlpacaREST's equivalent statics for why this needs to be
    // nonisolated(unsafe) hoisted rather than a local captured by the
    // @Sendable decoding closure below.
    nonisolated(unsafe) private static let withFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(kind: StreamKind) {
        self.kind = kind
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let str = try d.singleValueContainer().decode(String.self)
            guard let date = Self.withFractionFormatter.date(from: str) ?? Self.plainFormatter.date(from: str) else {
                throw AlpacaError.decoding("Unparseable timestamp: \(str)")
            }
            return date
        }
    }

    private var url: URL {
        switch kind {
        case .bars: return URL(string: "wss://stream.data.alpaca.markets/v2/iex")!
        case .news: return URL(string: "wss://stream.data.alpaca.markets/v1beta1/news")!
        }
    }

    // MARK: - Lifecycle

    func events(symbols: [String]) -> AsyncStream<StreamEvent> {
        self.symbols = symbols
        isStopping = false
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
            self.runTask = Task { await self.runLoop() }
        }
    }

    func updateSymbols(_ newSymbols: [String]) async {
        let added = Set(newSymbols).subtracting(symbols)
        let removed = Set(symbols).subtracting(newSymbols)
        symbols = newSymbols
        guard task != nil else { return }
        if !removed.isEmpty { try? await send(action: "unsubscribe", symbols: Array(removed)) }
        if !added.isEmpty { try? await send(action: "subscribe", symbols: Array(added)) }
    }

    func stop() {
        isStopping = true
        runTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Connection loop

    private func runLoop() async {
        while !isStopping && !Task.isCancelled {
            do {
                emit(.status(reconnectAttempt == 0 ? .connecting : .reconnecting, stream: kind))
                try await connectAndAuthenticate()
                reconnectAttempt = 0
                try await receiveLoop()
            } catch {
                if isStopping || Task.isCancelled { return }
                emit(.error("\(kind.rawValue) stream: \(error.localizedDescription)"))
                emit(.status(.reconnecting, stream: kind))
            }
            guard !isStopping && !Task.isCancelled else { return }
            // Exponential backoff, capped. Alpaca will drop a client that
            // reconnects in a tight loop, which is worse than waiting.
            reconnectAttempt = min(reconnectAttempt + 1, 6)
            let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func connectAndAuthenticate() async throws {
        let settings = Settings.shared
        guard settings.hasCredentials else { throw AlpacaError.missingCredentials }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        task = socket

        // The server greets with [{"T":"success","msg":"connected"}] first.
        _ = try await receiveMessages()

        emit(.status(.authenticating, stream: kind))
        let auth = ["action": "auth", "key": settings.alpacaKeyID, "secret": settings.alpacaSecret]
        try await sendJSON(auth)

        let authReply = try await receiveMessages()
        let authenticated = try authReply.contains { message in
            if case .success(let msg) = message { return msg.contains("authenticated") }
            if case .error(let code, let msg) = message {
                // 406 is the classic free-tier symptom: another session is open.
                throw AlpacaError.http(code, msg)
            }
            return false
        }
        guard authenticated else { throw AlpacaError.decoding("Authentication was refused") }

        try await send(action: "subscribe", symbols: symbols)
        emit(.status(.subscribed, stream: kind))
    }

    private func send(action: String, symbols: [String]) async throws {
        guard !symbols.isEmpty else { return }
        let payload: [String: Any]
        switch kind {
        case .bars:
            // Bars only. Deliberately not subscribing to trades or quotes —
            // those are the channels the free plan caps at 30.
            payload = ["action": action, "bars": symbols]
        case .news:
            payload = ["action": action, "news": symbols]
        }
        try await sendJSONObject(payload)
    }

    private func sendJSON(_ dict: [String: String]) async throws {
        try await sendJSONObject(dict)
    }

    private func sendJSONObject(_ dict: [String: Any]) async throws {
        guard let task else { throw AlpacaError.decoding("Socket is not open") }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop() async throws {
        while !isStopping && !Task.isCancelled {
            let messages = try await receiveMessages()
            for message in messages {
                switch message {
                case .bar(let bar): emit(.bar(bar))
                case .news(let item): emit(.news(item))
                case .error(let code, let msg): emit(.error("Alpaca \(code): \(msg)"))
                case .success, .subscription, .ignored: break
                }
            }
        }
    }

    // MARK: - Message decoding

    private enum Message {
        case bar(MinuteBar)
        case news(NewsItem)
        case success(String)
        case error(Int, String)
        case subscription
        case ignored
    }

    /// Alpaca always sends arrays, and may batch many data points into one
    /// frame if the client is slow. Decode defensively — one bad element
    /// should never take down the socket.
    private func receiveMessages() async throws -> [Message] {
        guard let task else { throw AlpacaError.decoding("Socket is not open") }
        let raw = try await task.receive()
        let data: Data
        switch raw {
        case .string(let string): data = Data(string.utf8)
        case .data(let d): data = d
        @unknown default: return []
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { element -> Message? in
            guard let type = element["T"] as? String else { return nil }
            switch type {
            case "b":
                guard let payload = try? JSONSerialization.data(withJSONObject: element),
                      let bar = try? decoder.decode(MinuteBar.self, from: payload) else { return nil }
                return .bar(bar)
            case "n":
                guard let payload = try? JSONSerialization.data(withJSONObject: element),
                      let item = try? decoder.decode(NewsItem.self, from: payload) else { return nil }
                return .news(item)
            case "success":
                return .success(element["msg"] as? String ?? "")
            case "error":
                return .error(element["code"] as? Int ?? 0, element["msg"] as? String ?? "")
            case "subscription":
                return .subscription
            default:
                return .ignored
            }
        }
    }

    private func emit(_ event: StreamEvent) {
        continuation?.yield(event)
    }
}

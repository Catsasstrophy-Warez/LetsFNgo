#if canImport(Network)
import Foundation
import Network
import NexusAutomotive

/// An ELM327 over Wi-Fi: a plain TCP socket (Network framework).
///
/// Most Wi-Fi clones create their own access point and listen on
/// 192.168.0.10:35000; some use 192.168.1.10 or port 23.
public final class WiFiTransport: OBDTransport, @unchecked Sendable {
    public static let defaultHost = "192.168.0.10"
    public static let defaultPort: UInt16 = 35000

    public let descriptor: OBDAdapterDescriptor
    public let received: AsyncStream<[UInt8]>
    private let input: AsyncStream<[UInt8]>.Continuation
    public let connectTimeout: TimeInterval

    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "nexus.obd.wifi")
    private let connection: NWConnection
    private var opening: CheckedContinuation<Void, Error>?

    public init(host: String = WiFiTransport.defaultHost, port: UInt16 = WiFiTransport.defaultPort, connectTimeout: TimeInterval = 8) {
        descriptor = OBDAdapterDescriptor(kind: .wifi, identifier: "\(host):\(port)", name: "Wi-Fi adapter at \(host):\(port)")
        self.connectTimeout = connectTimeout
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // Commands are a few bytes; don't wait to coalesce.
        tcp.connectionTimeout = Int(connectTimeout.rounded(.up))
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 35000, using: NWParameters(tls: nil, tcp: tcp)
        )
        (received, input) = AsyncStream.makeStream(of: [UInt8].self)
    }

    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                opening = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.update(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
                    self?.finishOpening(OBDLinkError.transport("Couldn't reach the adapter. Join its Wi-Fi network first."))
                }
            }
        }
        queue.async { [self] in receive() }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: OBDLinkError.transport(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    public func close() async {
        queue.async { [self] in
            finishOpening(OBDLinkError.notConnected)
            connection.cancel()
            input.finish()
        }
    }

    private func update(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishOpening(nil)
        case .waiting:
            // No route yet, or the local-network permission prompt is showing.
            // The connect timeout decides.
            break
        case .failed(let error):
            finishOpening(OBDLinkError.transport(error.localizedDescription))
            input.finish()
        case .cancelled:
            finishOpening(OBDLinkError.notConnected)
            input.finish()
        default:
            break
        }
    }

    private func finishOpening(_ error: (any Error)?) {
        guard let opening else { return }
        self.opening = nil
        if let error {
            connection.cancel()
            opening.resume(throwing: error)
        } else {
            opening.resume()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { input.yield([UInt8](data)) }
            if isComplete || error != nil {
                input.finish()
            } else {
                receive()
            }
        }
    }
}
#endif

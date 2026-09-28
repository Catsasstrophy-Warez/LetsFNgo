import Foundation

/// An adapter seen while scanning.
public struct BluetoothAdapterCandidate: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    /// Advertises a service ELM327 clones use, or has a name like one.
    public var looksLikeOBD: Bool

    public init(id: UUID, name: String, rssi: Int, looksLikeOBD: Bool) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.looksLikeOBD = looksLikeOBD
    }
}

#if canImport(CoreBluetooth)
import CoreBluetooth
import NexusAutomotive

/// The GATT layouts common ELM327 BLE clones use. Anything else is found
/// generically: a notify characteristic and a write characteristic.
enum BluetoothOBDServices {
    /// (service, notify, write). FFE0/FFE1 uses one characteristic for both.
    static let known: [(service: CBUUID, notify: CBUUID, write: CBUUID)] = [
        (CBUUID(string: "FFE0"), CBUUID(string: "FFE1"), CBUUID(string: "FFE1")),
        (CBUUID(string: "FFF0"), CBUUID(string: "FFF1"), CBUUID(string: "FFF2")),
        (CBUUID(string: "18F0"), CBUUID(string: "2AF0"), CBUUID(string: "2AF1")),
        // Microchip transparent UART (OBDLink CX and others).
        (
            CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"), CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616"),
            CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
        ),
    ]
    static var serviceUUIDs: [CBUUID] { known.map(\.service) }
    static let nameHints = ["OBD", "ELM", "VLINK", "V-LINK", "VGATE", "ICAR", "VEEPEAK", "KONNWEI", "CARISTA", "LELINK", "BLE", "SCAN"]
}

/// Scans for BLE peripherals and lists likely OBD adapters first.
///
/// Many clones don't advertise their service, so the scan isn't filtered by
/// service; every named, connectable peripheral is listed.
public final class BluetoothAdapterScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "nexus.obd.ble.scan")
    private var central: CBCentralManager!
    private var found: [UUID: BluetoothAdapterCandidate] = [:]
    private var continuation: AsyncStream<[BluetoothAdapterCandidate]>.Continuation?
    private var generation = 0

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Current candidates, likely adapters first, updated as they're seen.
    /// Scanning stops when the consumer stops iterating.
    public func scan() -> AsyncStream<[BluetoothAdapterCandidate]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [BluetoothAdapterCandidate].self, bufferingPolicy: .bufferingNewest(1))
        queue.async { [self] in
            generation += 1
            let current = generation
            let previous = self.continuation
            self.continuation = continuation
            previous?.finish()
            found = [:]
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    // A newer scan owns the manager now.
                    guard self.generation == current else { return }
                    if self.central.isScanning { self.central.stopScan() }
                    self.continuation = nil
                }
            }
            startIfReady()
        }
        return stream
    }

    /// Why scanning can't run, or nil when Bluetooth is available.
    public var unavailableReason: String? {
        queue.sync { Self.reason(central.state) }
    }

    static func reason(_ state: CBManagerState) -> String? {
        switch state {
        case .poweredOn, .unknown, .resetting: nil
        case .poweredOff: "Bluetooth is off."
        case .unauthorized: "Nexus isn't allowed to use Bluetooth. Allow it in Settings."
        case .unsupported: "This device doesn't support Bluetooth LE."
        @unknown default: nil
        }
    }

    private func startIfReady() {
        guard continuation != nil, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        startIfReady()
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertised, !name.isEmpty else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let upper = name.uppercased()
        let likely =
            services.contains { BluetoothOBDServices.serviceUUIDs.contains($0) } || BluetoothOBDServices.nameHints.contains { upper.contains($0) }
        found[peripheral.identifier] = BluetoothAdapterCandidate(id: peripheral.identifier, name: name, rssi: RSSI.intValue, looksLikeOBD: likely)
        continuation?.yield(found.values.sorted { ($0.looksLikeOBD ? 0 : 1, -$0.rssi, $0.name) < ($1.looksLikeOBD ? 0 : 1, -$1.rssi, $1.name) })
    }
}

/// An ELM327 over Bluetooth LE (CoreBluetooth).
///
/// It connects to one peripheral by identifier, discovers every service,
/// and picks a notify characteristic for replies and a write characteristic
/// for commands, preferring the known clone layouts (FFE0/FFE1, FFF0/FFF1+FFF2,
/// 18F0/2AF0+2AF1). Writes are split to the peripheral's maximum length.
public final class BluetoothLETransport: NSObject, OBDTransport, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public let descriptor: OBDAdapterDescriptor
    public let received: AsyncStream<[UInt8]>
    private let input: AsyncStream<[UInt8]>.Continuation
    public let connectTimeout: TimeInterval

    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "nexus.obd.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notify: CBCharacteristic?
    private var write: CBCharacteristic?
    private var opening: CheckedContinuation<Void, Error>?
    /// Sends waiting for acknowledgement: chunks still unacknowledged, and the caller.
    private var writes: [(remaining: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var servicesPending = 0

    public init(peripheral id: UUID, name: String, connectTimeout: TimeInterval = 10) {
        descriptor = OBDAdapterDescriptor(kind: .bluetoothLE, identifier: id.uuidString, name: name)
        self.connectTimeout = connectTimeout
        (received, input) = AsyncStream.makeStream(of: [UInt8].self)
        super.init()
    }

    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                opening = continuation
                if central == nil {
                    central = CBCentralManager(delegate: self, queue: queue)
                } else {
                    connectIfReady()
                }
                queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
                    self?.finishOpening(OBDLinkError.transport("The adapter didn't finish connecting."))
                }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let peripheral, let write, peripheral.state == .connected else {
                    continuation.resume(throwing: OBDLinkError.notConnected)
                    return
                }
                guard !bytes.isEmpty else {
                    continuation.resume()
                    return
                }
                let withResponse = write.properties.contains(.write)
                let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
                let limit = max(20, peripheral.maximumWriteValueLength(for: type))
                let chunks = stride(from: 0, to: bytes.count, by: limit).map { Data(bytes[$0..<min($0 + limit, bytes.count)]) }
                if withResponse {
                    // Resumed by didWriteValueFor once every chunk is acknowledged.
                    writes.append((chunks.count, continuation))
                }
                for chunk in chunks { peripheral.writeValue(chunk, for: write, type: type) }
                if !withResponse { continuation.resume() }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let peripheral { central?.cancelPeripheralConnection(peripheral) }
                peripheral = nil
                failPending(OBDLinkError.notConnected)
                input.finish()
                continuation.resume()
            }
        }
    }

    // MARK: Connecting

    private func connectIfReady() {
        guard opening != nil, let central else { return }
        switch central.state {
        case .poweredOn:
            guard let target = central.retrievePeripherals(withIdentifiers: [UUID(uuidString: descriptor.identifier)!]).first else {
                finishOpening(OBDLinkError.transport("The adapter is out of range or was forgotten. Scan again."))
                return
            }
            peripheral = target
            target.delegate = self
            central.connect(target)
        case .unknown, .resetting:
            break  // Wait for the next state update.
        default:
            finishOpening(OBDLinkError.transport(BluetoothAdapterScanner.reason(central.state) ?? "Bluetooth isn't available."))
        }
    }

    private func finishOpening(_ error: (any Error)?) {
        guard let opening else { return }
        self.opening = nil
        if let error {
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            opening.resume(throwing: error)
        } else {
            opening.resume()
        }
    }

    private func failPending(_ error: any Error) {
        finishOpening(error)
        let waiting = writes
        writes = []
        for write in waiting { write.continuation.resume(throwing: error) }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            connectIfReady()
        } else if let reason = BluetoothAdapterScanner.reason(central.state) {
            failPending(OBDLinkError.transport(reason))
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        servicesPending = 0
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        finishOpening(OBDLinkError.transport(error?.localizedDescription ?? "The adapter refused the connection."))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        failPending(OBDLinkError.notConnected)
        input.finish()
    }

    // MARK: Discovery

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            finishOpening(OBDLinkError.transport("The adapter has no services."))
            return
        }
        servicesPending = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        servicesPending -= 1
        guard servicesPending <= 0, opening != nil else { return }
        guard let pair = Self.choose(peripheral.services ?? []) else {
            finishOpening(OBDLinkError.transport("No serial characteristic pair (notify + write) was found on this device."))
            return
        }
        notify = pair.0
        write = pair.1
        peripheral.setNotifyValue(true, for: pair.0)
    }

    /// Picks the reply and command characteristics: a known layout first,
    /// then any service with both a notify and a write characteristic, then
    /// any notify and write characteristic on the device.
    static func choose(_ services: [CBService]) -> (CBCharacteristic, CBCharacteristic)? {
        func canNotify(_ c: CBCharacteristic) -> Bool { c.properties.contains(.notify) || c.properties.contains(.indicate) }
        func canWrite(_ c: CBCharacteristic) -> Bool { c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) }
        for layout in BluetoothOBDServices.known {
            guard let service = services.first(where: { $0.uuid == layout.service }), let characteristics = service.characteristics else { continue }
            if let notify = characteristics.first(where: { $0.uuid == layout.notify && canNotify($0) }),
                let write = characteristics.first(where: { $0.uuid == layout.write && canWrite($0) })
            {
                return (notify, write)
            }
        }
        // Skip the standard GAP/GATT/device-information services.
        let standard = ["1800", "1801", "180A", "180F"].map { CBUUID(string: $0) }
        let custom = services.filter { !standard.contains($0.uuid) }
        for service in custom {
            let characteristics = service.characteristics ?? []
            if let both = characteristics.first(where: { canNotify($0) && canWrite($0) }) { return (both, both) }
            if let notify = characteristics.first(where: canNotify), let write = characteristics.first(where: canWrite) { return (notify, write) }
        }
        let all = custom.flatMap { $0.characteristics ?? [] }
        if let notify = all.first(where: canNotify), let write = all.first(where: canWrite) { return (notify, write) }
        return nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic == notify else { return }
        if let error {
            finishOpening(OBDLinkError.transport("The adapter refused notifications: \(error.localizedDescription)"))
        } else if characteristic.isNotifying {
            finishOpening(nil)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, characteristic == notify, let value = characteristic.value, !value.isEmpty else { return }
        input.yield([UInt8](value))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard !writes.isEmpty else { return }
        if let error {
            writes.removeFirst().continuation.resume(throwing: OBDLinkError.transport(error.localizedDescription))
            return
        }
        writes[0].remaining -= 1
        if writes[0].remaining <= 0 { writes.removeFirst().continuation.resume() }
    }
}
#endif

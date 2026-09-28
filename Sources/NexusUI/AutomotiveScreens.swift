#if canImport(SwiftUI)
import Charts
import Foundation
import NexusAutomotive
import NexusCore
import NexusModel
import NexusOBDTransports
import NexusTelemetry
import SwiftUI

/// The garage: vehicles in the store, and adding one by VIN.
struct GarageSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var adding = false

    var body: some View {
        _ = env.revision
        let vehicles = (try? VehicleRuntime(store: env.store).vehicles()) ?? []
        return Section("Garage (\(vehicles.count))") {
            ForEach(vehicles) { vehicle in
                Button { try? env.context.open(vehicle.id, from: .project) } label: {
                    LabeledContent(vehicle.title, value: vehicle.vin.rawValue).font(.callout)
                }
            }
            Button("Add vehicle by VIN", systemImage: "car.badge.gearshape") { adding = true }
        }
        .sheet(isPresented: $adding) { AddVehicleSheet().environment(env) }
    }
}

struct AddVehicleSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var vin = ""
    @State private var title = ""
    @State private var odometer = ""
    @State private var error: ClassifiedError?

    var body: some View {
        NavigationStack {
            Form {
                TextField("VIN (17 characters)", text: $vin)
                    .font(.body.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                TextField("Name (optional)", text: $title)
                TextField("Odometer, km (optional)", text: $odometer)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if let decoded = try? VIN(vin) {
                    Section("Decoded from the VIN") {
                        LabeledContent("Manufacturer", value: decoded.manufacturer ?? "Unknown")
                        LabeledContent("Country", value: decoded.country ?? "Unknown")
                        if let year = decoded.modelYear { LabeledContent("Model year", value: String(year)) }
                        TruthBadge(.derived)
                    }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("Add vehicle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(vin.count < 17) }
            }
        }
    }

    private func add() {
        do {
            let vehicle = try VehicleRuntime(store: env.store).addVehicle(
                vin: vin.trimmingCharacters(in: .whitespaces), title: title.isEmpty ? nil : title,
                odometerKm: Double(odometer.replacingOccurrences(of: ",", with: ".")), by: env.user
            )
            if let project = env.context.activeProject ?? env.demo?.project {
                try env.projects.add(vehicle.id, to: project, by: env.user)
            }
            dismiss()
            try env.context.open(vehicle.id, from: .project)
        } catch {
            self.error = classify(error).preserving("No vehicle was added.")
        }
    }
}

/// A vehicle's domain view inside Object Detail: identity decoded from the
/// VIN, trouble codes with their meanings, service history, scan-tool
/// import, and the charging-system diagnosis.
struct VehicleDomainView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var importing = false
    @State private var servicing = false
    @State private var diagnosing = false
    @State private var connecting = false
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let runtime = VehicleRuntime(store: env.store)
        return Group {
            if let vehicle = try? runtime.vehicle(id) {
                Section("Vehicle") {
                    LabeledContent("VIN", value: vehicle.vin.rawValue).font(.callout.monospaced())
                    if let year = vehicle.modelYear { LabeledContent("Model year", value: String(year)) }
                    if let km = vehicle.odometerKm { LabeledContent("Odometer", value: "\(km.formatted()) km") }
                    LabeledContent("Components", value: "\(vehicle.components.count)")
                }
                Section("Trouble codes") {
                    let faults = (try? runtime.faults(of: id)) ?? []
                    if faults.isEmpty { Text("No stored codes.").foregroundStyle(.secondary) }
                    ForEach(faults) { fault in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fault.title)
                            HStack {
                                if case .string(let status)? = fault.attributes[AutomotiveKey.dtcStatus]?.value {
                                    Text(status.capitalized).font(.caption)
                                }
                                Text("Code").font(.caption)
                                TruthBadge(fault.provenance.truth)
                                Text("Meaning").font(.caption)
                                TruthBadge(fault.truth(of: AutomotiveKey.description) ?? .claimed)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button("Import scan-tool log", systemImage: "cable.connector") { importing = true }
                }
                Section {
                    Button("Connect adapter", systemImage: "antenna.radiowaves.left.and.right") { connecting = true }
                } header: {
                    Text("Live data")
                } footer: {
                    Text("An ELM327 adapter over Bluetooth LE or Wi-Fi: live gauges, trouble codes and freeze frame, saved to this vehicle.")
                }
                Section("Diagnose") {
                    Button(diagnosing ? "Preparing the charging model…" : "Diagnose charging system", systemImage: "bolt.car") {
                        diagnose(vehicle)
                    }
                    .disabled(diagnosing || ChargingSystem(vehicle) == nil)
                    Text("Opens an investigation with four candidate causes and the best next test.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Service history") {
                    let history = (try? runtime.serviceHistory(of: id)) ?? []
                    if history.isEmpty { Text("No service recorded.").foregroundStyle(.secondary) }
                    ForEach(history, id: \.procedure.id) { entry in
                        LabeledContent(entry.procedure.title, value: entry.event.at.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Record service", systemImage: "wrench.and.screwdriver") { servicing = true }
                }
                if let error { Section { ClassifiedErrorView(error) } }
            }
        }
        .sheet(isPresented: $importing) { ScanToolImportSheet(vehicle: id).environment(env) }
        .sheet(isPresented: $servicing) { ServiceEntrySheet(vehicle: id).environment(env) }
        .sheet(isPresented: $connecting) { OBDLiveSheet(vehicle: id).environment(env) }
    }

    private func diagnose(_ vehicle: Vehicle) {
        guard let system = ChargingSystem(vehicle) else { return }
        diagnosing = true
        Task {
            // Prediction intervals come from simulating each cause; warm them off the main thread.
            _ = await Task.detached(priority: .userInitiated) { try? ChargingDiagnosis.intervals() }.value
            do {
                let codes = ((try? VehicleRuntime(store: env.store).faults(of: vehicle.id)) ?? []).map(\.id)
                let opened = try ChargingDiagnosis(system: system).open(in: env.investigations, vehicle: vehicle.id, evidence: codes, by: env.user)
                if let project = env.context.activeProject ?? env.demo?.project {
                    try env.projects.add(opened.investigation, to: project, by: env.user)
                }
                try env.context.open(opened.investigation, in: .investigation, from: .command)
                error = nil
            } catch {
                self.error = classify(error).preserving("No investigation was opened.")
            }
            diagnosing = false
        }
    }
}

/// Paste an ELM327 session (mode 01 PIDs, mode 03/07 codes, ATRV) and store
/// what it read: PIDs as display truth (the ECU's own values), codes as
/// recorded faults, the adapter's voltage as an observed reading.
struct ScanToolImportSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let vehicle: ObjectID
    @State private var log = ""
    @State private var summary: String?
    @State private var error: ClassifiedError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $log)
                        .font(.caption.monospaced())
                        .frame(minHeight: 200)
                } header: {
                    Text("Scan-tool log")
                } footer: {
                    Text("One command per block, e.g. “>01 0C” then “41 0C 1A F8”, “>03” then “43 01 05 62”, or “ATRV” then “12.2V”.")
                }
                if let summary { Section { Label(summary, systemImage: "checkmark.circle") } }
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("Import scan-tool log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { importLog() }.disabled(log.isEmpty) }
            }
        }
    }

    private func importLog() {
        let runtime = VehicleRuntime(store: env.store)
        var readings: [OBDReading] = []
        var codes: [DTCStatus: [DTC]] = [:]
        var volts: Double?
        var skipped = 0
        // Split into command blocks at prompts (">") or command echoes.
        let blocks = log.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for block in blocks {
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            let command = lines.first?.uppercased().replacingOccurrences(of: " ", with: "") ?? ""
            let response = lines.dropFirst().joined(separator: "\n")
            if command == "ATRV" {
                volts = ELM327.parseVoltage(response)
                continue
            }
            guard let messages = try? ELM327.parse(response.isEmpty ? block : response, command: command) else {
                skipped += 1
                continue
            }
            for message in messages {
                guard let mode = message.bytes.first else { continue }
                if mode == 0x41, let decoded = try? OBD.decodeMode01(message.bytes, ecu: message.ecu) {
                    readings += decoded
                } else if let decoded = (try? OBD.decodeDTCs(message.bytes, hasCount: true)) ?? (try? OBD.decodeDTCs(message.bytes, hasCount: false)) {
                    codes[decoded.status, default: []] += decoded.codes
                } else {
                    skipped += 1
                }
            }
        }
        do {
            try env.store.batch { _ in
                if !readings.isEmpty { try runtime.record(readings, on: vehicle) }
                for (status, list) in codes where !list.isEmpty {
                    try runtime.recordTroubleCodes(list, status: status, on: vehicle, by: env.user)
                }
                if let volts, let scanTool = try runtime.vehicle(vehicle).component(.ecu) {
                    try runtime.recordAdapterVoltage(volts, on: vehicle, scanTool: scanTool)
                }
            }
            let codeCount = codes.values.map(\.count).reduce(0, +)
            summary = "Stored \(readings.count) PID readings (display truth), \(codeCount) trouble codes (recorded)"
                + (volts.map { ", connector voltage \($0.formatted()) V (observed)" } ?? "")
                + (skipped > 0 ? ". \(skipped) blocks weren't understood and were skipped." : ".")
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing from this log was stored; the import is all or nothing.")
        }
    }
}

struct ServiceEntrySheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let vehicle: ObjectID
    @State private var title = ""
    @State private var date = Date()
    @State private var odometer = ""
    @State private var steps = ""
    @State private var error: ClassifiedError?

    var body: some View {
        NavigationStack {
            Form {
                TextField("What was done", text: $title)
                DatePicker("When", selection: $date, displayedComponents: .date)
                TextField("Odometer, km", text: $odometer)
                TextField("Steps, one per line", text: $steps, axis: .vertical)
                if let error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("Record service")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.isEmpty || Double(odometer) == nil)
                }
            }
        }
    }

    private func save() {
        do {
            let entry = ServiceEntry(
                title: title, performedAt: date, odometerKm: Double(odometer) ?? 0,
                steps: steps.split(separator: "\n").map(String.init)
            )
            try VehicleRuntime(store: env.store).recordService(entry, on: vehicle, by: env.user)
            dismiss()
        } catch {
            self.error = classify(error).preserving("The service history is unchanged.")
        }
    }
}

// MARK: Live adapter

/// The live readings offered as gauges, with their dial ranges.
struct LivePIDChoice: Identifiable, Hashable {
    let pid: UInt8
    let label: String
    let range: ClosedRange<Double>
    let decimals: Int
    var id: UInt8 { pid }

    static let all: [LivePIDChoice] = [
        LivePIDChoice(pid: 0x0C, label: "RPM", range: 0...8000, decimals: 0),
        LivePIDChoice(pid: 0x0D, label: "Speed", range: 0...240, decimals: 0),
        LivePIDChoice(pid: 0x05, label: "Coolant", range: -40...130, decimals: 0),
        LivePIDChoice(pid: 0x42, label: "Voltage", range: 10...16, decimals: 2),
        LivePIDChoice(pid: 0x06, label: "Short trim", range: -25...25, decimals: 1),
        LivePIDChoice(pid: 0x07, label: "Long trim", range: -25...25, decimals: 1),
        LivePIDChoice(pid: 0x04, label: "Load", range: 0...100, decimals: 0),
    ]
}

/// One adapter session for the live sheet: scanning, connecting, polling
/// into telemetry, and code reads. Everything it stores goes through
/// `OBDDriveRecorder` into the canonical store; this only keeps what the
/// screen shows.
@MainActor
@Observable
final class OBDLiveModel {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
    }

    struct Point: Identifiable, Hashable {
        var pid: UInt8
        var time: Date
        var value: Double
        var id: String { "\(pid)-\(time.timeIntervalSinceReferenceDate)" }
    }

    var phase = Phase.idle
    var error: ClassifiedError?
    var drive: OBDDrive?
    var latest: [UInt8: OBDReading] = [:]
    /// The last minute of readings, for the strip chart.
    var points: [Point] = []
    var selected: Set<UInt8> = [0x0C, 0x0D, 0x05, 0x42]
    /// The last pass returned nothing: typically the ignition is off.
    var noData = false
    var codes: [DTCStatus: [DTC]]?
    var freezeFrame: FreezeFrame?
    var working: String?
    var cleared: String?
    let liveTruth = TruthClass.display
    var candidates: [BluetoothAdapterCandidate] = []
    var bluetoothProblem: String?
    /// A `BluetoothAdapterScanner` where CoreBluetooth exists.
    @ObservationIgnored private var scanner: AnyObject?
    @ObservationIgnored private var recorder: OBDDriveRecorder?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Gauges the car supports (all of them until connected).
    var available: [LivePIDChoice] {
        LivePIDChoice.all.filter { drive?.supportedPIDs.contains($0.pid) ?? true }
    }

    func scanBluetooth() {
        #if canImport(CoreBluetooth)
        let scanner = (scanner as? BluetoothAdapterScanner) ?? BluetoothAdapterScanner()
        self.scanner = scanner
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            // The manager reports its state shortly after it starts.
            try? await Task.sleep(for: .seconds(1))
            self?.bluetoothProblem = scanner.unavailableReason
            for await list in scanner.scan() {
                self?.candidates = list
                self?.bluetoothProblem = scanner.unavailableReason
            }
        }
        #endif
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
    }

    func connect(_ transport: any OBDTransport, env: NexusEnvironment, vehicle: ObjectID) {
        stopScanning()
        error = nil
        cleared = nil
        phase = .connecting("Connecting to \(transport.descriptor.name)…")
        let recorder: OBDDriveRecorder
        do {
            recorder = try OBDDriveRecorder(
                session: ELM327Session(transport: transport), telemetry: TelemetryStore(store: env.store), by: env.user, liveTruth: liveTruth
            )
        } catch {
            fail(error)
            return
        }
        self.recorder = recorder
        Task {
            do {
                let drive = try await recorder.start(vehicle: vehicle)
                self.drive = drive
                selected = selected.filter { drive.supportedPIDs.contains($0) }
                if selected.isEmpty { selected = Set(available.prefix(4).map(\.pid)) }
                phase = .connected
                startPolling()
            } catch {
                await recorder.stop()
                if self.recorder === recorder { self.recorder = nil }
                fail(error)
            }
        }
    }

    func select(_ pid: UInt8, _ on: Bool) {
        if on { selected.insert(pid) } else { selected.remove(pid) }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        guard let recorder else { return }
        let pids = LivePIDChoice.all.map(\.pid).filter { selected.contains($0) }
        guard !pids.isEmpty else { return }
        pollTask = Task { [weak self] in
            do {
                for try await frame in recorder.live(pids, every: .milliseconds(250)) {
                    self?.show(frame)
                }
            } catch {
                // Cancelled because the selection changed or the sheet closed: not a failure.
                if !Task.isCancelled { self?.lost(error) }
            }
        }
    }

    private func show(_ frame: OBDLiveFrame) {
        noData = frame.isEmpty
        for reading in frame.readings {
            latest[reading.pid] = reading
            points.append(Point(pid: reading.pid, time: frame.at, value: reading.value))
        }
        let cutoff = frame.at.addingTimeInterval(-60)
        if let first = points.first, first.time < cutoff { points.removeAll { $0.time < cutoff } }
    }

    /// The link dropped mid-drive.
    private func lost(_ error: any Error) {
        disconnect()
        fail(error)
    }

    func readCodes() {
        guard let recorder else { return }
        working = "Reading trouble codes…"
        Task {
            do {
                codes = try await recorder.readTroubleCodes()
                freezeFrame = try await recorder.readFreezeFrame()
                error = nil
            } catch {
                self.error = classify(error).preserving("Live readings continue.")
            }
            working = nil
        }
    }

    /// Runs only from the confirmation dialog's destructive button, which a
    /// person taps; the confirmation names that person and this vehicle.
    func clearCodes(confirmedBy person: Origin, vehicle: ObjectID) {
        guard let recorder else { return }
        working = "Clearing trouble codes…"
        Task {
            do {
                let confirmation = try ClearCodesConfirmation(person: person, vehicle: vehicle, confirmedAt: Date())
                let archived = try await recorder.clearTroubleCodes(confirmation)
                cleared = "Codes cleared. \(archived.count) faults are archived in the vehicle's history."
                freezeFrame = nil
                codes = try await recorder.readTroubleCodes()
                error = nil
            } catch {
                self.error = classify(error)
            }
            working = nil
        }
    }

    func disconnect() {
        stopScanning()
        pollTask?.cancel()
        pollTask = nil
        if let recorder { Task { await recorder.stop() } }
        recorder = nil
        drive = nil
        phase = .idle
        latest = [:]
        points = []
        codes = nil
        freezeFrame = nil
        noData = false
        working = nil
    }

    private func fail(_ error: any Error) {
        self.error = classify(error)
        phase = .idle
    }
}

/// A trouble code as listed in the live sheet; the same code can be both stored and pending.
private struct CodeRow: Identifiable, Hashable {
    var status: DTCStatus
    var code: DTC
    var id: String { "\(status.rawValue)-\(code.code)" }
}

/// Connect an OBD-II adapter to this vehicle: scan Bluetooth LE or enter a
/// Wi-Fi address, then watch live gauges, read codes, and clear them only
/// after confirming.
struct OBDLiveSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let vehicle: ObjectID
    @State private var model = OBDLiveModel()
    @State private var link = AdapterLink.bluetooth
    @State private var host = "192.168.0.10"
    @State private var port = "35000"
    @State private var confirmingClear = false
    @State private var chartPID: UInt8 = 0x0C

    enum AdapterLink: String, CaseIterable {
        case bluetooth = "Bluetooth"
        case wifi = "Wi-Fi"
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .idle:
                    chooser
                case .connecting(let step):
                    Section {
                        ProgressView(step)
                    } footer: {
                        Text("The adapter resets, then searches for the car's protocol. This can take up to 15 seconds.")
                    }
                case .connected:
                    connected
                }
                if let error = model.error { Section { ClassifiedErrorView(error) } }
            }
            .navigationTitle("OBD-II adapter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.disconnect()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Clear trouble codes?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear codes on the vehicle", role: .destructive) { model.clearCodes(confirmedBy: env.user, vehicle: vehicle) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This turns off the check-engine light, erases the freeze frame and resets the readiness monitors, so the car may fail an emissions test until it has been driven. Permanent codes stay until the car clears them itself."
                )
            }
        }
        .onAppear { if link == .bluetooth { model.scanBluetooth() } }
        .onDisappear { model.disconnect() }
    }

    // MARK: Choosing an adapter

    @ViewBuilder
    private var chooser: some View {
        Section {
            Picker("Adapter", selection: $link) {
                ForEach(AdapterLink.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: link) { _, new in
                if new == .bluetooth { model.scanBluetooth() } else { model.stopScanning() }
            }
        } footer: {
            Text("Plug the adapter into the OBD-II port under the dashboard and turn the ignition on.")
        }
        switch link {
        case .bluetooth: bluetoothAdapters
        case .wifi: wifiAdapter
        }
    }

    @ViewBuilder
    private var bluetoothAdapters: some View {
        #if canImport(CoreBluetooth)
        Section {
            if let problem = model.bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
            } else if model.candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for adapters…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.candidates) { candidate in
                Button {
                    model.connect(BluetoothLETransport(peripheral: candidate.id, name: candidate.name), env: env, vehicle: vehicle)
                } label: {
                    HStack {
                        Label(candidate.name, systemImage: candidate.looksLikeOBD ? "car.side" : "dot.radiowaves.left.and.right")
                        Spacer()
                        Text("\(candidate.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint(candidate.looksLikeOBD ? "Likely an OBD adapter" : "Unknown Bluetooth device")
            }
        } header: {
            Text("Bluetooth LE adapters")
        } footer: {
            Text(
                "No adapter listed? Check its light is on and it isn't connected to another phone. Adapters that use classic Bluetooth (not LE) can't connect to iPhone; use a BLE or Wi-Fi one."
            )
        }
        #else
        Section { Text("Bluetooth isn't available on this device.").foregroundStyle(.secondary) }
        #endif
    }

    @ViewBuilder
    private var wifiAdapter: some View {
        Section {
            TextField("Address", text: $host)
                .font(.body.monospaced())
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Port", text: $port)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            #if canImport(Network)
            Button("Connect", systemImage: "wifi") {
                model.connect(WiFiTransport(host: host, port: UInt16(port) ?? WiFiTransport.defaultPort), env: env, vehicle: vehicle)
            }
            .disabled(host.isEmpty || UInt16(port) == nil)
            #endif
        } header: {
            Text("Wi-Fi adapter")
        } footer: {
            Text("Join the adapter's Wi-Fi network (often “WiFi_OBDII” or “V-LINK”) in Settings first. Most listen at 192.168.0.10, port 35000.")
        }
    }

    // MARK: Connected

    @ViewBuilder
    private var connected: some View {
        if let drive = model.drive {
            Section("Adapter") {
                LabeledContent("Adapter", value: drive.identity.adapter.name)
                LabeledContent("Chip", value: drive.identity.version)
                LabeledContent("Protocol", value: drive.identity.vehicleProtocol.name)
                if let vin = drive.vin { LabeledContent("VIN", value: vin.rawValue).font(.callout.monospaced()) }
                if let volts = drive.identity.voltage {
                    LabeledContent("Connector voltage") {
                        HStack {
                            Text("\(volts.formatted(.number.precision(.fractionLength(1)))) V")
                            TruthBadge(.observed)
                        }
                    }
                }
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { model.disconnect() }
            }
            Section {
                if model.noData {
                    Label("No data. The ignition may be off; turn it on or start the engine.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                let shown = model.available.filter { model.selected.contains($0.pid) }
                if shown.isEmpty {
                    Text("Choose readings below.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 12) {
                        ForEach(shown) { gauge($0) }
                    }
                    strip(shown)
                }
            } header: {
                HStack {
                    Text("Live")
                    TruthBadge(model.liveTruth)
                }
            } footer: {
                Text("Readings are saved to this vehicle's telemetry as they arrive, with the adapter and protocol they came from.")
            }
            Section("Readings") {
                ForEach(model.available) { choice in
                    Toggle(choice.label, isOn: Binding(get: { model.selected.contains(choice.pid) }, set: { model.select(choice.pid, $0) }))
                }
            }
            codes
        }
    }

    private func gauge(_ choice: LivePIDChoice) -> some View {
        let reading = model.latest[choice.pid]
        let value = min(max(reading?.value ?? choice.range.lowerBound, choice.range.lowerBound), choice.range.upperBound)
        let text = reading.map { $0.value.formatted(.number.precision(.fractionLength(choice.decimals))) } ?? "—"
        return VStack(spacing: 4) {
            Gauge(value: value, in: choice.range) {
                Text(choice.label)
            } currentValueLabel: {
                Text(text)
            }
            .gaugeStyle(.accessoryCircular)
            Text(choice.label).font(.caption)
            Text(OBD.pids[choice.pid]?.unit ?? "").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.label)
        .accessibilityValue(reading.map { "\(text) \($0.unit)" } ?? "No data")
    }

    @ViewBuilder
    private func strip(_ shown: [LivePIDChoice]) -> some View {
        let current = shown.first { $0.pid == chartPID } ?? shown[0]
        let points = model.points.filter { $0.pid == current.pid }
        Picker("Chart", selection: $chartPID) {
            ForEach(shown) { Text($0.label).tag($0.pid) }
        }
        if points.count > 1 {
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value(current.label, point.value))
            }
            .chartYAxisLabel { Text(OBD.pids[current.pid]?.unit ?? "") }
            .frame(height: 120)
            .accessibilityLabel("\(current.label) over the last minute")
        } else {
            Text("Waiting for readings…").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codes: some View {
        Section {
            if let codes = model.codes {
                let rows = DTCStatus.allCases.flatMap { status in (codes[status] ?? []).map { CodeRow(status: status, code: $0) } }
                if rows.isEmpty { Label("No trouble codes.", systemImage: "checkmark.circle") }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.code.code) \(DTCKnowledgeBase.generic.describe(row.code))")
                        HStack {
                            Text(row.status.rawValue.capitalized).font(.caption)
                            TruthBadge(.recorded)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let frame = model.freezeFrame, let trigger = frame.trigger, !frame.readings.isEmpty {
                    DisclosureGroup("Freeze frame for \(trigger.code)") {
                        ForEach(frame.readings, id: \.pid) { reading in
                            LabeledContent(reading.name, value: "\(reading.value.formatted()) \(reading.unit)")
                        }
                    }
                }
            }
            Button(model.working ?? "Read codes", systemImage: "list.bullet.clipboard") { model.readCodes() }
                .disabled(model.working != nil)
            Button("Clear codes…", systemImage: "trash", role: .destructive) { confirmingClear = true }
                .disabled(model.working != nil || model.codes == nil)
            if let cleared = model.cleared { Label(cleared, systemImage: "checkmark.circle") }
        } header: {
            Text("Trouble codes")
        } footer: {
            Text("Codes are saved to the vehicle as recorded faults. Read them before clearing; codes are never cleared without your confirmation.")
        }
    }
}
#endif

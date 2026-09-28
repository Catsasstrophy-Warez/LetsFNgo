#if canImport(SwiftUI)
import Foundation
import NexusAutomotive
import NexusCore
import NexusModel
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
#endif

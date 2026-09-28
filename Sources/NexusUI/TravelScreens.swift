#if canImport(SwiftUI)
import Foundation
import NexusCore
import NexusModel
import NexusTravel
import SwiftUI
import UniformTypeIdentifiers

/// Trips in the Project screen: itinerary and boarding-pass import, and new
/// trips. Imported legs are recorded truth pointing at the stored file.
struct TravelSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var importing: ImportKind?
    @State private var newTrip = ""
    @State private var summary: String?
    @State private var error: ClassifiedError?

    enum ImportKind: Identifiable {
        case calendar, boardingPass
        var id: Self { self }
    }

    var body: some View {
        _ = env.revision
        let travel = TravelRuntime(store: env.store)
        let trips = (try? travel.trips()) ?? []
        return Section("Trips (\(trips.count))") {
            ForEach(trips) { trip in
                Button { try? env.context.open(trip.id, from: .project) } label: {
                    let legs = (try? travel.legs(of: trip.id)) ?? []
                    LabeledContent(trip.name, value: legs.first.map { $0.start.formatted(date: .abbreviated, time: .omitted) } ?? "No legs")
                }
            }
            HStack {
                TextField("New trip", text: $newTrip)
                Button("Add") { addTrip() }.disabled(newTrip.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Import itinerary (.ics)", systemImage: "calendar.badge.plus") { importing = .calendar }
            Button("Import boarding pass (pass.json)", systemImage: "airplane") { importing = .boardingPass }
            if let summary { Label(summary, systemImage: "checkmark.circle").font(.caption) }
            if let error { ClassifiedErrorView(error) }
        }
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: importing == .boardingPass ? [.json, .plainText, .data] : [UTType(filenameExtension: "ics") ?? .data, .data]
        ) { result in
            let kind = importing
            importing = nil
            importFile(result, kind: kind ?? .calendar)
        }
    }

    private func addTrip() {
        do {
            let trip = try TravelRuntime(store: env.store).addTrip(newTrip.trimmingCharacters(in: .whitespaces), by: env.user)
            if let project = env.context.activeProject ?? env.demo?.project { try env.projects.add(trip.id, to: project, by: env.user) }
            newTrip = ""
            error = nil
        } catch {
            self.error = classify(error).preserving("No trip was added.")
        }
    }

    private func importFile(_ result: Result<URL, Error>, kind: ImportKind) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let importer = ItineraryImporter(store: env.store)
            let imported: ItineraryImportResult
            switch kind {
            case .calendar: imported = try importer.importICS(data, named: url.lastPathComponent, floatingTimeZone: .current, by: env.user)
            case .boardingPass: imported = try importer.importBoardingPass(data, named: url.lastPathComponent, by: env.user)
            }
            summary = "\(imported.trip.name): \(imported.created.count) legs added, \(imported.updated.count) updated."
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing from the file was stored; an import is all or nothing.")
        }
    }
}

/// A trip inside Object Detail: its legs in order with connection times, the
/// conflicts derived from them, and a person's correction of a leg's mode.
struct TripDomainView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let travel = TravelRuntime(store: env.store)
        let timeline = try? travel.timeline(of: id)
        return Group {
            if let timeline {
                Section("Timeline") {
                    if timeline.entries.isEmpty { Text("No legs yet. Import an itinerary from the project.").foregroundStyle(.secondary) }
                    ForEach(Array(timeline.entries.enumerated()), id: \.offset) { _, entry in
                        switch entry {
                        case .leg(let leg): legRow(leg)
                        case .connection(_, _, let duration):
                            Label("\(Int(duration / 60)) min connection", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Conflicts") {
                    if timeline.conflicts.isEmpty { Text("No overlaps or tight connections.").foregroundStyle(.secondary) }
                    ForEach(Array(timeline.conflicts.enumerated()), id: \.offset) { _, conflict in
                        HStack {
                            Label(conflict.message, systemImage: "exclamationmark.triangle").font(.callout)
                            Spacer()
                            TruthBadge(conflict.truth)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                let bookings = (try? travel.bookings(of: id)) ?? []
                if !bookings.isEmpty {
                    Section("Bookings") {
                        ForEach(bookings) { booking in
                            Button { try? env.context.open(booking.id, from: .collection) } label: { Text(booking.title) }
                        }
                    }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
    }

    private func legRow(_ leg: TravelLeg) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { try? env.context.open(leg.id, from: .collection) } label: { Text(leg.title) }
            HStack {
                Text(leg.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                if let end = leg.end { Text("– \(end.formatted(date: .omitted, time: .shortened))").font(.caption) }
                Menu(leg.mode.rawValue) {
                    ForEach(LegMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { setMode(mode, of: leg.id) }
                    }
                }
                .font(.caption)
                TruthBadge(leg.modeTruth ?? leg.record.provenance.truth)
                if let seat = leg.seat { Text("Seat \(seat)").font(.caption) }
            }
        }
    }

    private func setMode(_ mode: LegMode, of leg: ObjectID) {
        do {
            _ = try TravelRuntime(store: env.store).setMode(mode, of: leg, by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}
#endif

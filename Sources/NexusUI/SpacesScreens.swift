#if canImport(SwiftUI)
import Foundation
import NexusArchitecture
import NexusCore
import NexusModel
import SwiftUI
import UniformTypeIdentifiers

/// Buildings in the Project screen: their derived floor area, space-list
/// and IFC import, and new buildings.
struct SpacesSection: View {
    @Environment(NexusEnvironment.self) private var env
    @State private var importing: ImportKind?
    @State private var newBuilding = ""
    @State private var summary: String?
    @State private var error: ClassifiedError?

    enum ImportKind: Identifiable {
        case spaceList, ifc
        var id: Self { self }
    }

    var body: some View {
        _ = env.revision
        let spaces = SpaceRuntime(store: env.store)
        let buildings = (try? spaces.all(.building)) ?? []
        return Section("Buildings (\(buildings.count))") {
            ForEach(buildings) { building in
                Button { try? env.context.open(building.id, from: .project) } label: {
                    HStack {
                        Text(building.title)
                        Spacer()
                        if let area = try? spaces.area(of: building.id) {
                            Text("\(area.spaces) spaces · \(area.squareMetres.formatted(.number.precision(.fractionLength(0)))) m²").font(.caption)
                            TruthBadge(area.truth)
                        }
                    }
                }
            }
            HStack {
                TextField("New building", text: $newBuilding)
                Button("Add") { addBuilding() }.disabled(newBuilding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Import space list (CSV)", systemImage: "tablecells") { importing = .spaceList }
            Button("Import IFC model (spaces only)", systemImage: "building.2") { importing = .ifc }
            if let summary { Label(summary, systemImage: "checkmark.circle").font(.caption) }
            if let error { ClassifiedErrorView(error) }
        }
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: importing == .ifc ? [UTType(filenameExtension: "ifc") ?? .data, .data] : [.commaSeparatedText, .plainText]
        ) { result in
            let kind = importing
            importing = nil
            importFile(result, kind: kind ?? .spaceList)
        }
    }

    private func addBuilding() {
        do {
            let building = try SpaceRuntime(store: env.store).add(.building, named: newBuilding.trimmingCharacters(in: .whitespaces), by: env.user)
            if let project = env.context.activeProject ?? env.demo?.project { try env.projects.add(building.id, to: project, by: env.user) }
            newBuilding = ""
            error = nil
        } catch {
            self.error = classify(error).preserving("No building was added.")
        }
    }

    private func importFile(_ result: Result<URL, Error>, kind: ImportKind) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let importer = SpaceImporter(store: env.store)
            let imported: SpaceImportResult
            switch kind {
            case .spaceList: imported = try importer.importSpaceList(data, named: url.lastPathComponent, by: env.user)
            case .ifc: imported = try importer.importIFC(data, named: url.lastPathComponent, by: env.user)
            }
            summary = "Added \(imported.created.count) sites, buildings, floors and spaces; updated \(imported.updated.count)."
            error = nil
        } catch {
            self.error = classify(error).preserving("Nothing from the file was stored; an import is all or nothing.")
        }
    }
}

/// A site, building, storey or space inside Object Detail: where it is,
/// its area, what it contains, the assets located there and, for a space,
/// today's bookings.
struct SpatialDomainView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var childName = ""
    @State private var bookingTitle = ""
    @State private var error: ClassifiedError?

    var body: some View {
        _ = env.revision
        let spaces = SpaceRuntime(store: env.store)
        let record = env.object(id)
        let level = record.flatMap { SpatialLevel($0.type) }
        return Group {
            if let record, let level {
                Section("Location") {
                    Text(((try? spaces.path(of: id)) ?? [record]).map(\.title).joined(separator: " › ")).font(.callout)
                    if let area = try? spaces.area(of: id) {
                        HStack {
                            LabeledContent("Floor area", value: "\(area.squareMetres.formatted(.number.precision(.fractionLength(1)))) m²")
                            TruthBadge(level == .space ? (record.truth(of: SpaceKey.area) ?? record.provenance.truth) : area.truth)
                        }
                        if area.spacesWithoutArea > 0 { Text("\(area.spacesWithoutArea) spaces have no area.").font(.caption) }
                    }
                }
                if level != .space {
                    Section("Contains") {
                        ForEach((try? spaces.children(of: id)) ?? []) { child in
                            Button(child.title) { try? env.context.open(child.id, from: .collection) }
                        }
                        let next = SpatialLevel.allCases.first { $0 > level }!
                        HStack {
                            TextField("New \(next.rawValue)", text: $childName)
                            Button("Add") { addChild(next) }.disabled(childName.isEmpty)
                        }
                    }
                }
                Section("Assets here") {
                    let assets = (try? spaces.assets(in: id)) ?? []
                    if assets.isEmpty { Text("Nothing located here. Place equipment from its own page.").foregroundStyle(.secondary) }
                    ForEach(assets) { asset in
                        Button { try? env.context.open(asset.id, from: .collection) } label: { ObjectRow(record: asset) }
                    }
                }
                if level == .space {
                    Section("Today's bookings") {
                        let today = Calendar.current.dateInterval(of: .day, for: Date())
                        let bookings = (try? spaces.reservations(of: id, during: today)) ?? []
                        if bookings.isEmpty { Text("Free all day.").foregroundStyle(.secondary) }
                        ForEach(bookings) { booking in
                            LabeledContent(
                                booking.title,
                                value: "\(booking.start.formatted(date: .omitted, time: .shortened)) – \(booking.end.formatted(date: .omitted, time: .shortened))")
                        }
                        HStack {
                            TextField("Book the next hour for…", text: $bookingTitle)
                            Button("Book") { bookNextHour() }.disabled(bookingTitle.isEmpty)
                        }
                    }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
    }

    private func addChild(_ level: SpatialLevel) {
        do {
            _ = try SpaceRuntime(store: env.store).add(level, named: childName, in: id, by: env.user)
            childName = ""
            error = nil
        } catch {
            self.error = classify(error)
        }
    }

    private func bookNextHour() {
        let calendar = Calendar.current
        let start = calendar.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        do {
            _ = try SpaceRuntime(store: env.store).reserve(id, title: bookingTitle, from: start, to: start.addingTimeInterval(3_600), by: env.user)
            bookingTitle = ""
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}

/// Where a piece of equipment (or any other asset) is: its space, and
/// moving it to another. Shown in Object Detail for physical objects.
struct AssetLocationView: View {
    @Environment(NexusEnvironment.self) private var env
    let id: ObjectID
    @State private var error: ClassifiedError?

    static let assetTypes: Set<ObjectType> = [.equipment, .component, .sensor, .instrument, "vehicle"]

    var body: some View {
        _ = env.revision
        let spaces = SpaceRuntime(store: env.store)
        let rooms = (try? spaces.all(.space)) ?? []
        return Group {
            if !rooms.isEmpty {
                Section("Location") {
                    if let current = try? spaces.location(of: id) {
                        Button { try? env.context.open(current.id, from: .collection) } label: {
                            LabeledContent("In", value: ((try? spaces.path(of: current.id)) ?? [current]).map(\.title).joined(separator: " › "))
                        }
                    } else {
                        Text("Not placed in a space.").foregroundStyle(.secondary)
                    }
                    Menu("Move to…") {
                        ForEach(rooms) { room in
                            Button(room.title) { move(to: room.id) }
                        }
                    }
                }
            }
            if let error { Section { ClassifiedErrorView(error) } }
        }
    }

    private func move(to space: ObjectID) {
        do {
            _ = try SpaceRuntime(store: env.store).locate(id, in: space, by: env.user)
            error = nil
        } catch {
            self.error = classify(error)
        }
    }
}
#endif

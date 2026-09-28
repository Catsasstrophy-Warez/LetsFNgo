#if canImport(SwiftUI) && canImport(PencilKit) && os(iOS)
import Foundation
import NexusCore
import NexusModel
import PencilKit
import SwiftUI

extension ObjectType {
    /// A drawing on top of an object: Pencil markup of a schematic, a photo or a note.
    static let annotation: ObjectType = "annotation"
}

extension RelationKind {
    static let annotates: RelationKind = "annotates"
}

/// Pencil markup on an object. Each save is an `annotation` object that
/// `annotates` the subject, with the drawing stored as a blob, so markup has
/// the same identity, provenance and history as everything else.
struct MarkupSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let subject: ObjectID
    @State private var drawing = PKDrawing()
    @State private var existing: ObjectID?
    @State private var error: ClassifiedError?

    var body: some View {
        NavigationStack {
            CanvasView(drawing: $drawing)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Markup: \(env.title(subject))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                }
                .safeAreaInset(edge: .top) { if let error { ClassifiedErrorView(error).padding() } }
                .onAppear(perform: load)
        }
    }

    /// Opens the latest markup on this object for further drawing.
    private func load() {
        guard let latest = try? env.store.relationships(to: subject, kind: .annotates).last,
            let record = env.object(latest.from),
            case .string(let digest)? = record.attributes["drawing"]?.value,
            let data = try? env.store.blobData(sha256: digest),
            let saved = try? PKDrawing(data: data)
        else { return }
        drawing = saved
        existing = record.id
    }

    private func save() {
        do {
            let blob = try env.store.putBlob(drawing.dataRepresentation(), mediaType: "application/x-pencilkit-drawing")
            let provenance = Provenance(origin: env.user, truth: .recorded, timestamp: Date(), method: "Pencil markup")
            if let existing {
                _ = try env.store.update(existing, by: env.user, instruction: "Edited markup") {
                    $0.attributes["drawing"] = Attribute(.string(blob.sha256))
                }
            } else {
                try env.store.batch { store in
                    let note = try store.create(ObjectRecord(
                        type: .annotation, title: "Markup of \(env.title(subject))", attributes: ["drawing": Attribute(.string(blob.sha256))],
                        provenance: provenance
                    ))
                    _ = try store.relate(Relationship(kind: .annotates, from: note.id, to: subject, validFrom: Date(), provenance: provenance))
                }
            }
            dismiss()
        } catch {
            self.error = classify(error).preserving("Your drawing is still on the canvas.")
        }
    }
}

private struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        context.coordinator.picker = picker
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        var picker: PKToolPicker?

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}
#endif

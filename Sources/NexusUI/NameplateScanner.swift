#if canImport(SwiftUI) && canImport(VisionKit) && os(iOS)
import NexusCore
import NexusSearch
import SwiftUI
import VisionKit

/// Live nameplate scanning: the camera reads text as you point it at a tag
/// or nameplate, and each recognised line is matched to equipment with
/// `NameplateMatcher`. Recognition runs on device.
struct NameplateScannerSheet: View {
    @Environment(NexusEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var matches: [NameplateMatcher.Match] = []

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LiveTextScanner(lines: $lines)
                    .ignoresSafeArea(edges: .horizontal)
                List {
                    if matches.isEmpty {
                        Text(lines.isEmpty ? "Point the camera at a nameplate or tag." : "No equipment matches “\(lines.prefix(3).joined(separator: " · "))” yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(matches, id: \.object) { match in
                        Button {
                            try? env.context.open(match.object, from: .search)
                            dismiss()
                        } label: {
                            LabeledContent(match.title, value: "\(Int(match.confidence * 100)) % · \(match.evidence)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .navigationTitle("Scan nameplate")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onChange(of: lines) { match() }
            .sensoryFeedback(.success, trigger: matches.first?.object)
        }
    }

    private func match() {
        let project = env.context.activeProject ?? env.demo?.project
        matches = (try? NameplateMatcher(engine: env.search).match(lines: lines, scope: project)) ?? []
    }
}

/// VisionKit's live text scanner, reporting recognised lines.
private struct LiveTextScanner: UIViewControllerRepresentable {
    @Binding var lines: [String]

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()], qualityLevel: .accurate, recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(lines: $lines) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var lines: Binding<[String]>

        init(lines: Binding<[String]>) {
            self.lines = lines
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(allItems)
        }

        private func report(_ items: [RecognizedItem]) {
            let text = items.compactMap { item -> String? in
                if case .text(let text) = item { return text.transcript }
                return nil
            }
            if text != lines.wrappedValue { lines.wrappedValue = text }
        }
    }
}
#endif

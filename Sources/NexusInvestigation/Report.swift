import Foundation
import NexusCore
import NexusModel
import NexusPersistence

extension InvestigationRuntime {
    /// Generates a report artifact for an investigation.
    ///
    /// Every figure in the text carries a citation marker `[n]`, and the
    /// report object is linked `derivedFrom` to each cited object, so any
    /// number in the report can be traced back to its measurement, claim or
    /// source. The report itself is derived truth.
    @discardableResult
    public func generateReport(for investigation: ObjectID, by author: Origin) throws -> ObjectRecord {
        try store.batch { store in
            guard let record = try store.object(investigation), record.type == .investigation else {
                throw InvestigationError.notAnInvestigation(investigation)
            }
            var citations: [ObjectID] = []
            func cite(_ id: ObjectID) -> String {
                if let index = citations.firstIndex(of: id) { return "[\(index + 1)]" }
                citations.append(id)
                return "[\(citations.count)]"
            }

            var lines = ["# Investigation report: \(record.title) \(cite(investigation))", ""]
            let subjects = try store.objects(try store.relationships(from: investigation, kind: .investigates).map(\.to))
            if !subjects.isEmpty {
                lines.append("Subject: " + subjects.map { "\($0.title) \(cite($0.id))" }.joined(separator: ", "))
                lines.append("")
            }

            lines.append("## Hypotheses")
            for hypothesis in try hypotheses(of: investigation) {
                lines.append("- **\(hypothesis.state.rawValue)**: \(hypothesis.statement) \(cite(hypothesis.id))")
                for dependency in try store.relationships(from: hypothesis.id, kind: .dependsOn) {
                    if let claim = try store.claim(dependency.to) {
                        let sources = try store.objects(claim.sources).map { "\($0.title) \(cite($0.id))" }.joined(separator: ", ")
                        lines.append("  - relies on: \(claim.statement) \(cite(claim.id)) (source: \(sources))")
                    }
                }
                for kind in [RelationKind.supports, .contradicts] {
                    for link in try store.relationships(to: hypothesis.id, kind: kind) {
                        guard let reading = try store.measurement(link.from) else { continue }
                        lines.append("  - \(kind.rawValue == "supports" ? "supported" : "contradicted") by \(describe(reading)) \(cite(reading.id))")
                    }
                }
            }
            lines.append("")

            lines.append("## Measurements")
            let evidence = try store.relationships(from: investigation, kind: .contains).map(\.to)
            let readings = try evidence.compactMap { try store.measurement($0) }.sorted { ($0.sampledAt, $0.id) < ($1.sampledAt, $1.id) }
            for reading in readings {
                lines.append("- \(describe(reading)) \(cite(reading.id))")
            }
            lines.append("")

            let divergences = try store.events(about: investigation).filter { $0.kind == .firstDivergence }
            if let divergence = divergences.first {
                let refs = divergence.provenance.dependencies.map(cite).joined()
                lines.append("## First divergence")
                lines.append("\(divergence.summary) \(refs)")
                lines.append("")
            }

            let verification = try (record.attributes["resolution"]?.provenance?.dependencies ?? []).compactMap { try store.measurement($0) }
            if !verification.isEmpty {
                lines.append("## Verification")
                for reading in verification {
                    lines.append("- \(describe(reading)) \(cite(reading.id))")
                }
                lines.append("")
            }

            if case .string(let status)? = record.attributes["status"]?.value {
                lines.append("Status: \(status)")
            }
            if case .string(let resolution)? = record.attributes["resolution"]?.value {
                let refs = (record.attributes["resolution"]?.provenance?.dependencies ?? []).map(cite).joined()
                lines.append("Resolution: \(resolution) \(refs)")
            }

            lines.append("")
            lines.append("## References")
            let cited = try store.objects(citations)
            for (index, object) in cited.enumerated() {
                lines.append("\(index + 1). \(object.title) (\(object.type), \(object.provenance.truth.rawValue)) \(object.id)")
            }

            let now = clock.now()
            let provenance = Provenance(
                origin: author, truth: .derived, timestamp: now, method: "investigation report", dependencies: citations
            )
            let report = try store.create(ObjectRecord(
                type: .report, title: "Report: \(record.title)",
                attributes: ["body": Attribute(.string(lines.joined(separator: "\n")))],
                provenance: provenance
            ))
            try store.relate(Relationship(kind: .produced, from: investigation, to: report.id, provenance: provenance))
            for id in citations {
                try store.relate(Relationship(kind: .derivedFrom, from: report.id, to: id, provenance: provenance))
            }
            return report
        }
    }

    private func describe(_ reading: MeasurementRecord) -> String {
        var text = "\(reading.quantityName) = \(format(reading.value.value)) \(reading.value.unit) (\(reading.truth.rawValue)"
        if let loading = reading.loading { text += ", \(loading)" }
        return text + ")"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

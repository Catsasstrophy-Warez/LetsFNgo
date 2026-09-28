import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence

// Large-graph timings for the canonical store. Not part of `swift test`.
//
//     swift run -c release NexusBenchmarks            # full size
//     swift run -c release NexusBenchmarks 0.1        # 10 % scale
//
// Results are recorded in docs/PERFORMANCE.md.

let scale = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 1
let objectCount = Int(100_000 * scale)
let fanout = 3 // relationships per object: 300k at full scale
let measurementCount = Int(50_000 * scale)
let testPointCount = max(1, measurementCount / 100)
let batchSize = 5_000

let words = [
    "pump", "valve", "transmitter", "loop", "terminal", "relay", "motor", "breaker", "sensor", "drive",
    "level", "pressure", "flow", "temperature", "current", "voltage", "fuse", "contactor", "switch", "panel",
]
let author = Origin.user(id: "bench")
let clock = SystemClock()

func provenance(_ truth: TruthClass = .recorded) -> Provenance {
    Provenance(origin: author, truth: truth, timestamp: clock.now())
}

var results: [(String, String)] = []

@discardableResult
@MainActor func time<T>(_ label: String, count: Int? = nil, _ body: () throws -> T) rethrows -> T {
    let start = ContinuousClock.now
    let value = try body()
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    var line = String(format: "%.3f s", seconds)
    if let count, count > 0 {
        line += String(format: " (%.1f µs/op, %.0f ops/s)", seconds / Double(count) * 1e6, Double(count) / seconds)
    }
    print("\(label): \(line)")
    results.append((label, line))
    return value
}

let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-bench-\(UUID().uuidString).sqlite")
defer {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
}

print("Nexus benchmark: \(objectCount) objects, \(objectCount * fanout) relationships, \(measurementCount) measurements")
print("Database: \(url.path)")

var ids: [ObjectID] = []
var testPoints: [ObjectID] = []

do {
    let store = try NexusStore(.file(url))

    try time("Insert \(objectCount) objects (batches of \(batchSize))", count: objectCount) {
        ids.reserveCapacity(objectCount)
        for batchStart in stride(from: 0, to: objectCount, by: batchSize) {
            try store.batch { store in
                for index in batchStart..<min(batchStart + batchSize, objectCount) {
                    let isTestPoint = index % (objectCount / testPointCount) == 0 && testPoints.count < testPointCount
                    let title = "\(words[index % words.count]) \(words[(index / words.count) % words.count]) \(index)"
                    let record = try store.create(ObjectRecord(
                        type: isTestPoint ? .testPoint : .component, title: title,
                        attributes: ["note": Attribute(.string("\(words[(index * 7) % words.count]) check \(index % 97)"))],
                        provenance: provenance()
                    ))
                    ids.append(record.id)
                    if isTestPoint { testPoints.append(record.id) }
                }
            }
        }
    }

    let relationshipCount = objectCount * fanout
    try time("Insert \(relationshipCount) relationships (batches of \(batchSize))", count: relationshipCount) {
        var pending = 0
        var index = 0
        while index < objectCount {
            try store.batch { store in
                pending = 0
                while index < objectCount, pending < batchSize {
                    for k in 1...fanout {
                        try store.relate(Relationship(
                            kind: .contains, from: ids[index], to: ids[(index * fanout + k) % objectCount], provenance: provenance()
                        ))
                    }
                    pending += fanout
                    index += 1
                }
            }
        }
    }

    try time("Insert \(measurementCount) measurements (batches of \(batchSize))", count: measurementCount) {
        let base = Date()
        for batchStart in stride(from: 0, to: measurementCount, by: batchSize) {
            try store.batch { store in
                for index in batchStart..<min(batchStart + batchSize, measurementCount) {
                    try store.add(MeasurementRecord(
                        quantityName: "loop current", value: Quantity(4 + Double(index % 1_600) / 100, "mA"), uncertainty: 0.02,
                        testPoint: testPoints[index % testPoints.count], sampledAt: base + Double(index),
                        provenance: provenance(.observed)
                    ))
                }
            }
        }
    }

    let queries = ["pump", "valve transmitter", "loop check", "breaker 12", "temperature sensor", "fuse", "relay panel", "drive"]
    try time("FTS search, \(queries.count * 25) queries (limit 50)", count: queries.count * 25) {
        for _ in 0..<25 {
            for query in queries {
                _ = try store.search(query, limit: 50)
            }
        }
    }

    let graph = ObjectGraph(store: store)
    let reached = try time("Traverse depth 6 from root (outgoing contains)") {
        try graph.traverse(from: ids[0], kinds: [.contains], direction: .outgoing, maxDepth: 6)
    }
    print("  reached \(reached.count) objects")
    let both = try time("Traverse depth 3 from root (both directions)") {
        try graph.traverse(from: ids[0], kinds: [.contains], direction: .both, maxDepth: 3)
    }
    print("  reached \(both.count) objects")

    let sampled = Array(testPoints.prefix(100))
    let total = try time("Measurements at a test point, \(sampled.count) queries", count: sampled.count) {
        try sampled.reduce(0) { $0 + (try store.measurements(at: $1).count) }
    }
    print("  \(total) measurements returned")
    try time("Observed measurements at a test point, \(sampled.count) queries", count: sampled.count) {
        for point in sampled { _ = try store.measurements(at: point, truth: .observed) }
    }
    try time("Point lookups of 10000 objects by ID", count: 10_000) {
        for index in stride(from: 0, to: objectCount, by: max(1, objectCount / 10_000)) { _ = try store.object(ids[index]) }
    }
    try time("Batch fetch of 10000 objects", count: 10_000) {
        _ = try store.objects(Array(ids.prefix(10_000)))
    }
    try time("Update 1000 objects (new revisions)", count: 1_000) {
        try store.batch { store in
            for index in 0..<1_000 {
                try store.update(ids[index], by: author) { $0.title += " rev" }
            }
        }
    }
}

let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
print(String(format: "Database size: %.1f MB", Double((attributes[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576))

try time("Reload: open store") {
    _ = try NexusStore(.file(url))
}
let reloaded = try NexusStore(.file(url))
try time("Reload: first FTS query") { _ = try reloaded.search("pump", limit: 50) }
let testPointObjects = try time("Reload: all test point objects by type") { try reloaded.objects(ofType: .testPoint) }
print("  \(testPointObjects.count) test points")
try time("Reload: all \(objectCount) component objects by type", count: objectCount) {
    _ = try reloaded.objects(ofType: .component)
}

// Component costs: how much of a write or read is JSON rather than SQLite.
let sample = try reloaded.objects(Array(ids.prefix(10_000)))
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let encoded = try time("JSON encode of 10000 ObjectRecords (sorted keys)", count: sample.count) {
    try sample.map { try encoder.encode($0) }
}
try time("JSON decode of 10000 ObjectRecords", count: encoded.count) {
    let decoder = JSONDecoder()
    for data in encoded { _ = try decoder.decode(ObjectRecord.self, from: data) }
}
print(String(format: "  mean record size %.0f bytes", Double(encoded.reduce(0) { $0 + $1.count }) / Double(encoded.count)))

print("\n| Operation | Time |\n|---|---|")
for (label, line) in results {
    print("| \(label) | \(line) |")
}

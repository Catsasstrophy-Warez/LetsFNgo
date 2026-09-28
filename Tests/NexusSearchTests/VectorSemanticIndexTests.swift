import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import Testing

@testable import NexusSearch

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")

private func prov() -> Provenance {
    Provenance(origin: tech, truth: .recorded, timestamp: t0)
}

@discardableResult
private func make(_ store: NexusStore, _ title: String, _ type: ObjectType = .component, body: String? = nil) throws -> ObjectID {
    var attributes: [String: Attribute] = [:]
    if let body { attributes["body"] = Attribute(.string(body)) }
    return try store.create(ObjectRecord(type: type, title: title, attributes: attributes, provenance: prov())).id
}

/// A small panel's worth of objects, so a synonym hit has to beat real distractors.
private func seedPanel(_ store: NexusStore) throws -> (transmitter: ObjectID, psu: ObjectID) {
    let transmitter = try make(store, "LT-101 level transmitter", .sensor)
    let psu = try make(store, "24 V PSU", .component, body: "DIN rail, feeds the instrument loop")
    try make(store, "PSH-205 pressure switch", .sensor)
    try make(store, "Pump P-3 motor starter", .component)
    try make(store, "Shift handover notes", .document, body: "Checked the pump seal and cleaned the strainer")
    try make(store, "Control valve FV-12", .component)
    try make(store, "Relief valve inspection", .task)
    return (transmitter, psu)
}

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nexus-vectors-\(UUID().uuidString).sqlite")
}

private func removeStore(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
}

@Suite struct HashingEmbedderTests {
    @Test func vectorsAreDeterministicAndUnitLength() {
        let embedder = HashingEmbedder(dimension: 256)
        let first = embedder.embed("LT-101 level transmitter")
        let second = HashingEmbedder(dimension: 256).embed("LT-101 level transmitter")
        #expect(first == second)
        #expect(first.count == 256)
        #expect(abs(EmbeddingMath.dot(first, first) - 1) < 1e-4)
        #expect(embedder.embed("  ,;  ").allSatisfy { $0 == 0 })
        #expect(embedder.modelID == "nexus.hashing.v1.256")
        #expect(HashingEmbedder(dimension: 64).embed("x").count == 64)
        #expect(HashingEmbedder.fingerprint("pump").count == 32)
        #expect(HashingEmbedder.fingerprint("pump") == HashingEmbedder.fingerprint("pump"))
        #expect(HashingEmbedder.fingerprint("pump") != HashingEmbedder.fingerprint("pumps"))
    }

    #if canImport(NaturalLanguage)
        @Test func sentenceEmbeddingIsUnitLengthWhenAvailable() throws {
            guard let embedder = NLEmbeddingEmbedder() else { return }
            let vector = embedder.embed("The level transmitter reads high")
            #expect(vector.count == embedder.dimension)
            #expect(abs(EmbeddingMath.dot(vector, vector) - 1) < 1e-3)
            #expect(embedder.embed("   ").allSatisfy { $0 == 0 })
        }
    #endif

    @Test func abbreviationsLandNearTheirMeaning() {
        let embedder = HashingEmbedder()
        func similarity(_ a: String, _ b: String) -> Float { EmbeddingMath.dot(embedder.embed(a), embedder.embed(b)) }
        let pairs = [
            ("xmtr", "level transmitter"), ("TB-4", "terminal block 4"), ("PSU", "power supply"), ("DMM", "multimeter"),
            ("4-20 mA", "loop current"), ("4 to 20mA signal", "current loop"), ("VFD fault", "variable frequency drive fault"),
            ("gnd", "earth"),
        ]
        for (a, b) in pairs {
            let related = similarity(a, b)
            let unrelated = similarity(a, "shift handover notes")
            #expect(related > 0.25, "\(a) ~ \(b): \(related)")
            #expect(related > unrelated + 0.2, "\(a) ~ \(b): \(related) vs \(unrelated)")
        }
        // "4-200" is not a loop range, and "24" isn't the 4 of one.
        #expect(!HashingEmbedder.tokens(of: "4-200 psi").contains("loopcurrent"))
        #expect(!HashingEmbedder.tokens(of: "24-20").contains("loopcurrent"))
        #expect(HashingEmbedder.tokens(of: "4–20mA").contains("loopcurrent"))
    }

    @Test func stemmingJoinsInflections() {
        #expect(HashingEmbedder.stem("transmitters") == HashingEmbedder.stem("transmitter"))
        #expect(HashingEmbedder.stem("supplies") == HashingEmbedder.stem("supply"))
        #expect(HashingEmbedder.stem("calibration") == HashingEmbedder.stem("calibrate"))
        #expect(HashingEmbedder.stem("glass") == "glass")
        #expect(HashingEmbedder.stem("101") == "101")
    }
}

@Suite struct VectorStoreTests {
    @Test func vectorsRoundTripAndReportStaleness() throws {
        let store = try NexusStore(.inMemory)
        #expect(store.schemaVersion >= 6)
        let id = try make(store, "Pump", .component)
        let orphan = ObjectID.make()
        let vector: [Float] = [0.5, -0.25, 1e-7, -.greatestFiniteMagnitude, 0]
        #expect(StoredVector.decode(StoredVector.encode(vector), dimension: 5) == vector)
        #expect(StoredVector.decode(StoredVector.encode(vector), dimension: 4) == nil)

        try store.upsertVectors([
            StoredVector(object: id, model: "m", vector: vector, contentHash: "h1", updatedAt: t0),
            StoredVector(object: orphan, model: "m", vector: [1, 0, 0, 0, 0], contentHash: "h2", updatedAt: t0),
            StoredVector(object: id, model: "other", vector: [1], contentHash: "h3", updatedAt: t0),
        ])
        let stored = try #require(try store.vector(object: id, model: "m"))
        #expect(stored.vector == vector)
        #expect(stored.dimension == 5)
        #expect(stored.objectType == .component)
        #expect(try store.vector(object: orphan, model: "m")?.objectType == nil)
        #expect(try store.vectorCount(model: "m") == 2)

        // Upsert replaces on (object, model).
        try store.upsertVector(StoredVector(object: id, model: "m", vector: [0, 1, 0, 0, 0], contentHash: "h1b", updatedAt: t0))
        #expect(try store.vectorCount(model: "m") == 2)
        #expect(try store.vector(object: id, model: "m")?.contentHash == "h1b")
        #expect(try store.vectorContentHashes(model: "m") == [id: "h1b", orphan: "h2"])

        let fresh = ObjectID.make()
        let stale = try store.staleVectorObjects(model: "m", current: [id: "h1b", orphan: "changed", fresh: "new"])
        #expect(Set(stale) == [orphan, fresh])

        var streamed: [ObjectID] = []
        try store.forEachVectorChunk(model: "m", chunkSize: 1) { streamed += $0.map(\.object) }
        #expect(streamed == [id, orphan].sorted())

        // Deleted objects are skipped by default.
        try store.setLifecycle(.deleted, of: id, by: tech)
        #expect(try store.vectors(model: "m").map(\.object) == [orphan])
        #expect(try store.vectors(model: "m", includeDeleted: true).count == 2)

        try store.deleteVectors(object: id, model: "m")
        #expect(try store.vector(object: id, model: "m") == nil)
        #expect(try store.vector(object: id, model: "other") != nil)
        try store.deleteVectors(model: "other")
        #expect(try store.vectorCount(model: "other") == 0)
        #expect(throws: StoreError.self) {
            try store.upsertVector(StoredVector(object: id, model: "m", vector: [.nan], contentHash: "", updatedAt: t0))
        }
    }

    @Test func vectorWritesStayOutOfTheChangeFeed() throws {
        let store = try NexusStore(.inMemory)
        let id = try make(store, "Pump")
        let before = store.latestChangeSequence
        try store.upsertVector(StoredVector(object: id, model: "m", vector: [1], contentHash: "h", updatedAt: t0))
        #expect(store.latestChangeSequence == before)
    }
}

@Suite struct VectorSemanticIndexTests {
    @Test func synonymsFindEachOther() throws {
        let store = try NexusStore(.inMemory)
        let seeded = try seedPanel(store)
        let engine = try SearchEngine.withVectors(store: store, graph: ObjectGraph(store: store))
        let index = try #require(engine.semantic as? VectorSemanticIndex)
        index.waitUntilCurrent()
        #expect(index.count == 7)

        // Full text alone can't bridge an abbreviation.
        #expect(try store.search("xmtr").isEmpty)
        let transmitter = try engine.search(SearchQuery("xmtr"))
        #expect(transmitter.first?.id == seeded.transmitter)
        #expect(transmitter.first?.matchedBy == [.semantic])

        let psu = try engine.search(SearchQuery("power supply"))
        #expect(psu.first?.id == seeded.psu)
        #expect(psu.first?.matchedBy.contains(.semantic) == true)

        // Neighbours below the similarity floor are left out rather than padded in.
        #expect(try index.matches(for: "xmtr", limit: 50).count < 7)
        #expect(try index.matches(for: "quantum chromodynamics", limit: 50).isEmpty)

        // Full-text and semantic hits fuse: a word match that is also a
        // semantic neighbour outranks one found by only one retriever.
        let fused = try engine.search(SearchQuery("level transmitter"))
        #expect(fused.first?.id == seeded.transmitter)
        #expect(fused.first?.matchedBy == [.fullText, .semantic])
    }

    @Test func typeAndScopeFiltersApplyWhileRanking() throws {
        let store = try NexusStore(.inMemory)
        let seeded = try seedPanel(store)
        let manual = try make(store, "Transmitter manual", .document, body: "Wiring the xmtr to TB-2")
        let index = try VectorSemanticIndex(store: store)
        index.waitUntilCurrent()

        let documents = try index.matches(for: "xmtr", limit: 5, types: [.document])
        #expect(documents.map(\.id) == [manual])
        let scoped = try index.matches(for: "xmtr", limit: 5, scope: [seeded.psu, seeded.transmitter])
        #expect(scoped.map(\.id) == [seeded.transmitter])
        #expect(try index.nearest(to: "xmtr", limit: 1, types: [.sensor], scope: nil) == [seeded.transmitter])

        let engine = SearchEngine(store: store, graph: ObjectGraph(store: store), semantic: index)
        let results = try engine.search(SearchQuery("xmtr", types: [.sensor]))
        #expect(results.map(\.id) == [seeded.transmitter])
    }

    @Test func updatesReEmbedAndDeletedObjectsDropOut() throws {
        let store = try NexusStore(.inMemory)
        let seeded = try seedPanel(store)
        let index = try VectorSemanticIndex(store: store)
        index.waitUntilCurrent()
        let model = index.modelID
        let firstHash = try #require(try store.vector(object: seeded.psu, model: model)?.contentHash)

        // Renaming re-embeds: the old meaning goes, the new one arrives.
        let spare = try make(store, "Spare parts cabinet", .document)
        index.waitUntilCurrent()
        #expect(try index.nearest(to: "power supply", limit: 1) == [seeded.psu])
        try store.update(spare, by: tech) { $0.title = "Spare power supply shelf" }
        index.waitUntilCurrent()
        #expect(try index.nearest(to: "PSU", limit: 3).contains(spare))

        try store.update(seeded.psu, by: tech) { $0.title = "Pump P-7 impeller" }
        index.waitUntilCurrent()
        #expect(try store.vector(object: seeded.psu, model: model)?.contentHash != firstHash)
        #expect(try index.nearest(to: "power supply", limit: 1) == [spare])

        // A relationship or event doesn't change the text, so nothing is re-embedded.
        let before = try #require(try store.vector(object: spare, model: model)?.updatedAt)
        try store.relate(Relationship(kind: .contains, from: spare, to: seeded.psu, provenance: prov()))
        index.waitUntilCurrent()
        #expect(try store.vector(object: spare, model: model)?.updatedAt == before)

        // Deletion drops the object from memory and the store.
        try store.setLifecycle(.deleted, of: spare, by: tech)
        index.waitUntilCurrent()
        #expect(try !index.nearest(to: "power supply", limit: 10).contains(spare))
        #expect(try store.vector(object: spare, model: model) == nil)
        #expect(index.count == 7)
        #expect(index.lastError == nil)

        // Nothing is stale; forcing re-embeds every live object.
        #expect(try index.reindex(all: false) == 0)
        #expect(try index.reindex(all: true) == 7)
    }

    @Test func vectorsSurviveAReloadAndCatchUpOnMissedChanges() throws {
        let url = temporaryStoreURL()
        defer { removeStore(url) }
        let transmitter: ObjectID
        let psu: ObjectID
        do {
            let store = try NexusStore(.file(url))
            let seeded = try seedPanel(store)
            transmitter = seeded.transmitter
            psu = seeded.psu
            let index = try VectorSemanticIndex(store: store)
            index.waitUntilCurrent()
            #expect(index.count == 7)
        }

        // Changes made while no index is open.
        let added: ObjectID
        do {
            let store = try NexusStore(.file(url))
            added = try make(store, "Field xmitter spare", .component)
            try store.setLifecycle(.deleted, of: psu, by: tech)
        }

        let store = try NexusStore(.file(url))
        #expect(try store.vectorCount(model: HashingEmbedder().modelID) == 7)
        let loaded = try VectorSemanticIndex(store: store, followChanges: false)
        // Loaded from the store, not re-embedded; the deleted object is skipped on load.
        #expect(loaded.count == 6)
        #expect(try loaded.nearest(to: "xmtr", limit: 1) == [transmitter])

        let following = try VectorSemanticIndex(store: store)
        following.waitUntilCurrent()
        #expect(following.count == 7)
        #expect(try Set(following.nearest(to: "xmtr", limit: 2)) == [transmitter, added])
        #expect(try !following.nearest(to: "power supply", limit: 10).contains(psu))
        #expect(try store.vector(object: psu, model: following.modelID) == nil)
        #expect(try following.reindex(all: false) == 0)
    }

    @Test func twentyThousandObjectsSmoke() throws {
        let store = try NexusStore(.inMemory)
        let prefixes = ["LT", "PT", "FT", "TT", "XV", "HS"]
        let nouns = ["pump", "valve", "motor", "breaker", "heater", "fan", "tank", "filter"]
        try store.batch { store in
            for number in 0..<19_999 {
                let tag = "\(prefixes[number % prefixes.count])-\(1_000 + number)"
                try make(store, "\(tag) \(nouns[number % nouns.count]) \(number / nouns.count)", .component)
            }
        }
        let target = try make(store, "Marshalling cabinet 24 V power supply", .component)

        let started = Date()
        let index = try VectorSemanticIndex(store: store, followChanges: false)
        let embedded = try index.reindex(all: false)
        let indexing = Date().timeIntervalSince(started)
        #expect(embedded == 20_000)
        #expect(index.count == 20_000)
        #expect(try store.vectorCount(model: index.modelID) == 20_000)

        let queryStarted = Date()
        let matches = try index.matches(for: "PSU", limit: 25)
        let querying = Date().timeIntervalSince(queryStarted)
        #expect(matches.first?.id == target)
        #expect(!matches.isEmpty && matches.count <= 25)
        #expect(zip(matches, matches.dropFirst()).allSatisfy { $0.similarity >= $1.similarity })

        // Loading 20k stored vectors needs no embedding.
        let reloaded = try VectorSemanticIndex(store: store, followChanges: false)
        #expect(reloaded.count == 20_000)
        #expect(try reloaded.reindex(all: false) == 0)
        // Wall time is reported, not asserted: CI runs suites in parallel.
        print("vector smoke: embedded 20k in \(indexing)s, one query in \(querying)s")
    }
}

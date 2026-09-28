import Foundation
import NexusCore
import NexusModel
import NexusPersistence

/// One semantic neighbour and how close it is.
public struct SemanticMatch: Sendable, Hashable {
    public var id: ObjectID
    public var type: ObjectType
    /// Cosine similarity, −1…1; higher is closer.
    public var similarity: Float
}

/// Semantic retrieval over every live object, by brute-force cosine
/// similarity against vectors held in memory.
///
/// What is embedded: an object's title and its text attributes (the same
/// text full-text search indexes). Document passages are objects of their
/// own, so each passage gets its own vector and a hit lands on the passage.
///
/// Where vectors live: in the canonical store (migration 6), keyed by object
/// and `Embedder.modelID`, with a hash of the embedded text. Opening an index
/// loads them, so a reload doesn't re-embed anything that hasn't changed.
///
/// Keeping up: the index follows the store's change feed in the background.
/// Created and updated objects are re-embedded when their text hash changed;
/// objects whose lifecycle is `.deleted` drop out. It records the last
/// change sequence it applied (setting `semantic.vectors/<model>`), so on the
/// next open it catches up on whatever happened while it was closed. The
/// first open against a store with no watermark embeds everything.
///
/// Cost: a query is one embedding plus a dot product per object. At 100k
/// objects × 256 dimensions that is 25.6M multiply-adds and 100 MB of
/// Float32. Measured in a release build on a shared 4-core Linux container
/// (load average ~18, so an upper bound): 16–18 ms per query, 21 ms with a
/// type filter; embedding and storing all 100k took 5.8 s, and loading them
/// back 0.8 s. That's the envelope where brute force beats an ANN index on
/// simplicity; past about a million vectors, add one behind the same protocol.
public final class VectorSemanticIndex: SemanticIndex, @unchecked Sendable {
    public let store: NexusStore
    public let embedder: any Embedder
    public let minimumSimilarity: Float
    public var dimension: Int { embedder.dimension }
    public var modelID: String { embedder.modelID }

    /// Settings namespace holding each model's change-feed watermark.
    public static let settingsNamespace = "semantic.vectors"
    /// Embedded text is cut at this many characters.
    public static let maxTextCharacters = 8_000
    static let pageSize = 500

    private let queue = DispatchQueue(label: "nexus.search.vectors", qos: .utility)
    private var observation: ChangeObservation?

    /// Guards everything below.
    private let lock = NSLock()
    private var ids: [ObjectID] = []
    private var types: [ObjectType] = []
    private var hashes: [String] = []
    /// Row-major, `ids.count × dimension`.
    private var matrix: [Float] = []
    private var rows: [ObjectID: Int] = [:]
    private var pending: Set<ObjectID> = []
    private var pendingSequence: Int64 = 0
    private var caughtUp = false
    private var savedSequence: Int64 = 0
    private var failure: (any Error)?

    /// Opens the index for `embedder`'s model, loading stored vectors. With
    /// `followChanges`, it then catches up with the change feed and keeps up
    /// in the background; call `waitUntilCurrent()` to wait for that.
    public init(
        store: NexusStore, embedder: any Embedder = HashingEmbedder(), minimumSimilarity: Float? = nil, followChanges: Bool = true
    ) throws {
        self.store = store
        self.embedder = embedder
        self.minimumSimilarity = minimumSimilarity ?? embedder.minimumSimilarity
        try load()
        if followChanges {
            // Observe first, then catch up: a change landing in between is
            // seen twice at worst, and re-embedding is idempotent.
            observation = store.observeChanges { [weak self] changes in self?.enqueue(changes) }
            queue.async { [weak self] in self?.catchUp() }
        }
    }

    deinit {
        observation?.cancel()
    }

    /// Number of objects with a vector in memory.
    public var count: Int { lock.withLock { ids.count } }

    /// The last error from background indexing, if any. Failed objects stay
    /// queued and are retried on the next change or `waitUntilCurrent()`.
    public var lastError: (any Error)? { lock.withLock { failure } }

    /// Blocks until every change delivered so far has been applied. Don't
    /// call it from a change observer.
    public func waitUntilCurrent() {
        queue.sync { drain() }
    }

    /// Brings every vector up to date. With `all`, every object is embedded
    /// again (after an embedder change, say); otherwise only objects whose
    /// text changed or that have no vector. Vectors of deleted or missing
    /// objects are removed either way. Returns the number of objects embedded.
    @discardableResult
    public func reindex(all: Bool = false) throws -> Int {
        try queue.sync { try reindexOnQueue(force: all) }
    }

    // MARK: Query

    public func nearest(to text: String, limit: Int) throws -> [ObjectID] {
        try matches(for: text, limit: limit).map(\.id)
    }

    public func nearest(to text: String, limit: Int, types: Set<ObjectType>?, scope: Set<ObjectID>?) throws -> [ObjectID] {
        try matches(for: text, limit: limit, types: types, scope: scope).map(\.id)
    }

    /// The `limit` objects most similar to `text`, most similar first,
    /// optionally only of `types` and inside `scope`. Neighbours below
    /// `minimumSimilarity` are left out.
    public func matches(for text: String, limit: Int, types typeFilter: Set<ObjectType>? = nil, scope: Set<ObjectID>? = nil) throws
        -> [SemanticMatch]
    {
        guard limit > 0 else { return [] }
        let query = try embedder.embed(text)
        guard query.count == dimension, query.contains(where: { $0 != 0 }) else { return [] }
        let typeFilter = typeFilter?.isEmpty == true ? nil : typeFilter
        let threshold = minimumSimilarity
        let dimension = self.dimension

        return lock.withLock {
            var top = TopK(capacity: limit)
            matrix.withUnsafeBufferPointer { matrix in
                query.withUnsafeBufferPointer { query in
                    func consider(_ row: Int) {
                        if let typeFilter, !typeFilter.contains(types[row]) { return }
                        let score = Self.dot(matrix, row * dimension, query, dimension)
                        if score >= threshold { top.insert(score, row) }
                    }
                    // A small scope is cheaper to walk than the whole matrix.
                    if let scope, scope.count < ids.count / 4 {
                        for id in scope {
                            if let row = rows[id] { consider(row) }
                        }
                    } else {
                        for row in 0..<ids.count {
                            if let scope, !scope.contains(ids[row]) { continue }
                            consider(row)
                        }
                    }
                }
            }
            return top.sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : ids[lhs.row] < ids[rhs.row]
            }
            .map { SemanticMatch(id: ids[$0.row], type: types[$0.row], similarity: $0.score) }
        }
    }

    /// The text embedded for `record`: its title and text attributes.
    public static func content(of record: ObjectRecord) -> String {
        let body = record.searchableText
        let text = body.isEmpty ? record.title : record.title + "\n" + body
        return text.count > maxTextCharacters ? String(text.prefix(maxTextCharacters)) : text
    }

    // MARK: Background

    private func enqueue(_ changes: [StoreChange]) {
        let relevant = changes.filter { $0.kind == .created || $0.kind == .updated }
        lock.withLock {
            pending.formUnion(relevant.map(\.object))
            pendingSequence = max(pendingSequence, changes.map(\.seq).max() ?? 0)
        }
        queue.async { [weak self] in self?.drain() }
    }

    /// Applies queued changes. Runs on `queue`.
    private func drain() {
        let (batch, sequence, current) = lock.withLock {
            defer { pending = [] }
            return (pending, pendingSequence, caughtUp)
        }
        do {
            if !batch.isEmpty {
                try refresh(Array(batch))
            }
            if current { try saveWatermark(sequence) }
        } catch {
            lock.withLock {
                pending.formUnion(batch)
                failure = error
            }
        }
    }

    /// Replays the change feed since the stored watermark, or embeds
    /// everything when there is none. Runs on `queue`.
    private func catchUp() {
        do {
            if let text = try store.setting(Self.settingsNamespace, modelID), let watermark = Int64(text) {
                lock.withLock { savedSequence = watermark }
                var cursor = watermark
                while true {
                    let page = try store.changes(after: cursor, limit: 1_000)
                    guard let last = page.last else { break }
                    let ids = Set(page.filter { $0.kind == .created || $0.kind == .updated }.map(\.object))
                    try refresh(Array(ids))
                    cursor = last.seq
                }
                lock.withLock { caughtUp = true }
                try saveWatermark(cursor)
            } else {
                let latest = store.latestChangeSequence
                try reindexOnQueue(force: false)
                try saveWatermark(latest)
            }
        } catch {
            lock.withLock { failure = error }
        }
    }

    private func saveWatermark(_ sequence: Int64) throws {
        let advance = lock.withLock { sequence > savedSequence }
        guard advance else { return }
        try store.putSetting(Self.settingsNamespace, modelID, String(sequence))
        lock.withLock { savedSequence = max(savedSequence, sequence) }
    }

    private func reindexOnQueue(force: Bool) throws -> Int {
        var embedded = 0
        var seen: Set<ObjectID> = []
        var cursor: ObjectID?
        while true {
            let page = try store.objectPage(after: cursor, limit: Self.pageSize)
            guard let last = page.last else { break }
            embedded += try apply(page, missing: [], force: force)
            seen.formUnion(page.map(\.id))
            cursor = last.id
        }
        let orphans = lock.withLock { ids.filter { !seen.contains($0) } }
        _ = try apply([], missing: orphans, force: false)
        lock.withLock {
            caughtUp = true
            failure = nil
        }
        return embedded
    }

    /// Re-reads `ids` from the store and updates their vectors.
    private func refresh(_ ids: [ObjectID]) throws {
        for start in stride(from: 0, to: ids.count, by: Self.pageSize) {
            let chunk = Array(ids[start..<min(start + Self.pageSize, ids.count)])
            let records = try store.objects(chunk)
            let found = Set(records.map(\.id))
            _ = try apply(records, missing: chunk.filter { !found.contains($0) }, force: false)
        }
    }

    /// Embeds live records whose text changed (or all, with `force`) and
    /// drops deleted and missing ones, in the store and then in memory.
    private func apply(_ records: [ObjectRecord], missing: [ObjectID], force: Bool) throws -> Int {
        let known: [ObjectID: String] = lock.withLock {
            var known: [ObjectID: String] = [:]
            for record in records {
                if let row = rows[record.id] { known[record.id] = hashes[row] }
            }
            return known
        }
        var removals = missing
        var upserts: [StoredVector] = []
        var retyped: [(ObjectID, ObjectType)] = []
        let now = Date()
        for record in records {
            guard record.lifecycle != .deleted else {
                removals.append(record.id)
                continue
            }
            let text = Self.content(of: record)
            let hash = HashingEmbedder.fingerprint(text)
            if !force, known[record.id] == hash {
                retyped.append((record.id, record.type))
                continue
            }
            let vector = try embedder.embed(text)
            guard vector.count == dimension, vector.contains(where: { $0 != 0 }) else {
                removals.append(record.id)
                continue
            }
            upserts.append(
                StoredVector(object: record.id, model: modelID, vector: vector, contentHash: hash, updatedAt: now, objectType: record.type)
            )
        }
        try store.upsertVectors(upserts)
        try store.deleteVectors(objects: removals, model: modelID)
        lock.withLock {
            for vector in upserts {
                setRow(vector.object, vector.objectType ?? "", vector.vector, vector.contentHash)
            }
            for (id, type) in retyped {
                if let row = rows[id] { types[row] = type }
            }
            for id in removals {
                removeRow(id)
            }
        }
        return upserts.count
    }

    // MARK: Memory

    private func load() throws {
        try store.forEachVectorChunk(model: modelID) { chunk in
            lock.withLock {
                for vector in chunk where vector.dimension == dimension {
                    setRow(vector.object, vector.objectType ?? "", vector.vector, vector.contentHash)
                }
            }
        }
    }

    /// Caller holds `lock`.
    private func setRow(_ id: ObjectID, _ type: ObjectType, _ vector: [Float], _ hash: String) {
        if let row = rows[id] {
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension, with: vector)
            types[row] = type
            hashes[row] = hash
        } else {
            rows[id] = ids.count
            ids.append(id)
            types.append(type)
            hashes.append(hash)
            matrix.append(contentsOf: vector)
        }
    }

    /// Swap-removes a row. Caller holds `lock`.
    private func removeRow(_ id: ObjectID) {
        guard let row = rows.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if row != last {
            ids[row] = ids[last]
            types[row] = types[last]
            hashes[row] = hashes[last]
            for offset in 0..<dimension {
                matrix[row * dimension + offset] = matrix[last * dimension + offset]
            }
            rows[ids[row]] = row
        }
        ids.removeLast()
        types.removeLast()
        hashes.removeLast()
        matrix.removeLast(dimension)
    }

    @inline(__always)
    private static func dot(_ matrix: UnsafeBufferPointer<Float>, _ base: Int, _ query: UnsafeBufferPointer<Float>, _ dimension: Int) -> Float {
        var index = 0
        var wide = SIMD8<Float>()
        if let matrixBase = matrix.baseAddress, let queryBase = query.baseAddress {
            let row = UnsafeRawPointer(matrixBase + base)
            let probe = UnsafeRawPointer(queryBase)
            while index + 8 <= dimension {
                let offset = index * MemoryLayout<Float>.stride
                wide +=
                    row.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                    * probe.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                index += 8
            }
        }
        var a: Float = wide.sum()
        var b: Float = 0
        var c: Float = 0
        var d: Float = 0
        while index + 4 <= dimension {
            a += matrix[base + index] * query[index]
            b += matrix[base + index + 1] * query[index + 1]
            c += matrix[base + index + 2] * query[index + 2]
            d += matrix[base + index + 3] * query[index + 3]
            index += 4
        }
        while index < dimension {
            a += matrix[base + index] * query[index]
            index += 1
        }
        return (a + b) + (c + d)
    }
}

/// The `capacity` highest scores seen, as a min-heap on score.
struct TopK {
    struct Entry {
        var score: Float
        var row: Int
    }

    let capacity: Int
    private(set) var heap: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 0)
        heap.reserveCapacity(min(self.capacity, 1_024))
    }

    mutating func insert(_ score: Float, _ row: Int) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(Entry(score: score, row: row))
            siftUp(heap.count - 1)
        } else if score > heap[0].score {
            heap[0] = Entry(score: score, row: row)
            siftDown(0)
        }
    }

    func sorted(by areInIncreasingOrder: (Entry, Entry) -> Bool) -> [Entry] {
        heap.sorted(by: areInIncreasingOrder)
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].score < heap[parent].score else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].score < heap[smallest].score { smallest = left }
            if right < heap.count, heap[right].score < heap[smallest].score { smallest = right }
            guard smallest != parent else { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

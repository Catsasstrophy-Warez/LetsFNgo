import Foundation
import NexusCore
import NexusModel
import Testing
@testable import NexusPersistence

/// Guards against pathological (super-linear) behaviour, not absolute speed:
/// absolute numbers belong to `NexusBenchmarks` and docs/PERFORMANCE.md.
/// Bounds are loose enough for a debug build on a slow CI machine.
@Suite struct PerformanceSmokeTests {
    /// CPU time of the calling thread spent in `body`. The work is synchronous,
    /// so it stays on one thread, and CPU time ignores the scheduling delays
    /// that wall-clock time picks up when the rest of the suite runs in parallel.
    private static func seconds(_ body: () throws -> Void) rethrows -> Double {
        func now() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
        }
        let start = now()
        try body()
        return now() - start
    }

    @Test func insertAndSearchStayLinear() throws {
        let store = try NexusStore(.inMemory)
        let author = Origin.user(id: "smoke")
        let words = ["pump", "valve", "transmitter", "loop", "terminal", "relay", "motor", "breaker"]
        let chunk = 500
        var chunkTimes: [Double] = []
        var ids: [ObjectID] = []
        for chunkIndex in 0..<5 {
            chunkTimes.append(try Self.seconds {
                try store.batch { store in
                    for offset in 0..<chunk {
                        let index = chunkIndex * chunk + offset
                        let record = try store.create(ObjectRecord(
                            type: .component, title: "\(words[index % words.count]) \(index)",
                            attributes: ["note": Attribute(.string("\(words[(index / 8) % words.count]) check"))],
                            provenance: Provenance(origin: author, truth: .recorded, timestamp: Date())
                        ))
                        ids.append(record.id)
                    }
                }
            })
        }
        #expect(ids.count == 5 * chunk)
        // The last chunk costs about what the first did.
        #expect(chunkTimes[4] < chunkTimes[0] * 4 + 0.25, "insert slowed down: \(chunkTimes)")

        var hits = 0
        let searchTime = try Self.seconds {
            for _ in 0..<10 {
                for word in words { hits += try store.search(word, limit: 20).count }
            }
        }
        #expect(hits == 10 * words.count * 20)
        // 80 limited queries: milliseconds each, not a scan per hit.
        #expect(searchTime < 2, "80 searches took \(searchTime) s")
        #expect(try store.objects(Array(ids.suffix(500))).count == 500)
    }
}

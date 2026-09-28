import Foundation
import NexusCore
import NexusModel
import Testing
@testable import NexusPersistence

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct ContentHashTests {
    /// FIPS 180-4 / NIST CAVP example vectors.
    @Test func matchesPublishedVectors() {
        #expect(ContentHash.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ContentHash.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            ContentHash.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        #expect(
            ContentHash.sha256(
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
            ) == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
        #expect(
            ContentHash.sha256(Data(repeating: 0x61, count: 1_000_000))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    @Test func incrementalUpdatesMatchOneShot() {
        let data = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for split in [0, 1, 55, 56, 63, 64, 65, 500, 1_000] {
            var hasher = SHA256Hasher()
            hasher.update(data.prefix(split))
            hasher.update(data.dropFirst(split))
            #expect(hasher.finalize().map { String(format: "%02x", $0) }.joined() == ContentHash.sha256(data))
        }
    }
}

@Suite struct BlobStoreTests {
    @Test func putDeduplicatesBySHA256() throws {
        let store = try NexusStore(.inMemory, clock: ManualClock(t0))
        let bytes = Data("loop drawing rev C".utf8)
        let first = try store.putBlob(bytes, mediaType: "text/plain")
        let second = try store.putBlob(bytes, mediaType: "application/octet-stream")
        #expect(first == second)
        #expect(first.byteCount == bytes.count)
        #expect(first.mediaType == "text/plain")
        #expect(try store.blob(sha256: first.sha256) == first)
        #expect(try store.blobData(sha256: first.sha256) == bytes)
        #expect(try store.blobData(sha256: ContentHash.sha256("absent")) == nil)
        #expect(throws: BlobError.invalidDigest("not-a-digest")) { try store.blobData(sha256: "not-a-digest") }
        #expect(store.blobDirectory == nil)
    }

    @Test func fileStoreKeepsBytesBesideTheDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blobs-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".blobs"))
        }
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        let blob: BlobRef
        do {
            let store = try NexusStore(.file(url))
            blob = try store.putBlob(bytes, mediaType: "application/octet-stream")
            let directory = try #require(store.blobDirectory)
            let file = directory.appendingPathComponent(String(blob.sha256.prefix(2))).appendingPathComponent(blob.sha256)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        let reopened = try NexusStore(.file(url))
        #expect(try reopened.blob(sha256: blob.sha256) == blob)
        #expect(try reopened.blobData(sha256: blob.sha256) == bytes)

        // Tampered bytes are detected, not returned.
        let file = try #require(reopened.blobDirectory)
            .appendingPathComponent(String(blob.sha256.prefix(2))).appendingPathComponent(blob.sha256)
        try Data("tampered".utf8).write(to: file)
        #expect(throws: BlobError.corruptBytes(sha256: blob.sha256)) { try reopened.blobData(sha256: blob.sha256) }
        // A missing file is reported, and putting the bytes again restores it.
        try FileManager.default.removeItem(at: file)
        #expect(throws: BlobError.missingBytes(sha256: blob.sha256)) { try reopened.blobData(sha256: blob.sha256) }
        try reopened.putBlob(bytes, mediaType: "application/octet-stream")
        #expect(try reopened.blobData(sha256: blob.sha256) == bytes)
    }

    @Test func failedBatchLeavesNoBlobRow() throws {
        struct Abort: Error {}
        let store = try NexusStore(.inMemory)
        let bytes = Data("rolled back".utf8)
        #expect(throws: Abort.self) {
            try store.batch { store in
                try store.putBlob(bytes, mediaType: "text/plain")
                throw Abort()
            }
        }
        #expect(try store.blob(sha256: ContentHash.sha256(bytes)) == nil)
    }
}

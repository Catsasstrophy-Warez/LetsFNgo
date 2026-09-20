import XCTest
import Foundation
@testable import DayTradeScanner

/// Round-trip coverage for the `nonisolated static loadFromDisk`-shaped
/// functions added to BaselineStore/UniverseBuilder/SECFloatClient during
/// the Swift 6 actor-initializer fix (an actor's synchronous init can't
/// call its own actor-isolated instance methods, so each was restructured
/// into a static function that does the file I/O and decoding, assigned
/// directly to the stored property from init). These tests exist
/// specifically to catch a regression in that refactor — a wrong URL, a
/// dropped field, an encode/decode mismatch — since nothing else in the
/// suite exercises disk persistence at all.
final class DiskPersistenceRoundTripTests: XCTestCase {
    private func makeTempFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    // MARK: - BaselineStore

    private func makeBaseline(symbol: String) -> VolumeBaseline {
        VolumeBaseline(
            symbol: symbol,
            builtAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionsUsed: 20,
            cumulativeMedian: [100, 200, 300],
            barMedian: [10, 10, 10],
            priorClose: 50.0,
            atr14: 1.25,
            medianDailyVolume: 1_000_000
        )
    }

    func testBaselineStoreRoundTripsThroughDisk() throws {
        let url = makeTempFileURL("baselines")
        defer { try? FileManager.default.removeItem(at: url) }

        let original: [String: VolumeBaseline] = [
            "AAPL": makeBaseline(symbol: "AAPL"),
            "TSLA": makeBaseline(symbol: "TSLA")
        ]
        let data = try JSONEncoder().encode(original)
        try data.write(to: url)

        let loaded = BaselineStore.loadBaselinesFromDisk(at: url)

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["AAPL"]?.symbol, "AAPL")
        XCTAssertEqual(loaded["AAPL"]?.priorClose, 50.0)
        XCTAssertEqual(loaded["AAPL"]?.cumulativeMedian, [100, 200, 300])
        XCTAssertEqual(loaded["TSLA"]?.atr14, 1.25)
    }

    func testBaselineStoreLoadFromMissingFileReturnsEmptyRatherThanThrowing() {
        let url = makeTempFileURL("does-not-exist")
        let loaded = BaselineStore.loadBaselinesFromDisk(at: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testBaselineStoreLoadFromCorruptFileReturnsEmptyRatherThanCrashing() throws {
        let url = makeTempFileURL("corrupt-baselines")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not valid json".utf8).write(to: url)

        let loaded = BaselineStore.loadBaselinesFromDisk(at: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - UniverseBuilder

    private func makeProfile(symbol: String) -> VolatilityProfile {
        VolatilityProfile(
            symbol: symbol,
            builtAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionsAnalyzed: 60,
            atrPercent: 0.04,
            medianRangePercent: 0.03,
            upperRangePercent: 0.08,
            runnerFrequency: 0.1,
            runnerDayCount: 6,
            maxRangePercent: 0.22,
            compressionRatio: 0.7,
            medianDailyVolume: 2_500_000,
            volumeTrend: 1.1,
            lastClose: 12.5
        )
    }

    func testUniverseBuilderRoundTripsThroughDisk() throws {
        let url = makeTempFileURL("profiles")
        defer { try? FileManager.default.removeItem(at: url) }

        let original: [String: VolatilityProfile] = [
            "GME": makeProfile(symbol: "GME")
        ]
        let data = try JSONEncoder().encode(original)
        try data.write(to: url)

        let loaded = UniverseBuilder.loadProfilesFromDisk(at: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded["GME"]?.symbol, "GME")
        XCTAssertEqual(loaded["GME"]?.runnerDayCount, 6)
        XCTAssertEqual(loaded["GME"]?.lastClose, 12.5)
    }

    func testUniverseBuilderLoadFromMissingFileReturnsEmpty() {
        let url = makeTempFileURL("does-not-exist-profiles")
        let loaded = UniverseBuilder.loadProfilesFromDisk(at: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - SECFloatClient

    private func makeFloatRecord(symbol: String, cik: Int) -> SECFloatClient.FloatRecord {
        SECFloatClient.FloatRecord(
            symbol: symbol,
            cik: cik,
            entityName: "\(symbol) Inc.",
            sharesOutstanding: nil,
            publicFloatUSD: nil,
            floatShares: nil,
            sharesOutstandingDate: nil,
            publicFloatDate: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testSECFloatClientRoundTripsRecordsAndTickerMapThroughDisk() throws {
        let recordsURL = makeTempFileURL("sec-float")
        let mapURL = makeTempFileURL("sec-ticker-map")
        defer {
            try? FileManager.default.removeItem(at: recordsURL)
            try? FileManager.default.removeItem(at: mapURL)
        }

        let records: [String: SECFloatClient.FloatRecord] = [
            "MSFT": makeFloatRecord(symbol: "MSFT", cik: 789019)
        ]
        let tickerMap: [String: Int] = ["MSFT": 789019, "AAPL": 320193]

        try JSONEncoder().encode(records).write(to: recordsURL)
        try JSONEncoder().encode(tickerMap).write(to: mapURL)

        let loaded = SECFloatClient.loadFromDisk(recordsURL: recordsURL, mapURL: mapURL)

        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.records["MSFT"]?.cik, 789019)
        XCTAssertEqual(loaded.tickerToCIK["MSFT"], 789019)
        XCTAssertEqual(loaded.tickerToCIK["AAPL"], 320193)
        // Shorter ticker wins when two tickers map to the same CIK, per
        // loadFromDisk's own uniquingKeysWith rule.
        XCTAssertEqual(loaded.cikToTicker[789019], "MSFT")
    }

    func testSECFloatClientLoadFromMissingFilesReturnsAllEmpty() {
        let recordsURL = makeTempFileURL("missing-records")
        let mapURL = makeTempFileURL("missing-map")
        let loaded = SECFloatClient.loadFromDisk(recordsURL: recordsURL, mapURL: mapURL)
        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertTrue(loaded.tickerToCIK.isEmpty)
        XCTAssertTrue(loaded.cikToTicker.isEmpty)
    }

    func testSECFloatClientCIKToTickerPrefersShorterTickerOnCollision() throws {
        let recordsURL = makeTempFileURL("sec-float-collision")
        let mapURL = makeTempFileURL("sec-ticker-map-collision")
        defer {
            try? FileManager.default.removeItem(at: recordsURL)
            try? FileManager.default.removeItem(at: mapURL)
        }

        try JSONEncoder().encode([String: SECFloatClient.FloatRecord]()).write(to: recordsURL)
        // Two tickers resolving to the same CIK (e.g. a share-class alias) —
        // the shorter one should win the reverse cikToTicker lookup.
        let tickerMap: [String: Int] = ["GOOGL": 1652044, "GOOG": 1652044]
        try JSONEncoder().encode(tickerMap).write(to: mapURL)

        let loaded = SECFloatClient.loadFromDisk(recordsURL: recordsURL, mapURL: mapURL)
        XCTAssertEqual(loaded.cikToTicker[1652044], "GOOG")
    }
}

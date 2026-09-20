import XCTest
import Foundation
import SwiftData
@testable import DayTradeScanner

@MainActor
final class RecipeFitnessEngineTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Mirrors `DayTradeScannerApp`'s in-memory fallback container
    /// construction (`ModelConfiguration(isStoredInMemoryOnly: true)`).
    private func makeInMemoryLog() -> (PaperTradeLog, ModelContext) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: PaperTrade.self, configurations: configuration)
        let context = ModelContext(container)
        let log = PaperTradeLog()
        log.attach(context: context)
        return (log, context)
    }

    /// A long candidate (trend above VWAP, no VWAP event, so `open(from:)`
    /// resolves the direction to `.long`) at a controllable entry price.
    private func makeCandidate(symbol: String, entryPrice: Double, score: Double = 0.7) -> Candidate {
        let snapshot = SignalSnapshot(
            symbol: symbol,
            asOf: referenceDate,
            last: entryPrice,
            priorClose: entryPrice * 0.97,
            sessionOpen: entryPrice * 0.97,
            dayHigh: entryPrice * 1.05,
            dayLow: entryPrice * 0.95,
            vwap: entryPrice * 0.99,
            vwapZ: 1.0,
            vwapEvent: .none,
            minutesSinceVWAPEvent: nil,
            trend: .aboveVWAP,
            rvol: 3.0,
            cumulativeVolume: 300_000,
            baselineVolumeAtMinute: 100_000,
            minuteOfSession: 60,
            barRVOL: 2.0,
            gapPercent: 0.0,
            atr14: 0.5,
            rangePosition: 0.5,
            latestNews: nil,
            newsAgeMinutes: nil,
            newsCategory: nil,
            shortRatio: nil,
            shortRatioPercentile: nil,
            dollarVolume: 500_000,
            tradeCount: 50
        )
        var breakdown = ScoreBreakdown()
        breakdown.total = score
        return Candidate(snapshot: snapshot, breakdown: breakdown)
    }

    /// Opens and immediately closes a trade under `recipeName`, with a close
    /// price chosen so `bestAvailableReturn` resolves to a known sign.
    @discardableResult
    private func recordTrade(
        log: PaperTradeLog,
        symbol: String,
        recipeName: String,
        entryPrice: Double,
        closePrice: Double
    ) -> PaperTrade? {
        let candidate = makeCandidate(symbol: symbol, entryPrice: entryPrice)
        log.open(from: candidate, recipeName: recipeName)
        guard let trade = log.trades.first(where: { $0.symbol == symbol && $0.status == .open }) else {
            return nil
        }
        log.close(trade, at: closePrice)
        return trade
    }

    func testFitnessIsNilBelowMinimumSampleSizeAndNonNilAtThreshold() {
        let (log, _) = makeInMemoryLog()
        let engine = RecipeFitnessEngine()

        // 4 resolved trades — one short of the engine's minimum sample size of 5.
        for index in 0..<4 {
            recordTrade(log: log, symbol: "SYM\(index)", recipeName: "Recipe4", entryPrice: 10, closePrice: 11)
        }
        engine.recompute(using: log)
        XCTAssertNil(engine.fitness(for: "Recipe4"))

        // A 5th resolved trade crosses the minimum sample size.
        recordTrade(log: log, symbol: "SYM4", recipeName: "Recipe4", entryPrice: 10, closePrice: 11)
        engine.recompute(using: log)
        XCTAssertNotNil(engine.fitness(for: "Recipe4"))
    }

    func testMostlyWinningRecipeGetsMultiplierAboveOneClampedToBand() throws {
        let (log, _) = makeInMemoryLog()
        let engine = RecipeFitnessEngine()

        // 4 wins (+3% each), 1 loss (-1%): a clearly winning recipe.
        for index in 0..<4 {
            recordTrade(log: log, symbol: "WIN\(index)", recipeName: "Winner", entryPrice: 10, closePrice: 10.3)
        }
        recordTrade(log: log, symbol: "WIN4", recipeName: "Winner", entryPrice: 10, closePrice: 9.9)

        engine.recompute(using: log)
        let fitness = try XCTUnwrap(engine.fitness(for: "Winner"))
        XCTAssertGreaterThan(fitness.multiplier, 1.0)
        XCTAssertGreaterThanOrEqual(fitness.multiplier, 0.75)
        XCTAssertLessThanOrEqual(fitness.multiplier, 1.25)
    }

    func testMostlyLosingRecipeGetsMultiplierBelowOneClampedToBand() throws {
        let (log, _) = makeInMemoryLog()
        let engine = RecipeFitnessEngine()

        // 4 losses (-3% each), 1 win (+1%): a clearly losing recipe.
        for index in 0..<4 {
            recordTrade(log: log, symbol: "LOSE\(index)", recipeName: "Loser", entryPrice: 10, closePrice: 9.7)
        }
        recordTrade(log: log, symbol: "LOSE4", recipeName: "Loser", entryPrice: 10, closePrice: 10.1)

        engine.recompute(using: log)
        let fitness = try XCTUnwrap(engine.fitness(for: "Loser"))
        XCTAssertLessThan(fitness.multiplier, 1.0)
        XCTAssertGreaterThanOrEqual(fitness.multiplier, 0.75)
        XCTAssertLessThanOrEqual(fitness.multiplier, 1.25)
    }

    func testMultiplierForNilRecipeNameIsExactlyOne() {
        let engine = RecipeFitnessEngine()
        XCTAssertEqual(engine.multiplier(for: nil), 1.0)
    }
}

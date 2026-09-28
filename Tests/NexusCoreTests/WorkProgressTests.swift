import Foundation
import Testing

@testable import NexusCore

@Suite struct WorkProgressTests {
    @Test func stagesTrackUnitsCurrentItemAndOverallFraction() {
        let progress = WorkProgress(title: "Diagnose loop", stages: [("Sources checked", 4), ("Tests complete", nil)])
        #expect(progress.snapshot.fractionCompleted == 0)

        progress.begin(stage: 0)
        progress.advance(item: "Manual")
        progress.advance(item: "Datasheet")
        var snapshot = progress.snapshot
        #expect(snapshot.currentStage == 0)
        #expect(snapshot.currentItem == "Datasheet")
        #expect(snapshot.stages[0].completedUnits == 2)
        #expect(abs(snapshot.fractionCompleted - 0.25) < 1e-12)

        // Beginning the next stage completes the running one.
        progress.begin("Tests complete", item: "TB-4 voltage")
        snapshot = progress.snapshot
        #expect(snapshot.stages[0].state == .completed)
        #expect(snapshot.stages[0].completedUnits == 2, "Units are reported, not invented")
        #expect(snapshot.stages[1].state == .running)
        #expect(abs(snapshot.fractionCompleted - 0.75) < 1e-12, "Unknown totals count as half done")

        progress.finish()
        snapshot = progress.snapshot
        #expect(snapshot.isFinished)
        #expect(snapshot.fractionCompleted == 1)
        #expect(snapshot.currentItem == nil)
    }

    @Test func updatesStreamYieldsCurrentStateThenChangesAndFinishes() async {
        let progress = WorkProgress(title: "Build topology", stages: [("Nodes", 3)])
        var iterator = progress.updates().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.isFinished == false)
        #expect(initial?.currentStage == nil)

        progress.begin(stage: 0, item: "TB-4")
        #expect(await iterator.next()?.currentItem == "TB-4")

        progress.advance()
        progress.finish()
        // Buffering keeps only the newest pending value, so a slow consumer
        // skips to the latest state; the stream then ends.
        let last = await iterator.next()
        #expect(last?.isFinished == true)
        #expect(last?.stages[0].completedUnits == 3)
        #expect(await iterator.next() == nil)
    }

    @Test func subscribingAfterFinishYieldsTheFinalStateOnce() async {
        let progress = WorkProgress(title: "Done", stageNames: ["Only"])
        progress.finish()
        var count = 0
        for await snapshot in progress.updates() {
            #expect(snapshot.isFinished)
            count += 1
        }
        #expect(count == 1)
    }

    @Test func failureAndCancellationMarkTheRunningStageAndStopChanges() {
        let failing = WorkProgress(title: "Import", stageNames: ["Read", "Parse"])
        failing.begin(stage: 1)
        failing.fail("Bad header")
        failing.advance(by: 5)
        #expect(failing.snapshot.stages[1].state == .failed)
        #expect(failing.snapshot.stages[1].completedUnits == 0, "No changes after the work ends")
        #expect(failing.snapshot.failure == "Bad header")

        let cancelled = WorkProgress(title: "Simulate", stages: [("Ticks", 100)])
        cancelled.begin(stage: 0)
        cancelled.setCompleted(40)
        cancelled.cancel()
        #expect(cancelled.snapshot.isCancelled)
        #expect(abs(cancelled.snapshot.fractionCompleted - 0.4) < 1e-12)
    }

    @Test func concurrentReportersNeverLoseUnits() async {
        let progress = WorkProgress(title: "Parallel", stages: [("Items", 1000)])
        progress.begin(stage: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<100 { progress.advance() }
                }
            }
        }
        #expect(progress.snapshot.stages[0].completedUnits == 1000)
    }
}

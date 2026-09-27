import Testing
import ControlsPLC
import ControlsSimulation
@testable import ControlsTraining

@Test func chapterCertificationGeneratorCreatesSevenProgressivelyCumulativePracticals() throws {
    let exams = try StepByStepChapter.allCases.map { try ChapterCertificationGenerator.generate(chapter:$0, seed:500 + UInt64($0.rawValue)) }
    #expect(exams.count == 7)
    #expect(exams[0].kind == .buildFromScratch)
    #expect(exams[1].kind == .repairBrokenProgram)
    #expect(exams[4].kind == .diagnoseWholeController)
    #expect(exams[6].kind == .commissionWholeController)
    #expect(exams[6].requiredSkills == ApprenticeshipSkill.allCases)
    #expect(exams.map(\.passingPercent) == exams.map(\.passingPercent).sorted())
}

@Test func certificationProfileRequiresChapterCompletionAndPreviousCertification() {
    var progress = StepByStepProgressProfile()
    var profile = ChapterCertificationProfile()
    #expect(!profile.isUnlocked(.foundations, progress:progress))
    for lesson in StepByStepCatalog.lessons(in:StepByStepChapter.foundations) { progress.markComplete(lesson.id) }
    #expect(profile.isUnlocked(.foundations, progress:progress))
    for lesson in StepByStepCatalog.lessons(in:StepByStepChapter.digitalMachineControl) { progress.markComplete(lesson.id) }
    #expect(!profile.isUnlocked(.digitalMachineControl, progress:progress))
    profile.record(.init(chapter:.foundations, examID:"x", score:90, passed:true, verificationPerformed:true, feedback:[]))
    #expect(profile.isUnlocked(.digitalMachineControl, progress:progress))
}

@Test func ladderCertificationRequiresVerificationAndHigherChapterThreshold() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.foundations, seed:100)
    let lesson = try #require(StepByStepCatalog.lesson("foundation-first-rung"))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    let r = wb.addRung()
    try wb.append(.instruction(.xic(tag:"Start_PB")), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    let noVerify = ChapterCertificationAssessor.assessLadder(exam:exam, workbench:wb, verificationPerformed:false)
    let verified = ChapterCertificationAssessor.assessLadder(exam:exam, workbench:wb, verificationPerformed:true)
    #expect(!noVerify.passed)
    #expect(verified.passed)
}

@Test func architectureCertificationRestrictsChapterFiveAndSixRootCauseDomains() throws {
    let five = try ChapterCertificationGenerator.generate(chapter:.architectureNetworking, seed:333)
    let six = try ChapterCertificationGenerator.generate(chapter:.supervisoryData, seed:333)
    let arch5 = try #require(try five.makeArchitecture())
    let arch6 = try #require(try six.makeArchitecture())
    #expect([GeneratedArchitectureBoundary.taskScheduling,.routineCallPath,.tagScope,.remoteIO,.explicitMessaging].contains(arch5.primaryIssue!.boundary))
    #expect([GeneratedArchitectureBoundary.hmiMapping,.historianCollection].contains(arch6.primaryIssue!.boundary))
}

@Test func finalCertificationRequiresRootCauseAllRealRepairsAndVerification() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.commissioningCapstone, seed:9001)
    let architecture = try #require(try exam.makeArchitecture())
    let root = try #require(architecture.primaryIssue)
    let required = Set(architecture.issues.filter(\.shouldRepair).map(\.id))
    let incomplete = ChapterCertificationAssessor.assessArchitecture(exam:exam, architecture:architecture, identifiedIssueIDs:[root.id], repairedIssueIDs:[root.id], verificationPerformed:true)
    let complete = ChapterCertificationAssessor.assessArchitecture(exam:exam, architecture:architecture, identifiedIssueIDs:[root.id], repairedIssueIDs:required, verificationPerformed:true)
    #expect(!incomplete.passed)
    #expect(complete.passed)
}

@Test func certificationTranscriptRoundTripsAndReconstructsArchitectureAttempt() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.commissioningCapstone, seed:8128)
    let architecture = try #require(try exam.makeArchitecture())
    let primary = try #require(architecture.primaryIssue)
    let repairable = try #require(architecture.issues.first(where: { $0.shouldRepair }))
    var transcript = CertificationAttemptTranscript(exam:exam)
    transcript.append(.inspectedArchitecture)
    transcript.append(.identifiedPrimary(issueID:primary.id))
    transcript.append(.repairSelection(issueID:repairable.id, selected:true))
    transcript.append(.verificationSet(true))
    let result = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:91, passed:true, verificationPerformed:true, feedback:["verified"])
    transcript.append(.submitted(result))
    let data = try transcript.encodedJSON()
    let decoded = try CertificationAttemptTranscript.decodeJSON(data)
    #expect(decoded == transcript)
    #expect(decoded.identifiedPrimaryIssueID == primary.id)
    #expect(decoded.finalRepairSelections.contains(repairable.id))
    #expect(decoded.verificationPerformed)
    #expect(decoded.submittedResult == result)
}

@Test func failedCertificationCreatesTargetedRemediationFromWeakestSkills() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.digitalMachineControl, seed:222)
    let result = ChapterCertificationResult(
        chapter: exam.chapter, examID: exam.id, score:61, passed:false, verificationPerformed:true,
        feedback:["Seal topology failed"],
        skillScores:[.instructionChoice:0.8, .rungTopology:0.0, .interlocksAndState:0.5, .verification:1.0]
    )
    let plan = try #require(CertificationRemediationEngine.plan(after:result, exam:exam))
    #expect(plan.weakSkills.first == .rungTopology)
    #expect(plan.modules.first?.lessonID == "digital-motor-seal")
    #expect(plan.modules.count <= 3)
}

@Test func passingCertificationDoesNotCreateRemediation() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.foundations, seed:333)
    let result = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:95, passed:true, verificationPerformed:true, feedback:[], skillScores:[.verification:1])
    #expect(CertificationRemediationEngine.plan(after:result, exam:exam) == nil)
}

@Test func remediationRequiresAllTargetedModulesBeforeRetest() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.analogProcessControl, seed:444)
    let result = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:54, passed:false, verificationPerformed:false, feedback:[], skillScores:[.analogMath:0.2,.verification:0])
    let plan = try #require(CertificationRemediationEngine.plan(after:result, exam:exam))
    var progress = CertificationRemediationProgress(planID:plan.id)
    #expect(!progress.isReadyForRetest(plan))
    for module in plan.modules { progress.markComplete(module.id) }
    #expect(progress.isReadyForRetest(plan))
}

@Test func remediationRetestUsesFreshDeterministicSeed() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.architectureNetworking, seed:555)
    let result = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:40, passed:false, verificationPerformed:false, feedback:[], skillScores:[.communications:0,.verification:0])
    let planA = try #require(CertificationRemediationEngine.plan(after:result, exam:exam))
    let planB = try #require(CertificationRemediationEngine.plan(after:result, exam:exam))
    let retestA = try CertificationRemediationEngine.freshRetest(for:planA)
    let retestB = try CertificationRemediationEngine.freshRetest(for:planB)
    #expect(retestA.seed != exam.seed)
    #expect(retestA.id != exam.id)
    #expect(retestA.id == retestB.id)
    #expect(retestA.architectureSeed == retestB.architectureSeed)
}

@Test func architectureFailureMapsBoundaryToSpecificRemediationSkill() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.supervisoryData, seed:666)
    let architecture = try #require(try exam.makeArchitecture())
    let result = ChapterCertificationAssessor.assessArchitecture(exam:exam, architecture:architecture, identifiedIssueIDs:[], repairedIssueIDs:[], verificationPerformed:false)
    let plan = try #require(CertificationRemediationEngine.plan(after:result, exam:exam))
    let boundary = try #require(architecture.primaryIssue?.boundary)
    if boundary == .historianCollection {
        #expect(plan.weakSkills.contains(.historianReasoning))
    } else {
        #expect(plan.weakSkills.contains(.communications))
    }
    #expect(plan.weakSkills.contains(.verification))
}

@Test func certificationJourneyTranscriptRoundTripsFailRemediateRetestPass() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.analogProcessControl, seed:777)
    let failed = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:58, passed:false, verificationPerformed:false, feedback:["threshold proof missing"], skillScores:[.analogMath:0.4,.verification:0])
    let plan = try #require(CertificationRemediationEngine.plan(after:failed, exam:exam))
    let retest = try CertificationRemediationEngine.freshRetest(for:plan)
    let passed = ChapterCertificationResult(chapter:retest.chapter, examID:retest.id, score:91, passed:true, verificationPerformed:true, feedback:["verified"], skillScores:[.analogMath:0.95,.verification:1])
    var journey = CertificationJourneyTranscript(chapter:exam.chapter)
    journey.append(.attemptSubmitted(examID:exam.id, seed:exam.seed, result:failed))
    journey.append(.remediationAssigned(planID:plan.id, weakSkills:plan.weakSkills))
    for module in plan.modules { journey.append(.remediationModuleCompleted(moduleID:module.id)) }
    journey.append(.retestIssued(examID:retest.id, seed:retest.seed))
    journey.append(.attemptSubmitted(examID:retest.id, seed:retest.seed, result:passed))
    journey.append(.certified(examID:retest.id, score:passed.score))
    let decoded = try CertificationJourneyTranscript.decodeJSON(journey.encodedJSON())
    #expect(decoded == journey)
    #expect(decoded.attemptCount == 2)
    #expect(decoded.remediationCount == 1)
    #expect(decoded.isCertified)
}

@Test func automaticRemediationProofRejectsManualLookingButUnverifiedGrade() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.digitalMachineControl, seed:10001)
    let failed = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:50, passed:false, verificationPerformed:false, feedback:[], skillScores:[.rungTopology:0])
    let plan = try #require(CertificationRemediationEngine.plan(after:failed, exam:exam))
    let module = try #require(plan.modules.first(where: { $0.skill == .rungTopology }))
    let lesson = try #require(StepByStepCatalog.lesson(module.lessonID))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    let r = wb.addRung()
    try wb.append(.instruction(.xic(tag:"Stop_OK")), toRung:r)
    try wb.append(.parallel([.instruction(.xic(tag:"Start_PB")), .instruction(.xic(tag:"Motor_Run"))]), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    let grade = ApprenticeshipGrader.grade(workbench:wb, lesson:lesson, verificationPerformed:false)
    let proof = AutomaticRemediationProofVerifier.evaluate(module:module, grade:grade)
    #expect(!proof.automaticallyVerified)
}

@Test func automaticRemediationProofCompletesModuleOnlyAfterObservedVerification() throws {
    let exam = try ChapterCertificationGenerator.generate(chapter:.digitalMachineControl, seed:10002)
    let failed = ChapterCertificationResult(chapter:exam.chapter, examID:exam.id, score:50, passed:false, verificationPerformed:false, feedback:[], skillScores:[.rungTopology:0])
    let plan = try #require(CertificationRemediationEngine.plan(after:failed, exam:exam))
    let module = try #require(plan.modules.first(where: { $0.skill == .rungTopology }))
    let lesson = try #require(StepByStepCatalog.lesson(module.lessonID))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    let r = wb.addRung()
    try wb.append(.instruction(.xic(tag:"Stop_OK")), toRung:r)
    try wb.append(.parallel([.instruction(.xic(tag:"Start_PB")), .instruction(.xic(tag:"Motor_Run"))]), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    let grade = ApprenticeshipGrader.grade(workbench:wb, lesson:lesson, verificationPerformed:true)
    let proof = AutomaticRemediationProofVerifier.evaluate(module:module, grade:grade)
    var progress = CertificationRemediationProgress(planID:plan.id)
    let accepted = progress.recordAutomaticallyVerified(proof, for:module)
    #expect(accepted)
    #expect(progress.isComplete(module.id))
}

@Test func spacedMasterySchedulesRemediatedWeaknessIntoLaterChapter() {
    var profile = SpacedMasteryProfile()
    profile.recordRemediationMastery(skills:[.rungTopology], chapter:.digitalMachineControl)
    #expect(profile.dueSkills(entering:.digitalMachineControl).isEmpty)
    #expect(profile.dueSkills(entering:.sequencing) == [.rungTopology])
    let checks = SpacedMasteryScheduler.checks(profile:profile, entering:.sequencing, seed:1234)
    #expect(checks.first?.skill == .rungTopology)
    #expect(checks.first?.exercise.lessonID == "digital-motor-seal")
}

@Test func successfulSpacedRetrievalPushesNextCheckFartherOut() throws {
    var profile = SpacedMasteryProfile()
    profile.recordRemediationMastery(skills:[.analogMath], chapter:.analogProcessControl)
    profile.recordRetention(skill:.analogMath, passed:true, chapter:.architectureNetworking)
    let record = try #require(profile.record(for:.analogMath))
    #expect(record.successfulRetrievals == 1)
    #expect(record.strength > 0.78)
    #expect(record.nextDueChapter == .commissioningCapstone)
}

@Test func failedSpacedRetrievalCreatesEarlyReturnAndStrengthLoss() throws {
    var profile = SpacedMasteryProfile()
    profile.recordRemediationMastery(skills:[.communications], chapter:.architectureNetworking)
    profile.recordRetention(skill:.communications, passed:false, chapter:.supervisoryData)
    let record = try #require(profile.record(for:.communications))
    #expect(record.lapses == 1)
    #expect(record.strength < 0.78)
    #expect(record.nextDueChapter == .commissioningCapstone)
}

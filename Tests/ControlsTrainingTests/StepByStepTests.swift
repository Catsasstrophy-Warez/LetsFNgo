import Testing
import ControlsPLC
import ControlsSimulation
@testable import ControlsTraining

@Test func stepByStepCatalogCoversDigitalAnalogCommunicationsAndHistorian() {
    #expect(StepByStepCatalog.all.count == 28)
    #expect(!StepByStepCatalog.lessons(in: .digitalIO).isEmpty)
    #expect(StepByStepCatalog.lessons(in: .analogIO).count >= 4)
    #expect(StepByStepCatalog.lessons(in: .communications).count >= 5)
    #expect(!StepByStepCatalog.lessons(in: .historian).isEmpty)
    #expect(Set(StepByStepCatalog.all.map(\.track)).count == StepByStepTrack.allCases.count)
}

@Test func everyStepByStepLessonHasActionableStepsAndObjectives() {
    for lesson in StepByStepCatalog.all {
        #expect(!lesson.objectives.isEmpty)
        #expect(!lesson.steps.isEmpty)
        if !["foundation-scan", "foundation-controller-organization"].contains(lesson.id) { #expect(!lesson.tagsToCreate.isEmpty) }
        #expect(lesson.steps.allSatisfy { !$0.checkpoint.isEmpty && !$0.whyItMatters.isEmpty })
    }
}

@Test func stepByStepLessonSessionRequiresEveryCheckpointForCompletion() throws {
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    var session = StepByStepLessonSession(lessonID: lesson.id)
    #expect(!session.isComplete(lesson))
    for step in lesson.steps { session.markCheckpoint(step.id) }
    #expect(!session.isComplete(lesson))
    session.recordPrediction("I predict the seal branch will hold the rung true after Start releases.")
    session.recordTransferResponse("I can build the same pattern for a fan.")
    #expect(session.isComplete(lesson))
}

@Test func cyclicIOTeachingLabSeparatesSourceChangeFromRPIVisibility() throws {
    let lesson = try #require(StepByStepCatalog.lesson("comm-io-rpi"))
    let outcome = StepByStepLabRunner.run(lesson)
    #expect(outcome.passed)
    #expect(outcome.observations.contains { $0.contains("19 ms") })
}

@Test func producedConsumedTeachingLabUpdatesAtConfiguredRPI() throws {
    let lesson = try #require(StepByStepCatalog.lesson("comm-produced-consumed"))
    #expect(StepByStepLabRunner.run(lesson).passed)
}

@Test func cipReadAndWriteLabsModelExplicitTransactionCompletion() throws {
    let read = try #require(StepByStepCatalog.lesson("comm-msg-read"))
    let write = try #require(StepByStepCatalog.lesson("comm-msg-write"))
    #expect(StepByStepLabRunner.run(read).passed)
    #expect(StepByStepLabRunner.run(write).passed)
}

@Test func historianLabStoresPointOnlyAtConfiguredScanBoundary() throws {
    let lesson = try #require(StepByStepCatalog.lesson("historian-points-scan"))
    let outcome = StepByStepLabRunner.run(lesson)
    #expect(outcome.passed)
    #expect(outcome.observations.contains { $0.contains("1 s") })
}

@Test func communicationRuntimeDoesNotCompleteMSGBeforeLatency() {
    var runtime = IndustrialCommunicationRuntime(configuration: .init(kind: .cipDataTableRead, messageLatencyMilliseconds: 40), localTags: ["Copy":0], remoteTags:["Remote":12])
    runtime.triggerMessage(sourceTag:"Remote", destinationTag:"Copy")
    runtime.step(milliseconds:39)
    #expect(runtime.message.waiting)
    #expect(runtime.localTags["Copy"] == 0)
    runtime.step(milliseconds:1)
    #expect(runtime.message.done)
    #expect(runtime.localTags["Copy"] == 12)
}

@Test func historianRuntimePreservesTimestampAndQuality() {
    var historian = HistorianLabRuntime(points:[.init(sourceTag:"PV", pointName:"Pressure.PV", scanPeriodMilliseconds:100)])
    historian.step(milliseconds:100, sourceValues:["PV":45.2], qualities:["PV":.stale])
    let sample = historian.latest(pointName:"Pressure.PV")
    #expect(sample?.timeMilliseconds == 100)
    #expect(sample?.quality == .stale)
    #expect(sample?.value == 45.2)
}

@Test func referenceLadderProjectsCompileIntoExecutableControllerProjects() throws {
    let ids = ["foundation-first-rung", "digital-motor-seal", "digital-interlocks", "sequence-timer-counter", "analog-input-scaling", "analog-alarms", "analog-level-hysteresis", "comm-hmi-scada"]
    for id in ids {
        let project = try #require(try StepByStepReferenceProjectFactory.project(for:id))
        #expect(!project.tasks.isEmpty)
        #expect(project.tasks.first?.programs.first?.routine(named:"MainRoutine") != nil)
    }
}

@Test func analogScalingReferenceProjectComputesEngineeringUnits() throws {
    let project = try #require(try StepByStepReferenceProjectFactory.project(for:"analog-input-scaling"))
    var runtime = ControllerRuntime(project: project)
    try runtime.setMode(.run)
    _ = try runtime.scan(elapsedMilliseconds:10)
    #expect(abs((try runtime.project.controllerTags.real("PressurePV")) - 37.5) < 0.0001)
}

@Test func integratedCapstoneMovesControllerVisibleDataIntoHistorian() throws {
    let lesson = try #require(StepByStepCatalog.lesson("capstone-networked-pump"))
    #expect(StepByStepLabRunner.run(lesson).passed)
}

@Test func referenceProjectsPassTheirStructuralStepByStepValidators() throws {
    let ids = ["foundation-first-rung", "digital-motor-seal", "digital-interlocks", "sequence-timer-counter", "analog-input-scaling", "analog-alarms", "analog-level-hysteresis", "comm-hmi-scada"]
    for id in ids {
        let lesson = try #require(StepByStepCatalog.lesson(id))
        let project = try #require(try StepByStepReferenceProjectFactory.project(for:id))
        let report = StepByStepProjectValidator.validate(project:project, lesson:lesson)
        #expect(report.passed, "Reference project should satisfy lesson validator for \(id): \(report.findings)")
    }
}

@Test func motorLessonValidatorRejectsSeriesStartAndSealInsteadOfParallelBranch() throws {
    let tags = try TagStore(tags:[
        .init(name:"Start_PB", value:.bool(false), role:.input),
        .init(name:"Stop_OK", value:.bool(true), role:.input),
        .init(name:"Motor_Run", value:.bool(false), role:.output)
    ])
    let badRung = Rung(number:0, logic:.series([.instruction(.xic(tag:"Stop_OK")), .instruction(.xic(tag:"Start_PB")), .instruction(.xic(tag:"Motor_Run")), .instruction(.ote(tag:"Motor_Run"))]))
    let program = ControllerProgram(name:"StepByStep", routines:[.init(name:"MainRoutine", rungs:[badRung])])
    let project = ControllerProject(name:"BadSeal", controllerTags:tags, tasks:[.init(name:"MainTask", programs:[program])])
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    let report = StepByStepProjectValidator.validate(project:project, lesson:lesson)
    #expect(!report.passed)
    #expect(report.findings.contains { $0.id == "seal" && $0.severity == .failure })
}

@Test func stepByStepProgressionGatesAdvancedCommunicationsAndCapstone() throws {
    var progress = StepByStepProgressProfile()
    let scan = try #require(StepByStepCatalog.lesson("foundation-scan"))
    let tags = try #require(StepByStepCatalog.lesson("foundation-tags"))
    let foundation = try #require(StepByStepCatalog.lesson("foundation-first-rung"))
    let motor = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    let msg = try #require(StepByStepCatalog.lesson("comm-msg-read"))
    let capstone = try #require(StepByStepCatalog.lesson("capstone-networked-pump"))
    #expect(progress.isUnlocked(scan))
    #expect(!progress.isUnlocked(foundation))
    #expect(!progress.isUnlocked(motor))
    #expect(!progress.isUnlocked(msg))
    #expect(!progress.isUnlocked(capstone))
    progress.markComplete(scan.id)
    #expect(progress.isUnlocked(tags))
    progress.markComplete(tags.id)
    #expect(progress.isUnlocked(foundation))
    progress.markComplete(foundation.id)
    #expect(!progress.isUnlocked(motor))
    for lesson in StepByStepCatalog.all where lesson.id != capstone.id { progress.markComplete(lesson.id) }
    #expect(progress.isUnlocked(capstone))
}

@Test func workbenchCompilesLearnerRungIntoExecutablePLCProject() throws {
    var wb = LadderConstructionWorkbench(projectName:"FirstLearnerRung")
    try wb.addTag(.init(name:"Start_PB", dataType:.bool, role:.input))
    try wb.addTag(.init(name:"Motor_Run", dataType:.bool, role:.output))
    let r = wb.addRung(comment:"First rung")
    try wb.append(.instruction(.xic(tag:"Start_PB")), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    #expect(wb.compile().succeeded)
    let result = try WorkbenchRunner.run(workbench:wb, inputValues:["Start_PB":.bool(true)])
    #expect(try result.runtime.project.controllerTags.bool("Motor_Run"))
}

@Test func workbenchRejectsMissingTagBeforeExecution() throws {
    var wb = LadderConstructionWorkbench()
    try wb.addTag(.init(name:"Start_PB", dataType:.bool, role:.input))
    let r = wb.addRung()
    try wb.append(.instruction(.xic(tag:"Start_PB")), toRung:r)
    try wb.append(.instruction(.ote(tag:"Forgotten_Output")), toRung:r)
    let report = wb.compile()
    #expect(!report.succeeded)
    #expect(report.issues.contains { $0.message.contains("Forgotten_Output") })
}

@Test func workbenchCanBuildParallelSealInAndPassLessonValidator() throws {
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    let r = wb.addRung(comment:"Learner seal in")
    try wb.append(.instruction(.xic(tag:"Stop_OK")), toRung:r)
    try wb.append(.parallel([.instruction(.xic(tag:"Start_PB")), .instruction(.xic(tag:"Motor_Run"))]), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    let validation = WorkbenchLessonFactory.validate(wb, lesson:lesson)
    #expect(validation.passed)
}

@Test func workbenchStructuralValidatorStillRejectsSeriesSealIn() throws {
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    let r = wb.addRung()
    try wb.append(.instruction(.xic(tag:"Stop_OK")), toRung:r)
    try wb.append(.instruction(.xic(tag:"Start_PB")), toRung:r)
    try wb.append(.instruction(.xic(tag:"Motor_Run")), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    #expect(!WorkbenchLessonFactory.validate(wb, lesson:lesson).passed)
}

@Test func workbenchAnalogScalingCanBeConstructedAndRun() throws {
    let lesson = try #require(StepByStepCatalog.lesson("analog-input-scaling"))
    let reference = try #require(try StepByStepReferenceProjectFactory.project(for:lesson.id))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    for rung in try #require(reference.tasks.first?.programs.first?.routine(named:"MainRoutine")).rungs {
        let index = wb.addRung(comment:rung.comment)
        let flattened: [Instruction] = {
            func f(_ n: LogicNode) -> [Instruction] { switch n { case let .instruction(i): [i]; case let .series(ns), let .parallel(ns): ns.flatMap(f) } }
            return f(rung.logic)
        }()
        for instruction in flattened { try wb.append(.instruction(instruction), toRung:index) }
    }
    let run = try WorkbenchRunner.run(workbench:wb)
    #expect(abs((try run.runtime.project.controllerTags.real("PressurePV")) - 37.5) < 0.0001)
    #expect(WorkbenchLessonFactory.validate(wb, lesson:lesson).passed)
}

@Test func onlineLabPendingTestAssembleLifecycleUsesRealWorkbench() throws {
    var wb = LadderConstructionWorkbench(projectName:"OnlineLab")
    try wb.addTag(.init(name:"Start_PB", dataType:.bool, role:.input))
    try wb.addTag(.init(name:"Motor_Run", dataType:.bool, role:.output))
    let r = wb.addRung(comment:"Initial")
    try wb.append(.instruction(.xic(tag:"Start_PB")), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    var lab = OnlineProgrammingLab(workbench:wb)
    try lab.beginEdit()
    try lab.mutatePending { try $0.updateRungComment(at:0, to:"Edited online") }
    let run = try lab.testEdits(inputValues:["Start_PB":.bool(true)])
    #expect(try run.runtime.project.controllerTags.bool("Motor_Run"))
    #expect(lab.state == .testing)
    #expect(lab.rungPower(rungNumber:0)?.outgoingCondition == true)
    try lab.assembleEdits()
    #expect(lab.state == .offline)
    #expect(lab.assembled.rungs[0].comment == "Edited online")
}

@Test func onlineLabBlocksOutputChangingEditWhileEquipmentRuns() throws {
    var wb = LadderConstructionWorkbench()
    try wb.addTag(.init(name:"A", dataType:.bool, role:.input))
    try wb.addTag(.init(name:"Out", dataType:.bool, role:.output))
    let r = wb.addRung(); try wb.append(.instruction(.xic(tag:"A")), toRung:r); try wb.append(.instruction(.ote(tag:"Out")), toRung:r)
    var lab = OnlineProgrammingLab(workbench:wb)
    lab.setControllerMode(.run); lab.setEquipmentOperating(true)
    try lab.beginEdit()
    try lab.mutatePending { try $0.replaceInstruction(inRung:0, elementIndex:0, with:.xio(tag:"A")) }
    let assessment = lab.assessPending()
    #expect(!assessment.canTest)
    #expect(assessment.findings.contains { $0.id == "output-risk" })
}

@Test func tagAutocompleteIncludesTimerAndCounterMembers() throws {
    var wb = LadderConstructionWorkbench()
    try wb.addTag(.init(name:"T_Fill", dataType:.timer))
    try wb.addTag(.init(name:"C_Box", dataType:.counter))
    let suggestions = WorkbenchTagAutocomplete.suggestions(for:"T_Fill.", in:wb).map(\.value)
    #expect(suggestions.contains("T_Fill.ACC"))
    #expect(suggestions.contains("T_Fill.DN"))
    #expect(WorkbenchTagAutocomplete.suggestions(for:"C_Box.D", in:wb).map(\.value).contains("C_Box.DN"))
}

@Test func workbenchCanReorderElementsAndEditOperands() throws {
    var wb = LadderConstructionWorkbench()
    try wb.addTag(.init(name:"A", dataType:.bool, role:.input)); try wb.addTag(.init(name:"B", dataType:.bool, role:.input)); try wb.addTag(.init(name:"Out", dataType:.bool, role:.output))
    let r = wb.addRung(); try wb.append(.instruction(.xic(tag:"A")), toRung:r); try wb.append(.instruction(.xic(tag:"B")), toRung:r); try wb.append(.instruction(.ote(tag:"Out")), toRung:r)
    try wb.moveElement(inRung:0, from:1, to:0)
    try wb.replaceInstruction(inRung:0, elementIndex:0, with:.xio(tag:"B"))
    #expect(wb.rungs[0].elements.first?.instructions.first == .xio(tag:"B"))
}


@Test func beginnerCurriculumIsOrderedAndPedagogicallyComplete() {
    let findings = StepByStepCurriculumAuditor.audit()
    #expect(findings.filter { $0.severity == .failure }.isEmpty, "Curriculum audit failures: \(findings)")
    #expect(StepByStepCatalog.all.first?.id == "foundation-scan")
    #expect(StepByStepCatalog.all.last?.id == "capstone-networked-pump")
}

@Test func controllerOrganizationLabSeparatesBeginnerStructuredAndRemoteConcepts() {
    let model = ControllerOrganizationLabModel.training
    #expect(model.visibleSummary(focus:.basics).contains { $0.contains("Task") })
    #expect(model.visibleSummary(focus:.structuredData).contains { $0.contains("UDT") })
    #expect(model.visibleSummary(focus:.remoteIO).contains { $0.contains("RPI") })
}

@Test func apprenticeshipGeneratorTargetsWeakestAvailableSkill() throws {
    var progress = StepByStepProgressProfile()
    for id in ["foundation-scan","foundation-tags","foundation-first-rung","foundation-controller-organization","digital-xic-xio","digital-command-feedback","digital-motor-seal"] { progress.markComplete(id) }
    let skills = ApprenticeshipSkillProfile(scores:[.rungTopology:0.1, .verification:0.9, .instructionChoice:0.8])
    let exercise = try #require(ApprenticeshipExerciseGenerator.next(for:progress, skills:skills, seed:7))
    #expect(exercise.targetSkills.contains(.rungTopology))
}

@Test func apprenticeshipPartialCreditExplainsBrokenSealTopology() throws {
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    let broken = try #require(try ApprenticeshipExerciseGenerator.brokenWorkbench(for:lesson.id))
    let grade = ApprenticeshipGrader.grade(workbench:broken, lesson:lesson, verificationPerformed:true)
    #expect(!grade.passed)
    #expect(grade.awardedPoints > 0)
    #expect(grade.components.contains { $0.id == "seal" && $0.awardedPoints == 0 })
    #expect(grade.components.contains { $0.id == "stop" && $0.awardedPoints > 0 })
}

@Test func apprenticeshipCorrectSealNeedsVerificationToPass() throws {
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    var wb = try WorkbenchLessonFactory.starter(for:lesson.id)
    let r = wb.addRung()
    try wb.append(.instruction(.xic(tag:"Stop_OK")), toRung:r)
    try wb.append(.parallel([.instruction(.xic(tag:"Start_PB")), .instruction(.xic(tag:"Motor_Run"))]), toRung:r)
    try wb.append(.instruction(.ote(tag:"Motor_Run")), toRung:r)
    #expect(!ApprenticeshipGrader.grade(workbench:wb, lesson:lesson, verificationPerformed:false).passed)
    #expect(ApprenticeshipGrader.grade(workbench:wb, lesson:lesson, verificationPerformed:true).passed)
}

@Test func apprenticeshipSkillProfileLearnsFromGrade() throws {
    let lesson = try #require(StepByStepCatalog.lesson("digital-motor-seal"))
    let broken = try #require(try ApprenticeshipExerciseGenerator.brokenWorkbench(for:lesson.id))
    let grade = ApprenticeshipGrader.grade(workbench:broken, lesson:lesson, verificationPerformed:true)
    var profile = ApprenticeshipSkillProfile(scores:[.rungTopology:0.5])
    profile.apply(grade)
    #expect(profile.score(for:.rungTopology) < 0.5)
}

@Test func expandedApprenticeshipChallengeBankCoversMultipleDomains() throws {
        #expect(ApprenticeshipChallengeCatalog.all.count >= 15)
        let lessonIDs = Set(ApprenticeshipChallengeCatalog.all.map(\.lessonID))
        #expect(lessonIDs.contains("digital-motor-seal"))
        #expect(lessonIDs.contains("analog-input-scaling"))
        #expect(lessonIDs.contains("comm-remote-io"))
        #expect(lessonIDs.contains("historian-points"))
        #expect(lessonIDs.contains("capstone-networked-pump"))
    }

@Test func brokenProgramLibraryIncludesAnalogAndInterlockMistakes() throws {
        let interlock = try ApprenticeshipExerciseGenerator.brokenWorkbench(for:"digital-interlocks")
        let scaling = try ApprenticeshipExerciseGenerator.brokenWorkbench(for:"analog-input-scaling")
        let alarm = try ApprenticeshipExerciseGenerator.brokenWorkbench(for:"analog-alarms")
        #expect(interlock != nil)
        #expect(scaling != nil)
        #expect(alarm != nil)
        if let lesson = StepByStepCatalog.lesson("analog-input-scaling"), let scaling {
            let report = WorkbenchLessonFactory.validate(scaling, lesson:lesson)
            #expect(report.passed == false)
            #expect(report.findings.contains(where:{ $0.id == "scale-sub" && $0.severity == .failure }))
        }
    }

@Test func fieldAssignmentsSpanAllHeroMachines() {
        #expect(ScenarioFieldAssignmentCatalog.all.count >= 9)
        let machines = Set(ScenarioFieldAssignmentCatalog.all.map(\.machineID))
        #expect(machines == Set(HeroMachineID.allCases))
    }

@Test func adaptiveGeneratorUsesExpandedChallengeBank() {
        var progress = StepByStepProgressProfile()
        for lesson in StepByStepCatalog.all { progress.markComplete(lesson.id) }
        let skills = ApprenticeshipSkillProfile(scores:[.analogMath:0.1, .verification:0.9])
        let exercise = ApprenticeshipExerciseGenerator.next(for:progress, skills:skills, seed:7)
        #expect(exercise != nil)
        #expect(exercise?.targetSkills.contains(.analogMath) == true)
        #expect(exercise?.id.hasPrefix("challenge-") == true)
    }


@Test func inheritedProjectCatalogProvidesFiveToFifteenRungPrioritizationAssignments() throws {
    #expect(InheritedProjectCatalog.all.count >= 5)
    for assignment in InheritedProjectCatalog.all {
        #expect((5...15).contains(assignment.rungCount))
        #expect(assignment.issues.contains(where:{ $0.role == .primaryRootCause }))
        #expect(assignment.issues.contains(where:{ $0.role == .harmlessCodeSmell }))
        #expect(assignment.issues.contains(where:{ $0.role == .staleOrMisleadingSymptom }))
        let maybeWB = try InheritedProjectCatalog.makeWorkbench(for: assignment.id)
        let wb = try #require(maybeWB)
        #expect(wb.rungs.count == assignment.rungCount)
        #expect(wb.compile().succeeded)
    }
}

@Test func inheritedProjectAssessmentRewardsRootCauseAndPenalizesShotgunRepairs() throws {
    let assignment = try #require(InheritedProjectCatalog.assignment("packaging-shift-handoff"))
    let root = try #require(assignment.primaryIssue)
    let disciplined = InheritedProjectCatalog.assess(assignment: assignment, identified:[root.id], repaired:[root.id,"secondary-reset"], verificationPerformed:true)
    let shotgun = InheritedProjectCatalog.assess(assignment: assignment, identified:[root.id], repaired:Set(assignment.issues.map(\.id)), verificationPerformed:true)
    #expect(disciplined.score > shotgun.score)
    #expect(shotgun.feedback.contains(where:{ $0.localizedCaseInsensitiveContains("unnecessary") }))
}

@Test func sevenNewHeroMachinesHaveRunnableFaultPhysics() throws {
    let newIDs: [HeroMachineID] = [.roboticPalletizer,.wastewaterLiftStation,.refrigerationRack,.boilerSteamPlant,.cncCoolantCell,.cleanroomPressureSystem,.asrsCrane]
    for id in newIDs {
        let machine = try #require(HeroMachineCatalog.machine(id))
        let fault = try #require(machine.faults.first)
        var session = try #require(HeroMachineCatalog.start(machine:id, faultID:fault.id, mode:.technician))
        session.advance(days: fault.progression.last?.day ?? 90)
        let maybeEngine = try PlayableScenarioEngine(session:session)
        var engine = try #require(maybeEngine)
        try engine.startMachine()
        try engine.run(seconds:3)
        #expect(!engine.runtime.snapshot.analog.isEmpty)
        #expect(engine.runtime.fault.severity > 0.8)
    }
}


@Test func seededInheritedGeneratorIsDeterministicAndUsesTenToTwentyFiveRungs() throws {
    let a = SeededInheritedProjectGenerator.generate(seed: 424242)
    let b = SeededInheritedProjectGenerator.generate(seed: 424242)
    #expect(a.machineID == b.machineID)
    #expect(a.assignment.id == b.assignment.id)
    #expect(a.assignment.rungCount == b.assignment.rungCount)
    #expect(a.assignment.issues == b.assignment.issues)
    #expect((10...25).contains(a.assignment.rungCount))
    let wb = try InheritedProjectCatalog.makeWorkbench(for:a.assignment)
    #expect(wb.rungs.count == a.assignment.rungCount)
}

@Test func seededInheritedGeneratorSpansMultipleMachinesAndAlwaysContainsAdversarialEvidence() {
    let generated = (1...40).map { SeededInheritedProjectGenerator.generate(seed:UInt64($0)) }
    #expect(Set(generated.map(\.machineID)).count >= 10)
    for item in generated {
        #expect(item.assignment.primaryIssue != nil)
        #expect(item.assignment.issues.contains { $0.role == .harmlessCodeSmell })
        #expect(item.assignment.issues.contains { $0.role == .staleOrMisleadingSymptom })
    }
}

@Test func generatedInheritedProjectRewardsDisciplinedRepairOverShotgunEditing() {
    let generated = SeededInheritedProjectGenerator.generate(seed:99,machineID:.compressedAirPlant)
    let assignment = generated.assignment
    let root = assignment.primaryIssue!
    let disciplined = InheritedProjectCatalog.assess(assignment:assignment,identified:[root.id],repaired:Set(assignment.issues.filter(\.shouldRepair).map(\.id)),verificationPerformed:true)
    let shotgun = InheritedProjectCatalog.assess(assignment:assignment,identified:[root.id],repaired:Set(assignment.issues.map(\.id)),verificationPerformed:true)
    #expect(disciplined.score > shotgun.score)
}

@Test func stepByStepLessonsAreSeparatedIntoSevenOrderedChapters() {
    #expect(StepByStepChapter.allCases.count == 7)
    let flattened = StepByStepChapter.allCases.flatMap { StepByStepCatalog.lessons(in:$0) }
    #expect(flattened.map(\.id) == StepByStepCatalog.all.map(\.id))
    #expect(StepByStepCatalog.chapter(for:"foundation-scan") == .foundations)
    #expect(StepByStepCatalog.chapter(for:"analog-input-scaling") == .analogProcessControl)
    #expect(StepByStepCatalog.chapter(for:"comm-msg-write") == .architectureNetworking)
    #expect(StepByStepCatalog.chapter(for:"capstone-networked-pump") == .commissioningCapstone)
    #expect(!StepByStepCatalog.lessons(at:.beginner).isEmpty)
    #expect(!StepByStepCatalog.lessons(at:.intermediate).isEmpty)
    #expect(!StepByStepCatalog.lessons(at:.advanced).isEmpty)
}

@Test func generatedWholeControllerArchitectureIsDeterministicAndCrossBoundary() throws {
    let a = try GeneratedControllerArchitectureGenerator.generate(seed:777)
    let b = try GeneratedControllerArchitectureGenerator.generate(seed:777)
    #expect(a.title == b.title)
    #expect(a.primaryIssue?.boundary == b.primaryIssue?.boundary)
    #expect(a.taskCount >= 2)
    #expect(a.programCount >= 2)
    #expect(a.routineCount >= 4)
    #expect(!a.remoteModules.isEmpty)
    #expect(!a.messages.isEmpty)
    #expect(!a.hmiMappings.isEmpty)
    #expect(!a.historianPoints.isEmpty)
    #expect(Set(a.issues.map(\.role)) == Set(GeneratedArchitectureIssueRole.allCases))
}

@Test func generatedWholeControllerProjectExecutesThroughControllerRuntime() throws {
    let generated = try GeneratedControllerArchitectureGenerator.generate(seed:991)
    var runtime = ControllerRuntime(project: generated.controllerProject)
    try runtime.setMode(.run)
    let result = try runtime.scan(elapsedMilliseconds:10)
    #expect(!result.programs.isEmpty)
    #expect(result.programs.contains { !$0.routineTraces.isEmpty })
}

@Test func generatedArchitectureRewardsCrossBoundaryDiscipline() throws {
    let generated = try GeneratedControllerArchitectureGenerator.generate(seed:1234)
    let root = try #require(generated.primaryIssue)
    let required = Set(generated.issues.filter(\.shouldRepair).map(\.id))
    let disciplined = GeneratedControllerArchitectureAssessor.assess(generated, identifiedIssueIDs:[root.id], repairedIssueIDs:required, verificationPerformed:true)
    let shotgun = GeneratedControllerArchitectureAssessor.assess(generated, identifiedIssueIDs:[root.id], repairedIssueIDs:Set(generated.issues.map(\.id)), verificationPerformed:true)
    #expect(disciplined.score > shotgun.score)
}

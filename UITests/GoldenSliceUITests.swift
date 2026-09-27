import XCTest

/// Drives the Golden Slice field workflow on iPhone: find the equipment,
/// open the investigation, see the ranked next test and the hypotheses.
///
/// Rows combine their children into one accessibility element (so VoiceOver
/// reads them as one line), so lookups match on "label contains", the same
/// text a VoiceOver user hears. Each step fails with what it was looking for
/// and what was on screen instead.
final class GoldenSliceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTechnicianCanReachTheInvestigationAndItsNextTest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        try tap(app.buttons["more"].firstMatch, "the More button in the bottom bar", in: app)
        try tap(app.buttons["screen.investigation"].firstMatch, "Investigation in the More menu", in: app)
        try expect("LT-101 reads 86.9 % while T-1 overflows", in: app)
        try expect("Read channel span from controller", in: app)
        try expect("Excess loop resistance starves the transmitter", in: app)

        try tap(app.buttons["more"].firstMatch, "the More button in the bottom bar", in: app)
        try tap(app.buttons["screen.search"].firstMatch, "Search in the More menu", in: app)
        let field = app.searchFields.firstMatch
        try tap(field, "the search field", in: app)
        field.typeText("LT-101 transmitter")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "LT-101 level transmitter")).firstMatch
        try tap(result, "the LT-101 search result", in: app)
        try expect("LT-101 level transmitter", in: app)
    }

    /// The field workflow on iPhone: take the ranked next tests, record the
    /// readings, confirm the cause, create the repair task and close the case.
    @MainActor
    func testTechnicianDiagnosesAndClosesTheLoopFault() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        try tap(app.buttons["more"].firstMatch, "the More button in the bottom bar", in: app)
        try tap(app.buttons["screen.investigation"].firstMatch, "Investigation in the More menu", in: app)

        // Best test first: the channel span reads 100 %, as three hypotheses predict.
        try record(value: "100", unit: "%", in: app)
        try expect("configuredSpan = 100", in: app)
        // Next: terminal voltage under load. 11.4 V leaves only excess loop resistance.
        try record(value: "11.4", unit: "V", in: app)
        try expect("terminalVoltage = 11.4", in: app)

        try tap(app.buttons["Confirm as cause"].firstMatch, "the Confirm button on the remaining hypothesis", in: app)
        try expect("Cause: Excess loop resistance", in: app)

        try tap(app.buttons["Create repair task"].firstMatch, "Create repair task", in: app)
        try fill("field.steps", with: "Clean and re-terminate TB-4", in: app)
        try tap(app.buttons["command.run"].firstMatch, "Run", in: app)

        try tap(app.buttons["more"].firstMatch, "the More button in the bottom bar", in: app)
        try tap(app.buttons["screen.investigation"].firstMatch, "Investigation in the More menu", in: app)
        try tap(app.buttons["Close investigation"].firstMatch, "Close investigation", in: app)
        try fill("field.resolution", with: "Corroded terminal cleaned; loop reads true", in: app)
        try tap(app.buttons["command.run"].firstMatch, "Run", in: app)
        try expect("Closed", in: app)
    }

    @MainActor
    private func record(value: String, unit: String, in app: XCUIApplication) throws {
        print("Recording \(value) \(unit)")
        try tap(app.buttons["investigation.record"].firstMatch, "Record measurement", in: app)
        try fill("field.value", with: value, in: app)
        try fill("field.unit", with: unit, in: app)
        try tap(app.buttons["command.run"].firstMatch, "Run", in: app)
    }

    @MainActor
    private func fill(_ identifier: String, with text: String, in app: XCUIApplication) throws {
        let field = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        try tap(field, "the \(identifier) field", in: app)
        field.typeText(text)
    }

    @MainActor
    private func tap(_ element: XCUIElement, _ what: String, in app: XCUIApplication) throws {
        // Forms render lazily and may place the control off screen, above
        // or below: look further down first, then back up.
        var swipes = 0
        while !(element.waitForExistence(timeout: swipes == 0 ? 10 : 2) && element.isHittable), swipes < 10 {
            if swipes < 3 { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
        }
        guard element.exists else {
            throw failure("Couldn't find \(what)", in: app)
        }
        element.tap()
    }

    @MainActor
    private func expect(_ text: String, in app: XCUIApplication) throws {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        // Lists render lazily, so text further down only exists once scrolled to.
        var swipes = 0
        while !element.waitForExistence(timeout: swipes == 0 ? 15 : 2), swipes < 10 {
            if swipes < 3 { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
        }
        guard element.exists else {
            throw failure("Couldn't find text containing “\(text)”", in: app)
        }
    }

    /// A failure that lists what was visible, since CI only shows the message.
    @MainActor
    private func failure(_ message: String, in app: XCUIApplication) -> Error {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(40).map(\.label).filter { !$0.isEmpty }
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(80).map(\.label).filter { !$0.isEmpty }
        let banners = ["command.error", "command.confirmation"].compactMap { id -> String? in
            let banner = app.descendants(matching: .any).matching(identifier: id).firstMatch
            return banner.exists ? "\(id): \(banner.label)" : nil
        }
        let detail = "\(message). Banners: \(banners). Buttons: \(buttons). Texts: \(texts)."
        XCTFail(detail)
        return NSError(domain: "GoldenSliceUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

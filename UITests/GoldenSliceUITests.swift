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

    @MainActor
    private func tap(_ element: XCUIElement, _ what: String, in app: XCUIApplication) throws {
        guard element.waitForExistence(timeout: 15) else {
            throw failure("Couldn't find \(what)", in: app)
        }
        element.tap()
    }

    @MainActor
    private func expect(_ text: String, in app: XCUIApplication) throws {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        guard element.waitForExistence(timeout: 15) else {
            throw failure("Couldn't find text containing “\(text)”", in: app)
        }
    }

    /// A failure that lists what was visible, since CI only shows the message.
    @MainActor
    private func failure(_ message: String, in app: XCUIApplication) -> Error {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(30).map(\.label).filter { !$0.isEmpty }
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label).filter { !$0.isEmpty }
        let detail = "\(message). Buttons: \(buttons). Texts: \(texts)."
        XCTFail(detail)
        return NSError(domain: "GoldenSliceUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

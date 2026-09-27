import XCTest

/// Drives the Golden Slice field workflow on iPhone: find the equipment,
/// open the investigation, see the ranked next test and the hypotheses.
///
/// Rows combine their children into one accessibility element (so VoiceOver
/// reads them as one line), so lookups match on "label contains", the same
/// text a VoiceOver user hears.
final class GoldenSliceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTechnicianCanReachTheInvestigationAndItsNextTest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        app.buttons["More"].firstMatch.tap()
        app.buttons["Investigation"].firstMatch.tap()
        XCTAssertTrue(element(containing: "LT-101 reads 86.9 % while T-1 overflows", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element(containing: "Read channel span from controller", in: app).exists)
        XCTAssertTrue(element(containing: "Excess loop resistance starves the transmitter", in: app).exists)

        app.buttons["More"].firstMatch.tap()
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("LT-101 transmitter")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "LT-101 level transmitter")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(element(containing: "LT-101 level transmitter", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Observed", in: app).exists || element(containing: "Recorded", in: app).exists)
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}

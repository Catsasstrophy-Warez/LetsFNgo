import XCTest

/// Drives the Golden Slice field workflow on iPhone: find the equipment,
/// open the investigation, see the ranked next test and the hypotheses.
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
        XCTAssertTrue(app.staticTexts["LT-101 reads 86.9 % while T-1 overflows"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Read channel span from controller"].exists)
        XCTAssertTrue(app.staticTexts["Excess loop resistance starves the transmitter of compliance voltage"].exists)

        app.buttons["More"].firstMatch.tap()
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("LT-101 transmitter")
        app.buttons["LT-101 level transmitter"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["LT-101 level transmitter"].waitForExistence(timeout: 5))
    }
}

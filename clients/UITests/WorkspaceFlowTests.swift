// SPDX-License-Identifier: GPL-3.0-only
import XCTest

final class WorkspaceFlowTests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testNativeConnectionTextEventSourceAndQuestion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["XINLIKA_TEST_NAMESPACE"] = UUID().uuidString
        app.launch()
        let settings = app.buttons["connectionSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("http://127.0.0.1:28788")
        let token = app.secureTextFields["deviceToken"]
        token.tap(); token.typeText("native-test-local-only")
        app.buttons["saveConnection"].tap()
        XCTAssertTrue(app.staticTexts["已同步"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let addRecord = app.buttons["addTextRecord"]
        XCTAssertTrue(addRecord.waitForExistence(timeout: 5)); addRecord.tap()
        let editor = app.textViews["recordText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("Camera prototype delivery is Wednesday.")
        app.buttons["submitTextRecord"].tap()
        let event = app.staticTexts["相机计划讨论"].firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 30))
        capture("01 Synthetic native event", app: app)
        event.tap()
        XCTAssertTrue(app.staticTexts["Camera prototype delivery is Wednesday."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["纠正内容或来源"].firstMatch.exists)
        capture("02 Synthetic native literal source", app: app)
        app.buttons["纠正内容或来源"].firstMatch.tap()
        let correction = app.textViews["correctionText"]
        XCTAssertTrue(correction.waitForExistence(timeout: 5)); correction.tap()
        correction.typeText("\nCorrection: delivery is Thursday.")
        app.buttons["saveCorrection"].tap()
        let dismissed = NSPredicate(format: "exists == false")
        expectation(for: dismissed, evaluatedWith: app.buttons["saveCorrection"])
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Agent"].tap()
        let question = app.descendants(matching: .any)["agentQuestion"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5)); question.tap(); question.typeText("When is the camera prototype delivery?")
        app.buttons["sendQuestion"].tap()
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Thursday")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30))
        capture("03 Synthetic native corrected answer", app: app)
    }
}

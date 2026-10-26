import XCTest

final class DeviceSyncUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ scenario: String = "ready", suite: String, accessible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["SHENNAO_SYNC_FIXTURE": "1", "SHENNAO_SYNC_SUITE": suite, "SHENNAO_SYNC_SCENARIO": scenario]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-reading.appearance", accessible ? "dark" : "system"]
        if accessible { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["记录"].waitForExistence(timeout: 10))
        return app
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func expectCalls(_ count: Int, _ app: XCUIApplication) {
        let calls = element("sync-simulation-calls", app)
        XCTAssertTrue(calls.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "模拟设备调用：\(count)"), object: calls)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let target = element(id, app)
        for _ in 0..<8 {
            if target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, id); target.tap()
    }
    private func details(_ app: XCUIApplication) {
        app.tabBars.buttons["设备"].tap()
        tap("device-details", app)
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testOpenAppChecksAutomaticallyAndNavigationDoesNotDuplicateWork() {
        let app = launch(suite: UUID().uuidString)
        expectCalls(1, app)
        details(app)
        XCTAssertTrue(element("automatic-sync-last-check", app).waitForExistence(timeout: 5))
        app.tabBars.buttons["记录"].tap()
        XCTAssertFalse(element("automatic-sync-summary", app).exists)
        XCTAssertFalse(app.staticTexts["云端状态已更新"].exists)
        capture("015-results-first", app)
        XCUIDevice.shared.press(.home); app.activate()
        expectCalls(1, app)
        tap("result-ui-fixture", app)
        XCTAssertTrue(app.navigationBars["录音详情"].waitForExistence(timeout: 5))
    }

    func testPauseCancelsActiveWorkAndSurvivesRelaunchUntilExplicitResume() {
        let suite = UUID().uuidString
        var app = launch("working", suite: suite)
        expectCalls(1, app)
        tap("pause-automatic-sync", app)
        let resume = element("resume-automatic-sync", app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: resume)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.terminate(); app = launch(suite: suite)
        expectCalls(0, app)
        tap("resume-automatic-sync", app)
        expectCalls(1, app)
        details(app)
        XCTAssertTrue(element("automatic-sync-last-check", app).waitForExistence(timeout: 5))
    }

    func testFirstSetupRemembersDeviceAndNextLaunchNeedsNoDevicePage() {
        let suite = UUID().uuidString
        var app = launch("unbound", suite: suite)
        app.tabBars.buttons["设备"].tap()
        expectCalls(0, app)
        tap("remember-and-sync", app)
        expectCalls(1, app)
        tap("device-details", app)
        XCTAssertTrue(element("automatic-sync-last-check", app).waitForExistence(timeout: 5))
        app.terminate(); app = launch("unbound", suite: suite)
        expectCalls(1, app)
        XCTAssertTrue(app.tabBars.buttons["记录"].isSelected)
        XCTAssertTrue(element("result-ui-fixture", app).exists)
    }

    func testOneOffCheckDoesNotSilentlyReenablePausedTransfers() {
        let suite = UUID().uuidString
        var app = launch("paused", suite: suite)
        expectCalls(0, app)
        app.tabBars.buttons["设备"].tap()
        tap("manual-device-sync", app)
        tap("device-details", app)
        XCTAssertTrue(element("automatic-sync-last-check", app).waitForExistence(timeout: 5))
        app.tabBars.buttons["记录"].tap()
        expectCalls(1, app)
        XCTAssertTrue(element("resume-automatic-sync", app).exists)
        app.terminate(); app = launch(suite: suite)
        expectCalls(0, app)
        XCTAssertTrue(element("resume-automatic-sync", app).exists)
    }

    func testUnavailableDeviceKeepsResultsUsableAndDoesNotReportSuccess() {
        let app = launch("unavailable", suite: UUID().uuidString)
        details(app)
        let status = element("automatic-sync-status", app)
        let failure = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "没找到录音笔"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failure], timeout: 5), .completed)
        XCTAssertFalse(element("automatic-sync-last-check", app).exists)
        app.tabBars.buttons["记录"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        expectCalls(1, app)
        tap("result-ui-fixture", app)
        XCTAssertTrue(app.navigationBars["录音详情"].waitForExistence(timeout: 5))
    }

    func testSigningOutHidesRememberedDeviceAndStopsAutomaticTriggers() {
        let app = launch(suite: UUID().uuidString)
        details(app)
        XCTAssertTrue(element("automatic-sync-last-check", app).waitForExistence(timeout: 5))
        app.tabBars.buttons["设置"].tap()
        app.buttons["退出登录"].tap()
        let confirm = app.sheets.buttons["退出登录"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.staticTexts["登录后查看记录"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(app.buttons["先登录深脑账号"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("pause-automatic-sync", app).exists)
    }

    func testLargestTextAndDarkModeKeepPauseActionReachable() {
        let app = launch("working", suite: UUID().uuidString, accessible: true)
        expectCalls(1, app)
        tap("pause-automatic-sync", app)
        XCTAssertTrue(element("resume-automatic-sync", app).waitForExistence(timeout: 5))
        capture("015-accessibility-dark-paused", app)
    }
}

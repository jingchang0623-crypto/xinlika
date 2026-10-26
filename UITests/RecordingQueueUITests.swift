import XCTest

final class RecordingQueueUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ suite: String, accessible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["SHENNAO_SYNC_FIXTURE": "1", "SHENNAO_SYNC_SUITE": suite, "SHENNAO_SYNC_SCENARIO": "review"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-reading.appearance", accessible ? "dark" : "system"]
        if accessible { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["记录"].waitForExistence(timeout: 10))
        return app
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let target = element(id, app)
        if !target.exists { XCTAssertTrue(target.waitForExistence(timeout: 5), id) }
        for _ in 0..<8 {
            if target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, id); target.tap()
    }
    private func expectTransfers(_ count: Int, _ app: XCUIApplication) {
        let badge = element("sync-simulation-calls", app)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "下载：\(count) 上传：\(count)"), object: badge)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed, "Actual transfers: \(badge.value ?? "missing")")
    }
    private func queue(_ app: XCUIApplication) {
        tap("open-pending-recordings", app)
        XCTAssertTrue(app.navigationBars["录音管理"].waitForExistence(timeout: 5))
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testThreeHourBatchIsHeldThenBulkIgnoredAcrossRelaunch() {
        let suite = UUID().uuidString
        var app = launch(suite)
        XCTAssertTrue(element("open-pending-recordings", app).waitForExistence(timeout: 6))
        expectTransfers(0, app)
        capture("015-results-with-pending", app)
        queue(app)
        XCTAssertFalse(element("approve-recordings", app).isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "3 小时")).firstMatch.exists)
        capture("015-review-three-hour-batch", app)
        tap("select-all-recordings", app); tap("ignore-recordings", app)
        XCTAssertTrue(app.staticTexts["没有待确认录音"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["已忽略"].tap()
        XCTAssertTrue(element("queue-item-note20260907-100000", app).exists)
        capture("015-ignored-recordings", app)
        app.buttons["完成"].tap()
        expectTransfers(0, app)
        app.terminate(); app = launch(suite)
        app.tabBars.buttons["设备"].tap(); tap("device-details", app)
        XCTAssertTrue(element("automatic-sync-last-check", app).waitForExistence(timeout: 5))
        tap("open-recording-queue", app)
        XCTAssertTrue(app.staticTexts["没有待确认录音"].exists)
        app.segmentedControls.buttons["已忽略"].tap()
        XCTAssertTrue(element("queue-item-note20260907-100000", app).exists)
        app.buttons["完成"].tap(); expectTransfers(0, app)
    }

    func testRestoreRequiresReviewAndCancelledApprovalDoesNotTransfer() {
        let app = launch(UUID().uuidString)
        queue(app)
        tap("select-all-recordings", app); tap("ignore-recordings", app)
        app.segmentedControls.buttons["已忽略"].tap()
        tap("queue-item-note20260907-100000", app)
        tap("restore-recordings", app)
        app.segmentedControls.buttons["待确认"].tap()
        tap("select-all-recordings", app)
        tap("approve-recordings", app)
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "分析额度")).firstMatch.waitForExistence(timeout: 5))
        capture("015-confirm-analysis-quota", app)
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(element("queue-item-note20260907-100000", app).exists)
        app.buttons["完成"].tap(); expectTransfers(0, app)
    }

    func testApprovalWhilePausedWaitsUntilExplicitResume() {
        let app = launch(UUID().uuidString)
        XCTAssertTrue(element("open-pending-recordings", app).waitForExistence(timeout: 6))
        app.tabBars.buttons["设备"].tap(); tap("pause-automatic-sync", app)
        app.tabBars.buttons["记录"].tap(); queue(app)
        tap("queue-item-note20260907-100000", app)
        tap("approve-recordings", app)
        app.alerts.buttons["确认导入并分析"].tap()
        app.buttons["完成"].tap()
        expectTransfers(0, app)
        tap("resume-automatic-sync", app)
        expectTransfers(1, app)
        XCTAssertTrue(element("open-pending-recordings", app).exists)
    }

    func testLargeTextAndDarkModeKeepBulkActionsReachable() {
        let app = launch(UUID().uuidString, accessible: true)
        queue(app)
        tap("select-all-recordings", app)
        XCTAssertTrue(element("ignore-recordings", app).isHittable)
        XCTAssertTrue(element("approve-recordings", app).isHittable)
        capture("015-accessibility-dark-review", app)
        tap("approve-recordings", app)
        XCTAssertTrue(app.alerts.buttons["取消"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.buttons["确认导入并分析"].isHittable)
        capture("015-accessibility-dark-confirm", app)
        app.alerts.buttons["取消"].tap()
        tap("ignore-recordings", app)
        XCTAssertTrue(app.staticTexts["没有待确认录音"].waitForExistence(timeout: 5))
    }
}

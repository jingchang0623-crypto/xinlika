import XCTest

final class RecorderControlUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ recording: String = "idle", sync: String = "paused", accessible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["SHENNAO_SYNC_FIXTURE": "1", "SHENNAO_SYNC_SUITE": UUID().uuidString,
                                 "SHENNAO_SYNC_SCENARIO": sync, "SHENNAO_RECORDING_SCENARIO": recording]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-reading.appearance", accessible ? "dark" : "system"]
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
        XCTAssertTrue(target.waitForExistence(timeout: 12), id)
        for _ in 0..<6 {
            if target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, id)
        target.tap()
    }
    private func state(_ expected: String, _ app: XCUIApplication) {
        let state = element("recorder-state", app)
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: state)], timeout: 12), .completed)
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func commands(_ count: Int, _ app: XCUIApplication) {
        let badge = element("sync-simulation-calls", app)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue((badge.value as? String)?.contains("录音指令：\(count)") == true, badge.debugDescription)
    }

    func testStartAndSaveWhileSyncPausedPreservesPauseAndDoesNotUpload() {
        let app = launch()
        tap("open-recorder-controls", app)
        state("未录音", app)
        tap("recorder-start", app)
        state("录音中", app)
        capture("016-recording-sheet", app)
        tap("recorder-save", app)
        state("未录音", app)
        app.buttons["完成"].tap()
        XCTAssertTrue(element("resume-automatic-sync", app).exists)
        commands(2, app)
        XCTAssertTrue((element("sync-simulation-calls", app).value as? String)?.contains("下载：0 上传：0") == true)
    }
    func testStartPreemptsActiveDownloadWithoutChangingSyncPreference() {
        let app = launch(sync: "working")
        tap("open-recorder-controls", app)
        state("未录音", app)
        tap("recorder-start", app)
        state("录音中", app)
        app.buttons["完成"].tap()
        commands(1, app)
        XCTAssertTrue(element("recorder-banner", app).exists)
        XCTAssertFalse(element("resume-automatic-sync", app).exists)
        XCTAssertEqual(element("sync-simulation-calls", app).label, "模拟设备调用：1")
        capture("016-recording-results", app)
    }
    func testPhysicalRecordingAppearsWithoutOpeningDevicePageOrSendingCommand() {
        let app = launch("physical-start")
        XCTAssertTrue(element("recorder-banner", app).waitForExistence(timeout: 14))
        commands(0, app)
        tap("recorder-banner", app)
        state("录音中", app)
        XCTAssertTrue(element("recorder-duration", app).label.contains("3:00:00"))
        app.buttons["完成"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element("recorder-banner", app).waitForExistence(timeout: 10))
        commands(0, app)
    }
    func testPausedHardwareCanSaveAtAccessibilityTextSize() {
        let app = launch("paused", accessible: true)
        app.tabBars.buttons["设备"].tap()
        state("录音已暂停", app)
        capture("016-paused-device-ax-dark", app)
        XCTAssertFalse(element("recorder-resume", app).exists)
        tap("recorder-save", app)
        state("未录音", app)
        commands(1, app)
    }
    func testUnknownStatusOnlyOffersRefreshAndNeverSendsStart() {
        let app = launch("unknown")
        tap("open-recorder-controls", app)
        state("状态待确认", app)
        XCTAssertFalse(element("recorder-start", app).exists)
        tap("recorder-refresh", app)
        XCTAssertTrue(element("recorder-message", app).waitForExistence(timeout: 10))
        state("状态待确认", app)
        capture("016-unknown-state", app)
        app.buttons["完成"].tap()
        commands(0, app)
    }
    func testFailedReadbackDoesNotShowRecordingOrAutomaticallyRetry() {
        let app = launch("readback-unknown")
        tap("open-recorder-controls", app)
        state("未录音", app)
        tap("recorder-start", app)
        XCTAssertTrue(element("recorder-message", app).waitForExistence(timeout: 10))
        state("状态待确认", app)
        XCTAssertFalse(element("recorder-save", app).exists)
        app.buttons["完成"].tap()
        commands(1, app)
        XCUIDevice.shared.press(.home); app.activate()
        commands(1, app)
    }
    func testDeviceRejectsStartAndActualIdleStateIsPreserved() {
        let app = launch("rejected")
        tap("open-recorder-controls", app)
        state("未录音", app)
        tap("recorder-start", app)
        XCTAssertTrue(element("recorder-message", app).waitForExistence(timeout: 10))
        state("未录音", app)
        XCTAssertFalse(element("recorder-save", app).exists)
        app.buttons["完成"].tap()
        commands(1, app)
    }
    func testPhysicalStartDuringDownloadStopsTransferWithoutSendingRecordingCommands() {
        let app = launch("physical-start", sync: "working")
        XCTAssertTrue(element("recorder-banner", app).waitForExistence(timeout: 15))
        tap("recorder-banner", app)
        state("录音中", app)
        app.buttons["完成"].tap()
        commands(0, app)
        XCTAssertEqual(element("sync-simulation-calls", app).label, "模拟设备调用：1")
        XCTAssertFalse(element("resume-automatic-sync", app).exists)
    }
    func testDisconnectedRecorderCannotStartAndReportsRefreshFailure() {
        let app = launch("disconnected")
        tap("open-recorder-controls", app)
        state("状态待确认", app)
        tap("recorder-refresh", app)
        XCTAssertTrue(element("recorder-message", app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("recorder-start", app).exists)
        app.buttons["完成"].tap()
        commands(0, app)
    }

    func testSavedShortRecordingHasDirectReviewEntryWhileSyncIsPaused() {
        let app = launch()
        tap("open-recorder-controls", app)
        state("未录音", app)
        tap("recorder-start", app)
        state("录音中", app)
        tap("recorder-save", app)
        state("未录音", app)
        tap("recorder-show-saved", app)
        XCTAssertTrue(element("queue-item-note20260907-131301", app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "22 秒")).firstMatch.exists)
        capture("019-saved-short-review", app)
        app.navigationBars["录音管理"].buttons["完成"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(element("resume-automatic-sync", app).exists)
        commands(2, app)
        XCTAssertTrue((element("sync-simulation-calls", app).value as? String)?.contains("下载：0 上传：0") == true)
    }

    func testOpeningQueueDiscoversExistingShortFileWithoutTransfer() {
        let app = launch("catalog-short")
        app.tabBars.buttons["设备"].tap()
        tap("open-recording-queue", app)
        XCTAssertTrue(element("queue-item-note20260907-131301", app).waitForExistence(timeout: 10))
        app.navigationBars["录音管理"].buttons["完成"].tap()
        commands(0, app)
        XCTAssertTrue((element("sync-simulation-calls", app).value as? String)?.contains("下载：0 上传：0") == true)
        XCTAssertTrue(element("resume-automatic-sync", app).exists)
    }

    func testReadOnlyStatusRefreshDoesNotCancelActiveDeviceTask() {
        let app = launch("unknown", sync: "working")
        tap("open-recorder-controls", app)
        state("状态待确认", app)
        tap("recorder-refresh", app)
        app.buttons["完成"].tap()
        XCTAssertTrue((element("sync-simulation-calls", app).value as? String)?.contains("设备任务：运行") == true)
        commands(0, app)
    }
}

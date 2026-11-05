import XCTest

final class InterestFeedbackUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(large: Bool = false, resetHint: Bool = false) throws -> XCUIApplication {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let date = day.string(from: .now)
        let titles = ["锁屏录音稳定性", "奶茶口味闲聊"] + (3...12).map { "示例事项\($0)" }
        let events: [[String:Any]] = titles.enumerated().map { index,title in
            ["id":"event-\(index)","session_id":"session", "kind":"ambient", "title":title,
             "summary":"用于验证关注反馈的隔离示例，未连接真实录音或服务。", "source_kind":"live_conversation",
             "occurred_at":"\(date)T12:00:00+08:00", "created_at":"\(date)T12:01:00+08:00",
             "version":1,"sources":[],"card_style":"summary","user_interest":"neutral","interest_version":0,
             "suggested_interest":index == 0 ? "high" : "normal",
             "interest_reason":index == 0 ? "你多次关注锁屏录音的稳定性" : ""]
        }
        let fixture: [String:Any] = ["eventInterestProtocol":1,"documents":[],"claims":[],"advice":[],
            "interestProfile":["labelledEventCount":3,"readyForSuggestions":true],
            "processingJobs":[],"confirmedMemoryCount":0,"answers":[],"events":events,
            "today":["date":date,"time_zone":"Asia/Shanghai","groups":[],"timeline":events,
                "event_count":events.count,"focus_count":0,"unknown_time_count":0]]
        let app = XCUIApplication()
        app.launchEnvironment = ["XINLIKA_TIMELINE_PREVIEW_JSON":String(decoding: try JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)]
        if resetHint { app.launchEnvironment["XINLIKA_RESET_INTEREST_HINT"] = "1" }
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(row(0,app).waitForExistence(timeout: 10))
        return app
    }
    private func row(_ index: Int, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "interest-event-event-\(index)").firstMatch
    }
    private func swipe(_ row: XCUIElement, right: Bool) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.15 : 0.9,dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02,dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    func testRightSwipeImportantAndOfflineUndo() throws {
        let app = try launch()
        swipe(row(0,app),right: true)
        XCTAssertTrue(app.staticTexts["已标记为重要"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "important-offline"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["撤销"].tap()
        XCTAssertFalse(app.staticTexts["已标记为重要"].exists)
        XCTAssertTrue(row(0,app).exists)
    }
    func testLeftSwipeRetrievableFromAllAndDetailCanChangeRating() throws {
        let app = try launch()
        swipe(row(0,app),right: false)
        XCTAssertTrue(app.staticTexts["已标记为不重要"].waitForExistence(timeout: 3))
        XCTAssertFalse(row(0,app).exists)
        app.buttons["为我筛选"].tap(); app.buttons["全部事项"].tap()
        XCTAssertTrue(row(0,app).waitForExistence(timeout: 3))
        row(0,app).tap()
        XCTAssertTrue(app.buttons["重要"].waitForExistence(timeout: 3))
        app.buttons["重要"].tap()
        XCTAssertEqual(app.buttons["重要"].value as? String, "已选")
    }
    func testLargeTextDetailAlternativeAndVerticalScrollDoesNotRate() throws {
        let app = try launch(large: true)
        app.swipeUp()
        XCTAssertFalse(app.buttons["撤销"].exists)
        app.swipeDown()
        row(0,app).tap()
        XCTAssertTrue(app.buttons["重要"].waitForExistence(timeout: 3))
        app.buttons["重要"].tap()
        app.buttons["interest-more"].tap()
        XCTAssertTrue(app.buttons["取消标记"].waitForExistence(timeout: 3))
        app.buttons["取消标记"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "large-text-detail"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDetailDoesNotShowAnotherEventsSuccessFeedback() throws {
        let app = try launch()
        swipe(row(0, app), right: true)
        XCTAssertTrue(app.staticTexts["已标记为重要"].waitForExistence(timeout: 3))
        row(1, app).tap()
        XCTAssertTrue(app.buttons["重要"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["重要"].value as? String, "未选")
        XCTAssertFalse(app.staticTexts["已标记为重要"].exists)
        XCTAssertFalse(app.buttons["撤销"].exists)
    }

    func testDetailPresentsSummaryBeforeInterestActions() throws {
        let app = try launch()
        row(0,app).tap()
        let summary = app.staticTexts["interest-summary"]
        let important = app.buttons["重要"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(important.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.isHittable)
        XCTAssertLessThanOrEqual(summary.frame.maxY, important.frame.minY,
            "摘要应先于重要程度操作，不能再次被教学和反馈控件挤到下面。")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "summary-first"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDismissedGestureHintStaysHiddenAndHelpRemainsAvailable() throws {
        let app = try launch(resetHint: true)
        let hint = app.descendants(matching: .any).matching(identifier: "interest-hint").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 3))
        app.buttons["dismiss-interest-hint"].tap()
        XCTAssertFalse(hint.exists)

        app.terminate()
        var environment = app.launchEnvironment
        environment.removeValue(forKey: "XINLIKA_RESET_INTEREST_HINT")
        app.launchEnvironment = environment
        app.launch()
        XCTAssertTrue(row(0,app).waitForExistence(timeout: 10))
        XCTAssertFalse(hint.exists, "用户已关闭的教学不应在下次启动重新常驻。")
        app.buttons["设置"].tap()
        app.buttons["interest-help"].tap()
        let instructions = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "右滑", "左滑")).firstMatch
        XCTAssertTrue(instructions.waitForExistence(timeout: 3), "收起教学后仍应能主动查看手势说明。")
    }

    func testModelSuggestionIsQuietInTimelineAndAvailableInDetail() throws {
        let app = try launch()
        XCTAssertFalse(app.staticTexts["猜你关注"].exists)
        XCTAssertFalse(app.staticTexts["你多次关注锁屏录音的稳定性"].exists)
        row(0,app).tap()
        let explanation = app.descendants(matching: .any).matching(identifier: "interest-explanation").firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        explanation.tap()
        XCTAssertTrue(app.staticTexts["你多次关注锁屏录音的稳定性"].waitForExistence(timeout: 3))
    }
}

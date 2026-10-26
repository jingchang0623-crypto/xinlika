import XCTest

final class InterestFeedbackUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(large: Bool = false) throws -> XCUIApplication {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let date = day.string(from: .now)
        let titles = ["锁屏录音稳定性", "奶茶口味闲聊"] + (3...12).map { "示例事项\($0)" }
        let events: [[String:Any]] = titles.enumerated().map { index,title in
            ["id":"event-\(index)","session_id":"session", "kind":"ambient", "title":title,
             "summary":"用于验证关注反馈的隔离示例，未连接真实录音或服务。", "source_kind":"live_conversation",
             "occurred_at":"\(date)T12:00:00+08:00", "created_at":"\(date)T12:01:00+08:00",
             "version":1,"sources":[],"card_style":"summary","user_interest":"neutral","interest_version":0]
        }
        let fixture: [String:Any] = ["eventInterestProtocol":1,"documents":[],"claims":[],"advice":[],
            "processingJobs":[],"confirmedMemoryCount":0,"answers":[],"events":events,
            "today":["date":date,"time_zone":"Asia/Shanghai","groups":[],"timeline":events,
                "event_count":events.count,"focus_count":0,"unknown_time_count":0]]
        let app = XCUIApplication()
        app.launchEnvironment = ["XINLIKA_TIMELINE_PREVIEW_JSON":String(decoding: try JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)]
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
        XCTAssertTrue(app.staticTexts["重要"].exists)
    }
    func testLargeTextDetailAlternativeAndVerticalScrollDoesNotRate() throws {
        let app = try launch(large: true)
        app.swipeUp()
        XCTAssertFalse(app.buttons["撤销"].exists)
        app.swipeDown()
        row(0,app).tap()
        XCTAssertTrue(app.buttons["重要"].waitForExistence(timeout: 3))
        app.buttons["重要"].tap()
        XCTAssertTrue(app.buttons["取消标记"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "large-text-detail"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

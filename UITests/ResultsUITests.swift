import XCTest

final class ResultsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ scenario: String = "default", appearance: String = "system", accessible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHENNAO_UI_FIXTURE"] = "1"
        app.launchEnvironment["SHENNAO_UI_SCENARIO"] = scenario
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-reading.appearance", appearance]
        if accessible { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["记录"].waitForExistence(timeout: 10))
        return app
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func openRecord(_ app: XCUIApplication) {
        let record = element("result-ui-fixture", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        record.tap()
        XCTAssertTrue(app.navigationBars["录音详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["内容摘要"].waitForExistence(timeout: 5))
    }

    func testCloudUploadAndLocalRecordingShareListAndOpenCachedAnalysis() {
        let app = launch("cloud")
        XCTAssertEqual(app.buttons.matching(identifier: "result-ui-fixture").count, 1)
        let imported = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "云端上传样例 · 访谈")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 8))
        XCTAssertTrue(imported.label.contains("15 分钟"))
        XCTAssertFalse(imported.label.contains("日期未标注"))
        capture("020-cloud-and-local-list", app)
        imported.tap()
        XCTAssertTrue(app.staticTexts["内容摘要"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "直接上传的录音也能阅读现成分析")).firstMatch.exists)
        app.segmentedControls.buttons["完整分析"].tap()
        XCTAssertTrue(app.staticTexts["产品复盘：从录音到洞察"].waitForExistence(timeout: 5))
        capture("020-cloud-cached-analysis", app)
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func jump(_ title: String, app: XCUIApplication, swipes: Int = 12) {
        app.buttons["open-contents"].tap()
        let destination = app.buttons["toc-\(title)"]
        XCTAssertTrue(app.navigationBars["分析目录"].waitForExistence(timeout: 5))
        for _ in 0..<swipes where !destination.isHittable { app.swipeUp() }
        XCTAssertTrue(destination.isHittable)
        destination.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].isHittable, "目录必须滚动到实际正文")
    }

    func testOverviewQuoteAndNativeMarkdownTable() {
        let app = launch()
        capture("production-records", app)
        openRecord(app)
        capture("production-overview", app)
        let quote = element("quote-j", in: app)
        if !quote.isHittable { app.swipeUp() }
        quote.tap()
        XCTAssertTrue(app.staticTexts["需要直接看到分析"].exists)
        jump("方案对照", app: app)
        XCTAssertTrue(element("analysis-table", in: app).exists)
        XCTAssertTrue(app.staticTexts["表格可左右滑动"].exists)
        capture("production-analysis-table", app)
    }

    func testLongReportChapterJumpAndSavedPosition() {
        var app = launch("long")
        openRecord(app)
        jump("深入章节 30", app: app, swipes: 24)
        capture("production-long-report", app)
        app.navigationBars.buttons["记录"].tap()
        app.terminate()
        app = launch("long")
        openRecord(app)
        app.segmentedControls.buttons["完整分析"].tap()
        XCTAssertTrue(app.staticTexts["深入章节 30"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["深入章节 30"].isHittable)
    }

    func testSearchFiltersTitleAndSummary() {
        let app = launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("专注")
        XCTAssertTrue(element("result-ui-pending", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("result-ui-fixture", in: app).exists)
        search.typeText("不存在")
        XCTAssertFalse(element("result-ui-pending", in: app).exists)
    }

    func testInformationAndOriginalMarkdownRemainAccessible() {
        let app = launch()
        openRecord(app)
        XCTAssertFalse(app.staticTexts["第一性原理"].exists)
        app.buttons["更多"].tap()
        app.buttons["录音与分析信息"].tap()
        XCTAssertTrue(app.navigationBars["录音与分析信息"].waitForExistence(timeout: 5))
        // LabeledContent exposes its value on the combined accessibility element.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "第一性原理", "第一性原理")).firstMatch.exists)
        app.buttons["完成"].tap()
        app.buttons["更多"].tap()
        app.buttons["查看 Markdown 原文"].tap()
        XCTAssertTrue(app.navigationBars["Markdown 原文"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "# 产品复盘：从录音到洞察")).firstMatch.exists)
    }

    func testTabNavigationKeepsReadingMode() {
        let app = launch()
        openRecord(app)
        app.segmentedControls.buttons["完整分析"].tap()
        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5))
        capture("production-device", app)
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["完整分析"].isSelected)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture("production-settings", app)
    }

    func testEmptyCachedErrorAndAbsentAnalysis() {
        var app = launch("empty")
        XCTAssertTrue(app.staticTexts["登录后查看记录"].waitForExistence(timeout: 5))
        app.buttons["前往登录"].tap()
        XCTAssertTrue(app.navigationBars["设置"].exists)
        let email = app.textFields["邮箱"]
        let password = app.secureTextFields["密码"]
        XCTAssertTrue(email.waitForExistence(timeout: 3))
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        XCTAssertTrue(email.isEnabled)
        XCTAssertTrue(password.isEnabled)
        email.tap(); email.typeText("user@example.com")
        password.tap(); password.typeText("password")
        XCTAssertEqual(email.value as? String, "user@example.com")
        app.terminate()
        app = launch("error")
        openRecord(app)
        XCTAssertTrue(app.staticTexts["最新结果暂未取回"].exists)
        capture("production-cached-error", app)
        app.terminate()
        app = launch("absent")
        openRecord(app)
        XCTAssertTrue(app.staticTexts["暂无摘要，可以查看完整分析或原始转写。"].exists)
        XCTAssertFalse(app.buttons["open-contents"].isEnabled)
    }

    func testDarkAppearance() {
        let app = launch(appearance: "dark")
        openRecord(app)
        capture("production-dark-overview", app)
        jump("核心判断", app: app)
        capture("production-dark-analysis", app)
    }

    func testAccessibilityTextUsesMenuAndReadableTableFields() {
        let app = launch(accessible: true)
        openRecord(app)
        XCTAssertTrue(element("reading-mode-accessible", in: app).exists)
        capture("production-accessibility-overview", app)
        jump("方案对照", app: app)
        XCTAssertTrue(element("analysis-table", in: app).exists)
        XCTAssertFalse(app.staticTexts["表格可左右滑动"].exists)
        capture("production-accessibility-table", app)
    }
}

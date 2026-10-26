import XCTest

final class DesignPreviewUITests: XCTestCase {
    private func launch(_ screen: String = "records") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--screen=\(screen)", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testReadingFlowAndChapterJump() {
        let app = launch()
        let record = element("record-product-review", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        XCTAssertTrue(app.staticTexts["内容摘要"].waitForExistence(timeout: 5))
        let quote = element("quote-trust", in: app)
        XCTAssertTrue(quote.exists)
        quote.tap()
        XCTAssertTrue(app.staticTexts["“我更关心这段录音有没有保存下来，以及什么时候能看到结果。”"].exists)
        app.segmentedControls.buttons["完整分析"].tap()
        XCTAssertTrue(element("chapter-context", in: app).waitForExistence(timeout: 5))
        app.buttons["open-contents"].tap()
        let destination = app.buttons["toc-risks"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.tap()
        let heading = element("chapter-risks", in: app)
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.isHittable, "目录必须真正滚动到对应章节")
    }

    func testSearchFiltersAndShowsNoResults() {
        let app = launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("专注")
        XCTAssertTrue(element("record-walking-notes", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("record-product-review", in: app).exists)
        search.typeText("不存在")
        XCTAssertFalse(element("record-walking-notes", in: app).exists)
    }

    func testTabNavigationPreservesReadingStateAndDemoPause() {
        let app = launch("overview")
        XCTAssertTrue(app.staticTexts["内容摘要"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["完整分析"].tap()
        app.tabBars.buttons["设备"].tap()
        app.buttons["toggle-demo-sync"].tap()
        XCTAssertTrue(app.staticTexts["同步已暂停"].exists)
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(element("chapter-context", in: app).exists)
        XCTAssertTrue(app.segmentedControls.buttons["完整分析"].isSelected)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["不会连接真实设备"].exists)
    }

    func testEmptyAndRecoverableErrorStates() {
        var app = launch("empty")
        XCTAssertTrue(app.staticTexts["还没有录音"].waitForExistence(timeout: 10))
        app.terminate()
        app = launch("error")
        XCTAssertTrue(app.staticTexts["暂时无法刷新"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("record-product-review", in: app).exists)
        app.buttons["演示恢复"].tap()
        XCTAssertFalse(app.staticTexts["暂时无法刷新"].exists)
    }

    func testNativeScreenGallery() {
        for screen in ["records", "overview", "analysis", "device", "settings"] {
            let app = launch(screen)
            XCTAssertTrue(app.tabBars.buttons["记录"].waitForExistence(timeout: 10))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "design-\(screen)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }
}

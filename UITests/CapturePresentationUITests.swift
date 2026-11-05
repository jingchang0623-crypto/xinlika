import XCTest

/// Display-only fixtures: no connection, capture ledger, Bluetooth or uploader is created.
final class CapturePresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(status: String = "recording", gaps: Int = 0,
                        pending: Int = 0, aligned: Bool = false,
                        processingStatus: String? = nil) throws -> XCUIApplication {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let date = day.string(from: .now)
        let at = "\(date)T12:00:00+08:00"
        let sessionID = "isolated-capture-presentation"
        let stream: [String: Any] = ["id":"isolated-stream", "connection":"isolated-connection",
            "startedAt":at, "receivedAt":at, "received":120000, "sealed":120000]
        let session: [String: Any] = ["id":sessionID,
            "deviceID":"00000000-0000-0000-0000-000000000001", "startedAt":at,
            "cardFile":"20261028120000.opus", "batchSeconds":60,
            "sourceKind":"live_conversation", "processing":true, "status":status,
            "captureOrigin":"app", "streams":[stream], "gaps":gaps, "sequence":1,
            "referenceQueued":aligned, "automaticReference":true]
        let outbox: [[String: Any]] = (0..<pending).map { index in
            ["id":"isolated-message-\(index)", "file":"not-read-\(index).json",
             "sessionID":sessionID, "status":"pending", "attempts":0]
        }
        let capture: [String: Any] = ["sessions":[session], "outbox":outbox]
        let jobs: [[String: Any]] = processingStatus.map { value in
            [["id":"isolated-processing", "kind":"asr_audio", "status":value, "attempts":1]]
        } ?? []
        let timeline: [String: Any] = ["eventInterestProtocol":1, "documents":[], "claims":[],
            "advice":[], "processingJobs":jobs, "confirmedMemoryCount":0, "answers":[], "events":[],
            "today":["date":date, "time_zone":"Asia/Shanghai", "groups":[], "timeline":[],
                     "event_count":0, "focus_count":0, "unknown_time_count":0]]
        let app = XCUIApplication()
        app.launchEnvironment = [
            "XINLIKA_TIMELINE_PREVIEW_JSON":try json(timeline),
            "XINLIKA_CAPTURE_PREVIEW_JSON":try json(capture)
        ]
        if aligned {
            app.launchEnvironment["XINLIKA_REMOTE_CAPTURE_PREVIEW_JSON"] = try json([
                "id":sessionID, "status":"completed", "audio_seconds":60,
                "batch_count":1, "gap_count":gaps, "batch_seconds":60,
                "archive_status":"phone_card_bytes_verified"
            ])
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let recordingTab = app.tabBars.buttons["录音"]
        XCTAssertTrue(recordingTab.waitForExistence(timeout: 10))
        recordingTab.tap()
        XCTAssertTrue(element("capture-status", app).waitForExistence(timeout: 5))
        return app
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCurrentRecordingControlsPrecedeOtherSources() throws {
        let app = try launch()
        let mark = app.buttons["capture-mark"]
        let stop = app.buttons["capture-stop"]
        let watch = app.buttons["Apple Watch 录音"]
        XCTAssertTrue(mark.isHittable)
        XCTAssertTrue(stop.isHittable)
        if watch.exists { XCTAssertLessThan(stop.frame.minY, watch.frame.minY) }
        XCTAssertFalse(app.staticTexts["已收原声"].exists,
            "正常接收量应位于可展开详情，主操作不应被诊断字段挤开。")
        attach("capture-normal", app)
        reveal(watch, in: app)
    }

    func testPendingBacklogAndReceptionGapRemainVisible() throws {
        let app = try launch(gaps: 1, pending: 160)
        let pending = element("capture-pending", app)
        let gap = element("capture-gap", app)
        XCTAssertTrue(pending.exists && pending.isHittable)
        XCTAssertTrue((pending.label + String(describing: pending.value ?? "")).contains("160"))
        XCTAssertTrue(gap.exists && gap.isHittable)
        XCTAssertFalse(element("history-gap", app).exists)
        attach("capture-pending-gap", app)
    }

    func testAlignedHistoricalGapCanBeReviewed() throws {
        let app = try launch(status: "completed", gaps: 2, aligned: true)
        XCTAssertFalse(element("capture-gap", app).exists)
        XCTAssertFalse(element("history-gap", app).exists)
        let details = element("capture-sync-details", app)
        reveal(details, in: app)
        details.tap()
        let history = element("history-gap", app)
        reveal(history, in: app)
        XCTAssertTrue(history.label.contains("实时接收曾中断"))
        // LabeledContent exposes its label/value as one accessible element.
        let alignment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "当前文件已对齐")).firstMatch
        XCTAssertTrue(alignment.exists && alignment.isHittable)
        attach("capture-aligned-history", app)
    }

    func testProcessingFailuresRemainVisibleWithoutExpandingDetails() throws {
        for (status, message) in [("failed", "暂未完成，原声保留"),
                                  ("blocked_provider", "服务凭据或额度需检查")] {
            let app = try launch(processingStatus: status)
            let failure = app.staticTexts[message]
            XCTAssertTrue(failure.waitForExistence(timeout: 3))
            XCTAssertTrue(failure.isHittable)
            XCTAssertTrue(app.buttons["重试"].exists)
            attach("capture-processing-\(status)", app)
            app.terminate()
        }
    }
}

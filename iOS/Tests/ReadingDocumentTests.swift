import XCTest
@testable import Shennao

final class ReadingDocumentTests: XCTestCase {
    func testThirdPartyNoticesAreIncludedInAppBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Runtime Library Exception"))
        XCTAssertTrue(content.contains("John MacFarlane"))
    }
    func testHeadingsAndRichInlineText() throws {
        let document = try ReadingDocumentParser.parse("# 一级\n\n## 二级\n\n### 三级\n\n普通 **加粗 *组合*** 与 `代码` 和 ~~删除~~ 👩🏽‍💻")
        XCTAssertEqual(document.headings.map(\.level), [1, 2, 3])
        XCTAssertEqual(document.headings.map(\.title), ["一级", "二级", "三级"])
        let paragraph = try XCTUnwrap(document.blocks.last)
        XCTAssertEqual(String(paragraph.text.characters), "普通 加粗 组合 与 代码 和 删除 👩🏽‍💻")
        XCTAssertTrue(paragraph.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(paragraph.text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(paragraph.text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(paragraph.text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }
    func testNestedListsTaskMarkersAndQuotes() throws {
        let document = try ReadingDocumentParser.parse("3. 第三项\n   - 嵌套\n4. 第四项\n\n- [x] 原文完成\n- [ ] 原文未完成\n\n> 原话\n>\n> 第二段")
        XCTAssertEqual(document.blocks.compactMap(\.marker), ["3.", "•", "4.", "☑︎", "☐"])
        XCTAssertEqual(document.blocks[1].depth, 2)
        XCTAssertEqual(document.blocks.suffix(2).map(\.quoteDepth), [1, 1])
        XCTAssertTrue(document.blocks.contains { String($0.text.characters) == "第二段" })
    }
    func testTablesPreserveEscapedPipesAndAlignment() throws {
        let document = try ReadingDocumentParser.parse("| 左 | 中 | 右 |\n| :-- | :-: | --: |\n| a\\|b | **重点** | 42 |\n| 空尾 |")
        let table = try XCTUnwrap(document.blocks.first?.table)
        XCTAssertEqual(table.columns.count, 3)
        XCTAssertEqual(table.columns.map(\.alignment), [.leading, .center, .trailing])
        XCTAssertEqual(String(table.rows[0].cells[0].text.characters), "a|b")
        XCTAssertEqual(String(table.rows[0].cells[1].text.characters), "重点")
        XCTAssertEqual(table.rows[1].cells.count, 3)
        XCTAssertEqual(String(table.rows[1].cells[2].text.characters), "")
        XCTAssertEqual(Set(table.rows.flatMap(\.cells).map(\.id)).count, 6)
    }
    func testOnlySafeUserActivatedWebLinksRemainClickable() throws {
        for link in ["https://example.com/a", "http://example.com"] { XCTAssertTrue(ReadingLinkPolicy.allowed(URL(string: link)!)) }
        for link in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hello", "shennao://delete", "/relative", "https://user:secret@example.com"] {
            XCTAssertFalse(ReadingLinkPolicy.allowed(URL(string: link)!))
        }
        let document = try ReadingDocumentParser.parse("[安全](https://example.com) [危险](javascript:alert) ![图像说明](https://example.com/tracker.png)")
        let text = try XCTUnwrap(document.blocks.first?.text)
        XCTAssertTrue(String(text.characters).contains("图像说明，未自动加载"))
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://example.com")!])
        XCTAssertTrue(String(text.characters).contains("危险"))
    }
    func testHTMLAndCodeStayLiteral() throws {
        let document = try ReadingDocumentParser.parse("<script>alert('x')</script>\n\n```swift\nlet value = \"<b>\"\n```\n\n前<br>后")
        XCTAssertEqual(String(document.blocks[0].text.characters), "<script>alert('x')</script>\n")
        XCTAssertTrue(String(document.blocks[1].text.characters).contains("let value = \"<b>\""))
        XCTAssertEqual(String(document.blocks[2].text.characters), "前\n后")
    }
    func testDocumentIDsAreUniqueStableAndRevisionScoped() throws {
        let source = "## 重复\n\n文字\n\n## 重复\n\n- 同一内容\n- 同一内容"
        let first = try ReadingDocumentParser.parse(source)
        let second = try ReadingDocumentParser.parse(source)
        let changed = try ReadingDocumentParser.parse(source + "\n\n新内容")
        XCTAssertEqual(first.blocks.map(\.id), second.blocks.map(\.id))
        XCTAssertEqual(Set(first.blocks.map(\.id)).count, first.blocks.count)
        XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertTrue(Set(first.blocks.map(\.id)).isDisjoint(with: changed.blocks.map(\.id)))
        XCTAssertNotEqual(first.headings[0].id, first.headings[1].id)
    }
    func testLongReportKeepsTailAndEveryChapter() throws {
        XCTAssertGreaterThan(UIReadingFixtures.longAnalysis.count, 20_000)
        let document = try ReadingDocumentParser.parse(UIReadingFixtures.longAnalysis)
        XCTAssertEqual(document.headings.last?.title, "报告结尾")
        XCTAssertEqual(document.headings.filter { $0.title.hasPrefix("深入章节") }.count, 36)
        XCTAssertEqual(String(try XCTUnwrap(document.blocks.last).text.characters), "长文末尾内容仍应完整可读。")
        XCTAssertGreaterThan(document.blocks.count, 180)
    }
    func testEmptyDocument() throws {
        let document = try ReadingDocumentParser.parse("  \n")
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertTrue(document.headings.isEmpty)
    }
}

final class RecordPresentationTests: XCTestCase {
    private var sample: LedgerItem { UIReadingFixtures.records(scenario: "default")[0] }
    func testRecordingDateDoesNotChangeWhenCacheRefreshes() {
        var record = sample
        let first = RecordPresentation(record)
        record.updatedAt = Date.distantFuture
        record.resultUpdatedAt = Date.distantFuture
        XCTAssertEqual(first.date, RecordPresentation(record).date)
        XCTAssertNotNil(first.date)
    }
    func testTranscriptionIsNotAnalysisCompletion() {
        var record = sample
        record.meeting = nil
        record.state = .ready
        XCTAssertEqual(RecordPresentation(record).status, "分析待更新")
        record.meeting = sample.meeting
        record.meeting?.analysis = nil
        record.meeting?.analysisAbsentReason = "录音较短"
        XCTAssertEqual(RecordPresentation(record).status, "未自动分析")
        record.meeting?.analysis = .init(status: "analyzing", markdown: nil, methods: [], routingReason: nil)
        XCTAssertEqual(RecordPresentation(record).status, "分析中")
        XCTAssertTrue(RecordPresentation(record).isWorking)
    }
    func testRecoverableFailureRemainsVisibleWithCachedAnalysis() {
        var record = sample
        record.resultError = "网络中断"
        XCTAssertTrue(RecordPresentation(record).needsAttention)
        XCTAssertEqual(RecordPresentation(record).status, "分析完成")
        record.state = .paused
        XCTAssertEqual(RecordPresentation(record).status, "同步待恢复")
    }
    func testDurationAndSearch() {
        XCTAssertEqual(RecordPresentation.duration(.nan), "时长未知")
        XCTAssertEqual(RecordPresentation.duration(.infinity), "时长未知")
        XCTAssertEqual(RecordPresentation.duration(-1), "时长未知")
        XCTAssertEqual(RecordPresentation.duration(61), "1 分钟")
        XCTAssertEqual(RecordPresentation.duration(3660), "1 小时 1 分钟")
        let rows = UIReadingFixtures.records(scenario: "default").map(RecordPresentation.init)
        XCTAssertEqual(RecordDateGroup.make(rows, query: "专注").flatMap(\.rows).map(\.id), ["ui-pending"])
        XCTAssertTrue(RecordDateGroup.make(rows, query: "不会存在的内容").isEmpty)
        XCTAssertEqual(RecordDateGroup.make(rows.reversed(), query: "").flatMap(\.rows).map(\.id), ["ui-fixture", "ui-pending"])
    }
}

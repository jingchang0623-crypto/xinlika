import XCTest
@testable import Shennao

final class ImportPolicyTests: XCTestCase {
    private let scope = RecordScope(orgId: "org", email: "test@example.test",
                                   config: AppConfig(apiBase: "https://api.test", supabaseURL: "https://auth.test", supabaseAnonKey: "test"))
    private func entry(_ seconds: UInt32 = 600, name: String = "note20260907-100000.") -> FileEntry {
        FileEntry(time: seconds, size: max(2000, seconds * 2000), name: name, rawName: [])
    }
    private func discover(_ entries: [FileEntry], records: [LedgerItem] = []) -> [LedgerItem] {
        ImportPolicy.discover(entries, records: records, scope: scope, deviceID: "device", minimumSeconds: 60)
    }

    func testThreeHourRecordingIsHeldBeforeAnyAudioTransfer() throws {
        let item = try XCTUnwrap(discover([entry(10800)]).first)
        XCTAssertEqual(item.importDisposition, .review)
        XCTAssertEqual(item.importReviewReason, .longRecording)
        XCTAssertEqual(item.receivedBytes, 0)
        XCTAssertFalse(item.autoUpload!)
        XCTAssertFalse(ImportPolicy.allowsUpload(item))
    }

    func testDurationBoundariesAndUnknownValues() {
        XCTAssertEqual(ImportPolicy.reviewReason(duration: 59, newCount: 1, minimumSeconds: 60), .shortRecording)
        XCTAssertNil(ImportPolicy.reviewReason(duration: 60, newCount: 1, minimumSeconds: 60))
        XCTAssertNil(ImportPolicy.reviewReason(duration: 7199, newCount: 1, minimumSeconds: 60))
        XCTAssertEqual(ImportPolicy.reviewReason(duration: 7200, newCount: 1, minimumSeconds: 60), .longRecording)
        for duration in [0, -1, Double.nan, .infinity] {
            XCTAssertEqual(ImportPolicy.reviewReason(duration: duration, newCount: 1, minimumSeconds: 0), .unknownDuration)
        }
        XCTAssertNil(ImportPolicy.reviewReason(duration: 30, newCount: 1, minimumSeconds: 0))
        XCTAssertEqual(ImportPolicy.reviewReason(duration: 10800, newCount: 1, minimumSeconds: 0), .longRecording)
    }

    func testBatchCountsOnlyUniqueNewFiles() {
        let files = (0..<5).map { entry(name: "record\($0).opus") }
        XCTAssertTrue(discover(files).allSatisfy { $0.importReviewReason == .batch && $0.autoUpload == false })
        XCTAssertTrue(discover(Array(files.prefix(4))).allSatisfy { $0.importDisposition == .automatic })
        XCTAssertEqual(discover(Array(repeating: files[0], count: 8)).count, 1)
        XCTAssertEqual(discover(Array(repeating: files[0], count: 8)).first?.importDisposition, .automatic)
        XCTAssertTrue(discover(files, records: discover([files[0]])).allSatisfy { $0.importDisposition == .automatic })
    }

    func testIgnoredFileStaysIgnoredAfterRelaunchAndRediscovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerStore(directory: directory)
        var item = try XCTUnwrap(discover([entry(10800)]).first)
        item.importDisposition = .ignored
        try ledger.upsert(item)
        let reopened = LedgerStore(directory: directory)
        XCTAssertTrue(discover([entry(10800)], records: reopened.items).isEmpty)
        XCTAssertTrue(reopened.items[0].isIgnored)
        XCTAssertFalse(reopened.items[0].isVisibleRecord)
        XCTAssertFalse(ImportPolicy.allowsUpload(reopened.items[0]))
    }

    func testUploadAdmissionRequiresExplicitAllowedDispositionAndAutoUpload() throws {
        var item = try XCTUnwrap(discover([entry(10800)]).first)
        item.state = .downloaded
        item.autoUpload = true
        for disposition in [ImportDisposition.review, .ignored] {
            item.importDisposition = disposition
            XCTAssertFalse(ImportPolicy.allowsUpload(item))
        }
        item.importDisposition = .approved
        XCTAssertTrue(ImportPolicy.allowsUpload(item), "An explicitly approved long meeting is permitted")
        item.autoUpload = false
        XCTAssertFalse(ImportPolicy.allowsUpload(item))
        item.autoUpload = true
        item.nextRetryAt = Date().addingTimeInterval(300)
        XCTAssertFalse(ImportPolicy.allowsUpload(item))
    }

    func testMigrationHoldsUnfinishedQueueWithoutChangingCompletedOrApprovedItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerStore(directory: directory)
        let states: [LedgerState] = [.paused, .downloading, .downloaded, .uploading, .failed, .processing, .ready]
        for (index, state) in states.enumerated() {
            var item = discover([entry(name: "record\(index).opus")])[0]
            item.importDisposition = nil
            item.state = state
            item.updatedAt = Date(timeIntervalSince1970: 1700000000 + Double(index))
            item.serverSessionId = "existing-session-\(index)"
            try ledger.upsert(item)
        }
        XCTAssertTrue(try ledger.holdLegacyImportQueue())
        XCTAssertFalse(try ledger.holdLegacyImportQueue())
        XCTAssertEqual(ledger.items.filter(\.isHeldForReview).count, 5)
        XCTAssertEqual(ledger.items.filter { [.processing, .ready].contains($0.state) && $0.importDisposition == nil }.count, 2)
        XCTAssertTrue(ledger.items.allSatisfy { $0.serverSessionId != nil })
        XCTAssertEqual(LedgerStore(directory: directory).items, ledger.items)
    }

    func testBatchPersistenceFailureDoesNotReleaseHeldDecisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerStore(directory: directory)
        try ledger.upsert(discover([entry(10800)]))
        let before = ledger.items
        let url = directory.appendingPathComponent("ledger.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var approved = before[0]; approved.importDisposition = .approved; approved.autoUpload = true
        XCTAssertThrowsError(try ledger.upsert([approved]))
        XCTAssertEqual(ledger.items, before)
    }

    func testIdentityIsScopedToAccountAndOrganization() {
        var other = discover([entry(10800)])[0]
        other.ownerKey = "someone-else"
        XCTAssertEqual(discover([entry(10800)], records: [other]).count, 1)
    }

    func testBackgroundReceiptIdentityAcceptsOldAndNewTaskDescriptions() {
        let key = String(repeating: "a", count: 64)
        XCTAssertEqual(BackgroundUploader.transferKey(key), key)
        XCTAssertEqual(BackgroundUploader.transferKey("record-id|" + key), key)
        XCTAssertNil(BackgroundUploader.transferKey("garbage"))
    }
    func testIncompleteListCannotAdmitAnApparentlySmallBatch() {
        let items = ImportPolicy.discover([entry()], records: [], scope: scope, deviceID: "device",
                                          minimumSeconds: 60, listComplete: false)
        XCTAssertEqual(items.first?.importReviewReason, .incompleteList)
        XCTAssertEqual(items.first?.autoUpload, false)
    }

    func testTwentyTwoSecondCatalogueEntryIsVisibleInReviewWithoutAllowingTransfer() throws {
        let item = try XCTUnwrap(ImportPolicy.discover([entry(22)], records: [], scope: scope,
                                                      deviceID: "device", minimumSeconds: 120).first)
        XCTAssertTrue(RecordingQueueSection.review.contains(item))
        XCTAssertEqual(item.importReviewReason, .shortRecording)
        XCTAssertEqual(item.receivedBytes, 0)
        XCTAssertFalse(item.importDisposition!.allowsTransfer)
        XCTAssertFalse(ImportPolicy.allowsUpload(item))
    }

    func testNewestShortRecordingComesBeforeOlderLongRecording() {
        let items = discover([entry(10800, name: "note20260906-100000."), entry(22, name: "note20260907-131301.")])
        let queue = RecordingQueueSection.review.sortedItems(in: items)
        XCTAssertEqual(queue.map(\.durationSec), [22, 10800])
    }

    func testCatalogueRefreshDoesNotUndoAnIgnoreOrCreateDuplicateEntry() {
        let e = entry(22)
        var held = discover([e])[0]
        XCTAssertTrue(discover([e], records: [held]).isEmpty)
        held.importDisposition = .ignored
        XCTAssertTrue(discover([e], records: [held]).isEmpty)
        XCTAssertFalse(RecordingQueueSection.review.contains(held))
    }

}

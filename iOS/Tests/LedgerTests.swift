import XCTest
@testable import Shennao

final class LedgerTests: XCTestCase {
    private var directory: URL!
    private let config = AppConfig(apiBase: "https://api.test",
        supabaseURL: "https://auth.test", supabaseAnonKey: "public")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShennaoLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only remove the unique test-owned directory.
        try FileManager.default.removeItem(at: directory)
    }

    private func item() -> LedgerItem {
        LedgerItem(id: "test-record", orgId: "org-a", deviceId: "device", fileBase: "note",
            title: "test", durationSec: 1, expectedBytes: 40, receivedBytes: 40,
            localFilename: "test.ogg", contentHash: "hash", serverSessionId: nil,
            transcriptId: nil, state: .downloaded, lastError: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLegacyRecordLoadsAndMigrationIsIdempotent() throws {
        let ledger = LedgerStore(directory: directory)
        try ledger.upsert(item())
        let reopened = LedgerStore(directory: directory)
        XCTAssertNil(reopened.loadError)
        XCTAssertNil(reopened.items.first?.ownerKey)
        let scope = RecordScope(orgId: "org-a", email: "alice@test.com", config: config)
        try reopened.adoptLegacyRecords(scope: scope)
        try reopened.adoptLegacyRecords(scope: scope)
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertTrue(scope.contains(reopened.items[0]))
        XCTAssertEqual(LedgerStore(directory: directory).items, reopened.items)
    }

    func testIdentityRequiresMatchingUserOrganizationAndEnvironment() {
        let alice = RecordScope(orgId: "org-a", email: "Alice@test.com", config: config)
        var record = item()
        record.ownerKey = alice.ownerKey
        XCTAssertTrue(alice.contains(record))
        XCTAssertFalse(RecordScope(orgId: "org-b", email: "Alice@test.com", config: config).contains(record))
        XCTAssertFalse(RecordScope(orgId: "org-a", email: "bob@test.com", config: config).contains(record))
        var other = config
        other.apiBase = "https://staging.test"
        XCTAssertFalse(RecordScope(orgId: "org-a", email: "Alice@test.com", config: other).contains(record))
        XCTAssertEqual(alice.ownerKey,
            RecordScope(orgId: "org-a", email: " alice@test.com ", config: config).ownerKey)
    }

    func testMigrationCannotClaimAnotherOrganizationOrOwnedRecord() throws {
        let ledger = LedgerStore(directory: directory)
        var record = item()
        try ledger.upsert(record)
        try ledger.adoptLegacyRecords(scope: RecordScope(orgId: "org-b", email: "bob@test.com", config: config))
        XCTAssertNil(ledger.items[0].ownerKey)
        record.ownerKey = "existing-owner"
        try ledger.upsert(record)
        try ledger.adoptLegacyRecords(scope: RecordScope(orgId: "org-a", email: "alice@test.com", config: config))
        XCTAssertEqual(ledger.items[0].ownerKey, "existing-owner")
    }

    func testCorruptLedgerIsNotSilentlyOverwritten() throws {
        let url = directory.appendingPathComponent("ledger.json")
        let corrupt = Data("invalid-json".utf8)
        try corrupt.write(to: url)
        let ledger = LedgerStore(directory: directory)
        XCTAssertNotNil(ledger.loadError)
        XCTAssertThrowsError(try ledger.upsert(item()))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSaveFailureDoesNotAdvanceInMemoryState() throws {
        let ledger = LedgerStore(directory: directory)
        try ledger.upsert(item())
        let before = ledger.items
        let file = directory.appendingPathComponent("ledger.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var changed = item()
        changed.state = .processing
        changed.serverSessionId = "s1"
        XCTAssertThrowsError(try ledger.upsert(changed))
        XCTAssertEqual(ledger.items, before)
    }

    func testSessionIdentityPersistsIndependentlyOfFinalUploadState() throws {
        let ledger = LedgerStore(directory: directory)
        var record = item()
        record.state = .uploading
        try ledger.upsert(record)
        record.serverSessionId = "s1"
        try ledger.upsert(record)
        record.state = .failed
        record.lastError = "network unavailable"
        try ledger.upsert(record)
        let recovered = try XCTUnwrap(LedgerStore(directory: directory).items.first)
        XCTAssertEqual(recovered.serverSessionId, "s1")
        XCTAssertTrue(recovered.canRetry)
        XCTAssertEqual(recovered.contentHash, "hash")
    }
}

import XCTest
@testable import Shennao

final class CloudRecordTests: XCTestCase {
    let sid = "10000000-0000-0000-0000-000000000001"
    let tid = "20000000-0000-0000-0000-000000000001"
    let org = "30000000-0000-0000-0000-000000000001"
    var scope: RecordScope { RecordScope(orgId: org, email: "test@example.test", config: AppConfig(apiBase: "https://api.test", supabaseURL: "https://auth.test", supabaseAnonKey: "public")) }
    func remote(transcript: Bool = true) -> CloudRecord {
        CloudRecord(sessionID: sid, transcriptID: transcript ? tid : nil, title: "网页上传的访谈",
                    startedAt: CloudRecord.date("2026-09-07T09:30:00.123Z"), durationSeconds: 900,
                    stage: transcript ? "analyzed" : "failed", headline: "现成的分析摘要")
    }
    func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testBothSourcesMergeByTranscriptWithoutDroppingStandaloneImport() throws {
        let sessions = try CloudRecord.sessions(encoded(["sessions": [["sessionId": sid, "transcriptId": tid,
            "title": "旧标题", "durationMs": 900000, "stage": "analyzed", "headline": "已有摘要"]]]))
        let second = "20000000-0000-0000-0000-000000000002"
        let transcripts = try CloudRecord.transcripts(encoded([
            ["id": tid, "title": "新标题", "recorded_at": "2026-09-06T09:30:00+08:00", "status": "ready"],
            ["id": second, "title": "独立导入", "created_at": "2026-09-05T09:30:00Z", "status": "ready"]
        ]))
        let combined = CloudRecord.combine(sessions: sessions, transcripts: transcripts)
        XCTAssertEqual(combined.count, 2)
        let linked = try XCTUnwrap(combined.first { $0.transcriptID == tid })
        XCTAssertEqual(linked.sessionID, sid)
        XCTAssertEqual(linked.title, "新标题")
        XCTAssertEqual(linked.stage, "analyzed")
        XCTAssertEqual(linked.headline, "已有摘要")
        XCTAssertEqual(linked.durationSeconds, 900)
        XCTAssertEqual(linked.startedAt, CloudRecord.date("2026-09-06T01:30:00Z"))
    }

    func testMalformedAndUnknownMetadataNeverPretendsSuccess() throws {
        XCTAssertThrowsError(try CloudRecord.sessions(encoded(["unexpected": []])))
        XCTAssertThrowsError(try CloudRecord.sessions(encoded(["sessions": [["sessionId": "invalid"]]])))
        let item = try XCTUnwrap(CloudRecord.sessions(encoded(["sessions": [["sessionId": sid,
            "durationMs": true, "stage": "future-state", "startedAt": "invalid"]]])).first)
        XCTAssertEqual(item.label, "云端状态待确认")
        XCTAssertNil(item.durationSeconds)
        XCTAssertNil(item.startedAt)
        XCTAssertThrowsError(try CloudRecord.transcripts(encoded(["error": "bad response"])))
    }

    func testCloudRecordIsVisibleAndCannotBecomeAnUploadOrDeviceTask() throws {
        var item = try XCTUnwrap(CloudLibrary.merging([remote()], into: [], scope: scope).first)
        XCTAssertTrue(item.isVisibleRecord)
        XCTAssertTrue(item.isCloudOnly)
        XCTAssertFalse(item.isLocallyControllable)
        XCTAssertFalse(item.autoUpload!)
        XCTAssertEqual(item.receivedBytes, 0)
        item.autoUpload = true; item.state = .downloaded
        XCTAssertFalse(ImportPolicy.allowsUpload(item), "Cloud catalogue data never creates an upload, even with an accidental flag")
        XCTAssertFalse(ImportPolicy.needsLegacyReview(item))
    }

    func testLocalAudioIdentityAndReviewDecisionSurviveRediscovery() throws {
        var local = try XCTUnwrap(CloudLibrary.merging([remote()], into: [], scope: scope).first)
        local = LedgerItem(id: "local-id", orgId: scope.orgId, deviceId: "recorder", fileBase: "note20260907-130000",
            title: "本地文件", durationSec: 22, expectedBytes: 44600, receivedBytes: 2000,
            localFilename: "local.ogg", contentHash: "retained-hash", serverSessionId: sid,
            state: .paused, updatedAt: Date(), ownerKey: scope.ownerKey, autoUpload: false,
            importDisposition: .review, importReviewReason: .shortRecording)
        let first = CloudLibrary.merging([remote()], into: [local], scope: scope)
        let again = CloudLibrary.merging([remote()], into: first, scope: scope)
        XCTAssertEqual(first, again)
        let item = try XCTUnwrap(again.first)
        XCTAssertEqual(item.id, local.id)
        XCTAssertEqual(item.localFilename, local.localFilename)
        XCTAssertEqual(item.receivedBytes, 2000)
        XCTAssertEqual(item.expectedBytes, 44600)
        XCTAssertEqual(item.contentHash, "retained-hash")
        XCTAssertEqual(item.importReviewReason, .shortRecording)
        XCTAssertTrue(item.isHeldForReview)
        XCTAssertFalse(item.autoUpload!)
    }

    func testLateLocalLinkCollapsesCloudCopyAndPreservesIgnore() throws {
        var cached = try XCTUnwrap(CloudLibrary.merging([remote()], into: [], scope: scope).first)
        cached.importDisposition = .ignored
        let local = LedgerItem(id: "local", orgId: scope.orgId, deviceId: "recorder", fileBase: "note20260907-130000",
            title: "旧标题", durationSec: 900, expectedBytes: 4000, receivedBytes: 4000,
            localFilename: "local.ogg", contentHash: "audio-hash", serverSessionId: sid,
            state: .ready, updatedAt: Date(), ownerKey: scope.ownerKey, autoUpload: false, importDisposition: .approved)
        let merged = CloudLibrary.merging([remote()], into: [cached, local], scope: scope)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "local")
        XCTAssertTrue(merged.first!.isIgnored)
        XCTAssertEqual(merged.first?.contentHash, "audio-hash")
    }

    func testAccountsStayIsolatedAndEmptyCatalogueDoesNotEraseCache() throws {
        let original = CloudLibrary.merging([remote()], into: [], scope: scope)
        let other = RecordScope(orgId: org, email: "other@example.test", config: AppConfig(apiBase: "https://api.test", supabaseURL: "https://auth.test", supabaseAnonKey: "public"))
        let combined = CloudLibrary.merging([remote()], into: original, scope: other)
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined.filter(scope.contains), original)
        XCTAssertNotEqual(combined[0].id, combined[1].id)
        XCTAssertEqual(CloudLibrary.merging([], into: original, scope: scope), original)
    }

    func testCloudCacheSurvivesRelaunchAndFailureIsNotAnUploadFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerStore(directory: directory)
        try store.mergeCloudRecords([remote(transcript: false)], scope: scope)
        let reopened = LedgerStore(directory: directory)
        XCTAssertEqual(reopened.items.map(\.id), store.items.map(\.id))
        XCTAssertEqual(reopened.items[0].cloud?.stage, "failed")
        XCTAssertEqual(reopened.items[0].cloud?.sessionID, sid)
        XCTAssertEqual(reopened.items[0].autoUpload, false)
        let presentation = RecordPresentation(reopened.items[0])
        XCTAssertEqual(presentation.status, "云端处理失败")
        XCTAssertFalse(presentation.isWorking)
        // Ledger ISO8601 persistence intentionally keeps whole seconds.
        XCTAssertEqual(try XCTUnwrap(presentation.date).timeIntervalSince1970,
                       try XCTUnwrap(remote().startedAt).timeIntervalSince1970, accuracy: 1)
    }

    func testUnknownCloudDurationDoesNotDisplayZeroSeconds() throws {
        var value = remote(); value.durationSeconds = nil
        let item = try XCTUnwrap(CloudLibrary.merging([value], into: [], scope: scope).first)
        XCTAssertTrue(RecordPresentation(item).metadata.contains("时长未知"))
    }

    func testHistoryPaginatesBeyondOneHundredWithOrgAndReadOnlyHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); RecordingURLProtocol.handler = nil }
        let brain = DeepBrain(config: DeepBrainConfig(apiBase: "https://api.test", supabaseUrl: "https://auth.test", supabaseAnonKey: "public"), transport: session)
        brain.token = "test-token"; brain.org = org
        var calls = 0
        RecordingURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            calls += 1
            if request.url!.path == "/api/mobile/sessions" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-deepbrain-org-id"), self.org)
                return (200, ["sessions": []])
            }
            XCTAssertEqual(request.url!.path, "/rest/v1/transcripts")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["org_id"], "eq.\(self.org)")
            XCTAssertEqual(query["order"], "id.asc")
            XCTAssertEqual(query["limit"], "100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public")
            if calls == 2 {
                XCTAssertNil(query["id"])
                return (200, (1...100).map { ["id": String(format: "20000000-0000-0000-0000-%012d", $0), "status": "ready"] })
            }
            if calls == 3 {
                XCTAssertEqual(query["id"], "gt.20000000-0000-0000-0000-000000000100")
                return (200, [["id": "20000000-0000-0000-0000-000000000101", "status": "ready"]])
            }
            XCTAssertEqual(query["id"], "gt.20000000-0000-0000-0000-000000000101")
            return (200, [])
        }
        let result = try await brain.cloudRecords()
        XCTAssertEqual(result.count, 101)
        XCTAssertEqual(calls, 4)
    }

    func testLaterPageFailureDoesNotPublishPartialHistory() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); RecordingURLProtocol.handler = nil }
        let brain = DeepBrain(config: DeepBrainConfig(apiBase: "https://api.test", supabaseUrl: "https://auth.test", supabaseAnonKey: "public"), transport: session)
        brain.token = "test-token"; brain.org = org
        var calls = 0
        RecordingURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 { return (200, ["sessions": []]) }
            if calls == 2 { return (200, (1...100).map { ["id": String(format: "20000000-0000-0000-0000-%012d", $0)] }) }
            return (503, ["error": "unavailable"])
        }
        do { _ = try await brain.cloudRecords(); XCTFail("Partial history must not be reported as successful") }
        catch { XCTAssertEqual(calls, 3) }
    }
}

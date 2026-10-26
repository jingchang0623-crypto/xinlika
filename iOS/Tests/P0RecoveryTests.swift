import XCTest
@testable import Shennao

final class MeetingContractTests: XCTestCase {
    func testAnalysisStateIsDistinctFromTranscription() throws {
        let id = UUID().uuidString
        for status in ["queued", "routing", "analyzing", "self_check", "persisting", "done", "failed", "completed"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "transcriptId": id, "analysis": ["status": status, "markdown": NSNull()]
            ])
            let meeting = try Meeting.parse(data)
            XCTAssertEqual(meeting.needsPolling, ["queued", "routing", "analyzing", "self_check", "persisting"].contains(status))
            if status == "done" { XCTAssertEqual(meeting.analysisLabel, "分析完成") }
            if status == "failed" { XCTAssertEqual(meeting.analysisLabel, "分析失败") }
            if status == "completed" { XCTAssertEqual(meeting.analysisLabel, "分析状态待确认") }
        }
    }

    func testMissingAnalysisUsesServerReason() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "transcriptId": UUID().uuidString, "analysis": NSNull(),
            "summary": NSNull(), "analysisAbsentReason": "录音较短，未自动分析"
        ])
        let meeting = try Meeting.parse(data)
        XCTAssertNil(meeting.analysis)
        XCTAssertEqual(meeting.analysisAbsentReason, "录音较短，未自动分析")
        XCTAssertFalse(meeting.needsPolling)
        XCTAssertEqual(meeting.speakers, [])
    }

    func testCoreContentAndCacheRoundTrip() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "transcriptId": UUID().uuidString, "title": "产品会",
            "summary": "## 摘要\n\n**保留原话** 👩🏽‍💻",
            "analysis": ["status": "done", "markdown": "结论", "methods": ["第一性原理"]],
            "atoms": [["id": "a", "statement": "判断", "quote": "证据"]],
            "commitments": [["id": "c", "speaker": "负责人", "quote": "下一步", "dueDate": "2026-09-10"]],
            "speakers": ["负责人"]
        ])
        let meeting = try Meeting.parse(data)
        XCTAssertEqual(meeting.judgments.first?.quote, "证据")
        XCTAssertEqual(meeting.commitments.first?.speaker, "负责人")
        XCTAssertEqual(meeting.analysis?.methods, ["第一性原理"])
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting)), meeting)
    }

    func testMalformedResponseCannotBecomeEmptySuccess() {
        XCTAssertThrowsError(try Meeting.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try Meeting.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try Meeting.parse(Data("invalid".utf8)))
    }

    func testResultEndpointAndRecordIdentity() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); RecordingURLProtocol.handler = nil }
        let brain = DeepBrain(config: DeepBrainConfig(apiBase: "https://api.test",
            supabaseUrl: "https://auth.test", supabaseAnonKey: "public"), transport: session)
        brain.token = "test"; brain.org = "org"
        let id = UUID().uuidString
        RecordingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/mobile/transcript/\(id)")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["transcriptId": id, "analysis": ["status": "done", "markdown": "真实结果"]])
        }
        let meeting = try await brain.meeting(id)
        XCTAssertEqual(meeting.analysis?.markdown, "真实结果")
        RecordingURLProtocol.handler = { _ in (200, ["transcriptId": UUID().uuidString]) }
        do { _ = try await brain.meeting(id); XCTFail("Wrong record must be rejected") } catch {}
    }

    @MainActor
    func testWebViewOriginChecksHostPortAndScheme() {
        let base = URL(string: "https://api.test/path")!
        XCTAssertTrue(SecureTranscriptWebView.Coordinator.sameOrigin(URL(string: "https://api.test:443/next")!, base))
        for target in ["http://api.test", "https://api.test.evil.com", "https://api.test:8443", "file:///etc/passwd"] {
            XCTAssertFalse(SecureTranscriptWebView.Coordinator.sameOrigin(URL(string: target)!, base))
        }
    }

    func testRetryPolicyIsBoundedAndDoesNotRetryPermanentErrors() {
        XCTAssertEqual(RetryPolicy.delay(attempt: 1), 30)
        XCTAssertEqual(RetryPolicy.delay(attempt: 200), 900)
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(RetryPolicy.isTransient(DeepBrainError.http("上传", 503, "")))
        XCTAssertFalse(RetryPolicy.isTransient(DeepBrainError.http("建会话", 400, "")))
        XCTAssertFalse(RetryPolicy.isTransient(TransferError.storage))
        XCTAssertFalse(RetryPolicy.isTransient(DeepBrainError.badResponse("failed")))
    }
}

@MainActor
final class CheckpointTests: XCTestCase {
    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShennaoCheckpointTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root)
    }

    func testResumeUsesOnlyDurablePacketBoundary() throws {
        try withDirectory { root in
            var checkpoint: DownloadCheckpoint? = try DownloadCheckpoint(recordID: "r", expected: 120, filename: "n.opus", directory: root)
            try checkpoint!.append(Array(repeating: 7, count: 59))
            try checkpoint!.flush()
            XCTAssertEqual(checkpoint!.manifest.committed, 40)
            checkpoint = nil
            let recovered = try DownloadCheckpoint(recordID: "r", expected: 120, filename: "n.opus", directory: root)
            XCTAssertEqual(recovered.received, 40)
            try recovered.append(Array(repeating: 8, count: 80))
            try recovered.flush(complete: true)
            XCTAssertEqual(try recovered.readComplete(), Data(Array(repeating: 7, count: 40) + Array(repeating: 8, count: 80)))
        }
    }

    func testCompleteCheckpointSurvivesRelaunch() throws {
        try withDirectory { root in
            var checkpoint: DownloadCheckpoint? = try DownloadCheckpoint(recordID: "r", expected: 80, filename: "n.opus", directory: root)
            try checkpoint!.append(Array(repeating: 4, count: 80))
            try checkpoint!.flush(complete: true)
            checkpoint = nil
            let recovered = try DownloadCheckpoint(recordID: "r", expected: 80, filename: "n.opus", directory: root)
            XCTAssertTrue(recovered.manifest.complete)
            XCTAssertEqual(try recovered.readComplete().count, 80)
        }
    }

    func testChangedDeviceFileCannotUseCheckpoint() throws {
        try withDirectory { root in
            _ = try DownloadCheckpoint(recordID: "r", expected: 80, filename: "n.opus", directory: root)
            XCTAssertThrowsError(try DownloadCheckpoint(recordID: "r", expected: 120, filename: "n.opus", directory: root))
            XCTAssertThrowsError(try DownloadCheckpoint(recordID: "r", expected: 80, filename: "other.opus", directory: root))
        }
    }

    func testCorruptedPartialFileIsPreservedAndRejected() throws {
        try withDirectory { root in
            var checkpoint: DownloadCheckpoint? = try DownloadCheckpoint(recordID: "r", expected: 80, filename: "n.opus", directory: root)
            try checkpoint!.append(Array(repeating: 4, count: 40))
            try checkpoint!.flush()
            let path = checkpoint!.file
            checkpoint = nil
            let corrupt = Data(repeating: 9, count: 40)
            try corrupt.write(to: path)
            XCTAssertThrowsError(try DownloadCheckpoint(recordID: "r", expected: 80, filename: "n.opus", directory: root))
            XCTAssertEqual(try Data(contentsOf: path), corrupt)
        }
    }

    func testTruncatedAndOversizedCannotBeCompleted() throws {
        try withDirectory { root in
            let checkpoint = try DownloadCheckpoint(recordID: "r", expected: 80, filename: "n.opus", directory: root)
            try checkpoint.append(Array(repeating: 1, count: 40))
            XCTAssertThrowsError(try checkpoint.flush(complete: true))
            XCTAssertThrowsError(try checkpoint.readComplete())
            XCTAssertThrowsError(try checkpoint.append(Array(repeating: 1, count: 41)))
            XCTAssertEqual(checkpoint.received, 40)
        }
    }

    func testDifferentAccountsHaveDifferentPartialFiles() throws {
        try withDirectory { root in
            let a = try DownloadCheckpoint(recordID: "account-a-record", expected: 80, filename: "n.opus", directory: root)
            let b = try DownloadCheckpoint(recordID: "account-b-record", expected: 80, filename: "n.opus", directory: root)
            XCTAssertNotEqual(a.file, b.file)
        }
    }
}

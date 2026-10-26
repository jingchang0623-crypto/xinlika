// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import XCTest
@testable import Xinlika

@MainActor
final class XinlikaUploadQueueTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private let server = "https://cloud.example.com"
    private func ledger(_ count: Int = 160, sessions: [String]? = nil) throws -> XinlikaCaptureStore {
        let messages = try (0..<count).map { i -> XinlikaCaptureStore.Message in
            let file = "message-\(i).json"
            try Data("{\"id\":\"message-\(i)\",\"evidence\":\"unchanged\"}".utf8).write(to: root.appendingPathComponent(file))
            return .init(id: "message-\(i)", file: file, sessionID: sessions?[i] ?? "session", serviceURL: server)
        }
        try JSONEncoder().encode(XinlikaCaptureStore.State(outbox: messages)).write(to: root.appendingPathComponent("capture.json"))
        return try XinlikaCaptureStore(root: root)
    }
    private func until(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(5)
        while !condition() && Date() < limit { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    func test160PendingEnvelopesDrainAfterNetworkFailureWithoutManualRetryOrReordering() async throws {
        let store = try ledger(), original = try Data(contentsOf: root.appendingPathComponent("message-0.json"))
        var sent: [String] = [], calls = 0, delays: [Double] = []
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { item in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            sent.append(item.id); return 200
        }, sleep: { seconds in delays.append(seconds); try await Task.sleep(for: .milliseconds(1)) })
        queue.start()
        try await until { !queue.isRunning }
        XCTAssertEqual(sent, (0..<160).map { "message-\($0)" })
        XCTAssertEqual(calls, 161); XCTAssertEqual(queue.acceptedCount, 160)
        XCTAssertEqual(store.snapshot().counts(for: server).pending, 0)
        XCTAssertEqual(store.snapshot().outbox[0].attempts, 2)
        XCTAssertEqual(delays, [2]); XCTAssertEqual(queue.phase, .idle)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("message-0.json")), original)
    }
    func testRepeatedDiskKicksDoNotBypassBackoffAndConnectivityWakeResumesIt() async throws {
        let store = try ledger(2); var calls = 0
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { _ in
            calls += 1; return calls == 1 ? 503 : 200
        })
        queue.start(); try await until { queue.phase == .waiting }
        for _ in 0..<100 { queue.start() }
        XCTAssertEqual(calls, 1)
        queue.wake(); try await until { !queue.isRunning }
        XCTAssertEqual(calls, 3); XCTAssertEqual(queue.acceptedCount, 2)
    }
    func testUnavailableResponseZeroIsRetriedRatherThanPermanentlyBlockingSession() async throws {
        let store = try ledger(2); var calls = 0
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { _ in
            calls += 1; return calls == 1 ? 0 : 200
        }, sleep: { _ in })
        queue.start(); try await until { !queue.isRunning }
        XCTAssertEqual(queue.acceptedCount, 2); XCTAssertEqual(store.snapshot().heldCount, 0)
    }
    func testConflictHoldsSameSessionButStillDrainsOtherSession() async throws {
        let store = try ledger(3, sessions: ["bad", "bad", "good"]); var sent: [String] = []
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { item in
            sent.append(item.id); return item.sessionID == "bad" ? 409 : 200
        })
        queue.start(); try await until { !queue.isRunning }
        XCTAssertEqual(sent, ["message-0", "message-2"])
        XCTAssertEqual(store.snapshot().heldCount, 2); XCTAssertEqual(store.snapshot().pendingCount, 0)
    }
    func testAuthFailureDoesNotAutomaticallyBurnThroughOtherRecordings() async throws {
        let store = try ledger(2, sessions: ["first", "second"]); var calls = 0
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { _ in
            calls += 1; return calls == 1 ? 401 : 200
        })
        queue.start(); try await until { !queue.isRunning }
        queue.start(); queue.wake()
        XCTAssertEqual(calls, 1); XCTAssertFalse(queue.isRunning)
        queue.wake(retryBlocked: true); try await until { !queue.isRunning }
        XCTAssertEqual(calls, 2); XCTAssertEqual(queue.acceptedCount, 1)
        XCTAssertEqual(store.snapshot().heldCount, 1)
    }
    func testRepeatedServiceFailuresKeepBackoffBoundedAndEventuallyResume() async throws {
        let store = try ledger(1); var calls = 0, delays: [Double] = []
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { _ in
            calls += 1; return calls <= 8 ? 503 : 200
        }, sleep: { seconds in delays.append(seconds) })
        queue.start(); try await until { !queue.isRunning }
        XCTAssertEqual(calls, 9); XCTAssertEqual(queue.acceptedCount, 1)
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30, 30, 30])
        XCTAssertEqual(store.snapshot().outbox[0].attempts, 9)
    }
    func testCancellingBackoffKeepsUnsentMessagesRecoverable() async throws {
        let store = try ledger(2)
        let queue = XinlikaUploadQueue(store: store, serviceURL: server, configurationKey: "test", send: { _ in 503 })
        queue.start(); try await until { queue.phase == .waiting }
        queue.cancel(); try await until { !queue.isRunning }
        XCTAssertEqual(store.snapshot().pendingCount, 2); XCTAssertEqual(queue.acceptedCount, 0)
    }
    func testUploadStatusCannotClaimAllUploadedWhile160Remain() {
        for phase in [XinlikaUploadQueue.Phase.idle, .uploading, .waiting, .blocked] {
            let text = XinlikaUploadPresentation.text(pending: 160, held: 0, phase: phase, status: 200,
                serviceReachable: true, processing: 0, hasResults: true)
            XCTAssertTrue(text.contains("160")); XCTAssertFalse(text.contains("已上传"))
        }
        let failed = XinlikaUploadPresentation.text(pending: 0, held: 0, phase: .idle, status: 200,
            serviceReachable: true, processing: 0, hasResults: true, failedProcessing: 3)
        XCTAssertTrue(failed.contains("3 项整理暂未完成"))
    }
}

private final class LivePostURLProtocol: URLProtocol {
    static var replies: [Result<Int, Error>] = []
    static var calls = 0
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        Self.requests.append(request)
        switch Self.replies.removeFirst() {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class XinlikaImmediatePostTests: XCTestCase {
    func testReceiptReuseAndContentChangesUseAuthenticatedImmediateTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LivePostURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let uploader = BackgroundUploader(directory: root, postSession: session)
        let file = root.appendingPathComponent("immutable.json")
        try Data("first".utf8).write(to: file)
        LivePostURLProtocol.calls = 0; LivePostURLProtocol.requests = []
        LivePostURLProtocol.replies = [.success(200), .success(200)]
        let url = URL(string: "https://cloud.example.com/v1/mobile/ingest")!
        let first = try await uploader.postFile(file, to: url, token: "test-token", identity: "same-id", attempt: 0)
        let cached = try await uploader.postFile(file, to: url, token: "test-token", identity: "same-id", attempt: 1)
        XCTAssertEqual(first, 200); XCTAssertEqual(cached, 200); XCTAssertEqual(LivePostURLProtocol.calls, 1)
        XCTAssertEqual(LivePostURLProtocol.requests[0].httpMethod, "POST")
        XCTAssertEqual(LivePostURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        try Data("changed".utf8).write(to: file)
        _ = try await uploader.postFile(file, to: url, token: "test-token", identity: "same-id", attempt: 1)
        XCTAssertEqual(LivePostURLProtocol.calls, 2, "A receipt must not validate different bytes")
    }
    func testNetworkFailureDoesNotCreateSuccessfulReceiptAndNextAttemptCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [LivePostURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let uploader = BackgroundUploader(directory: root, postSession: session)
        let file = root.appendingPathComponent("immutable.json"); try Data("evidence".utf8).write(to: file)
        LivePostURLProtocol.calls = 0; LivePostURLProtocol.replies = [.failure(URLError(.networkConnectionLost)), .success(200)]
        let url = URL(string: "https://cloud.example.com/v1/mobile/ingest")!
        do { _ = try await uploader.postFile(file, to: url, token: "test", identity: "id", attempt: 0); XCTFail("Expected network interruption") }
        catch { XCTAssertNotNil(error as? URLError) }
        _ = try await uploader.postFile(file, to: url, token: "test", identity: "id", attempt: 1)
        XCTAssertEqual(LivePostURLProtocol.calls, 2)
    }
}

import XCTest
@testable import Shennao

final class RecordingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (code, object) = try handler(request)
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: request.url!, statusCode: code,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class UploadContractTests: XCTestCase {
    private var session: URLSession!
    private var brain: DeepBrain!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        session = URLSession(configuration: config)
        brain = DeepBrain(config: DeepBrainConfig(apiBase: "https://api.test",
            supabaseUrl: "https://auth.test", supabaseAnonKey: "test-public-key"),
            captureClient: DeepBrain.fileImportClient, transport: session)
        brain.token = "test-token"
        brain.org = "test-org"
    }

    override func tearDown() {
        session.invalidateAndCancel()
        RecordingURLProtocol.handler = nil
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody {
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testFileImportContractAndStopBeforeFinalize() async throws {
        var paths: [String] = []
        var persisted = false
        RecordingURLProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            if path == "/api/recordings" {
                let json = try self.body(request)
                XCTAssertEqual(json["captureClient"] as? String, "upload")
                XCTAssertEqual(json["clientRequestId"] as? String, "stable-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-deepbrain-org-id"), "test-org")
                return (200, ["session": ["id": "s1", "status": "recording"]])
            }
            XCTAssertTrue(persisted, "Session ID must be saved before any upload")
            if path.hasSuffix("/ticket") {
                return (200, ["uploadUrl": "https://cos.test/object"])
            }
            if path == "/object" {
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            }
            return (200, [:])
        }
        let result = try await brain.upload(audio: [1, 2, 3], title: "test", durationSec: 1,
            clientRequestId: "stable-key", onSessionCreated: { sid in
                XCTAssertEqual(sid, "s1"); persisted = true
            })
        XCTAssertEqual(result.sessionId, "s1")
        XCTAssertEqual(paths, ["/api/recordings", "/api/recordings/s1/chunks/ticket",
            "/object", "/api/recordings/s1/chunks/0/complete",
            "/api/recordings/s1/stop", "/api/recordings/s1/finalize"])
    }

    func testSessionIdentitySurvivesTicketFailureAndRetryKeepsKey() async throws {
        var keys: [String] = []
        var storedID: String?
        RecordingURLProtocol.handler = { request in
            if request.url!.path == "/api/recordings" {
                keys.append(try self.body(request)["clientRequestId"] as! String)
                return (200, ["session": ["id": "same-session", "status": "recording"]])
            }
            return (503, ["error": "temporarily unavailable"])
        }
        for _ in 0..<2 {
            do {
                _ = try await brain.upload(audio: [1], title: "test", durationSec: 1,
                    clientRequestId: "same-key", onSessionCreated: { storedID = $0 })
                XCTFail("Must report failure")
            } catch {
                guard case DeepBrainError.http(_, 503, _) = error else {
                    return XCTFail("Unexpected \(error)")
                }
            }
        }
        XCTAssertEqual(storedID, "same-session")
        XCTAssertEqual(keys, ["same-key", "same-key"])
    }

    func testLocalPersistenceFailureStopsBeforeUploading() async throws {
        struct DiskFailure: Error {}
        var calls = 0
        RecordingURLProtocol.handler = { _ in
            calls += 1
            return (200, ["session": ["id": "s1", "status": "recording"]])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 1,
                clientRequestId: "key", onSessionCreated: { _ in throw DiskFailure() })
            XCTFail("Persistence error must propagate")
        } catch { XCTAssertTrue(error is DiskFailure) }
        XCTAssertEqual(calls, 1)
    }

    func testReadySessionDoesNotUploadAgain() async throws {
        var calls = 0
        RecordingURLProtocol.handler = { _ in
            calls += 1
            return (200, ["session": ["id": "s1", "status": "ready"]])
        }
        let result = try await brain.upload(audio: [1], title: "test", durationSec: 1, clientRequestId: "key")
        XCTAssertTrue(result.alreadyDone)
        XCTAssertEqual(calls, 1)
    }

    func testHTTP400DoesNotCreateLocalSessionIdentity() async throws {
        var storedID: String?
        RecordingURLProtocol.handler = { _ in
            (400, ["error": ["code": "INVALID_INPUT", "message": "采集端类型无效"]])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 1,
                clientRequestId: "key", onSessionCreated: { storedID = $0 })
            XCTFail("Must not succeed")
        } catch {
            guard case DeepBrainError.http(_, 400, let body) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertTrue(body.contains("采集端类型无效"))
        }
        XCTAssertNil(storedID)
    }

    func testVerifiedChunkRetrySkipsPUTAndStillFinalizes() async throws {
        var paths: [String] = []
        RecordingURLProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            if path == "/api/recordings" {
                return (200, ["session": ["id": "s1", "status": "uploading"]])
            }
            if path.hasSuffix("/ticket") {
                return (409, ["error": ["code": "CHUNK_ALREADY_VERIFIED"]])
            }
            return (200, [:])
        }
        _ = try await brain.upload(audio: [1], title: "test", durationSec: 1, clientRequestId: "key")
        XCTAssertEqual(paths, ["/api/recordings", "/api/recordings/s1/chunks/ticket",
            "/api/recordings/s1/stop", "/api/recordings/s1/finalize"])
    }

    func testFailedCloudSessionIsNotReportedAsCompleted() async throws {
        RecordingURLProtocol.handler = { _ in
            (200, ["session": ["id": "s1", "status": "failed"]])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 1, clientRequestId: "key")
            XCTFail("Failed session must not be treated as success")
        } catch {
            guard case DeepBrainError.badResponse = error else {
                return XCTFail("Unexpected \(error)")
            }
        }
    }

    func testResolveOrgDoesNotReusePreviousAccountCache() async throws {
        brain.org = "old-org"
        RecordingURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/rest/v1/memberships")
            XCTAssertTrue(request.url!.query!.contains("order=created_at.asc"))
            return (200, [["org_id": "new-org"]])
        }
        let org = try await brain.resolveOrg("new-token")
        XCTAssertEqual(org, "new-org")
    }

    func testBackgroundPartAdapterPreservesUploadContract() async throws {
        var paths: [String] = []
        var parts = 0
        RecordingURLProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            if path == "/api/recordings" {
                return (200, ["session": ["id": "s1", "status": "recording"]])
            }
            if path.hasSuffix("/ticket") { return (200, ["uploadUrl": "https://cos.test/part"]) }
            return (200, [:])
        }
        _ = try await brain.upload(audio: [1, 2, 3], title: "test", durationSec: 1,
            clientRequestId: "stable-key", uploadPart: { data, url, mime, key in
                parts += 1
                XCTAssertEqual(data, Data([1, 2, 3]))
                XCTAssertEqual(url.host, "cos.test")
                XCTAssertEqual(mime, "audio/ogg")
                XCTAssertEqual(key, "stable-key-0")
                return 200
            })
        XCTAssertEqual(parts, 1)
        XCTAssertFalse(paths.contains("/part"))
        XCTAssertEqual(Array(paths.suffix(2)), ["/api/recordings/s1/stop", "/api/recordings/s1/finalize"])
    }

    func testMissingHTTPResponseCannotConfirmChunk() async throws {
        var confirmed = false
        RecordingURLProtocol.handler = { request in
            if request.url!.path == "/api/recordings" {
                return (200, ["session": ["id": "s1", "status": "recording"]])
            }
            if request.url!.path.hasSuffix("/ticket") { return (200, ["uploadUrl": "https://cos.test/part"]) }
            confirmed = true
            return (200, [:])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 1,
                clientRequestId: "key", uploadPart: { _, _, _, _ in 0 })
            XCTFail("Missing HTTP response must fail")
        } catch {}
        XCTAssertFalse(confirmed)
    }

    func testDeletedAndUnknownSessionAreNotSuccess() async throws {
        for status in ["deleted", "deleting", "unknown"] {
            RecordingURLProtocol.handler = { _ in
                (200, ["session": ["id": "s1", "status": status]])
            }
            do {
                _ = try await brain.upload(audio: [1], title: "test", durationSec: 1, clientRequestId: "key")
                XCTFail("\(status) must not be treated as complete")
            } catch {}
        }
    }
    func testAdmissionDenialMakesNoNetworkRequests() async throws {
        var calls = 0
        RecordingURLProtocol.handler = { _ in calls += 1; return (200, [:]) }
        do {
            _ = try await brain.upload(audio: [1], title: "long", durationSec: 10800,
                clientRequestId: "key", checkContinuation: { throw CancellationError() })
            XCTFail("Must remain held")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
    }

    func testPauseAfterPUTStopsBeforeChunkCompleteAndFinalize() async throws {
        var paths: [String] = []
        var allowed = true
        RecordingURLProtocol.handler = { request in
            let path = request.url!.path; paths.append(path)
            if path == "/api/recordings" { return (200, ["session": ["id": "s1", "status": "recording"]]) }
            if path.hasSuffix("/ticket") { return (200, ["uploadUrl": "https://cos.test/object"]) }
            return (200, [:])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 600, clientRequestId: "key",
                uploadPart: { _, _, _, _ in allowed = false; return 200 },
                checkContinuation: { if !allowed { throw CancellationError() } })
            XCTFail("Pause must stop the next request")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(paths, ["/api/recordings", "/api/recordings/s1/chunks/ticket"])
    }

    func testPauseAfterStopPreventsFinalize() async throws {
        var paths: [String] = []
        var allowed = true
        RecordingURLProtocol.handler = { request in
            let path = request.url!.path; paths.append(path)
            if path == "/api/recordings" { return (200, ["session": ["id": "s1", "status": "recording"]]) }
            if path.hasSuffix("/ticket") { return (200, ["uploadUrl": "https://cos.test/object"]) }
            if path.hasSuffix("/stop") { allowed = false }
            return (200, [:])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 600, clientRequestId: "key",
                checkContinuation: { if !allowed { throw CancellationError() } })
            XCTFail("Finalization must be gated separately")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(paths.contains("/api/recordings/s1/stop"))
        XCTAssertFalse(paths.contains("/api/recordings/s1/finalize"))
    }

    func testVerifiedChunkCannotBypassPause() async throws {
        var paths: [String] = []
        var allowed = true
        RecordingURLProtocol.handler = { request in
            let path = request.url!.path; paths.append(path)
            if path == "/api/recordings" { return (200, ["session": ["id": "s1", "status": "uploading"]]) }
            allowed = false
            return (409, ["error": ["code": "CHUNK_ALREADY_VERIFIED"]])
        }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 600, clientRequestId: "key",
                checkContinuation: { if !allowed { throw CancellationError() } })
            XCTFail("Verified chunks cannot skip the stop gate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(paths.count, 2)
    }

    func testPauseOnUnauthorizedResponsePreventsAuthenticationRetry() async throws {
        var calls = 0
        var allowed = true
        RecordingURLProtocol.handler = { _ in calls += 1; allowed = false; return (401, [:]) }
        do {
            _ = try await brain.upload(audio: [1], title: "test", durationSec: 600, clientRequestId: "key",
                checkContinuation: { if !allowed { throw CancellationError() } })
            XCTFail("Pause also applies to the authentication retry path")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

}

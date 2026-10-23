// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

private func heartballRecordingDate(_ occurredAt: String?, _ recordedLocalTime: String?) -> Date? {
    if let occurredAt {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: occurredAt) ?? ISO8601DateFormatter().date(from: occurredAt) { return date }
    }
    guard let recordedLocalTime else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = .current
    return formatter.date(from: recordedLocalTime)
}

/// Separate local Heartball contract. It does not impersonate the DeepBrain API.
public struct HeartballState: Decodable, Equatable, Sendable {
    public struct Session: Decodable, Equatable, Sendable {
        public let id: String
        public let status: String
        public let audioSeconds: Double
        public let batchCount: Int
        public let gapCount: Int
        public let batchSeconds: Int
        public let ownedFile: String?
        public let error: String?
        public let archiveStatus: String
        public let clockStatus: String?
        public let clockVerifiedAt: String?
        public let clockTimezone: String?
    }
    public struct FocusRecord: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let status: String
        public let startedAt: String
        public let endedAt: String?
        public let audioSeconds: Double
        public let rangeCount: Int
        public let boundaryBasis: String
        public let processingStatus: String?
    }
    public struct Batch: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let sequence: Int
        public let audioSeconds: Double
        public let sha256: String
        public let reason: String
    }
    public struct Job: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let kind: String
        public let status: String
    }
    public let session: Session?
    public let focuses: [FocusRecord]
    public let batches: [Batch]
    public let jobs: [Job]
    public let asrEnabled: Bool
    public let captureLimitSeconds: Int?
    public let processingConfigured: Bool?
    public let agentConfigured: Bool?
}

public struct HeartballAgentState: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable {
        public struct Group: Decodable, Equatable, Sendable, Identifiable {
            public let id: String
            public let kind: String
            public let title: String
            public let summary: String?
            public let startLocal: String
            public let endLocal: String
            public let sessionCount: Int
            public let eventCount: Int
            public let focusCount: Int
            public let activityKind: String?
            public let events: [SemanticEvent]
        }
        public let date: String
        public let timeZone: String
        public let groups: [Group]
        public let eventCount: Int
        public let focusCount: Int
        public let unknownTimeCount: Int
    }
    public struct WorkspaceProgress: Decodable, Equatable, Sendable {
        public let receivedAt: String?
        public let organizedAt: String?
    }
    public struct SemanticEvent: Decodable, Equatable, Sendable, Identifiable {
        public struct Source: Decodable, Equatable, Sendable {
            public let documentId: String
            public let revision: Int
            public let quote: String
        }
        public let id: String
        public let sessionId: String
        public let kind: String
        public let title: String
        public let summary: String
        public let sourceKind: String
        public let occurredAt: String?
        public let recordedLocalTime: String?
        public let recordingTimeBasis: String?
        public let createdAt: String
        public let version: Int
        public let topicId: String?
        public let sources: [Source]
        public var recordingDate: Date? {
            heartballRecordingDate(occurredAt, recordedLocalTime)
        }

    }
    public struct Topic: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let summary: String
        public let version: Int
        public let eventIds: [String]
        public let conversationCount: Int
    }
    public struct Evidence: Decodable, Equatable, Sendable {
        public let batchId: String?
        public let startByte: Int?
        public let endByte: Int?
        public let precision: String?
    }
    public struct Document: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let kind: String
        public let sessionId: String?
        public let createdAt: String?
        public let occurredAt: String?
        public let recordedLocalTime: String?
        public let recordingTimeBasis: String?
        public let title: String
        public let summary: String
        public let text: String
        public let sourceKind: String
        public let status: String
        public let revision: Int
        public let boundaryQuality: String
        public let evidence: [Evidence]
        public let validationNotes: [String]
        public var recordingDate: Date? { heartballRecordingDate(occurredAt, recordedLocalTime) }
    }
    public struct Claim: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let documentId: String
        public let project: String
        public let kind: String
        public let statement: String
        public let owner: String
        public let dueAt: String?
        public let status: String
        public let quote: String
        public let version: Int
    }
    public struct Advice: Decodable, Equatable, Sendable, Identifiable {
        public struct Reference: Decodable, Equatable, Sendable { public let id: String; public let version: Int }
        public let id: String
        public let kind: String
        public let title: String
        public let body: String
        public let status: String
        public let evidence: [Reference]
    }
    public struct Job: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let kind: String
        public let status: String
        public let attempts: Int
        public let error: String?
    }
    public struct Answer: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let question: String
        public let answer: String
        public let status: String
        public let refs: [Advice.Reference]
    }
    public let documents: [Document]
    public let claims: [Claim]
    public let advice: [Advice]
    public let processingJobs: [Job]
    public let confirmedMemoryCount: Int
    public let answers: [Answer]
    public let events: [SemanticEvent]?
    public let topics: [Topic]?
    public let workspaceProgress: WorkspaceProgress?
    public let today: Day?
}

public actor HeartballClient {
    public struct MobileCapabilities: Decodable, Sendable {
        public let protocolVersion: Int
        public let maxBatchSeconds: Int
        public let hardwareControl: Bool
        public let asrConfigured: Bool?
        public let agentConfigured: Bool?
    }
    private struct Runtime: Decodable { let baseURL: URL; let token: String }
    private struct Failure: Decodable { let error: String }
    private let runtime: Runtime
    private let session: URLSession

    public init(runtimeFile: URL) throws {
        runtime = try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: runtimeFile))
        guard runtime.baseURL.scheme == "http", runtime.baseURL.host == "127.0.0.1",
              runtime.baseURL.user == nil, runtime.baseURL.password == nil else {
            throw URLError(.unsupportedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    /// Explicit mobile connection. Mac runtime-file initialization remains loopback-only.
    public init(baseURL: URL, token: String, allowPrivateHTTP: Bool = false) throws {
        guard baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, !token.isEmpty,
              baseURL.scheme == "https" || (allowPrivateHTTP && baseURL.scheme == "http") else { throw URLError(.unsupportedURL) }
        runtime = Runtime(baseURL: baseURL, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    private func request<T: Decodable>(_ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: runtime.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + runtime.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "本机服务暂不可用"
            throw NSError(domain: "Heartball", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    public struct VoiceStatus: Decodable, Sendable {
        public struct Sample: Decodable, Identifiable, Sendable {
            public let slot: Int
            public let status: String
            public let sessionId: String?
            public var id: Int { slot }
        }
        public let enrollmentId: String?
        public let status: String
        public let samples: [Sample]
        public let profileVersion: Int?
    }
    public func voiceState() async throws -> VoiceStatus { try await request("v1/voice") }
    public func beginVoiceEnrollment(id: UUID) async throws -> VoiceStatus {
        try await request("v1/voice", body: ["action":"begin", "id":id.uuidString.lowercased(), "consent":true])
    }
    public func bindVoiceSample(enrollment: String, slot: Int, session: String) async throws -> VoiceStatus {
        try await request("v1/voice", body: ["action":"bind", "enrollment_id":enrollment, "slot":slot, "session_id":session, "solo":true])
    }
    public func revokeVoiceEnrollment() async throws -> VoiceStatus { try await request("v1/voice", body: ["action":"revoke"]) }
    public struct CardSegments: Decodable, Sendable {
        public struct Segment: Decodable, Sendable { public let filename: String; public let bytes: Int; public let sha256: String; public let startedAt: String }
        public let segments: [Segment]
    }
    public func cardSegments(_ root: String) async throws -> CardSegments { try await request("v1/mobile/segments", query: [.init(name: "session_id", value: root)]) }
    public func state() async throws -> HeartballState { try await request("v1/state") }
    public func mobileCapabilities() async throws -> MobileCapabilities { try await request("v1/mobile/capabilities") }
    public func startCapture(id: UUID, batchSeconds: Int = 60, processing: Bool = false, sourceKind: String = "unknown") async throws -> HeartballState {
        var body: [String: Any] = ["id": id.uuidString.lowercased(), "batch_seconds": batchSeconds]
        if processing { body["processing"] = ["asr": true, "agent": true, "source_kind": sourceKind] }
        return try await request("v1/capture/start", body: body)
    }
    public func stopCapture(id: String) async throws -> HeartballState {
        try await request("v1/capture/stop", body: ["id": id])
    }
    public func startFocus(id: UUID, sessionID: String) async throws -> HeartballState {
        try await request("v1/focus/start", body: ["id": id.uuidString.lowercased(), "session_id": sessionID])
    }
    public func endFocus(id: String) async throws -> HeartballState {
        try await request("v1/focus/end", body: ["id": id])
    }
    public func agentState(on date: Date? = nil) async throws -> HeartballAgentState {
        // Resolve each refresh so midnight/time-zone changes roll Today over.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return try await request("v1/agent", query: [URLQueryItem(name: "day", value: formatter.string(from: date ?? .now)), URLQueryItem(name: "time_zone", value: TimeZone.current.identifier)])
    }
    public func feedback(target: String, action: String, version: Int? = nil, values: [String: String]? = nil) async throws -> HeartballAgentState {
        var body: [String: Any] = ["id": UUID().uuidString.lowercased(), "target_id": target, "action": action]
        if let version { body["expected_version"] = version }
        if let values {
            var edits: [String: Any] = values
            if values["due_at"] == "" { edits["due_at"] = NSNull() }
            body["values"] = edits
        }
        return try await request("v1/feedback", body: body)
    }
    public func submitText(_ text: String) async throws -> HeartballAgentState {
        try await request("v1/dialogues/text", body: ["id": UUID().uuidString.lowercased(), "session_id": UUID().uuidString.lowercased(),
            "text": text, "occurred_at": ISO8601DateFormatter().string(from: .now)])
    }
    public func askMemory(_ question: String) async throws -> HeartballAgentState {
        try await request("v1/memory/ask", body: ["id": UUID().uuidString.lowercased(), "question": question])
    }
    public func retryJob(id: String) async throws -> HeartballAgentState {
        try await request("v1/jobs/retry", body: ["id": id])
    }
    public func audio(batchID: String) async throws -> Data {
        guard let id = UUID(uuidString: batchID) else { throw URLError(.badURL) }
        var url = URLComponents(url: runtime.baseURL.appendingPathComponent("v1/audio"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "batch_id", value: id.uuidString.lowercased())]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + runtime.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

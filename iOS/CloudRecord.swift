import Foundation

/// Cloud metadata is a read-only view of existing work, never an upload request.
struct CloudRecord: Codable, Equatable {
    var sessionID: String?
    var transcriptID: String?
    var title: String
    var startedAt: Date?
    var durationSeconds: Double?
    var stage: String
    var headline: String?
    var problem: String?
    var updatedAt: Date?

    var key: String { transcriptID.map { "transcript:\($0)" } ?? "session:\(sessionID ?? "")" }
    var label: String {
        switch stage {
        case "recorded": "录音已保存"
        case "delivered": "转写中"
        case "transcribed": "转写完成"
        case "analyzed": "分析完成"
        case "failed": "云端处理失败"
        default: "云端状态待确认"
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" ? nil : value
    }
    private static func uuid(_ value: Any?) throws -> String? {
        guard let value = text(value) else { return nil }
        guard UUID(uuidString: value) != nil else { throw DeepBrainError.badResponse("云端记录标识无效") }
        return value.lowercased()
    }
    private static func duration(_ value: Any?, divisor: Double = 1) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue / divisor
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    static func sessions(_ data: Data) throws -> [CloudRecord] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["sessions"] as? [[String: Any]] else { throw DeepBrainError.badResponse("云端录音列表格式无效") }
        return try rows.map { row in
            guard let sid = try uuid(row["sessionId"]) else { throw DeepBrainError.badResponse("缺少云端会话标识") }
            return CloudRecord(sessionID: sid, transcriptID: try uuid(row["transcriptId"]),
                title: text(row["title"]) ?? "未命名录音", startedAt: date(row["startedAt"]),
                durationSeconds: duration(row["durationMs"], divisor: 1000),
                stage: text(row["stage"]) ?? "unknown", headline: text(row["headline"]), problem: text(row["problem"]))
        }
    }

    static func transcripts(_ data: Data) throws -> [CloudRecord] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DeepBrainError.badResponse("云端历史列表格式无效")
        }
        return try rows.map { row in
            guard let tid = try uuid(row["id"]) else { throw DeepBrainError.badResponse("缺少云端转写标识") }
            let status = text(row["status"])
            return CloudRecord(transcriptID: tid, title: text(row["title"]) ?? "未命名录音",
                startedAt: date(row["recorded_at"]) ?? date(row["created_at"]),
                durationSeconds: duration(row["audio_duration_sec"]),
                stage: status == "ready" ? "transcribed" : status == "failed" ? "failed" : "unknown",
                updatedAt: date(row["updated_at"]))
        }
    }

    static func combine(sessions: [CloudRecord], transcripts: [CloudRecord]) -> [CloudRecord] {
        var records: [String: CloudRecord] = [:]
        for record in sessions { records[record.key] = record }
        for transcript in transcripts {
            if var record = records[transcript.key] {
                record.title = transcript.title
                record.startedAt = transcript.startedAt ?? record.startedAt
                record.durationSeconds = transcript.durationSeconds ?? record.durationSeconds
                record.updatedAt = transcript.updatedAt
                records[transcript.key] = record
            } else { records[transcript.key] = transcript }
        }
        return records.values.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
}

enum CloudLibrary {
    /// Merge only within a verified account. Keep local audio, import decisions and IDs.
    static func merging(_ cloud: [CloudRecord], into records: [LedgerItem], scope: RecordScope) -> [LedgerItem] {
        var result = records
        for remote in cloud {
            let matches = result.filter { item in
                scope.contains(item) && ((remote.sessionID != nil && item.serverSessionId?.lowercased() == remote.sessionID) ||
                    (remote.transcriptID != nil && item.transcriptId?.lowercased() == remote.transcriptID))
            }.sorted { lhs, rhs in
                if lhs.isCloudOnly != rhs.isCloudOnly { return !lhs.isCloudOnly }
                return lhs.id < rhs.id
            }
            let newID = LedgerStore.sha256("cloud|\(scope.orgId)|\(scope.ownerKey)|\(remote.key)")
            var item = matches.first ?? LedgerItem(id: newID, orgId: scope.orgId, deviceId: "cloud",
                fileBase: remote.key, title: remote.title, durationSec: remote.durationSeconds ?? 0,
                expectedBytes: 0, receivedBytes: 0, localFilename: "\(newID).ogg", contentHash: "",
                state: remote.transcriptID == nil ? .processing : .ready, updatedAt: Date(),
                ownerKey: scope.ownerKey, autoUpload: false, importDisposition: .approved)
            if item.meeting == nil, let cached = matches.first(where: { $0.meeting != nil }) {
                item.meeting = cached.meeting; item.resultUpdatedAt = cached.resultUpdatedAt
            }
            if matches.contains(where: \.isIgnored) { item.importDisposition = .ignored; item.autoUpload = false }
            item.serverSessionId = item.serverSessionId ?? remote.sessionID
            item.transcriptId = item.transcriptId ?? remote.transcriptID
            if let previous = item.cloud,
               previous.stage != remote.stage || previous.updatedAt != remote.updatedAt {
                item.resultUpdatedAt = nil
            }
            item.cloud = remote
            item.title = remote.title
            if item.isCloudOnly {
                item.durationSec = remote.durationSeconds ?? 0
                item.state = remote.transcriptID == nil ? .processing : .ready
                item.autoUpload = false
            }
            let obsolete = Set(matches.filter { $0.isCloudOnly && $0.id != item.id }.map(\.id))
            result.removeAll { obsolete.contains($0.id) || $0.id == item.id }
            result.append(item)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension DeepBrain {
    func cloudRecords() async throws -> [CloudRecord] {
        guard let requestedOrg = org, UUID(uuidString: requestedOrg) != nil else { throw DeepBrainError.notLoggedIn }
        let (code, data) = try await authed("GET", "\(config.apiBase)/api/mobile/sessions", headers: { try authHeaders }, timeout: 20)
        guard (200..<300).contains(code) else { throw DeepBrainError.http("读取云端录音", code, "请稍后重试") }
        let sessions = try CloudRecord.sessions(data)
        var transcripts: [CloudRecord] = []
        var cursor: String?
        // A keyset cursor reaches the complete history without a latest-N cutoff.
        while true {
            try Task.checkCancellation()
            guard org == requestedOrg else { throw CancellationError() }
            var url = URLComponents(string: "\(configSupabaseURL)/rest/v1/transcripts")!
            url.queryItems = [
                .init(name: "org_id", value: "eq.\(requestedOrg)"),
                .init(name: "select", value: "id,title,created_at,recorded_at,audio_duration_sec,status,updated_at"),
                .init(name: "order", value: "id.asc"), .init(name: "limit", value: "100")
            ]
            if let cursor { url.queryItems?.append(.init(name: "id", value: "gt.\(cursor)")) }
            let (status, bytes) = try await authed("GET", url.url!.absoluteString, headers: { try restHeaders }, timeout: 20)
            guard (200..<300).contains(status) else { throw DeepBrainError.http("读取云端历史", status, "已保留上次记录，请稍后重试") }
            let page = try CloudRecord.transcripts(bytes)
            guard org == requestedOrg else { throw CancellationError() }
            if let cursor, page.contains(where: { ($0.transcriptID ?? "") <= cursor }) {
                throw DeepBrainError.badResponse("云端历史分页未前进")
            }
            transcripts.append(contentsOf: page)
            // Stop on an empty page, not on the requested page size: a server may
            // enforce a smaller maximum than the client's limit.
            guard let next = page.last?.transcriptID else { break }
            cursor = next
        }
        try Task.checkCancellation()
        return CloudRecord.combine(sessions: sessions, transcripts: transcripts)
    }
}

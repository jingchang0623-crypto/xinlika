import Foundation

struct Meeting: Codable, Equatable {
    struct Analysis: Codable, Equatable {
        var status: String
        var markdown: String?
        var methods: [String]
        var routingReason: String?
    }
    struct Judgment: Codable, Equatable, Identifiable {
        var id: String
        var statement: String
        var quote: String?
        var subject: String?
    }
    struct Commitment: Codable, Equatable, Identifiable {
        var id: String
        var statement: String
        var speaker: String?
        var dueDate: String?
    }
    var transcriptId: String
    var title: String
    var summary: String?
    var speakers: [String]
    var analysis: Analysis?
    var analysisAbsentReason: String?
    var judgments: [Judgment]
    var commitments: [Commitment]

    var analysisLabel: String {
        guard let analysis else { return "尚无分析" }
        switch analysis.status {
        case "done": return "分析完成"
        case "failed": return "分析失败"
        case "queued": return "等待分析"
        case "routing", "analyzing", "self_check", "persisting": return "分析中"
        default: return "分析状态待确认"
        }
    }
    var needsPolling: Bool {
        guard let analysis else { return analysisAbsentReason == nil }
        return ["queued", "routing", "analyzing", "self_check", "persisting"].contains(analysis.status)
    }
    static func parse(_ data: Data) throws -> Meeting {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tid = text(o["transcriptId"]) else { throw DeepBrainError.badResponse("缺少转写标识") }
        let a = o["analysis"] as? [String: Any]
        return Meeting(transcriptId: tid, title: text(o["title"]) ?? "未命名录音",
            summary: text(o["summary"]), speakers: (o["speakers"] as? [String]) ?? [],
            analysis: a.map { Analysis(status: text($0["status"]) ?? "unknown",
                markdown: text($0["markdown"]), methods: ($0["methods"] as? [String]) ?? [],
                routingReason: text($0["routingReason"])) },
            analysisAbsentReason: text(o["analysisAbsentReason"]),
            judgments: ((o["atoms"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
                guard let statement = text(row["statement"]) else { return nil }
                return Judgment(id: text(row["id"]) ?? "judgment-\(index)",
                    statement: statement, quote: text(row["quote"]), subject: text(row["subject"]))
            },
            commitments: ((o["commitments"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
                guard let statement = text(row["quote"]) else { return nil }
                return Commitment(id: text(row["id"]) ?? "commitment-\(index)", statement: statement,
                    speaker: text(row["speaker"]), dueDate: text(row["dueDate"]))
            })
    }
    private static func text(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "null" ? nil : clean
    }
}

extension DeepBrain {
    func meeting(_ transcriptId: String) async throws -> Meeting {
        guard UUID(uuidString: transcriptId) != nil else { throw DeepBrainError.badResponse("转写标识无效") }
        let (code, data) = try await authed("GET", "\(config.apiBase)/api/mobile/transcript/\(transcriptId)",
                                          headers: { try self.authHeaders }, timeout: 20)
        guard (200..<300).contains(code) else {
            throw DeepBrainError.http("读取分析", code, "暂时无法读取分析，请稍后重试")
        }
        let meeting = try Meeting.parse(data)
        guard meeting.transcriptId == transcriptId else { throw DeepBrainError.badResponse("分析记录不匹配") }
        return meeting
    }

    func startAnalysis(_ transcriptId: String) async throws {
        guard UUID(uuidString: transcriptId) != nil else { throw DeepBrainError.badResponse("转写标识无效") }
        let (code, _) = try await authed("POST",
            "\(config.apiBase)/api/mobile/transcript/\(transcriptId)/analyze",
            headers: { try self.authHeaders }, json: [:], timeout: 30)
        guard (200..<300).contains(code) else {
            throw DeepBrainError.http("开始分析", code,
                code == 409 ? "当前不能开始分析：可能已在处理或额度不足" : "分析提交失败，请稍后重试")
        }
    }

    func webEntry(_ transcriptId: String) async throws -> URL {
        guard UUID(uuidString: transcriptId) != nil else { throw DeepBrainError.badResponse("转写标识无效") }
        // Build the refresh-token body again after authentication refresh, never log it.
        var response: (Int, Data) = (0, Data())
        for attempt in 0..<2 {
            guard let refresh = TokenStore.get() else { throw DeepBrainError.notLoggedIn }
            response = try await request("POST", "\(config.apiBase)/api/mobile/web-ticket",
                headers: try authHeaders, json: ["refreshToken": refresh], timeout: 20)
            if response.0 != 401 || attempt == 1 { break }
            _ = try await authed("GET", "\(config.apiBase)/api/mobile/sessions",
                                headers: { try self.authHeaders }, timeout: 20)
        }
        guard (200..<300).contains(response.0),
              let o = try JSONSerialization.jsonObject(with: response.1) as? [String: Any],
              let ticket = o["ticket"] as? String, !ticket.isEmpty,
              var url = URLComponents(string: "\(config.apiBase)/api/mobile/web-open") else {
            throw DeepBrainError.badResponse("无法打开完整转写，请稍后重试")
        }
        url.queryItems = [URLQueryItem(name: "t", value: ticket),
                          URLQueryItem(name: "to", value: "/zh/transcript/\(transcriptId)")]
        guard let result = url.url else { throw DeepBrainError.invalidURL("网页地址无效") }
        return result
    }
}

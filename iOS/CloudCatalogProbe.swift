#if DEBUG
import Foundation

/// Explicit, read-only contract inspection using the phone's existing login.
enum CloudCatalogProbe {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--inspect-cloud-catalog") }

    static func run(config: AppConfig) async -> String {
        var report: [String: Any] = [:]
        do {
            let brain = DeepBrain(config: config.deepBrain)
            try await brain.connect()
            let (code, data) = try await brain.authed("GET", "\(config.apiBase)/api/mobile/sessions",
                                                     headers: { try brain.authHeaders }, timeout: 20)
            report["sessionsCode"] = code
            report["sessions"] = try JSONSerialization.jsonObject(with: data)
            if let org = brain.org {
                var url = URLComponents(string: "\(config.supabaseURL)/rest/v1/transcripts")!
                url.queryItems = [
                    .init(name: "org_id", value: "eq.\(org)"),
                    .init(name: "select", value: "id,title,created_at,recorded_at,audio_duration_sec,status,source_file_type,updated_at"),
                    .init(name: "order", value: "created_at.desc,id.desc"), .init(name: "limit", value: "100")
                ]
                let (status, bytes) = try await brain.authed("GET", url.url!.absoluteString,
                                                            headers: { try brain.restHeaders }, timeout: 20)
                report["transcriptsCode"] = status
                report["transcripts"] = try JSONSerialization.jsonObject(with: bytes)
            }
        } catch { report["errorCode"] = (error as NSError).code }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Shennao", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report).write(to: root.appendingPathComponent("cloud-catalog-inspection.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return "云端目录检查完成"
        } catch { return "目录检查日志保存失败" }
    }
}
#endif

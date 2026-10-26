import Foundation
import Security


/// Serialize refresh-token rotation across result polling and upload requests.
actor SessionRefreshGate {
    private var task: Task<Void, Error>?
    func run(_ operation: @escaping () async throws -> Void) async throws {
        if let task { return try await task.value }
        let current = Task { try await operation() }
        task = current
        defer { task = nil }
        try await current.value
    }
}

/// 深脑客户端。走现成的录音链路，不需要给深脑加任何接口。
///
/// 认证用「原生端 Bearer」通道（深脑 lib/recording/route-context.ts 明确支持）：
///   Authorization: Bearer <supabase access token> + x-deepbrain-org-id
///
/// 上传六步：建会话 → 要分片地址 → 直传 COS → 确认分片 → **stop 冻结清单** → finalize。
/// 漏掉 stop，finalize 必然 409「录音尚未冻结分片数量」。
public struct DeepBrainConfig: Codable {
    public let apiBase: String
    public let supabaseUrl: String
    public let supabaseAnonKey: String

    public static func load(from url: URL) throws -> DeepBrainConfig {
        try JSONDecoder().decode(DeepBrainConfig.self, from: Data(contentsOf: url))
    }
}

public enum DeepBrainError: Error, CustomStringConvertible {
    case notLoggedIn
    case http(String, Int, String)
    case badResponse(String)
    case invalidURL(String)
    case credentialStorage
    /// 录音链路来的转写是「权威数据」，深脑只允许服务端改。
    case canonicalReadOnly
    /// 这条已经分析过：改名要连原子主语、决策归属一起重挂，只能走网页。
    case alreadyAnalyzed

    public var description: String {
        switch self {
        case .notLoggedIn: return "尚未登录深脑"
        case .http(let what, let code, let body): return "\(what) 失败 HTTP \(code)：\(body.prefix(200))"
        case .badResponse(let s): return "应答不符合预期：\(s)"
        case .invalidURL(let s): return "网络地址无效：\(s)"
        case .credentialStorage: return "登录凭证保存失败，请解锁设备后重试"
        case .canonicalReadOnly:
            return "这条录音的说话人只能在深脑网页里指认——录音链路的数据是权威数据，客户端改不了。"
        case .alreadyAnalyzed:
            return "这条已经分析过了，改名要连洞察里的归属一起重挂，得在深脑网页里改。"
        }
    }
}

/// 钥匙串。与 Python 版共用同一个服务名，登录状态互通。
public enum Keychain {
    public static let service = "deepbrain-importer"

    public static func get(_ account: String = "refresh_token") -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ value: String, account: String = "refresh_token") -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

public final class DeepBrain {
    // 模块内可见：Speakers.swift 里的扩展要用（Swift 的 private 是文件级的）
    let config: DeepBrainConfig
    var token: String?
    var org: String?
    /// transcript_id -> recording_session_id。指认接口按会话寻址，而 App 全程拿的是
    /// transcript_id；这个映射一条录音只查一次。
    var sessionIdCache: [String: String] = [:]
    private let captureClient: String
    public static let fileImportClient = "upload"
    private let transport: URLSession
    private let refreshGate = SessionRefreshGate()
    private var connectedAt: Date?

    public init(config: DeepBrainConfig, captureClient: String = "macos", transport: URLSession? = nil) {
        self.config = config
        self.captureClient = captureClient
        self.transport = transport ?? Self.session
    }

    /// 真实录音时刻用 ISO8601 传给深脑。
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 专用会话：**绕开系统代理**。
    ///
    /// 深脑跑在国内服务器上（122.51.221.171）。这台 Mac 常年开着翻墙代理
    /// （HTTP/HTTPS/SOCKS 全指 127.0.0.1:7897），而 URLSession.shared 默认跟随系统代理——
    /// 于是本该 147ms 直达的请求被绕进代理，21 MB 的分片上传中途就断，
    /// 日志里只留下 "The network connection was lost."，看起来像深脑挂了。
    ///
    /// 实测：直连 147ms / 200，走代理反复失败。国内的自家服务器没有任何理由走代理。
    /// `connectionProxyDictionary = [:]` 是显式清空，不是"用默认"——默认就是跟随系统。
    ///
    /// 超时给得比默认长：录音分片单个可以到几 MB，弱网下 60s 的默认请求超时不够。
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 3600      // 三小时录音整体上传的上限
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    // MARK: - HTTP
    func request(_ method: String, _ url: String, headers: [String: String] = [:],
                         json: Any? = nil, body: Data? = nil,
                         timeout: TimeInterval = 300) async throws -> (Int, Data) {
        guard let endpoint = URL(string: url), endpoint.scheme == "https" else {
            throw DeepBrainError.invalidURL(url)
        }
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.httpBody = body
        }
        let (data, resp) = try await transport.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func json(_ status: Int, _ data: Data, _ what: String) throws -> Any {
        guard status < 400 else {
            throw DeepBrainError.http(what, status, String(decoding: data, as: UTF8.self))
        }
        return try JSONSerialization.jsonObject(with: data.isEmpty ? Data("{}".utf8) : data)
    }

    // MARK: - 认证
    public func connect() async throws {
        try await refreshGate.run {
            if self.token != nil, self.org != nil, let connectedAt = self.connectedAt,
               Date().timeIntervalSince(connectedAt) < 300 { return }
            try await self.refreshSession()
        }
    }

    private func refreshSession() async throws {
        guard let refresh = TokenStore.get() else { throw DeepBrainError.notLoggedIn }
        let (st, data) = try await request(
            "POST", "\(config.supabaseUrl)/auth/v1/token?grant_type=refresh_token",
            headers: ["apikey": config.supabaseAnonKey], json: ["refresh_token": refresh], timeout: 20)
        guard st < 400, let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = d["access_token"] as? String else {
            throw DeepBrainError.http("刷新登录", st, "登录已失效，请重新登录")
        }
        try Task.checkCancellation()
        if let newRefresh = d["refresh_token"] as? String,
           !TokenStore.set(newRefresh) { throw DeepBrainError.credentialStorage }
        token = access
        org = try await resolveOrg(access)
        connectedAt = Date()
    }

    func resolveOrg(_ access: String) async throws -> String {
        // 2026-09-02 事故（先在安卓端撞上，这里是同一处漏洞的另一份实现）：
        // 查询原来没有 order by，账号如果有多条 membership，PostgREST
        // 不保证返回顺序——选到哪个组织全凭运气，选错了不会报任何错，
        // 只是那之后每一次查询都在查一个没有数据的空组织。
        // 这里比安卓端更危险：选中的结果会被 TokenStore 缓存写进
        // credentials.json，选错一次就永久错下去，直到手动 TokenStore.clear()。
        // 加 order=created_at.asc：最早那条 membership 几乎总是账号真正在用的那个。
        let (st, data) = try await request(
            "GET", "\(config.supabaseUrl)/rest/v1/memberships?select=org_id&order=created_at.asc&limit=1",
            headers: ["apikey": config.supabaseAnonKey, "Authorization": "Bearer \(access)"], timeout: 20)
        guard let rows = try json(st, data, "查询组织") as? [[String: Any]],
              let oid = rows.first?["org_id"] as? String else {
            throw DeepBrainError.badResponse("这个账号没有任何组织")
        }
        return oid
    }

    /// 直连 PostgREST 用的头（走用户登录态 + RLS），与走深脑 API 的 authHeaders 不同。
    var restHeaders: [String: String] {
        get throws {
            guard let token else { throw DeepBrainError.notLoggedIn }
            return ["apikey": config.supabaseAnonKey, "Authorization": "Bearer \(token)"]
        }
    }

    var configSupabaseURL: String { config.supabaseUrl.hasSuffix("/")
        ? String(config.supabaseUrl.dropLast()) : config.supabaseUrl }

    // 模块内可见：Speakers.swift 里的指认接口也走深脑 API 通道
    /// 带自动续期的请求。**所有需要登录的调用都该走它。**
    ///
    /// Supabase 的 access token 只活一小时，而 `connect()` 只在启动时刷新一次，
    /// 之后一直用同一个。于是开着 App 超过一小时之后：
    ///   · 直连 Supabase 的查询回 401 `JWT expired`（界面上是红字报错）
    ///   · 推送用的是同一个 token → **「推送卡住」**
    /// 两个现象同一个根因。2026-09-01 用户截图里就是这一条。
    ///
    /// 只续一次：续了还是 401 说明真的登录失效了，反复续只会空转，
    /// 而正确的做法是让用户重新登录。
    func authed(_ method: String, _ url: String,
                headers: () throws -> [String: String],
                json: Any? = nil, body: Data? = nil,
                timeout: TimeInterval = 300,
                checkContinuation: (() async throws -> Void)? = nil) async throws -> (Int, Data) {
        try Task.checkCancellation()
        try await checkContinuation?()
        var (st, data) = try await request(method, url, headers: try headers(),
                                           json: json, body: body, timeout: timeout)
        if st == 401 {
            try Task.checkCancellation()
            try await checkContinuation?()
            connectedAt = nil
            try await connect()
            // headers 是个闭包，重算一次才能拿到刚续出来的 token。
            // 传值进来的话，重试用的还是那个已经过期的。
            try Task.checkCancellation()
            try await checkContinuation?()
            (st, data) = try await request(method, url, headers: try headers(),
                                           json: json, body: body, timeout: timeout)
        }
        return (st, data)
    }

    var authHeaders: [String: String] {
        get throws {
            guard let token, let org else { throw DeepBrainError.notLoggedIn }
            return ["Authorization": "Bearer \(token)", "x-deepbrain-org-id": org]
        }
    }

    // MARK: - 上传
    public struct UploadResult {
        public let sessionId: String
        public let chunks: Int
        /// 会话此前已完成，本次是幂等重放，什么都没重传。
        public let alreadyDone: Bool
    }

    /// 单片上限 8MB（与深脑 service.ts 的 MAX_CHUNK_BYTES 对齐）。
    /// 1 小时录音的 opus 约 7.2MB，通常一片装得下。
    public static let maxChunkBytes = 8 * 1024 * 1024

    /// 上传一条录音。
    ///
    /// `startedAt` 是**录音发生的时刻**，不是上传时刻。不传的话深脑那边
    /// `recording_sessions.started_at` 走的是 `default now()`——于是一条昨天下午的会
    /// 在深脑里显示成今天中午，因为那才是它被推上去的时间。真实时刻就写在文件名里
    /// （note20260829-170356），从来只是没传过去。
    public func upload(audio: [UInt8], title: String, durationSec: Double,
                       clientRequestId: String, mime: String = "audio/ogg",
                       startedAt: Date? = nil,
                       projectId: String? = nil,
                       onSessionCreated: ((String) async throws -> Void)? = nil,
                       uploadPart: ((Data, URL, String, String) async throws -> Int)? = nil,
                       checkContinuation: (() async throws -> Void)? = nil,
                       onStep: ((String) -> Void)? = nil) async throws -> UploadResult {
        func check() async throws {
            try Task.checkCancellation()
            try await checkContinuation?()
        }
        try await check()
        onStep?("建会话")
        let (st1, d1) = try await authed("POST", "\(config.apiBase)/api/recordings", headers: { try self.authHeaders }, json: [
            "clientRequestId": clientRequestId,      // 幂等键：同一文件重传不会建两个会话
            "title": title, "captureClient": captureClient, "capabilities": ["mic"],
            // 服务端目前还不收这个字段，多传无害；等接口加上就自动生效。
            // 先从客户端把真相带上，比等两边同时改要稳。
        ].merging(startedAt.map { ["startedAt": Self.iso.string(from: $0)] } ?? [:]) { a, _ in a }
         .merging(projectId.map { ["projectId": $0] } ?? [:]) { a, _ in a }, checkContinuation: checkContinuation)
        guard let o1 = try json(st1, d1, "建会话") as? [String: Any],
              let session = o1["session"] as? [String: Any],
              let sid = session["id"] as? String else { throw DeepBrainError.badResponse("建会话没返回 id") }
        // 本地先持久化会话身份，后续失败也能查询同一个会话。
        try await onSessionCreated?(sid)

        // clientRequestId 是幂等键：同一文件重推会拿回同一个会话。
        // 如果它早已 stop/finalize，就不能再塞分片了（服务端会 409 INVALID_STATE）——
        // 这不是错误，是「已经做完了」。直接返回，别把重试变成失败。
        let existing = session["status"] as? String ?? ""
        // failed 不是「已经做完了」。以前这里把它一并当成完成，于是一条失败的会话
        // 会永远挡住重传——客户端每次都拿回同一个 failed 会话，报「无需重传」，
        // 而那条录音其实一个字都没进深脑。失败必须抛出来让人看见。
        if existing == "failed" {
            throw DeepBrainError.badResponse(
                "深脑那边这条会话是 failed 状态（\(sid)）。它挡着重传——"
                + "换一个幂等键重推，或先在深脑里删掉这条会话。")
        }
        if !["recording", "uploading"].contains(existing) {
            guard ["queued", "finalizing", "ready"].contains(existing) else {
                throw DeepBrainError.badResponse("会话状态 \(existing) 不支持上传，请检查云端记录")
            }
            onStep?("会话已是 \(existing)，无需重传")
            return UploadResult(sessionId: sid, chunks: session["expected_chunk_count"] as? Int ?? 0,
                                alreadyDone: true)
        }

        let totalMs = max(1, Int(durationSec * 1000))
        let parts = stride(from: 0, to: audio.count, by: Self.maxChunkBytes).map {
            Array(audio[$0..<min($0 + Self.maxChunkBytes, audio.count)])
        }
        for (seq, part) in parts.enumerated() {
            try await check()
            onStep?("分片 \(seq + 1)/\(parts.count)")
            let started = totalMs * seq / parts.count
            let ended = max(totalMs * (seq + 1) / parts.count, started + 1)
            let (st2, d2) = try await authed(
                "POST", "\(config.apiBase)/api/recordings/\(sid)/chunks/ticket",
                headers: { try self.authHeaders }, json: [
                    "sequence": seq, "idempotencyKey": "\(clientRequestId)-\(seq)",
                    "mimeType": mime, "byteLength": part.count,
                    "startedAtMs": started, "endedAtMs": ended, "uploadMode": "background",
                ], checkContinuation: checkContinuation)
            if st2 == 409, String(decoding: d2, as: UTF8.self).contains("CHUNK_ALREADY_VERIFIED") {
                onStep?("分片 \(seq + 1) 已在服务端，跳过")     // 重试时的正常情况
                continue
            }
            guard let ticket = try json(st2, d2, "申请上传地址") as? [String: Any],
                  let uploadUrl = ticket["uploadUrl"] as? String else {
                throw DeepBrainError.badResponse("ticket 没有 uploadUrl")
            }
            let st3: Int
            try await check()
            if let uploadPart {
                guard let endpoint = URL(string: uploadUrl), endpoint.scheme == "https" else {
                    throw DeepBrainError.invalidURL("上传地址不是 HTTPS")
                }
                st3 = try await uploadPart(Data(part), endpoint, mime, "\(clientRequestId)-\(seq)")
            } else {
                st3 = try await request("PUT", uploadUrl,
                    headers: ["Content-Type": mime], body: Data(part), timeout: 600).0
            }
            guard (200..<300).contains(st3) else {
                throw DeepBrainError.http("直传 COS", st3, "文件上传失败，请重新取票重试")
            }
            try await check()
            let (st4, d4) = try await authed(
                "POST", "\(config.apiBase)/api/recordings/\(sid)/chunks/\(seq)/complete",
                headers: { try self.authHeaders }, json: [:], checkContinuation: checkContinuation)
            _ = try json(st4, d4, "确认分片 \(seq)")
        }

        // 必须先 stop 冻结「分片总数 + 时长」，否则 finalize 会 409。
        // 这是深脑录音链路的核心不变量：清单一旦冻结，后到的分片再也进不来。
        onStep?("冻结清单")
        try await check()
        let (st5, d5) = try await authed("POST", "\(config.apiBase)/api/recordings/\(sid)/stop",
                                         headers: { try self.authHeaders },
                                         json: ["durationMs": totalMs, "expectedChunkCount": parts.count], checkContinuation: checkContinuation)
        _ = try json(st5, d5, "冻结清单")

        onStep?("收尾")
        try await check()
        let (st6, d6) = try await authed("POST", "\(config.apiBase)/api/recordings/\(sid)/finalize",
                                         headers: { try self.authHeaders }, json: [:], checkContinuation: checkContinuation)
        _ = try json(st6, d6, "收尾")
        return UploadResult(sessionId: sid, chunks: parts.count, alreadyDone: false)
    }

    public struct SessionState {
        public let status: String
        public let transcriptId: String?
        public let errorCode: String?
    }

    /// CB08 等自带硬件的一步式绑定（spec 019）。deviceNo 是用户现起的名字，
    /// 不是设备自己报的号——CB08 没有真实序列号。
    ///
    /// `.deviceTaken` 单独区分出来：那不是网络失败，是"这个名字已经被
    /// 另一个账号绑过了"，调用方要能就地换个名字重试，而不是报一句
    /// 笼统的"失败了"。
    public enum DeviceBindOutcome {
        case ok
        case deviceTaken
        case failed(String)
    }

    public func selfRegisterDevice(provider: String, deviceNo: String) async -> DeviceBindOutcome {
        do {
            let (st, data) = try await authed(
                "POST", "\(config.apiBase)/api/devices/self-register",
                headers: { try self.authHeaders },
                json: ["provider": provider, "deviceNo": deviceNo])
            if st < 400 { return .ok }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = obj?["error"] as? String
            switch code {
            case "device_taken": return .deviceTaken
            case "device_no_invalid": return .failed("这个名字里有空格或特殊字符，换一个")
            default: return .failed("绑定失败（HTTP \(st)）")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func sessionState(_ id: String) async throws -> SessionState {
        // 2026-09-02 事故：这里原来走的是 request()（只用当时那份 token，
        // 401 也不会重试），而它是 Monitor 后台轮询循环里的调用点——
        // 会话开着超过一小时，access token 过期之后，同一批会话 id
        // 会以 46 秒一轮的节奏被永久 401 下去，而 refreshBrainStatus 的
        // `try?` 把每一次失败都悄悄吞掉，界面上什么都不会显示，
        // 用户唯一能看到的是"分析状态一直不更新"，看不出原因。
        // upload() 那批调用今天早些时候已经改成 authed()，这条路径漏改了。
        let (st, d) = try await authed("GET", "\(config.apiBase)/api/recordings/\(id)",
                                        headers: { try self.authHeaders })
        guard let o = try json(st, d, "查会话") as? [String: Any],
              let s = o["session"] as? [String: Any] else { throw DeepBrainError.badResponse("没有 session") }
        return SessionState(status: s["status"] as? String ?? "未知",
                            transcriptId: s["final_transcript_id"] as? String,
                            errorCode: s["last_error_code"] as? String)
    }
}

public extension DeepBrain {
    /// 用邮箱密码登录，换回 refresh token 存进钥匙串。
    ///
    /// 在此之前 Swift 版没有登录能力——靠 Python 版留下的钥匙串条目活着，
    /// 换一台机器直接跑不起来。这是"给别人用"的硬阻塞。
    ///
    /// 密码只用于换 token，不落盘、不打印、不进日志。
    func signIn(email: String, password: String) async throws {
        let (st, data) = try await request(
            "POST", "\(configSupabaseURL)/auth/v1/token?grant_type=password",
            headers: ["apikey": config.supabaseAnonKey],
            json: ["email": email, "password": password])
        guard st < 400,
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = d["refresh_token"] as? String,
              let access = d["access_token"] as? String else {
            let body = String(decoding: data, as: UTF8.self)
            // 不要把服务端原文直接抛给用户——里面可能带邮箱
            throw DeepBrainError.http("登录", st,
                body.contains("Invalid login") ? "邮箱或密码不对" : "登录失败")
        }
        let resolvedOrg = try await resolveOrg(access)
        guard TokenStore.saveSession(refresh: refresh, email: email, orgId: resolvedOrg) else {
            throw DeepBrainError.credentialStorage
        }
        token = access
        org = resolvedOrg
    }

    /// 退出：清掉钥匙串里的凭证。
    func signOut() {
        connectedAt = nil
        TokenStore.clear()
        token = nil
        org = nil
    }

    static var signedInEmail: String? { TokenStore.get("email") }
    static var hasCredentials: Bool { TokenStore.get() != nil }
}

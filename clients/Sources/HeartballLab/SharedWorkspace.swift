// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import LuyinbiCore

struct SharedWorkspaceConnection: Codable, Sendable {
    let baseURL: URL
    let token: String

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XinlikaOpenSource/shared-connection.json")
    }
    static func allows(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host else { return false }
        if url.scheme == "https" { return true }
        guard url.scheme == "http" else { return false }
        if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { (0...255).contains($0) } &&
            (parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
    }
    func save(to file: URL) throws {
        guard Self.allows(baseURL), !token.isEmpty else { throw URLError(.unsupportedURL) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

actor SharedWorkspaceClient {
    private struct Capabilities: Decodable { let protocolVersion: Int; let workspaceMode: String; let hardwareControl: Bool }
    private struct Snapshot: Decodable { let revision: Int; let viewKey: String; let changed: Bool; let state: HeartballAgentState? }
    private struct Failure: Decodable { let error: String }
    nonisolated let content: HeartballClient
    private let connection: SharedWorkspaceConnection
    private let session: URLSession
    private var cursor: Int?
    private var viewKey: String?

    init(_ connection: SharedWorkspaceConnection) throws {
        guard SharedWorkspaceConnection.allows(connection.baseURL) else { throw URLError(.unsupportedURL) }
        self.connection = connection
        content = try HeartballClient(baseURL: connection.baseURL, token: connection.token, allowPrivateHTTP: true)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 10
        session = URLSession(configuration: settings)
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "共享服务暂时无法连接"
            throw NSError(domain: "XinlikaShared", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    func validate() async throws {
        let capabilities: Capabilities = try await get("v1/shared/capabilities")
        guard capabilities.protocolVersion == 1, capabilities.workspaceMode == "single_user", !capabilities.hardwareControl else {
            throw URLError(.badServerResponse)
        }
    }
    func refresh(reset: Bool = false) async throws -> HeartballAgentState? {
        if reset { cursor = nil; viewKey = nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        var query = [URLQueryItem(name: "day", value: formatter.string(from: .now)), URLQueryItem(name: "time_zone", value: TimeZone.current.identifier)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: String(cursor))) }
        if let viewKey { query.append(URLQueryItem(name: "view", value: viewKey)) }
        do {
            let snapshot: Snapshot = try await get("v1/shared/sync", query: query)
            guard snapshot.revision >= 0, snapshot.changed == (snapshot.state != nil) else { throw URLError(.badServerResponse) }
            if let cursor, snapshot.revision < cursor { return nil }
            cursor = snapshot.revision; viewKey = snapshot.viewKey
            return snapshot.state
        } catch let error as NSError where error.domain == "XinlikaShared" && error.code == 409 && !reset {
            // Restored/replaced server state requires a fresh authoritative snapshot.
            return try await refresh(reset: true)
        }
    }
}

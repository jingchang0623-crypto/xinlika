// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

struct XinlikaConnection: Codable, Equatable {
    var baseURL: URL
    var token: String
    static var file: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["XINLIKA_TEST_NAMESPACE"], UUID(uuidString: name) != nil {
            return root.appendingPathComponent("XinlikaUITests/\(name)/connection.json")
        }
        #endif
        return root.appendingPathComponent("Xinlika/connection.json")
    }
    static func isAllowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host else { return false }
        if url.scheme == "https" { return true }
        guard url.scheme == "http" else { return false }
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && (octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])))
    }
    func save() throws {
        guard Self.isAllowed(baseURL), !token.isEmpty, baseURL.query == nil, baseURL.fragment == nil else { throw TransferError.invalidAddress }
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
    static func load() -> Self? { try? JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) }
}

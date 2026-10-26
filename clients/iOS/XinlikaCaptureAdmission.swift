// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// Persist the user's selected card and capture options across tabs and launches.
struct XinlikaCapturePreferences: Codable, Equatable {
    var deviceID: UUID?
    var deviceName: String?
    var source = "unknown"
    var processing = true
    var automaticHardwareCapture = true

    private static let key = "Xinlika.CapturePreferences.v1"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Read-only admission. A key notification alone never establishes an active file.
enum XinlikaCaptureAdmission {
    struct Reading {
        var state: UInt8?
        var filename: String?
        var seconds: Int?
    }
    static func fileKey(_ name: String) -> String { name.lowercased().split(separator: ".").first.map(String.init) ?? "" }
    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= Proto.filenameFieldLen && !name.contains("/") && !name.contains("\\") &&
            !name.contains("\0") && !fileKey(name).isEmpty
    }
    static func confirmedFile(first: Reading, second: Reading) -> String? {
        guard first.state == 1, second.state == 1,
              let name = first.filename, let after = second.filename,
              validFilename(name), validFilename(after), fileKey(name) == fileKey(after),
              let beforeSeconds = first.seconds, let afterSeconds = second.seconds,
              beforeSeconds >= 0, afterSeconds > beforeSeconds else { return nil }
        return after
    }
    static func confirm(read: () async throws -> Reading,
                        settle: () async throws -> Void = { try await Task.sleep(for: .milliseconds(1100)) }) async throws -> String? {
        let first = try await read()
        guard first.state == 1 else { return nil }
        try await settle()
        try Task.checkCancellation()
        let second = try await read()
        try Task.checkCancellation()
        return confirmedFile(first: first, second: second)
    }
}

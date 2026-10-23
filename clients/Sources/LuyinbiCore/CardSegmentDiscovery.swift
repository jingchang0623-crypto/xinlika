// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import CryptoKit

/// Read-only candidates, not permission to stop a file or a claim of seamless audio.
public enum CardSegmentDiscovery {
    public struct File: Equatable, Sendable {
        public let name: String
        public let bytes: Int
        public init(name: String, bytes: Int) { self.name = name; self.bytes = bytes }
    }
    public static func canonical(_ name: String) -> String { String(name.lowercased().split(separator: ".").first ?? "") + ".opus" }
    public static func clock(_ name: String) -> Date? {
        let name = canonical(name)
        guard name.count == 24, name.hasPrefix("note"), name.hasSuffix(".opus") else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "'note'yyyyMMdd-HHmmss'.opus'"; f.isLenient = false
        guard let date = f.date(from: name), f.string(from: date) == name else { return nil }; return date
    }
    public static func next(after previous: File, rootFile: String, startedAt: Date, endedAt: Date, files: [File]) -> File? {
        guard (21600000...21608000).contains(previous.bytes), previous.bytes % 40 == 0,
              let p = clock(previous.name), let root = clock(rootFile) else { return nil }
        let candidates = files.filter { item in
            guard item.bytes > 0, item.bytes % 40 == 0, item.bytes <= 172800000, let date = clock(item.name), date > p else { return false }
            let delta = date.timeIntervalSince(p) - Double(previous.bytes) / 2000
            let start = startedAt.addingTimeInterval(date.timeIntervalSince(root))
            return (-2...3).contains(delta) && start < endedAt && start.addingTimeInterval(Double(item.bytes) / 2000) <= endedAt.addingTimeInterval(3)
        }
        guard candidates.count == 1 else { return nil }; return candidates[0]
    }
    public static func id(root: String, filename: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(("xinlika-card-segment:" + root + ":" + canonical(filename)).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        return [String(h.prefix(8)), String(h.dropFirst(8).prefix(4)), String(h.dropFirst(12).prefix(4)), String(h.dropFirst(16).prefix(4)), String(h.suffix(12))].joined(separator: "-")
    }
}

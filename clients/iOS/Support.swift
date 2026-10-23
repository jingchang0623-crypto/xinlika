// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import OSLog

enum CaptureDigest {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

enum Diagnostics {
    private static let logger = Logger(subsystem: "org.xinlika.ios", category: "capture")
    static func event(_ name: String, record: String? = nil, bytes: Int? = nil, error: Error? = nil) {
        let identity = record.map { String(CaptureDigest.sha256($0).prefix(8)) } ?? "-"
        logger.info("\(name, privacy: .public) record=\(identity, privacy: .public) bytes=\(bytes ?? 0) code=\((error as NSError?)?.code ?? 0)")
    }
}

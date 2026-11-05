import Foundation
import CryptoKit

/// Version 1 deliberately supports one canonical transport: 16 kHz mono PCM WAV.
/// Transport identities never depend on delivery order or the phone's current account.
enum WatchCaptureProtocol {
    static let version = 1
    static let sampleRate = 16_000
    static let segmentFrames = 960_000
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    static func wav(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        integer(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8)); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2))
        integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    static func validate(_ data: Data, segment: WatchAudioSegment) throws {
        guard segment.sequence >= 0, segment.sequence < 100_000, segment.frameCount > 0,
              segment.frameCount <= segmentFrames, segment.offsetMilliseconds >= 0,
              segment.offsetMilliseconds < 7 * 86_400_000, segment.sha256.count == 64,
              segment.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              segment.byteCount == segment.frameCount * 2 + 44, data.count == segment.byteCount,
              data.count >= 46, hash(data) == segment.sha256,
              wav(Data(data.dropFirst(44))) == data else { throw WatchCaptureError.invalidEvidence }
    }
}

enum WatchCaptureError: LocalizedError {
    case invalidEvidence, conflict, noRecording, storage
    var errorDescription: String? {
        switch self {
        case .invalidEvidence: return "录音校验未通过，原声已保留"
        case .conflict: return "录音身份或内容冲突，未覆盖已有内容"
        case .noRecording: return "当前没有正在录制的内容"
        case .storage: return "无法保存录音，请检查可用空间"
        }
    }
}

struct WatchRecordingHeader: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let installationID: UUID
    let bindingID: String?
    let startedAt: Date
    let timeZone: String
    func validate() throws {
        guard schemaVersion == WatchCaptureProtocol.version, startedAt.timeIntervalSince1970.isFinite,
              TimeZone(identifier: timeZone) != nil,
              bindingID == nil || (bindingID!.count == 64 && bindingID!.allSatisfy({ "0123456789abcdef".contains($0) }))
        else { throw WatchCaptureError.invalidEvidence }
    }
}
struct WatchAudioSegment: Codable, Equatable, Identifiable {
    let id: UUID
    let sequence: Int
    let offsetMilliseconds: Int
    let frameCount: Int
    let byteCount: Int
    let sha256: String
    var duration: Double { Double(frameCount) / Double(WatchCaptureProtocol.sampleRate) }
    var filename: String { id.uuidString.lowercased() + ".wav" }
}
struct WatchCaptureEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case focus, interrupted, ended }
    let id: UUID
    let kind: Kind
    let offsetMilliseconds: Int
    let endMilliseconds: Int?
    let finalSegmentCount: Int?
    let reason: String?
    func validate() throws {
        guard offsetMilliseconds >= 0, offsetMilliseconds < 7 * 86_400_000,
              (reason?.count ?? 0) <= 120 else { throw WatchCaptureError.invalidEvidence }
        switch kind {
        case .focus:
            guard let endMilliseconds, endMilliseconds > offsetMilliseconds, endMilliseconds < 7 * 86_400_000,
                  finalSegmentCount == nil else { throw WatchCaptureError.invalidEvidence }
        case .ended:
            guard let finalSegmentCount, (0...100_000).contains(finalSegmentCount), endMilliseconds == nil
            else { throw WatchCaptureError.invalidEvidence }
        case .interrupted: guard endMilliseconds == nil, finalSegmentCount == nil else { throw WatchCaptureError.invalidEvidence }
        }
    }
}
struct WatchFileEnvelope: Codable { let recording: WatchRecordingHeader; let segment: WatchAudioSegment }
struct WatchEventEnvelope: Codable { let recording: WatchRecordingHeader; let event: WatchCaptureEvent }
struct WatchCaptureReceipt: Codable {
    let recordingID: UUID
    let itemID: UUID
    let sha256: String // File digest or digest of the immutable event envelope.
}

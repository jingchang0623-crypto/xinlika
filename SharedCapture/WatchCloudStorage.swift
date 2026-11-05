import Foundation

/// An authenticated, freshly checked remote WAV, bound to its original uploader.
/// A bare HTTP upload status never authorizes removal of a phone's last copy.
struct WatchCloudAudioReceipt: Codable, Equatable {
    let schemaVersion: Int
    let workspaceID: UUID
    let deviceID: UUID
    let recordingID: UUID
    let segmentID: UUID
    let sequence: Int
    let offsetMilliseconds: Int
    let frameCount: Int
    let byteCount: Int
    let sha256: String
    let verified: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", workspaceID = "workspace_id", deviceID = "device_id"
        case recordingID = "session_id", segmentID = "segment_id", sequence
        case offsetMilliseconds = "offset_ms", frameCount = "frame_count", byteCount = "byte_count"
        case sha256, verified
    }

    func matches(recording: UUID, segment: WatchAudioSegment, target: WatchCloudStorageTarget) -> Bool {
        schemaVersion == 1 && verified && workspaceID == UUID(uuidString: target.workspaceID)
            && deviceID == UUID(uuidString: target.deviceID) && recordingID == recording
            && segmentID == segment.id && sequence == segment.sequence
            && offsetMilliseconds == segment.offsetMilliseconds && frameCount == segment.frameCount
            && byteCount == segment.byteCount && sha256 == segment.sha256
    }
}

struct WatchCloudStorageTarget {
    let bindingID: String
    let serviceURL: String
    let workspaceID: String
    let deviceID: String
}

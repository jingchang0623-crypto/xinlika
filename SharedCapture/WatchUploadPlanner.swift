import Foundation

struct WatchCloudTarget {
    let bindingID: String
    let serviceURL: String
    let workspaceID: String
}
struct WatchCloudMessage {
    let recordingID: UUID
    let key: String
    let body: Data
}

/// Replay plans are derived entirely from immutable recording evidence and its
/// saved grant. The current account cannot silently adopt historical recordings.
enum WatchUploadPlanner {
    static func next(in archive: WatchCaptureArchive, target: WatchCloudTarget, blocked: Set<String> = []) throws -> WatchCloudMessage? {
        for r in archive.snapshot().recordings.sorted(by: { $0.header.startedAt < $1.header.startedAt }) {
            guard let grant = r.cloudGrant, grant.bindingID == target.bindingID, grant.serviceURL == target.serviceURL else { continue }
            let session: [String: Any] = ["schema_version": 1, "id": r.id.uuidString.lowercased(),
                "device_id": r.header.installationID.uuidString.lowercased(), "workspace_id": target.workspaceID,
                "started_at": ISO8601DateFormatter().string(from: r.header.startedAt), "time_zone": r.header.timeZone,
                "capture_source": "apple_watch", "sample_rate": 16000, "channels": 1,
                "processing": ["asr": true, "agent": true, "source_kind": grant.sourceKind]]
            func message(_ key: String, _ fields: [String: Any]) throws -> WatchCloudMessage {
                var body = fields; body["id"] = key; body["session"] = session
                return .init(recordingID: r.id, key: key, body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            }
            var expected = 0
            for segment in r.segments.sorted(by: { $0.sequence < $1.sequence }) {
                guard segment.sequence == expected else { break }; expected += 1
                let key = segment.id.uuidString.lowercased()
                if r.cloudAccepted.contains(key) { continue }
                if blocked.contains(key) { break }
                let audio = try Data(contentsOf: archive.file(segment))
                try WatchCaptureProtocol.validate(audio, segment: segment)
                return try message(key, ["kind": "segment", "sequence": segment.sequence,
                    "offset_ms": segment.offsetMilliseconds, "frame_count": segment.frameCount,
                    "sha256": segment.sha256, "audio_base64": audio.base64EncodedString()])
            }
            guard r.complete, expected == r.segments.count,
                  r.segments.allSatisfy({ r.cloudAccepted.contains($0.id.uuidString.lowercased()) }) else { continue }
            let ordered = r.events.sorted {
                if ($0.kind == .ended) != ($1.kind == .ended) { return $1.kind == .ended }
                if $0.offsetMilliseconds != $1.offsetMilliseconds { return $0.offsetMilliseconds < $1.offsetMilliseconds }
                return $0.id.uuidString < $1.id.uuidString
            }
            for event in ordered {
                let key = event.id.uuidString.lowercased()
                if r.cloudAccepted.contains(key) { continue }
                if blocked.contains(key) { break }
                var fields: [String: Any] = ["kind": event.kind.rawValue, "offset_ms": event.offsetMilliseconds]
                if let end = event.endMilliseconds { fields["end_ms"] = end }
                if let count = event.finalSegmentCount { fields["segment_count"] = count }
                if let reason = event.reason { fields["reason"] = reason }
                return try message(key, fields)
            }
        }
        return nil
    }
}

import Foundation

enum ImportDisposition: String, Codable {
    case automatic, approved, review, ignored
    var allowsTransfer: Bool { self == .automatic || self == .approved }
}

enum ImportReviewReason: String, Codable {
    case shortRecording, longRecording, batch, existingQueue, unknownDuration, incompleteList
    var label: String {
        switch self {
        case .shortRecording: "短录音"
        case .longRecording: "长录音"
        case .batch: "批量录音"
        case .existingQueue: "待继续"
        case .unknownDuration: "时长待确认"
        case .incompleteList: "列表未完整"
        }
    }
}

/// Metadata can identify a reason to ask, never prove that a recording is worthless.
enum ImportPolicy {
    static let defaultMinimumSeconds = 60
    static let batchLimit = 5
    static let longRecordingSeconds: Double = 2 * 60 * 60

    static func reviewReason(duration: Double, newCount: Int, minimumSeconds: Int) -> ImportReviewReason? {
        guard duration.isFinite, duration > 0 else { return .unknownDuration }
        if duration < Double(minimumSeconds) { return .shortRecording }
        if duration >= longRecordingSeconds { return .longRecording }
        if newCount >= batchLimit { return .batch }
        return nil
    }

    static func needsLegacyReview(_ item: LedgerItem) -> Bool {
        item.importDisposition == nil && item.isLocallyControllable
    }

    static func allowsUpload(_ item: LedgerItem, now: Date = Date()) -> Bool {
        guard !item.isCloudOnly, item.importDisposition?.allowsTransfer == true, item.autoUpload == true,
              [.downloaded, .uploading, .failed].contains(item.state) else { return false }
        return item.nextRetryAt == nil || item.nextRetryAt! <= now
    }

    static func discover(_ entries: [FileEntry], records: [LedgerItem], scope: RecordScope,
                         deviceID: String, minimumSeconds: Int, listComplete: Bool = true) -> [LedgerItem] {
        var seen = Set<String>()
        let fresh = entries.filter { entry in
            let base = DeviceSyncPlan.fileBase(entry.name)
            let key = LedgerStore.sha256("\(scope.orgId)|\(scope.ownerKey)|\(deviceID)|\(base)|\(entry.size)")
            return seen.insert(key).inserted && !records.contains {
                scope.contains($0) && $0.deviceId == deviceID && $0.fileBase == base && $0.expectedBytes == Int(entry.size)
            }
        }
        return fresh.map { entry in
            let base = DeviceSyncPlan.fileBase(entry.name)
            let id = LedgerStore.sha256("\(scope.orgId)|\(scope.ownerKey)|\(deviceID)|\(base)|\(entry.size)")
            let reason: ImportReviewReason? = listComplete ? reviewReason(duration: Double(entry.time), newCount: fresh.count, minimumSeconds: minimumSeconds) : .incompleteList
            return LedgerItem(id: id, orgId: scope.orgId, deviceId: deviceID, fileBase: base,
                              title: base, durationSec: Double(entry.time), expectedBytes: Int(entry.size),
                              receivedBytes: 0, localFilename: "\(id).ogg", contentHash: "", state: .paused,
                              updatedAt: Date(), ownerKey: scope.ownerKey, autoUpload: reason == nil,
                              importDisposition: reason == nil ? .automatic : .review, importReviewReason: reason)
        }
    }
}

extension LedgerItem {
    var isLocallyControllable: Bool {
        !isCloudOnly && transcriptId == nil && state != .processing && state != .ready
    }
    var isHeldForReview: Bool { importDisposition == .review }
    var isIgnored: Bool { importDisposition == .ignored }
    var isVisibleRecord: Bool { !isHeldForReview && !isIgnored }
}

enum RecordingQueueSection: String, CaseIterable, Identifiable {
    case review = "待确认", active = "处理中", ignored = "已忽略"
    var id: String { rawValue }
    func contains(_ item: LedgerItem) -> Bool {
        switch self {
        case .review: item.isHeldForReview
        case .active: !item.isHeldForReview && !item.isIgnored &&
            (item.isLocallyControllable || item.state == .processing || item.meeting?.needsPolling == true)
        case .ignored: item.isIgnored
        }
    }

    /// A just-saved short recording should appear before older, long recordings.
    func sortedItems(in records: [LedgerItem]) -> [LedgerItem] {
        records.filter(contains).sorted {
            let left = $0.recordedAt ?? $0.updatedAt
            let right = $1.recordedAt ?? $1.updatedAt
            return left == right ? $0.id < $1.id : left > right
        }
    }
}

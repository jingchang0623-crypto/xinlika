import CryptoKit
import Foundation

enum LedgerState: String, Codable {
    case downloading
    case paused
    case downloaded
    case uploading
    case processing
    case ready
    case failed

    var label: String {
        switch self {
        case .downloading: return "下载中"
        case .paused: return "等待设备恢复"
        case .downloaded: return "已下载"
        case .uploading: return "正在上传"
        case .processing: return "深脑处理中"
        case .ready: return "转写完成"
        case .failed: return "需要处理"
        }
    }
}

struct LedgerItem: Codable, Identifiable, Equatable {
    let id: String
    let orgId: String
    let deviceId: String
    let fileBase: String
    var title: String
    var durationSec: Double
    var expectedBytes: Int
    var receivedBytes: Int
    var localFilename: String
    var contentHash: String
    var serverSessionId: String?
    var transcriptId: String?
    var state: LedgerState
    var lastError: String?
    var updatedAt: Date
    var ownerKey: String? = nil
    var audioHash: String? = nil
    var meeting: Meeting? = nil
    var resultUpdatedAt: Date? = nil
    var resultError: String? = nil
    var autoUpload: Bool? = nil
    var retryCount: Int? = nil
    var nextRetryAt: Date? = nil
    var importDisposition: ImportDisposition? = nil
    var importReviewReason: ImportReviewReason? = nil
    var cloud: CloudRecord? = nil

    var isCloudOnly: Bool { deviceId == "cloud" }
    var recordedAt: Date? { Continuation.startedAt(base: fileBase) ?? cloud?.startedAt }
    var displayDuration: String { isCloudOnly && cloud?.durationSeconds == nil ? "时长未知" : RecordPresentation.duration(durationSec) }

    var resultLabel: String { meeting?.analysisLabel ?? cloud?.label ?? (transcriptId != nil ? "分析待更新" : state.label) }

    var canRetry: Bool { state == .failed || state == .downloaded || state == .uploading }
}

struct RecordScope: Equatable {
    let orgId: String
    let ownerKey: String

    init(orgId: String, email: String, config: AppConfig) {
        self.orgId = orgId
        ownerKey = LedgerStore.sha256("\(config.apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")))|\(config.supabaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))|\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
    }

    func contains(_ item: LedgerItem) -> Bool { item.orgId == orgId && item.ownerKey == ownerKey }
}

final class LedgerStore {
    private let root: URL
    private let audioRoot: URL
    private let ledgerURL: URL
    private(set) var items: [LedgerItem] = []
    private(set) var loadError: Error?

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = directory ?? support.appendingPathComponent("Shennao", isDirectory: true)
        audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        ledgerURL = root.appendingPathComponent("ledger.json")
        do {
            try fileManager.createDirectory(at: audioRoot, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: ledgerURL.path) {
                items = try JSONDecoder.shennao.decode([LedgerItem].self, from: Data(contentsOf: ledgerURL))
            }
        } catch { loadError = error }
    }

    func id(orgId: String, deviceId: String, fileBase: String, expectedBytes: Int) -> String {
        Self.sha256("\(orgId)|\(deviceId)|\(fileBase)|\(expectedBytes)")
    }

    func existing(orgId: String, deviceId: String, fileBase: String, expectedBytes: Int) -> LedgerItem? {
        let key = id(orgId: orgId, deviceId: deviceId, fileBase: fileBase, expectedBytes: expectedBytes)
        return items.first { $0.id == key }
    }

    func audioURL(for id: String) -> URL {
        audioRoot.appendingPathComponent("\(id).ogg")
    }

    func upsert(_ item: LedgerItem) throws {
        var updated = items
        if let index = updated.firstIndex(where: { $0.id == item.id }) {
            updated[index] = item
        } else {
            updated.append(item)
        }
        updated.sort { $0.updatedAt > $1.updatedAt }
        try save(updated)
    }

    func item(id: String) -> LedgerItem? { items.first { $0.id == id } }

    func mergeCloudRecords(_ records: [CloudRecord], scope: RecordScope) throws {
        let merged = CloudLibrary.merging(records, into: items, scope: scope)
        if merged != items { try save(merged) }
    }

    /// A whole batch decision is persisted atomically, before any transfer is resumed.
    func upsert(_ changes: [LedgerItem]) throws {
        var updated = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in changes { updated[item.id] = item }
        try save(updated.values.sorted { $0.updatedAt > $1.updatedAt })
    }

    @discardableResult
    func holdLegacyImportQueue() throws -> Bool {
        if let loadError { throw loadError }
        let changes = items.filter(ImportPolicy.needsLegacyReview).map { original in
            var item = original
            item.importDisposition = .review
            item.importReviewReason = .existingQueue
            item.autoUpload = false
            return item
        }
        guard !changes.isEmpty else { return false }
        try upsert(changes)
        return true
    }

    func fileExists(for item: LedgerItem) -> Bool {
        FileManager.default.fileExists(atPath: audioRoot.appendingPathComponent(item.localFilename).path)
    }

    func fileURL(for item: LedgerItem) -> URL {
        audioRoot.appendingPathComponent(item.localFilename)
    }

    private func save(_ updated: [LedgerItem]) throws {
        if let loadError { throw loadError }
        let data = try JSONEncoder.shennao.encode(updated)
        try data.write(to: ledgerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        items = updated
    }

    /// 仅供升级时恢复已有登录态使用，登录新账号时不得调用。
    func adoptLegacyRecords(scope: RecordScope) throws {
        let legacy = items.filter { $0.ownerKey == nil && $0.orgId == scope.orgId }
        guard !legacy.isEmpty else { return }
        try save(items.map { item in
            var item = item
            if item.ownerKey == nil && item.orgId == scope.orgId { item.ownerKey = scope.ownerKey }
            return item
        })
    }

    static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var shennao: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var shennao: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

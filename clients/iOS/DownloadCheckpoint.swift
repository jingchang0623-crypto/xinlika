// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import CryptoKit

enum DownloadFailure: Error, CustomStringConvertible {
    case corruptCheckpoint, wrongFile, incomplete, deviceRejected(UInt8), storage
    var description: String {
        switch self {
        case .corruptCheckpoint: return "下载检查点损坏，原始片段已保留，请联系支持"
        case .wrongFile: return "设备文件已变化，已停止续传以免混入其他录音"
        case .incomplete: return "下载尚未完整，已保存断点，设备恢复后可继续"
        case .deviceRejected(let code): return "设备拒绝下载（\(code)），请检查设备中的录音"
        case .storage: return "保存下载断点失败，请检查可用空间；已保存的内容仍保留"
        }
    }
}

/// Single-writer partial file. The manifest only points at fsynced, whole Opus packets.
/// Uncommitted tail bytes can be replaced, never the original audio on the device.
@MainActor
final class DownloadCheckpoint {
    struct Manifest: Codable, Equatable {
        var recordID: String
        var expected: Int
        var filename: String
        var committed: Int
        var hash: String
        var complete: Bool
    }
    let file: URL
    private let manifestURL: URL
    private let handle: FileHandle
    private(set) var manifest: Manifest
    private(set) var received: Int
    private var lastFlush: Date = Date()
    private var hasher = SHA256()
    private var hashTail = Data()

    init(recordID: String, expected: Int, filename: String, directory: URL? = nil) throws {
        guard expected > 0, expected % OggWrap.packetLen == 0 else { throw DownloadFailure.wrongFile }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xinlika/Partial", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = CaptureDigest.sha256(recordID)
        file = directory.appendingPathComponent(key + ".opus.part")
        manifestURL = directory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
                guard manifest.recordID == recordID, manifest.expected == expected,
                      manifest.filename == filename, manifest.committed >= 0,
                      manifest.committed <= expected, manifest.committed % OggWrap.packetLen == 0 else {
                    throw DownloadFailure.wrongFile
                }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count >= manifest.committed,
                      CaptureDigest.sha256(Data(data.prefix(manifest.committed))) == manifest.hash else {
                    throw DownloadFailure.corruptCheckpoint
                }
            } catch let error as DownloadFailure { throw error }
            catch { throw DownloadFailure.corruptCheckpoint }
        } else {
            // An orphan file without a manifest is not a trustworthy checkpoint; preserve it.
            guard !FileManager.default.fileExists(atPath: file.path) else { throw DownloadFailure.corruptCheckpoint }
            try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            manifest = Manifest(recordID: recordID, expected: expected, filename: filename,
                committed: 0, hash: CaptureDigest.sha256(Data()), complete: false)
            try JSONEncoder().encode(manifest).write(to: manifestURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        received = manifest.committed
        hasher.update(data: try Data(contentsOf: file, options: .mappedIfSafe).prefix(received))
        handle = try FileHandle(forUpdating: file)
        try handle.truncate(atOffset: UInt64(received))
        try handle.seek(toOffset: UInt64(received))
    }

    deinit { try? handle.close() }

    func append(_ bytes: [UInt8]) throws {
        guard received + bytes.count <= manifest.expected else { throw DownloadFailure.wrongFile }
        do { try handle.write(contentsOf: Data(bytes)) }
        catch { throw DownloadFailure.storage }
        received += bytes.count
        hashTail.append(contentsOf: bytes)
        let wholePackets = hashTail.count - hashTail.count % OggWrap.packetLen
        if wholePackets > 0 {
            hasher.update(data: hashTail.prefix(wholePackets))
            hashTail = Data(hashTail.dropFirst(wholePackets))
        }
        if received - manifest.committed >= 262_144 || Date().timeIntervalSince(lastFlush) >= 1 {
            try flush()
        }
    }

    func flush(complete: Bool = false) throws {
        if complete && received != manifest.expected { throw DownloadFailure.incomplete }
        do {
            try handle.synchronize()
            let committed = received - received % OggWrap.packetLen
            var updated = manifest
            updated.committed = committed
            updated.hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            updated.complete = complete
            try JSONEncoder().encode(updated).write(to: manifestURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            manifest = updated
            lastFlush = Date()
        } catch { throw DownloadFailure.storage }
    }

    func readComplete() throws -> Data {
        guard manifest.complete, manifest.committed == manifest.expected else { throw DownloadFailure.incomplete }
        let raw = try Data(contentsOf: file, options: .mappedIfSafe)
        guard raw.count == manifest.expected, CaptureDigest.sha256(raw) == manifest.hash else {
            throw DownloadFailure.corruptCheckpoint
        }
        return raw
    }
}

extension BLEClient {
    @MainActor
    func download(checkpoint: DownloadCheckpoint,
                  onProgress: @escaping (Int, Int) -> Void) async throws {
        if checkpoint.manifest.complete { return }
        try Task.checkCancellation()
        let offset = checkpoint.received
        try sendRaw(try Proto.buildImportRequest(checkpoint.manifest.filename,
            offset: UInt32(offset), seq: nextSeq()))
        Diagnostics.event("ble_download_requested", record: checkpoint.manifest.recordID, bytes: offset)
        var lastPacket = Date()
        var lastReport = Date.distantPast
        do {
            while true {
                try Task.checkCancellation()
                guard let (_, frame) = await nextFrame(timeout: 0.5) else {
                    if !isConnected { throw BLEError.notConnected }
                    if Date().timeIntervalSince(lastPacket) > 15 { throw DownloadFailure.incomplete }
                    continue
                }
                guard frame.type == Proto.T.file else { continue }
                switch frame.cmd {
                case Proto.FileCmd.importBegin:
                    lastPacket = Date()
                    if frame.body.count >= 4 {
                        let declared = frame.body.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        // CB08 firmware variants disagree on IMPORT_BEGIN layout. File-list size,
                        // bounded append and final byte/hash checks are the authoritative guards.
                        Diagnostics.event("ble_import_begin_field", record: checkpoint.manifest.recordID,
                                          bytes: Int(declared))
                    }
                case Proto.FileCmd.importData:
                    try checkpoint.append(frame.body)
                    lastPacket = Date()
                    onProgress(checkpoint.received, checkpoint.manifest.expected)
                    if Date().timeIntervalSince(lastReport) >= 10 {
                        Diagnostics.event("ble_download_progress", record: checkpoint.manifest.recordID,
                                          bytes: checkpoint.manifest.committed)
                        lastReport = Date()
                    }
                case Proto.FileCmd.importEnd:
                    let code = frame.body.first ?? 255
                    guard code == 0 else { throw DownloadFailure.deviceRejected(code) }
                    guard checkpoint.received == checkpoint.manifest.expected else { throw DownloadFailure.incomplete }
                    try checkpoint.flush(complete: true)
                    return
                default: break
                }
            }
        } catch {
            try checkpoint.flush()
            throw error
        }
    }
}

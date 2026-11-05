import Foundation
import Observation
import WatchConnectivity
import AVFoundation
import UIKit

struct WatchCloudBinding: Codable {
    let id: String
    let serviceURL: String
    let workspaceID: String
    let deviceID: String
    let connectionFingerprint: String
}

@MainActor @Observable
final class WatchCapturePhoneModel {
    static let shared = WatchCapturePhoneModel()
    private(set) var records: [WatchCaptureArchive.Record] = []
    private(set) var notice = "在 Apple Watch 上开始录音，原声会自动同步到这里"
    private(set) var uploading = false
    private(set) var localStorageBytes: Int64 = 0
    private(set) var loadingPlayerID: UUID?
    private(set) var enabled: Bool
    private(set) var binding: WatchCloudBinding?
    private(set) var playerID: UUID?
    @ObservationIgnored private(set) var archive: WatchCaptureArchive?
    @ObservationIgnored private var bridge: WatchPhoneBridge?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var needsPump = false
    @ObservationIgnored private var maintenanceWorker: Task<Void, Never>?
    @ObservationIgnored private var needsMaintenance = false
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var blocked: Set<String> = []
    @ObservationIgnored private var configurationRevision = 0
    @ObservationIgnored private var playerDelegate: WatchPhonePlayerDelegate?
    @ObservationIgnored private var transferObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    private static var root: URL { XinlikaConnection.file.deletingLastPathComponent().appendingPathComponent("WatchCapture") }
    private static var settingsURL: URL { root.appendingPathComponent("settings.json") }
    @ObservationIgnored private let relaySession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 45
        return URLSession(configuration: c)
    }()
    struct Settings: Codable { var enabled: Bool; var binding: WatchCloudBinding? }
    init() {
        let settings = (try? WatchCaptureProtocol.decode(Settings.self, Data(contentsOf: Self.settingsURL)))
        enabled = settings?.enabled ?? false; binding = settings?.binding
        do {
            let archive = try WatchCaptureArchive(root: Self.root, allowsCloudEviction: true)
            self.archive = archive
            bridge = WatchPhoneBridge(archive: archive) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.reload()
                    self.bridge?.publish(bindingID: self.enabled && self.currentConnection() != nil ? self.binding?.id : nil)
                    if let error { self.notice = error }
                    self.pump(); self.maintainRelay()
                }
            }
            bridge?.start(); reload(); pump(); maintainRelay()
            transferObserver = NotificationCenter.default.addObserver(forName: BackgroundUploader.finished,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pump() } }
            activationObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resume() } }
        } catch { notice = "无法打开手表录音存储，未接收或上传新内容" }
    }
    private func saveSettings() throws {
        try WatchCaptureProtocol.encode(Settings(enabled: enabled, binding: binding)).write(to: Self.settingsURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func fingerprint(_ connection: XinlikaConnection) -> String {
        WatchCaptureProtocol.hash(Data((connection.baseURL.absoluteString + "|" + connection.token).utf8))
    }
    private func currentConnection() -> XinlikaConnection? {
        guard let c = XinlikaConnection.load(), let binding, binding.connectionFingerprint == fingerprint(c) else { return nil }
        return c
    }
    var needsServiceBinding: Bool { enabled && currentConnection() == nil }
    func setEnabled(_ value: Bool) async {
        guard archive != nil else { return }
        configurationRevision += 1
        let revision = configurationRevision
        if !value {
            enabled = false; worker?.cancel()
            do { try saveSettings(); bridge?.publish(bindingID: nil); notice = "云端整理已暂停，手表录音继续本地保存" }
            catch { notice = error.localizedDescription }
            return
        }
        guard let connection = XinlikaConnection.load(), XinlikaConnection.isAllowed(connection.baseURL) else { notice = "请先在录音卡页配置处理服务"; return }
        do {
            var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/shared/capabilities"))
            request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard configurationRevision == revision else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let caps = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workspaceID = caps["workspaceId"] as? String, UUID(uuidString: workspaceID) != nil,
                  let deviceID = caps["deviceId"] as? String, UUID(uuidString: deviceID) != nil,
                  caps["access"] as? String == "editor", caps["watchAudioVersion"] as? Int == 1
            else { notice = "处理服务尚未支持手表音频，原声可先保存在手机"; return }
            guard XinlikaConnection.load() == connection else { throw WatchCaptureError.conflict }
            let id = WatchCaptureProtocol.hash(Data((connection.baseURL.absoluteString + "|" + workspaceID + "|" + deviceID).utf8))
            binding = .init(id: id, serviceURL: connection.baseURL.absoluteString, workspaceID: workspaceID, deviceID: deviceID,
                connectionFingerprint: fingerprint(connection))
            enabled = true; try saveSettings(); blocked.removeAll()
            bridge?.publish(bindingID: id); notice = "新录音将上传原声并自动整理；已有本地录音需逐条选择"
            reload(); pump()
        } catch { enabled = false; notice = "服务连接未完成，原声仍保留在手机" }
    }
    func grant(_ record: WatchCaptureArchive.Record) {
        guard enabled, currentConnection() != nil, let archive, let binding else { notice = "请先启用手表云端整理"; return }
        do {
            try archive.grant(record.id, .init(bindingID: binding.id, serviceURL: binding.serviceURL, sourceKind: "unknown"))
            reload(); pump()
        } catch { notice = "这条录音属于其他处理空间，已保留原归属" }
    }
    func reload() {
        records = (archive?.snapshot().recordings ?? []).sorted { $0.header.startedAt > $1.header.startedAt }
        localStorageBytes = archive?.localStorageBytes() ?? 0
    }
    func resume() {
        reload(); blocked.removeAll()
        if needsServiceBinding { notice = "处理服务已更换，旧录音保留原归属。请重新连接服务后采集新录音。" }
        bridge?.publish(bindingID: enabled && currentConnection() != nil ? binding?.id : nil)
        pump(); maintainRelay()
    }
    func play(_ record: WatchCaptureArchive.Record, segment: WatchAudioSegment) {
        guard let archive else { return }
        let toggleOff = playerID == segment.id || loadingPlayerID == segment.id
        stopPlayback()
        if toggleOff { return }
        let generation = playbackGeneration
        loadingPlayerID = segment.id
        playbackTask = Task { [weak self] in
            guard let self else { return }
            defer { if playbackGeneration == generation { loadingPlayerID = nil; playbackTask = nil } }
            do {
                let audio: Data
                if FileManager.default.fileExists(atPath: archive.file(segment).path) {
                    audio = try Data(contentsOf: archive.file(segment))
                } else {
                    guard let connection = currentConnection(), let binding,
                          record.cloudGrant?.bindingID == binding.id, record.cloudGrant?.serviceURL == binding.serviceURL,
                          record.cloudAccepted.contains(segment.id.uuidString.lowercased()) else { throw WatchCaptureError.conflict }
                    var url = URLComponents(url: connection.baseURL.appendingPathComponent("v1/audio"), resolvingAgainstBaseURL: false)!
                    url.queryItems = [.init(name: "batch_id", value: segment.id.uuidString.lowercased())]
                    audio = try await remoteData(url.url!, connection: connection)
                    guard currentConnection() == connection else { throw WatchCaptureError.conflict }
                }
                try Task.checkCancellation()
                guard playbackGeneration == generation else { return }
                try WatchCaptureProtocol.validate(audio, segment: segment)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let delegate = WatchPhonePlayerDelegate { [weak self] in
                    Task { @MainActor in if self?.playbackGeneration == generation { self?.stopPlayback() } }
                }
                playerDelegate = delegate
                player = try AVAudioPlayer(data: audio); player?.delegate = delegate
                guard player?.play() == true else { throw WatchCaptureError.invalidEvidence }
                playerID = segment.id; loadingPlayerID = nil
            } catch is CancellationError { }
            catch { if playbackGeneration == generation { stopPlayback(); notice = "原声读取未完成，请检查网络；云端与手表原声保留" } }
        }
    }
    private func stopPlayback() {
        playbackGeneration += 1; playbackTask?.cancel(); playbackTask = nil
        player?.stop(); player = nil; playerDelegate = nil; playerID = nil; loadingPlayerID = nil
    }
    func hasLocalAudio(_ segment: WatchAudioSegment) -> Bool {
        archive.map { FileManager.default.fileExists(atPath: $0.file(segment).path) } ?? false
    }
    func status(_ record: WatchCaptureArchive.Record) -> String {
        if !record.complete { return record.ended == nil ? "正在接收 · 云端确认后释放手机暂存" : "等待补齐手表录音" }
        guard let grant = record.cloudGrant else { return "已存手机 · 本地保留" }
        if grant.bindingID != binding?.id { return "已保留原处理空间，未转发" }
        let total = record.segments.count + record.events.count
        if record.cloudAccepted.count >= total {
            let released = record.segments.allSatisfy { segment in
                !hasLocalAudio(segment) && record.cloudAudioReceipts?.contains(where: { $0.segmentID == segment.id && $0.sha256 == segment.sha256 }) == true
            }
            return released ? "已存云端 · 手机原声已释放" : "已上传 · 等待云端核验后释放手机暂存"
        }
        return enabled ? "待上传 \(max(0, total - record.cloudAccepted.count)) 项" : "云端整理已暂停"
    }
    private func pump() {
        if worker != nil { needsPump = true; return }
        guard enabled, let archive, let binding, let connection = currentConnection() else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                uploading = false; worker = nil; reload()
                if needsPump { needsPump = false; Task { @MainActor [weak self] in self?.pump() } }
            }
            var failures = 0
            while !Task.isCancelled, enabled, currentConnection() == connection {
                reload()
                // Auto grants only apply to recordings that opted into this exact
                // workspace at creation. Unbound history requires an explicit tap.
                for r in records where r.header.bindingID == binding.id && r.cloudGrant == nil {
                    do { try archive.grant(r.id, .init(bindingID: binding.id, serviceURL: binding.serviceURL, sourceKind: "unknown")) }
                    catch { notice = "无法保存整理授权，未上传原声"; return }
                }
                let next: WatchCloudMessage
                do {
                    guard let candidate = try WatchUploadPlanner.next(in: archive, target: .init(bindingID: binding.id, serviceURL: binding.serviceURL, workspaceID: binding.workspaceID), blocked: blocked) else { return }
                    next = candidate
                }
                catch { notice = "无法读取待传原声，已保留录音与账本"; return }
                guard !Task.isCancelled else { return }
                uploading = true
                do {
                    let path = archive.root.appendingPathComponent(next.key + ".upload.json")
                    let data = next.body
                    if FileManager.default.fileExists(atPath: path.path) {
                        guard try Data(contentsOf: path) == data else { throw WatchCaptureError.conflict }
                    } else { try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    let status = try await BackgroundUploader.shared.postFile(path,
                        to: connection.baseURL.appendingPathComponent("v1/watch/ingest"), token: connection.token,
                        identity: next.key, attempt: failures)
                    try Task.checkCancellation()
                    if status == 200 {
                        try archive.cloudAccepted(next.recordingID, key: next.key); failures = 0; reload(); maintainRelay(); continue
                    }
                    if [401, 403].contains(status) { notice = "处理服务授权失效，手表原声仍保留"; return }
                    if (400..<500).contains(status), ![408, 429].contains(status) {
                        blocked.insert(next.key); notice = "手表音频校验未通过，原声已保留"; return
                    }
                } catch is CancellationError { return }
                catch { notice = "等待网络恢复后继续上传，原声已保留" }
                failures += 1; uploading = false
                do { try await Task.sleep(for: .seconds(min(60, pow(2, Double(min(failures, 6)))))) } catch { return }
            }
        }
    }

    private func remoteData(_ url: URL, connection: XinlikaConnection) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await relaySession.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == url
        else { throw WatchCaptureError.invalidEvidence }
        return data
    }

    /// Only authenticated, hash-verified cloud evidence allows eviction. Old
    /// services, offline requests, changed accounts and partial uploads retain WAVs.
    private func maintainRelay() {
        if maintenanceWorker != nil { needsMaintenance = true; return }
        guard let archive, let binding, let connection = currentConnection() else { return }
        let target = WatchCloudStorageTarget(bindingID: binding.id, serviceURL: binding.serviceURL,
            workspaceID: binding.workspaceID, deviceID: binding.deviceID)
        maintenanceWorker = Task { [weak self] in
            guard let self else { return }
            var finished = false
            defer {
                maintenanceWorker = nil; reload()
                let again = needsMaintenance && finished; needsMaintenance = false
                if again { maintainRelay() }
            }
            do {
                for record in archive.snapshot().recordings {
                    guard record.cloudGrant?.bindingID == target.bindingID,
                          record.cloudGrant?.serviceURL == target.serviceURL else { continue }
                    for event in record.events where record.cloudAccepted.contains(event.id.uuidString.lowercased()) {
                        try archive.removeAcceptedUpload(record.id, key: event.id.uuidString.lowercased())
                    }
                    for segment in record.segments where record.cloudAccepted.contains(segment.id.uuidString.lowercased()) {
                        let pendingEnvelope = archive.root.appendingPathComponent(segment.id.uuidString.lowercased() + ".upload.json")
                        guard hasLocalAudio(segment) || FileManager.default.fileExists(atPath: pendingEnvelope.path) else { continue }
                        try Task.checkCancellation()
                        guard currentConnection() == connection, self.binding?.id == binding.id else { return }
                        var url = URLComponents(url: connection.baseURL.appendingPathComponent("v1/watch/audio-receipt"), resolvingAgainstBaseURL: false)!
                        url.queryItems = [.init(name: "session_id", value: record.id.uuidString.lowercased()),
                                          .init(name: "segment_id", value: segment.id.uuidString.lowercased())]
                        let data = try await remoteData(url.url!, connection: connection)
                        let receipt = try JSONDecoder().decode(WatchCloudAudioReceipt.self, from: data)
                        try Task.checkCancellation()
                        guard currentConnection() == connection, self.binding?.id == binding.id else { return }
                        try archive.releasePhoneAudio(receipt, target: target)
                        reload()
                    }
                }
                finished = true
            } catch is CancellationError { }
            catch { notice = "等待云端原声核验，手机暂存尚未释放；可联网后重试" }
        }
    }

}

private final class WatchPhonePlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let finished: @Sendable () -> Void
    init(finished: @escaping @Sendable () -> Void) { self.finished = finished }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finished() }
}

/// A non-main-actor delegate commits the file before returning to the OS.
final class WatchPhoneBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let archive: WatchCaptureArchive
    private let changed: @Sendable (String?) -> Void
    private let session = WCSession.default
    init(archive: WatchCaptureArchive, changed: @escaping @Sendable (String?) -> Void) { self.archive = archive; self.changed = changed }
    func start() { guard WCSession.isSupported() else { return }; session.delegate = self; session.activate(); diagnostic("start") }
    private func diagnostic(_ event: String, error: Error? = nil) {
        WatchConnectivityStatus.save(event, session: session, root: archive.root, error: error)
    }
    func publish(bindingID: String?) {
        diagnostic("publish")
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        if session.applicationContext["captureProtocol"] as? Int == 1,
           (session.applicationContext["bindingID"] as? String) == bindingID { return }
        var context: [String: Any] = ["captureProtocol": 1]
        context["bindingID"] = bindingID
        do { try session.updateApplicationContext(context) }
        catch { changed("手表设置待同步，原声仍会保留") }
    }
    private func receipt(_ receipt: WatchCaptureReceipt) throws {
        guard session.activationState == .activated else { throw WatchCaptureError.conflict }
        session.transferUserInfo(["receipt": try WatchCaptureProtocol.encode(receipt)])
    }
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            guard let metadata = file.metadata?["envelope"] as? Data, metadata.count <= 8192 else { throw WatchCaptureError.invalidEvidence }
            let envelope = try WatchCaptureProtocol.decode(WatchFileEnvelope.self, metadata)
            try receipt(archive.receive(envelope, temporaryFile: file.fileURL)); diagnostic("file_received"); changed(nil)
        } catch { diagnostic("file_rejected", error: error); changed("手表录音暂未确认接收，原声仍保留在手表") }
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["event"] as? Data, data.count <= 8192 else { return }
        do { try receipt(archive.receive(WatchCaptureProtocol.decode(WatchEventEnvelope.self, data))); diagnostic("event_received"); changed(nil) }
        catch { diagnostic("event_rejected", error: error); changed("手表标记暂未确认，等待重新同步") }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["captureProtocol"] as? Int == 1 else { replyHandler(["captureProtocol": 0]); return }
        diagnostic("handshake_received")
        replyHandler(["captureProtocol": 1])
        changed(nil)
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { diagnostic("activated", error: error); changed(error == nil ? nil : "手表同步暂不可用") }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { changed(nil) }
    func sessionReachabilityDidChange(_ session: WCSession) { changed(nil) }
}

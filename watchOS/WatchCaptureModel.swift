import Foundation
import Observation
import AVFoundation
import WatchConnectivity

@MainActor @Observable
final class WatchCaptureModel {
    private(set) var recording = false
    private(set) var seconds: Double = 0
    private(set) var level: Float = 0
    private(set) var focusStart: Int?
    private(set) var notice = "手机不在身边也能先录音"
    private(set) var pending = 0
    private(set) var busy = false
    @ObservationIgnored private var archive: WatchCaptureArchive?
    @ObservationIgnored private var engine: WatchRecorderEngine?
    @ObservationIgnored private var bridge: WatchSenderBridge?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    @ObservationIgnored private var resetObserver: NSObjectProtocol?
    init() {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XinlikaWatch")
            let archive = try WatchCaptureArchive(root: root, recoverDrafts: true)
            self.archive = archive
            bridge = WatchSenderBridge(archive: archive) { [weak self] message in
                Task { @MainActor in self?.reload(); if let message { self?.notice = message } }
            }
            bridge?.start(); reload()
        } catch { notice = "无法恢复录音存储，未开始录音" }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in self?.stop(reason: "audio_interruption") } }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
            // Ignore our own category/activation change during startup.
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.stop(reason: "audio_route_changed") }
            }
        }
        resetObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop(reason: "audio_services_reset") } }
    }
    func start() async {
        guard !busy, !recording, let archive else { return }
        busy = true; defer { busy = false }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { notice = "请在设置中允许麦克风录音"; return }
        do {
            let header = try archive.begin(bindingID: bridge?.bindingID)
            recordingID = header.id
            let engine = WatchRecorderEngine(archive: archive, recordingID: header.id)
            engine.changed = { [weak self] elapsed, level in
                Task { @MainActor in
                    guard self?.recordingID == header.id, self?.recording == true else { return }
                    self?.seconds = elapsed; self?.level = level; self?.reload(); self?.bridge?.flush()
                }
            }
            engine.failure = { [weak self] error in Task { @MainActor in
                guard self?.recordingID == header.id else { return }
                self?.stop(reason: "audio_write_failed"); self?.notice = error.localizedDescription
            } }
            self.engine = engine
            try engine.start()
            recording = true; seconds = 0; notice = "录音中 · 先保存在手表"
        } catch {
            if let recordingID { try? archive.end(recordingID, offset: 0) }
            engine?.stop(); engine = nil; recordingID = nil; notice = error.localizedDescription
        }
    }
    func toggleFocus() {
        guard recording, let archive, let id = recordingID else { return }
        let offset = max(0, engine?.capturedMilliseconds ?? Int(seconds * 1000))
        do {
            focusStart = try archive.toggleFocus(id, offset: offset)
            bridge?.flush()
        } catch { notice = error.localizedDescription }
    }
    func stop(reason: String? = nil) {
        guard recording, let archive, let id = recordingID else { return }
        engine?.stop()
        seconds = max(seconds, Double(engine?.capturedMilliseconds ?? 0) / 1000)
        engine = nil
        do {
            try archive.closeFocus(id, offset: Int(seconds * 1000))
            if let reason { try archive.event(id, .init(id: UUID(), kind: .interrupted, offsetMilliseconds: Int(seconds * 1000),
                endMilliseconds: nil, finalSegmentCount: nil, reason: reason)) }
            try archive.end(id, offset: Int(seconds * 1000))
            notice = reason == nil ? "已保存在手表，等待同步" : "录音已中断，已录内容已保存；请重新开始"
        } catch { notice = "保存未完成，原声已保留，重开 App 后恢复" }
        recording = false; recordingID = nil; focusStart = nil; level = 0; reload(); bridge?.flush()
    }
    func retry() { bridge?.flush(force: true); reload() }
    private func reload() { pending = archive?.snapshot().recordings.reduce(0) { $0 + $1.pending } ?? 0 }
}

final class WatchSenderBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let archive: WatchCaptureArchive
    private let changed: @Sendable (String?) -> Void
    private let session = WCSession.default
    private let transfers = DispatchQueue(label: "xinlika.watch.transfers")
    private var lastSent: [UUID: Date] = [:]
    private var lastHandshake = Date.distantPast
    private var reconciledLegacyTransfers = false
    private var handshakeCompleted = false
    private var retry: DispatchWorkItem?
    var bindingID: String? { session.receivedApplicationContext["bindingID"] as? String }
    init(archive: WatchCaptureArchive, changed: @escaping @Sendable (String?) -> Void) { self.archive = archive; self.changed = changed }
    func start() { guard WCSession.isSupported() else { return }; session.delegate = self; session.activate(); diagnostic("start") }
    func flush(force: Bool = false) {
        transfers.async { [self] in
            if force { lastSent.removeAll() }
            sendPending()
        }
    }
    private func diagnostic(_ event: String, error: Error? = nil) {
        WatchConnectivityStatus.save(event, session: session, root: archive.root, error: error)
    }
    private func sendPending() {
        diagnostic("flush")
        guard session.activationState == .activated else { return }
        if !reconciledLegacyTransfers {
            // Replace requests created before the phone upgrade even when the
            // live channel is unavailable. Cancellation never removes the disk
            // journal; stable item IDs make late deliveries safe to deduplicate.
            for transfer in session.outstandingFileTransfers where transfer.file.metadata?["transportVersion"] as? Int != 2 { transfer.cancel() }
            for transfer in session.outstandingUserInfoTransfers where transfer.userInfo["transportVersion"] as? Int != 2 { transfer.cancel() }
            reconciledLegacyTransfers = true
        }
        handshakeIfReachable()
        // outstanding* prevents every progress update from enqueueing another copy.
        let files = Set(session.outstandingFileTransfers.filter {
            !reconciledLegacyTransfers || $0.file.metadata?["transportVersion"] as? Int == 2
        }.compactMap { $0.file.metadata?["itemID"] as? String })
        let events = Set(session.outstandingUserInfoTransfers.filter {
            !reconciledLegacyTransfers || $0.userInfo["transportVersion"] as? Int == 2
        }.compactMap { $0.userInfo["itemID"] as? String })
        var fileBudget = max(0, 4 - files.count), eventBudget = max(0, 8 - events.count)
        for record in archive.snapshot().recordings {
            let received = Set(record.receipts.map(\.itemID))
            for segment in record.segments where !received.contains(segment.id) && !files.contains(segment.id.uuidString) {
                guard fileBudget > 0, Date().timeIntervalSince(lastSent[segment.id] ?? .distantPast) >= 60 else { continue }
                do {
                    let envelope = try WatchCaptureProtocol.encode(WatchFileEnvelope(recording: record.header, segment: segment))
                    session.transferFile(archive.file(segment), metadata: ["envelope": envelope, "itemID": segment.id.uuidString, "transportVersion": 2])
                    lastSent[segment.id] = .now; fileBudget -= 1
                } catch { changed(error.localizedDescription) }
            }
            for event in record.events where !received.contains(event.id) && !events.contains(event.id.uuidString) {
                guard eventBudget > 0, Date().timeIntervalSince(lastSent[event.id] ?? .distantPast) >= 60 else { continue }
                if let data = try? WatchCaptureProtocol.encode(WatchEventEnvelope(recording: record.header, event: event)) {
                    session.transferUserInfo(["event": data, "itemID": event.id.uuidString, "transportVersion": 2])
                    lastSent[event.id] = .now; eventBudget -= 1
                }
            }
        }
        retry?.cancel(); retry = nil
        if archive.snapshot().recordings.contains(where: { $0.pending > 0 }) {
            let work = DispatchWorkItem { [weak self] in self?.sendPending() }
            retry = work; transfers.asyncAfter(deadline: .now() + 60, execute: work)
        }
    }
    private func handshakeIfReachable() {
        guard session.isReachable, !handshakeCompleted, Date().timeIntervalSince(lastHandshake) >= 30 else { return }
        lastHandshake = .now
        session.sendMessage(["captureProtocol": 1], replyHandler: { [weak self] reply in
            guard reply["captureProtocol"] as? Int == 1 else { return }
            self?.transfers.async { [weak self] in
                guard let self, !self.handshakeCompleted else { return }
                self.diagnostic("handshake_received")
                self.handshakeCompleted = true
            }
        }, errorHandler: { [weak self] error in self?.diagnostic("handshake_failed", error: error) })
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { diagnostic("activated", error: error); flush(); changed(error.map { _ in "同步暂不可用，原声保留在手表" }) }
    func sessionReachabilityDidChange(_ session: WCSession) { flush() }
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) { flush() }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { flush(); changed(nil) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["receipt"] as? Data else { return }
        do { try archive.acknowledge(WatchCaptureProtocol.decode(WatchCaptureReceipt.self, data)); diagnostic("receipt_received"); flush(); changed(nil) }
        catch { changed("同步回执未通过校验，原声仍保留") }
    }
    private func scheduleRetry() {
        flush()
    }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        diagnostic("file_finished", error: error)
        changed(error == nil ? nil : "同步暂未完成，原声保留在手表"); scheduleRetry()
    }
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) { diagnostic("event_finished", error: error); scheduleRetry() }
}

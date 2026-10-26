// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import Observation
import UIKit
import Network

@MainActor @Observable
final class XinlikaModel {
    static let shared = XinlikaModel()
    var capture = XinlikaCaptureStore.State()
    var selectedDay: Date?
    var agent: HeartballAgentState?
    private(set) var interestQueue: XinlikaInterestQueue?
    var interestMessage: String?
    private(set) var lastInterest: (event: HeartballAgentState.SemanticEvent, previous: String)?
    var supportsInterest: Bool { agent?.eventInterestProtocol == 1 }
    private var interestServer: String { connection?.baseURL.absoluteString ?? "isolated-preview" }
    var interestNotice: String? { interestMessage ?? interestQueue?.notice(server: interestServer) }
    func interest(for event: HeartballAgentState.SemanticEvent) -> String {
        interestQueue?.localValue(eventID: event.id, eventVersion: event.version,
            version: event.interestVersion ?? 0, server: interestServer) ?? event.userInterest ?? "neutral"
    }
    func interestPending(_ event: HeartballAgentState.SemanticEvent) -> Bool {
        interestQueue?.pending(eventID: event.id, server: interestServer) == true
    }
    func interestBlocked(_ event: HeartballAgentState.SemanticEvent) -> Bool {
        interestQueue?.blocked(eventID: event.id, server: interestServer) == true
    }
    func rateInterest(_ event: HeartballAgentState.SemanticEvent, value: String, undo: Bool = false) {
        guard supportsInterest else { interestMessage = "请更新处理服务后再标记"; return }
        guard let interestQueue else { interestMessage = "关注反馈账本无法打开，请检查可用空间"; return }
        let previous = interest(for: event)
        guard previous != value || interestBlocked(event) else { return }
        do {
            try interestQueue.enqueue(eventID: event.id, eventVersion: event.version,
                interestVersion: event.interestVersion ?? 0, value: value, server: interestServer)
            lastInterest = undo ? nil : (event, previous)
            interestMessage = nil
            pumpInterest()
        } catch { interestMessage = "标记未能保存在手机，请检查可用空间" }
    }
    func undoInterest() {
        guard let lastInterest else { return }
        rateInterest(lastInterest.event, value: lastInterest.previous, undo: true)
    }
    func lastInterestDismiss() { lastInterest = nil }
    private func pumpInterest() {
        #if DEBUG
        if timelinePreview { return }
        #endif
        guard supportsInterest, let client, let interestQueue else { return }
        interestQueue.wake(server: interestServer) { item in
            try await client.rateEvent(requestID: item.id, event: item.eventID, version: item.eventVersion,
                interestVersion: item.interestVersion, value: item.value)
        }
    }
    var remoteCapture: HeartballState.Session?
    var voiceStatus: HeartballClient.VoiceStatus?
    var voiceSessionID: String?
    private var voiceTimer: Task<Void, Never>?
    var devices: [Discovered] = []
    var selectedDevice: UUID?
    var capturePreferences = XinlikaCapturePreferences.load() {
        didSet {
            capturePreferences.save()
            if !capturePreferences.automaticHardwareCapture { hardwareObservation?.cancel() }
            resumeHardwareObservation()
        }
    }
    var hardwareStatus = "选择录音卡后可自动接入机身录音"
    private var hardwareObservation: Task<Void, Never>?
    private var hardwareKeyTask: Task<Void, Never>?
    private var idleHandshakeConnection: UUID?
    var busy = false
    var message: String?
    var asrConfigured = false
    var agentConfigured = false
    private var serviceReachable = false
    var serviceMessage: String {
        guard connection != nil else { return "尚未连接处理服务" }
        let processing = agent?.processingJobs.filter { ["queued", "running", "retryable"].contains($0.status) }.count ?? 0
        let failed = agent?.processingJobs.filter { ["failed", "blocked_provider"].contains($0.status) }.count ?? 0
        return XinlikaUploadPresentation.text(pending: pending, held: held, phase: uploadQueue?.phase ?? .idle,
            status: uploadQueue?.lastHTTPStatus, serviceReachable: serviceReachable,
            processing: processing, hasResults: agent != nil, failedProcessing: failed)
    }
    var connection: XinlikaConnection?
    var store: XinlikaCaptureStore?
    var uploadQueue: XinlikaUploadQueue?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    private var reconnectTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var referenceTask: Task<Void, Never>?
    private var referenceDownloadActive = false
    private var captureStartPending = false
    var canStartCapture: Bool {
        !recording && !captureStartPending && hardwareKeyTask == nil && (!busy || referenceDownloadActive)
    }
    private var sdkAttachAttempted = Set<String>()
    private var waitingSinceUptime: Double?
    private var foreground = true
    #if DEBUG
    private(set) var timelinePreview = false
    #endif
    private let handshake = RecorderButtonHandshake(mode: .vendor)
    @ObservationIgnored private lazy var ble: BLEClient = {
        let client = BLEClient()
        client.onFrameObservation = { [weak self, handshake, weak client] observation in
            // The disk sink is captured before callbacks are installed below.
            if let response = handshake.response(connection: observation.connectionID, source: observation.source,
                                                 frame: observation.frame, at: observation.uptime) {
                try? client?.send(response.type, response.command, [response.result])
            }
            Task { @MainActor [weak self] in self?.reload() }
        }
        client.onNotificationObservation = { [handshake] event in
            if event.isNotifying { handshake.connected(event.connectionID) }
        }
        client.onDisconnect = { [weak self, handshake] _ in
            handshake.disconnected()
            Task { @MainActor in
                guard let self else { return }
                self.idleHandshakeConnection = nil
                guard self.recording else { self.resumeHardwareObservation(); return }
                try? self.store?.gap("bluetooth_disconnect_unresolved")
                self.message = "蓝牙已断开，卡上继续录音；保存后自动补齐"
                self.reload(); self.pumpUploads(); self.recoverConnection()
            }
        }
        client.onRestore = { [weak self] _ in Task { @MainActor in self?.recoverConnection(); self?.resumeHardwareObservation() } }
        client.onPoweredOn = { [weak self] in Task { @MainActor in self?.recoverConnection(); self?.resumeHardwareObservation() } }
        client.onConnectAvailable = { [weak self] _ in Task { @MainActor in self?.recoverConnection(); self?.resumeHardwareObservation() } }
        return client
    }()
    var session: XinlikaCaptureStore.Session? { capture.sessions.last }
    var recording: Bool { session.map { ["recording", "reconnecting", "interrupted", "preparing", "attention", "waiting_audio"].contains($0.status) } ?? false }
    var pending: Int { capture.counts(for: connection?.baseURL.absoluteString).pending }
    var held: Int { capture.counts(for: connection?.baseURL.absoluteString).held }
    var historicalMessages: Int { capture.historicalCount(excluding: connection?.baseURL.absoluteString) }
    var cardAligned: Bool { remoteCapture?.id == session?.id && remoteCapture?.archiveStatus == "phone_card_bytes_verified" }
    var gapLabel: String { cardAligned ? "实时接收曾中断；完整卡文件已保留" : "实时接收有缺口，保存后自动补齐" }
    var captureLabel: String {
        guard recording else { return "录音已保存" }
        return session?.status == "recording" ? "持续记录中" : "卡上录音待核对，正在恢复接收"
    }
    private var client: HeartballClient? {
        guard let connection, XinlikaConnection.isAllowed(connection.baseURL) else { return nil }
        return try? HeartballClient(baseURL: connection.baseURL, token: connection.token, allowPrivateHTTP: true)
    }
    func refreshVoice() async {
        guard let client else { return }
        do {
            if let value = UserDefaults.standard.dictionary(forKey: "Xinlika.PendingVoiceBinding"),
               value["server"] as? String == connection?.baseURL.absoluteString,
               let enrollment = value["enrollment"] as? String,
               let sid = value["session"] as? String, let slot = value["slot"] as? Int {
                voiceStatus = try await client.bindVoiceSample(enrollment: enrollment, slot: slot, session: sid)
                UserDefaults.standard.removeObject(forKey: "Xinlika.PendingVoiceBinding")
            }
            voiceStatus = try await client.voiceState()
            if let sid = session?.id, voiceStatus?.samples.contains(where: { $0.sessionId == sid }) == true { voiceSessionID = sid }
        } catch { message = error.localizedDescription }
    }
    func beginVoiceEnrollment() async {
        guard let client, !recording, !busy else { return }
        do { voiceStatus = try await client.beginVoiceEnrollment(id: UUID()); message = nil }
        catch { message = error.localizedDescription }
    }
    func startVoiceSample(slot: Int) async {
        guard let enrollment = voiceStatus?.enrollmentId, !recording, !busy else { return }
        await start(source: "unknown", processing: false)
        guard recording, message == nil, let sid = session?.id, session?.cardFile.isEmpty == false else { return }
        voiceSessionID = sid
        UserDefaults.standard.set(["server":connection?.baseURL.absoluteString ?? "", "enrollment":enrollment,
                                   "session":sid,"slot":slot], forKey: "Xinlika.PendingVoiceBinding")
        await refreshVoice()
        voiceTimer?.cancel()
        voiceTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            guard let self, self.recording, self.session?.id == sid else { return }
            await self.stop()
            await self.refreshVoice()
        }
    }
    func revokeVoice() async {
        guard let client, !recording else { return }
        do {
            voiceStatus = try await client.revokeVoiceEnrollment()
            UserDefaults.standard.removeObject(forKey: "Xinlika.PendingVoiceBinding")
        } catch { message = error.localizedDescription }
    }
    func inspectCardForVoice() async {
        guard !busy, !recording, let selectedDevice,
              let device = devices.first(where: { $0.peripheral.identifier == selectedDevice }) ?? ble.knownDevice(selectedDevice) else { return }
        busy = true; defer { busy = false }
        do {
            if !ble.isConnected { try await ble.connect(device, synchronizeClock: false, requireKeyNotifications: true) }
            let state = try await ble.recordStatus()
            let name = try await ble.currentFilename()
            let time = try await ble.recordingExchange(Proto.KeyCmd.timeReq, reply: Proto.KeyCmd.timeAck)
            let seconds = time.flatMap { RecorderReading.decodeTime($0)?.seconds }
            let same = name.map { key($0) == key(session?.cardFile ?? "") } ?? false
            try recordRecoveryEvidence(["action":"voice_read_only_identity", "state":state as Any? ?? NSNull(),
                "filename":name as Any? ?? NSNull(), "seconds":seconds as Any? ?? NSNull(), "same_owned_file":same])
            message = "设备：\(state == 1 ? "录音中" : state == 2 ? "空闲" : "未确认")；文件 \(name ?? "未知")；计时 \(seconds.map(String.init) ?? "未知") 秒；\(same ? "与上次文件相同" : "与上次文件不同")"
        } catch { message = error.localizedDescription }
    }
    private init() {
        #if DEBUG
        let previewEnvironment = ProcessInfo.processInfo.environment
        if previewEnvironment["XINLIKA_TIMELINE_PREVIEW"] != nil || previewEnvironment["XINLIKA_TIMELINE_PREVIEW_JSON"] != nil {
            timelinePreview = true
            interestQueue = try? XinlikaInterestQueue(file: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("interest.json"))
            do {
                let data = try previewEnvironment["XINLIKA_TIMELINE_PREVIEW_JSON"].map { Data($0.utf8) }
                    ?? Data(contentsOf: URL(fileURLWithPath: previewEnvironment["XINLIKA_TIMELINE_PREVIEW"]!))
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                let snapshot = try decoder.decode(HeartballAgentState.self, from: data)
                agent = snapshot
                let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: snapshot.today?.timeZone ?? "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
                selectedDay = snapshot.today.flatMap { f.date(from: $0.date) }
            } catch { message = "离线界面回放无法读取" }
            return // Fail closed: no ledger, credentials, BLE, uploader or network.
        }
        #endif
        connection = XinlikaConnection.load()
        do {
            interestQueue = try XinlikaInterestQueue(file: XinlikaConnection.file.deletingLastPathComponent().appendingPathComponent("interest-feedback.json"))
        } catch { interestMessage = "关注反馈账本无法打开，请检查可用空间" }
        selectedDevice = capturePreferences.deviceID
        foreground = UIApplication.shared.applicationState == .active
        do {
            var subdirectory = "Xinlika/Capture"
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["XINLIKA_TEST_NAMESPACE"], UUID(uuidString: name) != nil { subdirectory = "XinlikaUITests/\(name)/Capture" }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.environment["XINLIKA_TRANSPORT_PROBE"] == "1" { subdirectory = "Xinlika/TransportProbe" }
            #endif
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(subdirectory)
            store = try XinlikaCaptureStore(root: root)
            if let connection { try store?.bindLegacyUploads(to: connection.baseURL.absoluteString) }
            store?.onChange = { [weak self] in Task { @MainActor in self?.reload(); self?.pumpUploads() } }
            reload()
            if selectedDevice == nil, let previous = session, let id = UUID(uuidString: previous.deviceID) {
                // Migrate only the exact card already used by this app, never a nearby radio.
                selectedDevice = id
                capturePreferences.deviceID = id
                capturePreferences.deviceName = ble.knownDevice(id)?.name ?? "已使用的录音卡"
                capturePreferences.save()
            }
        } catch { message = "采集账本无法打开，未连接设备或开始录音" }
        BackgroundUploader.shared.restore()
        let network = NWPathMonitor()
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self?.pumpUploads(); self?.uploadQueue?.wake(); self?.pumpInterest()
            }
        }
        network.start(queue: DispatchQueue(label: "xinlika.upload.connectivity"))
        networkMonitor = network
        pumpUploads()
        installSink()
        if recording { recoverConnection() }
        else { resumeHardwareObservation(); scheduleReference() }
        #if DEBUG
        let probeEnvironment = ProcessInfo.processInfo.environment
        if probeEnvironment["XINLIKA_SAVE_OWNED"] == "1", recording {
            Task {
                await reconnectTask?.value
                await stop()
                if store?.active()?.status == "completed" { await verifySavedCard() }
            }
        }
        let shouldStart = probeEnvironment["XINLIKA_AUTOSTART"] == "1" && (session == nil || session?.status == "completed")
        let shouldVerify = probeEnvironment["XINLIKA_VERIFY_SAVED"] == "1" && session?.status == "completed"
        if shouldStart || shouldVerify {
            Task {
                if shouldVerify {
                    await verifySavedCard()
                    guard store?.active()?.referenceQueued == true else { return }
                }
                guard shouldStart else { return }
                await scan()
                guard devices.count == 1 else { message = "请在录音卡页选择本次测试设备"; return }
                selectedDevice = devices[0].peripheral.identifier
                await start(source: "unknown", processing: true)
            }
        }
        #endif
    }
    private func installSink() {
        guard let store else { return }
        let client = ble
        client.onFrameObservation = { [store, handshake, weak client, weak self] observation in
            store.receive(observation)
            let response = handshake.response(connection: observation.connectionID, source: observation.source,
                frame: observation.frame, at: observation.uptime)
            if let response { try? client?.send(response.type, response.command, [response.result]) }
            if observation.source == "AE23", observation.frame.type == 3, observation.frame.body.isEmpty,
               let command = observation.frame.cmd, [1, 3, 5, 7].contains(command) {
                Task { @MainActor [weak self] in self?.hardwareKey(observation, needsReply: response == nil) }
            }
        }
    }
    func selectDevice(_ id: UUID) async {
        guard !busy, !recording else { return }
        busy = true
        let previous = hardwareObservation
        previous?.cancel(); await previous?.value
        if ble.connectedIdentifier != id { handshake.disable(); ble.disconnect(); idleHandshakeConnection = nil }
        selectedDevice = id
        capturePreferences.deviceID = id
        capturePreferences.deviceName = devices.first { $0.peripheral.identifier == id }?.name
        busy = false
        resumeHardwareObservation()
    }
    private func captureReading() async throws -> XinlikaCaptureAdmission.Reading {
        let state = try await ble.recordStatus(timeout: 1.5)
        guard state == 1 else { return .init(state: state) }
        let name = try await ble.currentFilename(timeout: 1.5)
        let time = try await ble.recordingExchange(Proto.KeyCmd.timeReq, reply: Proto.KeyCmd.timeAck, timeout: 1.5)
        return .init(state: state, filename: name, seconds: time.flatMap { RecorderReading.decodeTime($0)?.seconds })
    }
    @discardableResult
    private func adoptRunningRecording(device id: UUID, source: String, processing: Bool) async throws -> Bool {
        guard let store, let connection, ble.connectedIdentifier == id else { return false }
        guard let name = try await XinlikaCaptureAdmission.confirm(read: { try await self.captureReading() }) else {
            throw issue("录音状态或文件尚未稳定，稍后自动检查")
        }
        try Task.checkCancellation()
        guard ble.connectedIdentifier == id else { throw BLEError.notConnected }
        guard try store.adoptHardwareRecording(device: id, filename: name, source: source,
            processing: processing, serviceURL: connection.baseURL.absoluteString) else {
            hardwareStatus = "该录音已有采集任务，未重复创建"; return false
        }
        handshake.adoptConfirmedRecording(name, at: ProcessInfo.processInfo.systemUptime)
        waitingSinceUptime = ProcessInfo.processInfo.systemUptime
        reload(); pumpUploads(); startMonitor()
        hardwareStatus = "已自动接入机身录音"
        message = "已接入正在进行的录音；开始接收前的原声将在保存后核对补齐"
        return true
    }
    private func resumeHardwareObservation() {
        guard hardwareObservation == nil, hardwareKeyTask == nil, !captureStartPending, !busy, !recording, store != nil, connection != nil,
              capturePreferences.automaticHardwareCapture, let id = selectedDevice else { return }
        installSink()
        hardwareObservation = Task {
            defer {
                hardwareObservation = nil
                // A preference change can cancel an old observer and request a new one.
                if Task.isCancelled { resumeHardwareObservation() }
            }
            while !Task.isCancelled, !recording, capturePreferences.automaticHardwareCapture, selectedDevice == id {
                if busy || captureStartPending || hardwareKeyTask != nil {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }; continue
                }
                busy = true
                do {
                    if !ble.isConnected {
                        guard let device = devices.first(where: { $0.peripheral.identifier == id }) ?? ble.knownDevice(id) else { throw BLEError.notFound }
                        hardwareStatus = "正在连接所选录音卡"
                        try await ble.waitPoweredOn()
                        try await ble.connect(device, synchronizeClock: false, restoring: true, requireKeyNotifications: true)
                        try ble.send(0, 18, [foreground ? 1 : 2])
                    }
                    guard ble.connectedIdentifier == id else { throw BLEError.notConnected }
                    let state = try await ble.recordStatus(timeout: 1.5)
                    if state == 1 {
                        _ = try await adoptRunningRecording(device: id, source: capturePreferences.source, processing: capturePreferences.processing)
                    } else if state == 2 {
                        if idleHandshakeConnection != ble.connectionIdentifier {
                            handshake.prepareSelectedIdle(at: ProcessInfo.processInfo.systemUptime)
                            idleHandshakeConnection = ble.connectionIdentifier
                        } else { handshake.update(state: state, filename: nil, at: ProcessInfo.processInfo.systemUptime) }
                        hardwareStatus = "已连接，等待机身开始录音"
                    } else {
                        hardwareStatus = state == 3 ? "机身录音已暂停，恢复后自动接入" : "录音状态待确认，正在自动检查"
                    }
                } catch is CancellationError { busy = false; return }
                catch { hardwareStatus = "等待录音卡恢复连接或状态确认" }
                busy = false; reload(); pumpUploads()
                if recording { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func hardwareKey(_ observation: BLEFrameObservation, needsReply: Bool) {
        guard observation.connectionID == ble.connectionIdentifier, hardwareKeyTask == nil,
              recording || (capturePreferences.automaticHardwareCapture && selectedDevice == ble.connectedIdentifier) else { return }
        // A physical start takes precedence over reading an older saved file.
        let yieldingReference = observation.frame.cmd == 1 ? referenceTask : nil
        yieldingReference?.cancel()
        hardwareKeyTask = Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "XinlikaHardwareCapture") { [weak self] in
                Task { @MainActor in self?.hardwareKeyTask?.cancel() }
            }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            let oldObserver = hardwareObservation
            oldObserver?.cancel(); await oldObserver?.value
            let oldMonitor = monitor
            oldMonitor?.cancel(); await oldMonitor?.value
            await yieldingReference?.value
            defer {
                hardwareKeyTask = nil
                if recording { startMonitor() } else { resumeHardwareObservation(); scheduleReference() }
            }
            while busy {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard observation.connectionID == ble.connectionIdentifier,
                  ProcessInfo.processInfo.systemUptime - observation.uptime <= 10 else { return }
            busy = true
            defer {
                // Stop the old file transfer only after servicing the physical key.
                // Its checkpoint survives; the observer reconnects to the running file.
                if yieldingReference != nil { ble.disconnect(); idleHandshakeConnection = nil }
                busy = false; reload(); pumpUploads()
            }
            do {
                let state = try await ble.recordStatus(timeout: 1.5)
                let name = state == 2 ? nil : try await ble.currentFilename(timeout: 1.5)
                if state == 2, observation.frame.cmd == 1, !recording,
                   idleHandshakeConnection != ble.connectionIdentifier {
                    handshake.prepareSelectedIdle(at: ProcessInfo.processInfo.systemUptime)
                    idleHandshakeConnection = ble.connectionIdentifier
                }
                handshake.update(state: state, filename: name, at: ProcessInfo.processInfo.systemUptime)
                if needsReply, let response = handshake.response(connection: observation.connectionID, source: observation.source,
                    frame: observation.frame, at: ProcessInfo.processInfo.systemUptime) {
                    try ble.send(response.type, response.command, [response.result])
                }
                if yieldingReference != nil {
                    for _ in 0..<4 {
                        if try await ble.recordStatus(timeout: 1.5) == 1 { break }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
            } catch { hardwareStatus = "机身操作待确认，正在自动检查" }
        }
    }
    func reload() {
        if let store {
            capture = store.snapshot()
            if session?.status == "recording", message?.hasPrefix("已重连，等待实时音频") == true { message = nil }
            var status: [String: Any] = ["at": XinlikaCaptureStore.stamp(), "pending": pending,
                "receivedBytes": session?.streams.reduce(0) { $0 + $1.received } ?? 0,
                "gaps": session?.gaps ?? 0, "status": session?.status ?? "idle",
                "streamCount": session?.streams.count ?? 0, "focused": session?.focus != nil]
            status["uploadPhase"] = String(describing: uploadQueue?.phase ?? .idle)
            status["heldUploads"] = held
            if let code = uploadQueue?.lastHTTPStatus { status["lastUploadHTTPStatus"] = code }
            if let at = uploadQueue?.lastAcceptedAt { status["lastUploadAcceptedAt"] = XinlikaCaptureStore.stamp(at) }
            status["notifications"] = ble.notificationStates
            status["transportBytes"] = ble.transportByteCounts
            status["liveFrameCount"] = ble.discardedLiveAudioFrameCount
            status["automaticReferencePending"] = capture.sessions.filter { $0.automaticReference == true && $0.status == "completed" && $0.referenceQueued != true }.count
            if let id = session?.id { status["sessionId"] = id }
            if let message { status["message"] = message }
            if let data = try? JSONSerialization.data(withJSONObject: status) {
                try? data.write(to: store.root.appendingPathComponent("status.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
    func configure(address: String, token: String) async {
        guard !busy, !recording, uploadQueue?.isRunning != true else {
            message = "请先传完待传录音，再切换处理服务"; return
        }
        busy = true
        let previous = hardwareObservation
        previous?.cancel(); await previous?.value
        defer { busy = false; resumeHardwareObservation() }
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TransferError.invalidAddress }
            guard pending == 0 || url == connection?.baseURL else {
                throw issue("待传原声属于当前服务；可更新凭据，传完后再切换地址")
            }
            if let connection { try store?.bindLegacyUploads(to: connection.baseURL.absoluteString) }
            else if !capture.outbox.isEmpty { throw issue("旧原声缺少服务归属，请先恢复原连接") }
            let next = XinlikaConnection(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            guard XinlikaConnection.isAllowed(url) else { throw TransferError.invalidAddress }
            let test = try HeartballClient(baseURL: url, token: next.token, allowPrivateHTTP: true)
            let capabilities = try await test.mobileCapabilities()
            guard capabilities.protocolVersion == 1, !capabilities.hardwareControl else { throw TransferError.invalidAddress }
            await interestQueue?.stop()
            try next.save(); connection = next; message = nil
            agent = nil; lastInterest = nil
            pumpUploads(); resumeHardwareObservation(); await refresh()
        } catch { message = "连接未保存：\(error.localizedDescription)" }
    }
    func submitText(_ text: String) async -> Bool {
        guard let client, !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        busy = true; defer { busy = false }
        do { agent = try await client.submitText(text); message = nil; return true }
        catch { message = error.localizedDescription; return false }
    }
    func scan() async {
        guard !recording, !busy else { return }
        busy = true
        let previous = hardwareObservation
        previous?.cancel(); await previous?.value
        defer { busy = false; resumeHardwareObservation() }
        do {
            devices = try await ble.scan(seconds: 5).filter { $0.byService || $0.name.lowercased().contains("cb08") }
            // A bonded recorder may stop advertising while the OS retains its
            // identity. Connecting that exact prior device still checks idle
            // state/catalogue before any start; never choose an unrelated radio.
            if devices.isEmpty, let prior = session, let id = UUID(uuidString: prior.deviceID), let known = ble.knownDevice(id) {
                devices = [known]
            }
        }
        catch { message = error.localizedDescription }
    }
    func start(source: String, processing: Bool) async {
        guard let id = selectedDevice, let device = devices.first(where: { $0.peripheral.identifier == id }) ?? ble.knownDevice(id), let store, canStartCapture else { return }
        guard let connection else { message = "请先连接处理服务"; return }
        captureStartPending = true
        let reference = referenceTask
        reference?.cancel(); await reference?.value
        guard !busy, !recording else { captureStartPending = false; resumeHardwareObservation(); return }
        busy = true
        let previous = hardwareObservation
        previous?.cancel(); await previous?.value
        defer { busy = false; captureStartPending = false; reload(); pumpUploads(); resumeHardwareObservation() }
        do {
            if processing {
                guard let client else { throw issue("请先连接处理服务") }
                let capabilities = try await client.mobileCapabilities()
                guard capabilities.asrConfigured == true, capabilities.agentConfigured == true else {
                    throw issue("服务尚未配置语音识别和文字模型，未开始录音；请先完成服务配置，或关闭自动整理仅保存原声")
                }
            }
            installSink()
            if !ble.isConnected || ble.connectedIdentifier != id {
                if ble.isConnected { ble.disconnect() }
                try await ble.connect(device, synchronizeClock: false, restoring: true, requireKeyNotifications: true)
            }
            try ble.send(0, 18, [foreground ? 1 : 2])
            let initialState = try await ble.recordStatus()
            if initialState == 1 {
                _ = try await adoptRunningRecording(device: id, source: source, processing: processing)
                return
            }
            guard initialState == 2 else { throw issue("录音卡已暂停或状态未知，请先确认机身状态") }
            let list = try await ble.fileList(hardTimeout: 12)
            guard list.gotDone else { throw issue("文件目录未确认") }
            let afterList = try await ble.recordStatus()
            if afterList == 1 {
                _ = try await adoptRunningRecording(device: id, source: source, processing: processing)
                return
            }
            guard afterList == 2 else { throw issue("空闲状态未确认") }
            handshake.armFromIdle(baselineNames: list.entries.map(\.name), at: ProcessInfo.processInfo.systemUptime)
            handshake.reserveAppStart()
            try ble.syncTime()
            let beforeStart = try await ble.recordStatus()
            if beforeStart == 1 {
                _ = try await adoptRunningRecording(device: id, source: source, processing: processing)
                return
            }
            guard beforeStart == 2 else { throw issue("设备状态改变，未开始录音") }
            try store.begin(device: id, source: source, processing: processing, serviceURL: connection.baseURL.absoluteString)
            let result = try await RecordingControl.perform(.start, send: { try self.ble.sendRecording($0) }, exchange: {
                try await self.ble.recordingExchange($0, reply: $1, timeout: 1.5)
            })
            guard result.message == nil, let name = try await ble.currentFilename(), !list.entries.contains(where: { key($0.name) == key(name) }) else {
                throw issue("新录音身份未确认，请查看卡；未重发开始或停止")
            }
            try store.ownedFile(name); handshake.claimAppCreatedFile(name)
            message = nil; startMonitor()
        } catch {
            handshake.disable(); idleHandshakeConnection = nil
            message = error.localizedDescription
            if store.active() != nil { try? store.gap("start_unconfirmed") }
        }
    }
    private func issue(_ text: String) -> NSError { NSError(domain: "Xinlika", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func key(_ name: String) -> String { name.lowercased().split(separator: ".").first.map(String.init) ?? name }
    func stop() async {
        guard !busy, let session, !session.cardFile.isEmpty else { return }
        busy = true
        reconnectTask?.cancel()
        await reconnectTask?.value
        let priorMonitor = monitor
        priorMonitor?.cancel()
        await priorMonitor?.value
        defer { busy = false; reload(); pumpUploads(); if recording { startMonitor() } else { resumeHardwareObservation(); scheduleReference() } }
        do {
            if ble.isConnected, try await ble.recordStatus() == 2 {
                let list = try await ble.fileList(hardTimeout: 12)
                guard list.gotDone, list.entries.contains(where: { key($0.name) == key(session.cardFile) && $0.size > 0 }),
                      try await ble.recordStatus() == 2 else { throw issue("已保存原文件尚未确认，未改变采集账本") }
                try store?.finish(saved: true); monitor?.cancel(); handshake.disable(); ble.disconnect()
                message = "已保存，正在自动补齐原声"
                return
            }
            guard ble.isConnected, let name = try await ble.currentFilename(), key(name) == key(session.cardFile),
                  try await ble.recordStatus() == 1 else { throw issue("录音身份或状态未确认，未发送保存") }
            let result = try await RecordingControl.perform(.save, send: { try self.ble.sendRecording($0) }, exchange: {
                try await self.ble.recordingExchange($0, reply: $1, timeout: 1.5)
            })
            guard result.saved else { throw issue("保存结果未确认，原声保留") }
            try store?.finish(saved: true); monitor?.cancel(); handshake.disable()
            ble.disconnect(); message = "已保存，正在自动补齐原声"
        } catch { message = error.localizedDescription }
    }
    func focus() { do { try store?.toggleFocus(); reload(); pumpUploads() } catch { message = error.localizedDescription } }
    func sceneChanged(active: Bool) {
        #if DEBUG
        if timelinePreview { return }
        #endif
        foreground = active
        if recording, ble.isConnected { try? ble.send(0, 18, [active ? 1 : 2]) }
        if active { reload(); pumpUploads(); uploadQueue?.wake(); pumpInterest(); if recording { recoverConnection() } else { resumeHardwareObservation(); scheduleReference() } }
        // No disconnect or cancellation of collection when the scene becomes inactive.
    }
    private func recoverConnection() {
        guard reconnectTask == nil, !busy, recording, session?.status != "attention",
              let session, let id = UUID(uuidString: session.deviceID) else { return }
        if ble.isConnected, ["recording", "waiting_audio"].contains(session.status) { return }
        reconnectTask = Task {
            defer { reconnectTask = nil }
            do {
                installSink(); try await ble.waitPoweredOn()
                if !ble.isConnected {
                    guard let known = ble.knownDevice(id) else { throw issue("请靠近已绑定录音卡后重试连接") }
                    try await ble.connect(known, synchronizeClock: false, restoring: true, requireKeyNotifications: true)
                }
                try Task.checkCancellation()
                let state = try await ble.recordStatus()
                if state == 2 {
                    let list = try await ble.fileList(hardTimeout: 12)
                    guard list.gotDone, list.entries.contains(where: { key($0.name) == key(session.cardFile) && $0.size > 0 }),
                          try await ble.recordStatus() == 2 else { throw issue("保存身份未确认，保留缺口待恢复") }
                    try store?.finish(saved: true); handshake.disable(); ble.disconnect()
                    message = "卡已保存，正在自动补齐原声"
                    reload(); pumpUploads(); resumeHardwareObservation(); scheduleReference(); return
                }
                guard state == 1, let name = try await ble.currentFilename(), key(name) == key(session.cardFile) else {
                    try store?.gap("physical_file_changed_unresolved")
                    throw issue("卡上录音身份变化，未发送开始、恢复或停止命令")
                }
                try store?.ownedFile(session.cardFile, waiting: true)
                handshake.adoptConfirmedRecording(session.cardFile, at: ProcessInfo.processInfo.systemUptime)
                waitingSinceUptime = ProcessInfo.processInfo.systemUptime
                try ble.send(0, 18, [foreground ? 1 : 2])
                message = "已重连，等待实时音频；保存后自动补齐缺口"
                startMonitor(); reload(); pumpUploads()
            } catch is CancellationError { }
            catch { message = error.localizedDescription; reload(); startMonitor() }
        }
    }
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task {
            while !Task.isCancelled, recording {
                do {
                    if busy || reconnectTask != nil {
                        try await Task.sleep(for: .milliseconds(250)); continue
                    }
                    if !ble.isConnected { recoverConnection() }
                    else {
                        let state = try await ble.recordStatus(timeout: 1.5)
                        let name = try await ble.currentFilename(timeout: 1.5)
                        handshake.update(state: state, filename: name, at: ProcessInfo.processInfo.systemUptime)
                        if state == 1, let session, let name, key(name) != key(session.cardFile) {
                            try store?.gap("physical_file_changed_unresolved"); message = "录音文件变化，请核对；未自动拼接"; reload(); return
                        }
                        if state == 2 {
                            try store?.finish(saved: true); handshake.disable(); ble.disconnect()
                            reload(); pumpUploads(); resumeHardwareObservation(); scheduleReference(); return
                        }
                        if try store?.detectStall(uptime: ProcessInfo.processInfo.systemUptime) == true {
                            message = "实时音频中断，卡上继续录音；保存后自动补齐"
                            reload(); recoverConnection()
                        }
                        try await attachCurrentLiveStream(state: state, filename: name)
                        for _ in 0..<16 { if await ble.nextFrame(timeout: 0.01) == nil { break } }
                    }
                    reload()
                    try await Task.sleep(for: .seconds(5))
                } catch is CancellationError { return }
                catch {
                    message = "接收待恢复，卡上原声保留"; reload()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    recoverConnection()
                }
            }
        }
    }
    /// The SDK's unpublished 01-01 constructor restored the real CB08 V1.0.0
    /// stream without resetting its filename or recording counter. Attempt once
    /// per connection, after verified ownership and ten seconds without audio.
    private func attachCurrentLiveStream(state: UInt8?, filename: String?) async throws {
        guard let session = store?.active(), session.status == "waiting_audio", session.gaps > 0,
              let waitingSinceUptime, ProcessInfo.processInfo.systemUptime - waitingSinceUptime >= 10,
              state == 1, let filename, key(filename) == key(session.cardFile),
              let id = UUID(uuidString: session.deviceID), ble.connectedIdentifier == id else { return }
        let attemptID = session.id + ":" + ble.connectionIdentifier.uuidString
        guard !sdkAttachAttempted.contains(attemptID) else { return }
        let firmware = try await ble.firmware(timeout: 1.5)
        guard LiveStreamAttachPolicy.permits(recorderName: ble.knownDevice(id)?.name ?? "", firmware: firmware,
            state: state, ownedFile: session.cardFile, currentFile: filename,
            quietSeconds: ProcessInfo.processInfo.systemUptime - waitingSinceUptime,
            notifications: ble.notificationStates) else {
            sdkAttachAttempted.insert(attemptID)
            try recordRecoveryEvidence(["action": "attach_not_supported", "firmware": firmware ?? "unknown"])
            return
        }
        guard try await ble.recordStatus(timeout: 1.5) == 1,
              let name = try await ble.currentFilename(timeout: 1.5), key(name) == key(session.cardFile),
              store?.active()?.status == "waiting_audio" else { return }
        let before = try await ble.recordingExchange(Proto.KeyCmd.timeReq, reply: Proto.KeyCmd.timeAck, timeout: 1.5)
        guard let seconds = before.flatMap({ RecorderReading.decodeTime($0)?.seconds }) else { return }
        sdkAttachAttempted.insert(attemptID)
        try recordRecoveryEvidence(["action": "sdk_01_01_once", "attempt_id": attemptID, "firmware": firmware ?? "unknown", "before_seconds": seconds])
        try ble.send(Proto.T.audio, Proto.AudioCmd.attachLive)
        try await Task.sleep(for: .seconds(2))
        let afterState = try await ble.recordStatus(timeout: 1.5)
        let afterName = try await ble.currentFilename(timeout: 1.5)
        let after = try await ble.recordingExchange(Proto.KeyCmd.timeReq, reply: Proto.KeyCmd.timeAck, timeout: 1.5)
        let same = afterName.map { key($0) == key(session.cardFile) } ?? false
        let afterSeconds = after.flatMap { RecorderReading.decodeTime($0)?.seconds }
        let monotonic = afterSeconds.map { $0 >= seconds } ?? false
        try recordRecoveryEvidence(["action": "sdk_01_01_readback", "state": afterState as Any? ?? NSNull(), "same_file": same,
            "after_seconds": afterSeconds as Any? ?? NSNull(), "counter_monotonic": monotonic,
            "received_bytes": store?.active()?.streams.reduce(0) { $0 + $1.received } ?? 0])
        if !same || afterState != 1 || !monotonic {
            try store?.gap("physical_file_changed_unresolved")
            throw issue("SDK 试验后身份或状态变化，已停止自动探测；未发送开始或停止")
        }
    }
    private func recordRecoveryEvidence(_ fields: [String: Any]) throws {
        guard let store else { return }
        var row = fields; row["at"] = XinlikaCaptureStore.stamp(); row["session_id"] = session?.id
        let url = store.root.appendingPathComponent("recovery-experiment.ndjson")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10])); try file.synchronize()
    }
    func pumpUploads() {
        guard let store, let connection else { return }
        let configurationKey = connection.baseURL.absoluteString + "|" + XinlikaCaptureStore.hash(Data(connection.token.utf8))
        if uploadQueue?.configurationKey != configurationKey {
            uploadQueue?.cancel()
            uploadQueue = XinlikaUploadQueue(store: store, serviceURL: connection.baseURL.absoluteString,
                configurationKey: configurationKey, send: { next in
                    try await BackgroundUploader.shared.postFile(store.root.appendingPathComponent(next.file),
                        to: connection.baseURL.appendingPathComponent("v1/mobile/ingest"), token: connection.token,
                        identity: next.id, attempt: next.attempts)
                }, changed: { [weak self] in self?.reload() })
        }
        uploadQueue?.start()
    }
    func retryUploads() {
        for item in capture.outbox where item.status == "blocked" && item.serviceURL == connection?.baseURL.absoluteString { try? store?.acknowledge(item.id, status: "pending") }
        pumpUploads(); uploadQueue?.wake(retryBlocked: true); if recording { recoverConnection() }
    }
    private func scheduleReference() {
        guard referenceTask == nil, !captureStartPending, !recording, let store, let connection else { return }
        guard store.snapshot().sessions.contains(where: { $0.status == "completed" && $0.automaticReference == true &&
            ($0.referenceQueued != true || $0.discoveryComplete != true) && $0.serviceURL == connection.baseURL.absoluteString }) else { return }
        referenceTask = Task {
            // BLE callbacks can wake the app in background. Keep finalization work
            // bounded by the OS grant; checkpoints survive expiration/relaunch.
            let background = UIApplication.shared.beginBackgroundTask(withName: "XinlikaCardRepair") { [weak self] in
                Task { @MainActor in self?.referenceTask?.cancel() }
            }
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                referenceTask = nil
            }
            while !Task.isCancelled, !recording {
                guard store.snapshot().sessions.contains(where: { $0.status == "completed" && $0.automaticReference == true &&
                    ($0.referenceQueued != true || $0.discoveryComplete != true) && $0.serviceURL == connection.baseURL.absoluteString }) else { return }
                if !busy, !captureStartPending, let next = store.nextReference(serviceURL: connection.baseURL.absoluteString) {
                    await downloadSavedCard(next)
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    // Retained for diagnostics/legacy retry; ordinary saves call the scheduler.
    func verifySavedCard() async {
        guard let session else { return }
        await downloadSavedCard(session)
    }
    private func downloadSavedCard(_ session: XinlikaCaptureStore.Session) async {
        guard !busy, !recording, session.status == "completed", let store,
              let id = UUID(uuidString: session.deviceID),
              session.serviceURL == connection?.baseURL.absoluteString else { return }
        busy = true
        referenceDownloadActive = true
        defer { referenceDownloadActive = false; busy = false; reload(); pumpUploads(); resumeHardwareObservation() }
        do {
            try store.referenceAttempt(session.id)
            try await ble.waitPoweredOn()
            if ble.isConnected, ble.connectedIdentifier != id { ble.disconnect() }
            if !ble.isConnected {
                guard let known = ble.knownDevice(id) else { throw BLEError.notFound }
                try await ble.connect(known, synchronizeClock: false, requireKeyNotifications: true)
            }
            let currentState = try await ble.recordStatus()
            if currentState == 1, capturePreferences.automaticHardwareCapture, selectedDevice == id {
                _ = try await adoptRunningRecording(device: id, source: capturePreferences.source, processing: capturePreferences.processing)
                return
            }
            guard currentState == 2 else { throw issue("卡仍在录音，未读取文件") }
            let list = try await ble.fileList(hardTimeout: 12)
            guard list.gotDone, let file = list.entries.first(where: { key($0.name) == key(session.cardFile) }),
                  file.size > 0, try await ble.recordStatus() == 2 else { throw DownloadFailure.wrongFile }
            if capturePreferences.automaticHardwareCapture, selectedDevice == id {
                handshake.armFromIdle(baselineNames: list.entries.map(\.name), at: ProcessInfo.processInfo.systemUptime)
                idleHandshakeConnection = ble.connectionIdentifier
            }
            func readVerified(_ filename: String, bytes: Int, recordID: String) async throws -> Data {
                let checkpoint = try DownloadCheckpoint(recordID: recordID, expected: bytes, filename: filename,
                    directory: store.root.appendingPathComponent("Reference"))
                try await ble.download(checkpoint: checkpoint) { received, total in
                    self.message = "自动补齐原声 \(received * 100 / total)%"
                }
                func unchanged() async throws -> Bool {
                    let after = try await self.ble.fileList(hardTimeout: 12)
                    let idle = try await self.ble.recordStatus() == 2
                    return after.gotDone && after.entries.contains(where: { self.key($0.name) == self.key(filename) && Int($0.size) == bytes }) && idle
                }
                let verified: Bool
                do { verified = try await unchanged() }
                catch BLEError.notConnected {
                    guard let known = ble.knownDevice(id) else { throw BLEError.notFound }
                    try await ble.connect(known, synchronizeClock: false, restoring: true, requireKeyNotifications: true)
                    verified = try await unchanged()
                }
                guard verified else { throw DownloadFailure.wrongFile }
                return try checkpoint.readComplete()
            }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let start = f.date(from: session.startedAt), let ended = session.endedAt.flatMap({ f.date(from: $0) }) else {
                throw issue("结束时间尚未确认，未推断后续分段")
            }
            var previous = CardSegmentDiscovery.File(name: session.cardFile, bytes: Int(file.size))
            let files = list.entries.map { CardSegmentDiscovery.File(name: CardSegmentDiscovery.canonical($0.name), bytes: Int($0.size)) }
            let cloudFiles = (try? await client?.cardSegments(session.id))?.segments ?? []
            var previousHash: String
            if session.referenceQueued != true {
                let raw = try await readVerified(session.cardFile, bytes: Int(file.size), recordID: session.id)
                try store.enqueueReference(raw, expected: Int(file.size), filename: session.cardFile, endCode: 0, sessionID: session.id)
                previousHash = XinlikaCaptureStore.hash(raw)
            } else if CardSegmentDiscovery.next(after: previous, rootFile: session.cardFile, startedAt: start, endedAt: ended, files: files) != nil {
                if let known = cloudFiles.first(where: { key($0.filename) == key(session.cardFile) && $0.bytes == Int(file.size) }) { previousHash = known.sha256 }
                else {
                    let raw = try await readVerified(session.cardFile, bytes: Int(file.size), recordID: session.id)
                    previousHash = XinlikaCaptureStore.hash(raw)
                }
            } else { try store.completeDiscovery(session.id); ble.disconnect(); return }
            // Each saved file has its own checkpoint and canonical cloud identity.
            // A long clock gap, ambiguous next file, or another recording is never bridged.
            while let next = CardSegmentDiscovery.next(after: previous, rootFile: session.cardFile, startedAt: start, endedAt: ended, files: files) {
                try Task.checkCancellation()
                let name = CardSegmentDiscovery.canonical(next.name)
                if let saved = store.snapshot().sessions.first(where: { $0.id == session.id })?.recoveredSegments?.first(where: { $0.filename == name }) {
                    guard saved.bytes == next.bytes else { throw DownloadFailure.wrongFile }
                    previousHash = saved.sha256; previous = next; continue
                }
                if let known = cloudFiles.first(where: { key($0.filename) == key(name) && $0.bytes == next.bytes }) {
                    try store.retainCloudSegment(.init(filename: name, bytes: next.bytes, sha256: known.sha256, startedAt: known.startedAt), sessionID: session.id)
                    previousHash = known.sha256; previous = next; continue
                }
                let raw = try await readVerified(name, bytes: next.bytes, recordID: CardSegmentDiscovery.id(root: session.id, filename: name))
                try store.enqueueSegment(raw, filename: name, previous: previous.name, previousHash: previousHash, sessionID: session.id)
                previousHash = XinlikaCaptureStore.hash(raw); previous = next
            }
            try store.completeDiscovery(session.id)
            message = "原声及已发现分段已保存待传"
            ble.disconnect()
        } catch is CancellationError {
            // A key handler needs this connection to grant the pending physical
            // start before it disconnects the interrupted reference transfer.
            if hardwareKeyTask == nil { ble.disconnect() }
        } catch {
            ble.disconnect()
            message = store.snapshot().error ?? "原声已保留，靠近录音卡后自动续传"
        }
    }
    func refresh() async {
        #if DEBUG
        if timelinePreview { return }
        #endif
        pumpUploads()
        guard let client else { return }
        do {
            let capabilities = try await client.mobileCapabilities()
            asrConfigured = capabilities.asrConfigured == true
            agentConfigured = capabilities.agentConfigured == true
            agent = try await client.agentState(on: selectedDay)
            interestQueue?.reconcile((agent?.today?.timelineEvents ?? []) + (agent?.events ?? []), server: interestServer)
            pumpInterest()
            remoteCapture = try await client.state().session
            if remoteCapture?.id == session?.id, remoteCapture?.archiveStatus == "phone_card_bytes_verified",
               message?.contains("卡上原声已保存待传") == true { message = nil }
            serviceReachable = true
        }
        catch { serviceReachable = false; writeStatus(error: (error as NSError).code); return }
        writeStatus(error: nil)
    }
    private func writeStatus(error: Int?) {
        // Readback for on-device verification contains counts and error codes only.
        var status: [String: Any] = ["at": XinlikaCaptureStore.stamp(), "serviceConnected": error == nil,
            "route": "xinlika", "captureSessionCount": capture.sessions.count, "pending": pending,
            "todayEventCount": agent?.today?.eventCount ?? 0]
        if let error { status["errorCode"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: XinlikaConnection.file.deletingLastPathComponent().appendingPathComponent("status.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func ask(_ question: String) async {
        guard let client, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { agent = try await client.askMemory(question) } catch { message = error.localizedDescription }
    }
    func retryProcessing(_ id: String) async {
        guard let client else { return }
        do { agent = try await client.retryJob(id: id) }
        catch { message = "处理尚未恢复，请检查服务连接" }
    }
    @discardableResult
    func feedback(target: String, action: String, version: Int? = nil, values: [String: String]? = nil) async -> Bool {
        guard let client else { message = "请先连接处理服务"; return false }
        do { agent = try await client.feedback(target: target, action: action, version: version, values: values); return true }
        catch { message = error.localizedDescription; return false }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import CoreBluetooth
import Darwin
import CB08ProbeSupport
import LuyinbiCore

let usage = """
CB08 本机实时采集验证（无上传、无删除、无 OTA、无静音裁剪）
  cb08-probe scan [--seconds 8]
  cb08-probe catalog --device UUID [--output 新目录]
  cb08-probe reference --device UUID --filename noteYYYYMMDD-HHMMSS.opus [--output 新目录]
  cb08-probe capture --device UUID [--output 新目录] [--seconds 90]
      [--start-if-idle] [--disconnect-at 30] [--disconnect-for 3]
      [--sync-clock-before-start]
      [--recovery passive|resume|start] [--stop-owned-at-end]
      [--observe-buttons]
      [--button-response vendor|reject-save|reject-save-zero|resume-on-save] [--app-state foreground|background]
      [--app-state-file 本机控制文件]

默认只连接指定设备并订阅，不启动/暂停/结束已有录音，不修改设备时间。
--start-if-idle 只在已确认空闲时开始一条测试录音；否则只观察已有录音。
--sync-clock-before-start 仅在空闲且即将新建录音时校时，并核对新文件名；重连不校时。
重连总是先观察 10 秒。resume/start 是可选的单次控制实验，仅允许操作本原型新建且文件身份未变的录音。
--stop-owned-at-end 只结束并保存在本次明确新建且身份仍未变的录音；切段/身份不明则保留录音状态。
退出默认仅断开蓝牙，卡上可能继续录音，请查看设备。Ctrl+C 会保存本机证据后退出。
输出：events.ndjson、按蓝牙连接/通知来源分开的原始音频、capture-summary.json。
reference 仅在卡上已停止录音且列表完整时下载指定原始文件，校验结束码和精确大小；不删除。
catalog 仅读目录和状态，不校时、不下载、不改变录音；结果保存到 catalog.json。
--observe-buttons 允许从空闲状态等待机身操作，并要求 AE23 通知就绪；只观察，不自动回应。
--button-response 为专用空闲测试启用 SDK 按键回应；reject-save 仅实验性返回保存失败，不重启硬件。
reject-save-zero 是未获 SDK 文档保证的数值 0 变体，只用于专用文件排查，不代表产品支持重点标记。
resume-on-save 在专用录音收到保存请求时单发继续命令，实验能否取消挂起保存；绝不发送开始或在停止后自动续录。
--app-state 发送 SDK 前后台协议通知；可从控制文件读取 foreground/background 切换，不代表 iOS 后台已验证。
"""

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func request() { lock.lock(); value = true; lock.unlock() }
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class ProbeRunner {
    private let config: ProbeConfiguration
    private let stop: StopFlag
    private let journal: CaptureJournal
    private let ble = BLEClient()
    private var ownedFile: String?
    private var previousSnapshot: ProbeSnapshot?
    private var drain: Task<Void, Never>?
    private var startUptime = ProcessInfo.processInfo.systemUptime
    private var lastPoll: Double = 0
    private var lastBattery: Double = 0
    private let buttonHandshake: RecorderButtonHandshake?
    private var announcedAppState: String?

    init(config: ProbeConfiguration, stop: StopFlag) throws {
        self.config = config; self.stop = stop
        journal = try CaptureJournal(directory: config.output, recordControlBodies: config.observeButtons)
        buttonHandshake = config.buttonResponse.map { RecorderButtonHandshake(mode: $0) }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func connect() async throws {
        guard let id = config.deviceID else { throw ProbeError.invalid("设备 ID 缺失") }
        try await ble.waitPoweredOn()
        let device: Discovered
        if let known = ble.knownDevice(id) { device = known }
        else {
            guard let found = try await ble.scan(seconds: 5).first(where: { $0.peripheral.identifier == id }) else {
                throw BLEError.notFound
            }
            device = found
        }
        journal.record("connect_attempt", fields: ["device": id.uuidString, "clockSync": "disabled"])
        try await ble.connect(device, synchronizeClock: false)
        if config.observeButtons {
            let deadline = now + 3
            while now < deadline, ble.notificationStates["AE23"] != true {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard ble.notificationStates["AE23"] == true else { throw ProbeError.invalid("AE23 按键通知未就绪，未进入按键实验") }
        }
        journal.record("connected", fields: ["mtu": String(ble.mtu)])
        announcedAppState = nil
        try announceAppState()
    }

    private func announceAppState() throws {
        guard let initial = config.appState else { return }
        let selected: String
        if let file = config.appStateFile, FileManager.default.fileExists(atPath: file.path) {
            selected = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { selected = initial }
        guard let params = RecorderButtonHandshake.appStateParameters(selected) else {
            throw ProbeError.invalid("前后台控制文件值无效，未发送设备命令")
        }
        guard announcedAppState != selected else { return }
        let seq = ble.nextSeq()
        try ble.sendRaw(Proto.buildFrame(0, 18, params, seq: seq))
        journal.record("app_state_tx", fields: ["state": selected, "dataHex": String(format: "0012%02x", params[0]),
                                              "sequence": String(seq), "host": "macOS_protocol_experiment_not_iOS_lifecycle"])
        announcedAppState = selected
    }

    private func snapshot(_ phase: String) async throws -> ProbeSnapshot {
        // Bracket the non-atomic status/time reads with file identity, especially at rollover.
        let firstNameBytes = try await ble.recordingExchange(Proto.KeyCmd.curNameReq, reply: Proto.KeyCmd.curNameAck, timeout: 1.5)
        let firstName = firstNameBytes.map { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let rawState = try await ble.recordingExchange(Proto.KeyCmd.statusReq, reply: Proto.KeyCmd.statusAck, timeout: 1.5)?.first
        let rawTime = try await ble.recordingExchange(Proto.KeyCmd.timeReq, reply: Proto.KeyCmd.timeAck, timeout: 1.5)
        let time = rawTime.flatMap(RecorderReading.decodeTime)
        let nameBytes = try await ble.recordingExchange(Proto.KeyCmd.curNameReq, reply: Proto.KeyCmd.curNameAck, timeout: 1.5)
        let name = nameBytes.flatMap { bytes -> String? in
            let s = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            return s.isEmpty ? nil : s
        }
        let stable = ProbeSnapshot.fileKey(firstName) != nil && ProbeSnapshot.fileKey(firstName) == ProbeSnapshot.fileKey(name)
        let value = ProbeSnapshot(uptime: now, state: rawState, filename: name,
                                  seconds: stable ? time?.seconds : nil, bytes: stable ? time?.bytes : nil)
        journal.record("snapshot", fields: ["phase": phase, "state": rawState.map(String.init) ?? "unknown",
                                            "filename": name ?? "unknown", "identityStableAcrossReads": String(stable),
                                            "seconds": value.seconds.map(String.init) ?? "unknown",
                                            "bytes": value.bytes.map(String.init) ?? "unknown"], uptime: value.uptime)
        if let old = previousSnapshot, old.fileKey != nil, value.fileKey != nil, !old.sameFile(as: value) {
            journal.record("physical_file_change", fields: [
                "previous": old.filename!, "current": name!, "previousSeconds": old.seconds.map(String.init) ?? "unknown",
                "currentSeconds": value.seconds.map(String.init) ?? "unknown",
                "earliestObservationUptime": String(old.uptime), "latestObservationUptime": String(value.uptime),
                "cause": "unknown_verify_cap_rollover_vs_manual_change",
            ])
            print("文件身份变化：\(old.filename!) → \(name!)；已记录时间区间，未发送停启命令")
        }
        // Preserve the last known identity through a brief unknown/idle transition at rollover.
        if value.fileKey != nil { previousSnapshot = value }
        lastPoll = now
        buttonHandshake?.update(state: value.state, filename: stable ? value.filename : nil, at: value.uptime)
        return value
    }

    private func observe(seconds: Double) async throws {
        let end = now + seconds
        while now < end, !stop.requested {
            try journal.checkHealthy()
            guard ble.isConnected else { throw BLEError.notConnected }
            if now - lastPoll >= 5 { _ = try await snapshot("observe") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func reconnect() async throws {
        for attempt in 1...3 {
            guard !stop.requested else { throw CancellationError() }
            do { try await connect(); return }
            catch {
                journal.record("reconnect_failed", fields: ["attempt": String(attempt), "error": String(describing: error)])
                ble.disconnect()
                if attempt == 3 { throw error }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reconnectTrial() async throws {
        let before = try await snapshot("before_planned_disconnect")
        let baseline = journal.status().audio.frames
        journal.record("planned_disconnect", fields: ["duration": String(config.disconnectFor)])
        ble.disconnect()
        let end = now + config.disconnectFor
        while now < end, !stop.requested { try await Task.sleep(for: .milliseconds(100)) }
        guard !stop.requested else { return }
        try await reconnect()
        // Subscriptions alone are tested before any recording mutation.
        let passiveBaseline = journal.status().audio.frames
        journal.record("recovery_window_start", fields: ["strategy": "passive", "baselineAudioFrames": String(passiveBaseline)])
        try await observe(seconds: 10)
        guard !stop.requested else { return }
        var after = try await snapshot("after_passive_reconnect")
        let count = journal.status().audio.frames - passiveBaseline
        let passiveEvidence = ProbePolicy.recoveryEvidence(before: before, after: after, audioFrames: count)
        journal.record("recovery_result", fields: ["strategy": "passive", "audioFrames": String(count), "evidence": passiveEvidence,
                                                   "preDisconnectAudioFrames": String(baseline)])
        print("重连仅订阅：\(passiveEvidence)")
        guard count == 0, config.recovery != .passive, !stop.requested else { return }
        guard ProbePolicy.mayRearm(ownedFile: ownedFile, before: before, current: after) else {
            journal.record("rearm_skipped", fields: ["reason": "recording_not_owned_or_identity_or_state_changed"])
            return
        }
        // Re-read immediately; never let the earlier observation authorize a delayed mutation.
        after = try await snapshot("before_single_rearm")
        guard ProbePolicy.mayRearm(ownedFile: ownedFile, before: before, current: after) else {
            journal.record("rearm_skipped", fields: ["reason": "fresh_check_failed"]); return
        }
        let rearmBaseline = journal.status().audio.frames
        let action: RecorderAction = config.recovery == .resume ? .resume : .start
        journal.record("experimental_rearm_tx", fields: ["strategy": config.recovery.rawValue, "command": "1-\(action.request)",
                                                         "warning": "may_change_recording_identity_not_a_proven_attach_command"])
        // Exactly one send, bypassing normal UI policy ONLY for this explicitly selected experiment.
        try ble.sendRecording(action)
        try await observe(seconds: 10)
        guard !stop.requested else { return }
        let final = try await snapshot("after_single_rearm")
        let frames = journal.status().audio.frames - rearmBaseline
        let evidence = ProbePolicy.recoveryEvidence(before: after, after: final, audioFrames: frames)
        journal.record("recovery_result", fields: ["strategy": config.recovery.rawValue, "audioFrames": String(frames), "evidence": evidence])
        print("单次 \(config.recovery.rawValue) 实验：\(evidence)")
    }

    private func stopOwnedIfRequested() async throws {
        guard config.stopOwnedAtEnd, let ownedFile else { return }
        if !ble.isConnected { try await connect() }
        let current = try await snapshot("before_optional_save")
        guard current.state == 1, current.fileKey == ProbeSnapshot.fileKey(ownedFile) else {
            journal.record("save_skipped", fields: ["reason": "identity_changed_or_state_uncertain_recording_left_untouched"])
            print("未结束录音：文件已切段/身份或状态未确认，请查看录音卡")
            return
        }
        journal.record("save_owned_tx", fields: ["command": "1-2"])
        let result = try await RecordingControl.perform(.save, send: { try self.ble.sendRecording($0) }, exchange: {
            try await self.ble.recordingExchange($0, reply: $1, timeout: 1.5)
        })
        journal.record("save_owned_result", fields: ["confirmed": String(result.saved)])
        guard result.saved else { throw ProbeError.invalid("结束保存未确认，请检查录音卡") }
        // Stop the generic drain before reading the final file catalogue.
        drain?.cancel(); await drain?.value; drain = nil
        let list = try await ble.fileList(hardTimeout: 10)
        let saved = list.entries.first { ProbeSnapshot.fileKey($0.name) == ProbeSnapshot.fileKey(ownedFile) }
        journal.record("saved_card_file", fields: ["found": String(saved != nil), "catalogComplete": String(list.gotDone),
                                                   "filename": saved?.name ?? "unknown", "bytes": saved.map { String($0.size) } ?? "unknown",
                                                   "seconds": saved.map { String($0.time) } ?? "unknown"])
        guard saved != nil, list.gotDone else { throw ProbeError.invalid("停止后尚未完整确认卡上文件，未作删除或覆盖") }
    }

    func run() async throws {
        var outcome = "error"
        var runError: Error?
        ble.onFrameObservation = { [journal, buttonHandshake, ble] observation in
            journal.receive(observation)
            guard let handshake = buttonHandshake else { return }
            guard let response = handshake.response(connection: observation.connectionID, source: observation.source,
                                                     frame: observation.frame, at: observation.uptime) else {
                if let candidate = DeviceButtonCandidate(source: observation.source, frame: observation.frame) {
                    journal.record("button_response_not_authorized", fields: ["kind": candidate.kind.rawValue,
                        "requestUptime": String(observation.uptime),
                        "reason": "connection_source_body_freshness_pending_or_test_ownership_guard"])
                }
                return
            }
            do {
                let seq = ble.nextSeq()
                try ble.sendRaw(Proto.buildFrame(response.type, response.command, [response.result], seq: seq))
                journal.record("button_response_tx", fields: ["kind": response.kind, "requestSequence": String(observation.frame.seq),
                    "connection": observation.connectionID.uuidString, "sequence": String(seq),
                    "dataHex": String(format: "%02x%02x%02x", response.type, response.command, response.result),
                    "requestUptime": String(response.requestUptime),
                    "enqueueDelaySeconds": String(ProcessInfo.processInfo.systemUptime - response.requestUptime),
                    "filename": response.filename ?? "unknown", "focusCandidate": String(response.isFocusCandidate),
                    "meaning": response.type == 1 ? "experimental_resume_while_save_pending_not_save_ack_or_restart" : "write_enqueued_not_device_completion"])
            } catch {
                handshake.disable()
                journal.record("button_response_error", fields: ["error": String(describing: error)])
            }
        }
        ble.onNotificationObservation = { [journal, buttonHandshake] event in
            if event.isNotifying { buttonHandshake?.connected(event.connectionID) }
            journal.record("notification_subscription", fields: ["connection": event.connectionID.uuidString,
                "source": event.source, "isNotifying": String(event.isNotifying), "error": event.error ?? "none"])
        }
        ble.onDisconnect = { [journal, buttonHandshake] error in
            buttonHandshake?.disconnected()
            journal.record("unexpected_disconnect", fields: ["error": error.map(String.init(describing:)) ?? "none"])
        }
        journal.record("capture_begin", fields: ["device": config.deviceID!.uuidString, "requestedSeconds": String(config.seconds),
                                                 "schemaVersion": "1",
                                                 "pid": String(getpid()),
                                                 "startIfIdle": String(config.startIfIdle), "recovery": config.recovery.rawValue,
                                                 "silenceFiltering": "disabled_preserve_measurement", "clockSync": config.syncClockBeforeStart ? "idle_before_owned_start_only" : "disabled",
                                                 "cloudUpload": "none", "stopOwnedAtEnd": String(config.stopOwnedAtEnd)])
        journal.record("button_experiment_configuration", fields: ["response": config.buttonResponse?.rawValue ?? "observe_only",
            "appState": config.appState ?? "unannounced", "appStateFile": config.appStateFile?.path ?? "none"])
        print("证据目录：\(config.output.path)")
        do {
            try await connect()
            let fw = try await ble.firmware(timeout: 2)
            let battery = try await ble.battery(timeout: 2)
            journal.record("device_info", fields: ["firmware": fw ?? "unknown", "battery": battery.map(String.init) ?? "unknown"])
            let initial = try await snapshot("preflight")
            guard let state = initial.state, [1, 2].contains(state) else { throw ProbeError.invalid("录音状态未知或暂停，未发送控制命令") }
            if config.syncClockBeforeStart && !ProbePolicy.maySyncClock(startIfIdle: config.startIfIdle, state: state) {
                throw ProbeError.invalid("自动校时采集要求设备空闲，未修改已有录音或设备时钟")
            }
            guard config.buttonResponse == nil || state == 2 else {
                throw ProbeError.invalid("按键回应实验必须从新鲜空闲状态开始，不操作发现的现有录音")
            }
            var oldFiles: Set<String> = []
            if state == 2 {
                guard config.startIfIdle || config.observeButtons else { throw ProbeError.invalid("设备未录音；可用 --observe-buttons 等待机身操作，或为测试指定 --start-if-idle") }
                let list = try await ble.fileList(hardTimeout: 10)
                guard list.gotDone else { throw ProbeError.invalid("起始文件列表不完整，无法确认新文件身份，未开始录音") }
                oldFiles = Set(list.entries.compactMap { ProbeSnapshot.fileKey($0.name) })
                guard try await snapshot("before_button_arm").state == 2 else {
                    throw ProbeError.invalid("读目录期间录音状态改变，未启用按键回应")
                }
                buttonHandshake?.armFromIdle(baselineNames: list.entries.map { $0.name }, at: now)
            }
            // Status replies use their own slot; drain all other already-journalled frames so the
            // production pending queue cannot accumulate unsolicited events during a four-hour run.
            drain = Task { [ble] in
                while !Task.isCancelled { _ = await ble.nextFrame(timeout: 0.25) }
            }
            if state == 2 && config.startIfIdle {
                // A second state read fences a user/device change while listing files.
                guard try await snapshot("before_start").state == 2, !stop.requested else { throw CancellationError() }
                let clockZone = TimeZone.current
                if config.syncClockBeforeStart {
                    try ble.syncTime()
                    journal.record("clock_sync_tx", fields: ["timezone": clockZone.identifier,
                        "utcOffsetSeconds": String(clockZone.secondsFromGMT()), "ack": "not_supported",
                        "scope": "idle_before_owned_start_no_reconnect_sync"])
                    // Queue ordering keeps the time command before start. A fresh
                    // status read fences physical activity while it was being written.
                    guard try await snapshot("after_clock_sync_before_start").state == 2, !stop.requested else { throw CancellationError() }
                }
                let startRequestedAt = Date()
                journal.record("start_owned_tx", fields: ["command": "1-0"])
                let started = try await RecordingControl.perform(.start, send: { try self.ble.sendRecording($0) }, exchange: {
                    try await self.ble.recordingExchange($0, reply: $1, timeout: 1.5)
                })
                let confirmed = try await snapshot("after_start")
                guard started.message == nil, confirmed.state == 1, let key = confirmed.fileKey, !oldFiles.contains(key) else {
                    throw ProbeError.invalid("新录音身份未确认，未重发开始或停止；请查看录音卡")
                }
                ownedFile = confirmed.filename
                buttonHandshake?.claimAppCreatedFile(ownedFile!)
                journal.record("owned_recording_confirmed", fields: ["filename": ownedFile!])
                if config.syncClockBeforeStart {
                    let checkedAt = Date()
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.timeZone = clockZone
                    formatter.dateFormat = "'note'yyyyMMdd-HHmmss"
                    formatter.isLenient = false
                    let fileDate = confirmed.filename.flatMap { formatter.date(from: String($0.prefix(19))) }
                    let verified = fileDate.map { $0 >= startRequestedAt.addingTimeInterval(-2) && $0 <= checkedAt.addingTimeInterval(2) } ?? false
                    journal.record("clock_verification", fields: ["status": verified ? "new_filename_matches_host_start" : "unverified_filename_mismatch",
                        "filename": ownedFile!, "timezone": clockZone.identifier,
                        "startRequestedAt": ISO8601DateFormatter().string(from: startRequestedAt),
                        "startConfirmedAt": ISO8601DateFormatter().string(from: checkedAt),
                        "filenameAt": fileDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown",
                        "deltaFromStartSeconds": fileDate.map { String($0.timeIntervalSince(startRequestedAt)) } ?? "unknown",
                        "toleranceSeconds": "2", "meaning": "new_file_start_clock_only_not_sample_or_word_alignment"])
                }
            } else if state == 1 {
                journal.record("attached_existing_recording", fields: ["mutationPermission": "none"])
            } else {
                journal.record("waiting_for_manual_button", fields: ["responseMode": config.buttonResponse?.rawValue ?? "observe_only", "ae23Ready": "true"])
                print("按键实验已就绪：设备空闲，AE23 已订阅，回应模式：\(config.buttonResponse?.rawValue ?? "observe_only")")
            }
            startUptime = now; lastBattery = now
            var planned = false
            while now - startUptime < config.seconds, !stop.requested {
                try journal.checkHealthy()
                if !ble.isConnected {
                    try await reconnect()
                    journal.record("unexpected_reconnect_passive_only")
                }
                try announceAppState()
                if !planned, let at = config.disconnectAt, now - startUptime >= at {
                    planned = true
                    do { try await reconnectTrial() }
                    catch BLEError.notConnected { journal.record("trial_interrupted_by_disconnect"); try await reconnect() }
                }
                if now - lastPoll >= 5 {
                    do { _ = try await snapshot("periodic") }
                    catch BLEError.notConnected { continue }
                    let stats = journal.status()
                    print(String(format: "%.0fs  已落盘 %d 帧 / %dB  最大到达间隔 %.3fs  %@",
                                 now - startUptime, stats.audio.frames, stats.audio.bytes, stats.audio.maxArrivalGapSeconds, ble.parserStats))
                }
                if now - lastBattery >= 60 {
                    // Use the reply slot, not expect(), alongside the generic drain.
                    // Battery is TYPE=0; leave it unpolled during capture to avoid competing consumers.
                    journal.record("health", fields: ["parser": ble.parserStats, "elapsedSeconds": String(now - startUptime)])
                    lastBattery = now
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            outcome = stop.requested ? "interrupted_observation_saved" : "observation_completed_hardware_claims_require_analysis"
        } catch { runError = error; journal.record("run_error", fields: ["error": String(describing: error)]) }

        // Only an explicitly opted-in save of the original owned file may mutate at shutdown.
        buttonHandshake?.disable()
        do { try await stopOwnedIfRequested() }
        catch { runError = runError ?? error; journal.record("save_error", fields: ["error": String(describing: error)]); outcome = "error" }
        if ble.isConnected {
            if let final = try? await snapshot("final") {
                print("结束时卡上状态：\(final.state.map(String.init) ?? "未知")；文件：\(final.filename ?? "未知")")
            }
        }
        drain?.cancel(); await drain?.value
        ble.onFrameObservation = nil
        ble.onNotificationObservation = nil
        ble.onDisconnect = nil
        ble.disconnect()
        journal.record("capture_end", fields: ["outcome": outcome, "cardFilesDeleted": "0", "elapsedSeconds": String(now - startUptime)])
        try journal.close(outcome: outcome)
        print("采集结束；音频和日志仅存本机。默认不会停止卡上录音，请查看录音卡。")
        if let runError { throw runError }
        try journal.checkHealthy()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
    exit(arguments.isEmpty ? 2 : 0)
}
let stop = StopFlag()
var signals: [DispatchSourceSignal] = []
for value in [SIGINT, SIGTERM] {
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
    source.setEventHandler { stop.request() }
    source.resume(); signals.append(source)
}
var code: Int32 = 0
do {
    let config = try ProbeConfiguration(arguments: arguments)
    if config.mode == .scan {
        let ble = BLEClient()
        let devices = try await ble.scan(seconds: config.seconds).filter {
            $0.byService || $0.name.localizedCaseInsensitiveContains("CB08")
        }
        let rows = devices.map { ["id": $0.peripheral.identifier.uuidString, "name": $0.name, "rssi": String($0.rssi), "ae20": String($0.byService)] }
        let object: [String: Any] = ["devices": rows, "seconds": config.seconds, "captureStarted": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        ble.disconnect()
    } else if config.mode == .catalog {
        let ble = BLEClient()
        defer { ble.disconnect() }
        try await ble.waitPoweredOn()
        let id = config.deviceID!
        let device: Discovered
        if let known = ble.knownDevice(id) { device = known }
        else {
            guard let found = try await ble.scan(seconds: 5).first(where: { $0.peripheral.identifier == id }) else { throw BLEError.notFound }
            device = found
        }
        try await ble.connect(device, synchronizeClock: false)
        let before = try await ble.recordStatus(timeout: 2)
        let beforeName = try await ble.currentFilename()
        let list = try await ble.fileList(hardTimeout: 15)
        let after = try await ble.recordStatus(timeout: 2)
        let afterName = try await ble.currentFilename()
        let rows: [[String: Any]] = list.entries.map {
            ["name": $0.name, "seconds": $0.time, "bytes": $0.size,
             "isCurrentFile": ProbeSnapshot.fileKey($0.name) == ProbeSnapshot.fileKey(afterName)]
        }
        let evidence: [String: Any] = ["device": id.uuidString, "files": rows, "listComplete": list.gotDone,
            "stateBefore": before.map { Int($0) } ?? -1, "stateAfter": after.map { Int($0) } ?? -1,
            "currentFileBefore": beforeName ?? "unknown", "currentFileAfter": afterName ?? "unknown",
            "clockSync": "disabled", "cardFilesDeleted": 0, "recordingControlCommands": 0]
        guard !FileManager.default.fileExists(atPath: config.output.path) else { throw ProbeError.invalid("输出目录已存在") }
        try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let file = config.output.appendingPathComponent("catalog.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        print(String(decoding: data, as: UTF8.self))
        guard list.gotDone else { throw ProbeError.invalid("目录未完整返回，不能据此认定文件不存在") }
    } else if config.mode == .reference {
        let ble = BLEClient()
        defer { ble.disconnect() }
        try await ble.waitPoweredOn()
        let id = config.deviceID!
        let device: Discovered
        if let known = ble.knownDevice(id) { device = known }
        else {
            guard let found = try await ble.scan(seconds: 5).first(where: { $0.peripheral.identifier == id }) else { throw BLEError.notFound }
            device = found
        }
        try await ble.connect(device, synchronizeClock: false)
        guard try await ble.recordStatus(timeout: 2) == 2 else { throw ProbeError.invalid("仍在录音或状态不明，未下载参考文件") }
        let list = try await ble.fileList(hardTimeout: 10)
        let matches = list.entries.filter { ProbeSnapshot.fileKey($0.name) == ProbeSnapshot.fileKey(config.filename) }
        guard list.gotDone, matches.count == 1 else { throw ProbeError.invalid("完整列表中未找到唯一的指定文件") }
        let entry = matches[0]
        guard try await ble.recordStatus(timeout: 2) == 2, !stop.requested else { throw ProbeError.invalid("录音状态已改变，未下载") }
        guard !FileManager.default.fileExists(atPath: config.output.path) else { throw ProbeError.invalid("输出目录已存在") }
        try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = config.output.appendingPathComponent("incomplete-reference.bin")
        let sink = try ReferenceDownloadSink(file: partial, expectedBytes: Int(entry.size))
        let started = Date()
        let budget = min(64, max(8, Int(entry.size) / 524_288 + 4))
        var attempts = 0
        var noProgressAttempts = 0
        var complete = false
        var endCode: UInt8?
        var lastError: String?
        var lastProgress = Date.distantPast
        func progress(force: Bool = false) throws {
            guard force || Date().timeIntervalSince(lastProgress) >= 1 else { return }
            try sink.flush()
            let data: [String: Any] = ["receivedBytes": sink.receivedBytes, "expectedBytes": entry.size,
                "updatedAt": ISO8601DateFormatter().string(from: Date()), "complete": complete,
                "attempts": attempts, "lastError": lastError ?? ""]
            try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(
                to: config.output.appendingPathComponent("download-progress.json"), options: .atomic)
            lastProgress = Date()
        }
        while attempts < budget, noProgressAttempts < 3, Date().timeIntervalSince(started) < 3600, !stop.requested {
            attempts += 1
            let before = sink.receivedBytes
            endCode = nil
            do {
                if !ble.isConnected { try await ble.connect(device, synchronizeClock: false) }
                guard try await ble.recordStatus(timeout: 2) == 2 else {
                    throw ProbeError.invalid("设备已开始录音或状态不明，停止下载")
                }
                let fresh = try await ble.fileList(hardTimeout: 10)
                let matching = fresh.entries.filter { ProbeSnapshot.fileKey($0.name) == ProbeSnapshot.fileKey(config.filename) }
                guard fresh.gotDone, matching.count == 1, matching[0].size == entry.size, matching[0].time == entry.time,
                      try await ble.recordStatus(timeout: 2) == 2 else {
                    throw ProbeError.invalid("文件身份、大小或空闲状态未重新确认，停止续传")
                }
                let offset = try sink.beginAttempt()
                try ble.sendRaw(try Proto.buildImportRequest(config.filename!, offset: offset, seq: ble.nextSeq()))
                var lastPacket = Date()
                while true {
                    if stop.requested { throw CancellationError() }
                    guard let (_, frame) = await ble.nextFrame(timeout: 0.5) else {
                        guard ble.isConnected else { throw BLEError.notConnected }
                        if Date().timeIntervalSince(lastPacket) > 15 { throw ReferenceDownloadSink.Failure.incomplete }
                        continue
                    }
                    guard frame.type == Proto.T.file else { continue }
                    if frame.cmd == Proto.FileCmd.importBegin { lastPacket = Date() }
                    else if frame.cmd == Proto.FileCmd.importData {
                        try sink.append(frame.body)
                        lastPacket = Date()
                        try progress()
                    } else if frame.cmd == Proto.FileCmd.importEnd {
                        endCode = frame.body.first
                        guard endCode == 0 else { throw ProbeError.invalid("设备拒绝参考文件下载") }
                        try sink.confirm(endCode: endCode)
                        complete = true
                        break
                    }
                }
                if complete { break }
            } catch {
                lastError = String(describing: error)
                try progress(force: true)
                noProgressAttempts = sink.receivedBytes == before ? noProgressAttempts + 1 : 0
                ble.disconnect()
                let retryable = (error is BLEError) || {
                    if case ReferenceDownloadSink.Failure.incomplete = error { return true }
                    return false
                }()
                if !retryable || stop.requested { break }
                try await Task.sleep(for: .seconds(2))
            }
        }
        try progress(force: true)
        if complete { try FileManager.default.moveItem(at: partial, to: config.output.appendingPathComponent(config.filename!)) }
        let evidence: [String: Any] = ["device": id.uuidString, "filename": config.filename!, "expectedBytes": entry.size,
            "receivedBytes": sink.receivedBytes, "endCode": endCode.map { Int($0) } ?? -1,
            "sizeAndEndConfirmed": complete, "attempts": attempts, "overlapBytesOnResume": 160,
            "downloadSeconds": Date().timeIntervalSince(started), "lastError": lastError ?? "",
            "cardFilesDeleted": 0, "clockSync": "disabled", "recordingControlCommands": 0]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(
            to: config.output.appendingPathComponent("reference.json"), options: .atomic)
        print(String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        guard complete else { throw ProbeError.invalid("参考文件不完整，原字节已保留，未作为成功样本") }
    } else { try await ProbeRunner(config: config, stop: stop).run() }
} catch {
    fputs("CB08 验证未通过：\(error)\n", stderr)
    code = 1
}
for source in signals { source.cancel() }
exit(code)

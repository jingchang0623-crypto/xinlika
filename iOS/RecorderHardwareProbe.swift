#if DEBUG
import SwiftUI

/// Explicit, local developer launch only. No ledger, cloud client or audio persistence.
@MainActor
final class RecorderHardwareProbe: ObservableObject {
    static var targetID: UUID? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--probe-recorder-id") ?? args.firstIndex(of: "--inspect-recorder-id"),
              args.indices.contains(i + 1) else { return nil }
        return UUID(uuidString: args[i + 1])
    }
    private var inspectionOnly: Bool { ProcessInfo.processInfo.arguments.contains("--inspect-recorder-id") }

    @Published private(set) var status = "准备验证录音控制"
    @Published private(set) var finished = false
    private let id: UUID
    private let ble = BLEClient()
    private var rows: [[String: String]] = []
    private var ran = false
    private var ownedName: String?
    private var stopSent = false

    init(id: UUID) { self.id = id }

    private func note(_ event: String, _ fields: [String: String] = [:]) {
        var row = fields
        row["event"] = event
        row["time"] = ISO8601DateFormatter().string(from: Date())
        rows.append(row)
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Shennao")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(inspectionOnly ? "recorder-catalog-inspection.json" : "recorder-probe.json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { status = "诊断日志保存失败" }
    }

    private func connect() async throws {
        try await ble.waitPoweredOn()
        let device: Discovered
        if let known = ble.knownDevice(id) { device = known }
        else {
            guard let hit = try await ble.scan(seconds: 4).first(where: { $0.peripheral.identifier == id }) else {
                throw BLEError.notFound
            }
            device = hit
        }
        try await ble.connect(device)
    }

    private func state(_ phase: String) async throws -> UInt8? {
        let value = try await ble.recordStatus(timeout: 2)
        note(phase, ["state": value.map(String.init) ?? "unknown"])
        return value
    }

    private func normalized(_ name: String) -> String {
        name.lowercased().components(separatedBy: ".").first ?? name.lowercased()
    }

    private func perform(_ action: RecorderAction) async throws -> RecordingControl.Result {
        try await RecordingControl.perform(action, send: { action in
            try self.ble.sendRecording(action)
            self.note("tx", ["command": "1-\(action.request)"])
        }, exchange: { command, reply in
            try await self.ble.recordingExchange(command, reply: reply, timeout: 2)
        })
    }

    private func stopOwnedRecording() async throws {
        guard let ownedName, !stopSent else { return }
        guard try await state("before_stop") != RecorderState.idle.rawValue,
              let current = try await ble.currentFilename(timeout: 2),
              normalized(current) == normalized(ownedName) else {
            note("stop_skipped_identity_changed")
            return
        }
        stopSent = true
        let result = try await perform(.save)
        note("production_save", ["confirmed": String(result.saved), "state": String(result.reading.state.rawValue)])
    }

    func run() async {
        guard !ran else { return }
        ran = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            ble.disconnect()
            UIApplication.shared.isIdleTimerDisabled = false
            finished = true
        }
        note("begin", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                       "mode": inspectionOnly ? "read_only_catalogue" : "production_recording_control"])
        do {
            try await connect()
            let firmware = try await ble.firmware(timeout: 2)
            note("connected", ["firmware": firmware ?? "unknown"])
            if inspectionOnly {
                guard try await state("inspection_state") == RecorderState.idle.rawValue else {
                    status = "录音尚未结束，未读取文件列表"
                    note("inspection_skipped_active")
                    return
                }
                let catalog = try await ble.fileList(hardTimeout: 8)
                for entry in catalog.entries {
                    note("file", ["name": entry.name, "seconds": String(entry.time), "bytes": String(entry.size)])
                }
                note("inspection_end", ["complete": String(catalog.gotDone), "count": String(catalog.entries.count)])
                status = "文件列表检查完成"
                return
            }
            let before = try await ble.fileList(hardTimeout: 8)
            note("files_before", ["count": String(before.entries.count), "complete": String(before.gotDone)])
            guard try await state("preflight") == RecorderState.idle.rawValue else {
                status = "录音卡未空闲，已停止验证"
                note("aborted_not_idle")
                return
            }
            status = "正在验证开始录音"
            let startResult = try await perform(.start)
            note("production_start", ["confirmed": String(startResult.message == nil), "state": String(startResult.reading.state.rawValue)])
            let started = try await state("after_start")
            let name = try await ble.currentFilename(timeout: 2)
            note("current_file", ["present": String(name != nil)])
            guard started == RecorderState.recording.rawValue, let name,
                  !before.entries.contains(where: { normalized($0.name) == normalized(name) }) else {
                status = "这组命令未能确认开始录音"
                note("start_not_confirmed")
                return
            }
            ownedName = name
            try await Task.sleep(for: .seconds(2))
            note("live_audio_before_disconnect", ["discardedFrames": String(ble.discardedLiveAudioFrameCount)])
            status = "正在验证断连后继续录音"
            ble.disconnect()
            note("disconnected")
            try await Task.sleep(for: .seconds(2))
            try await connect()
            let reconnectedState = try await state("after_reconnect")
            let current = try await ble.currentFilename(timeout: 2)
            note("reconnect_identity", ["sameFile": String(current.map(normalized) == normalized(name))])
            let audioAtReconnect = ble.discardedLiveAudioFrameCount
            try await Task.sleep(for: .seconds(2))
            note("live_audio_after_reconnect", ["framesInTwoSeconds": String(ble.discardedLiveAudioFrameCount - audioAtReconnect)])
            if let body = try await ble.recordingExchange(Proto.KeyCmd.timeReq, reply: Proto.KeyCmd.timeAck, timeout: 2),
               let time = RecorderReading.decodeTime(body) {
                note("recording_time", ["seconds": String(time.seconds), "bytes": String(time.bytes)])
            }
            status = "正在验证结束并保存"
            try await stopOwnedRecording()
            let finalState = try await state("final_state")
            let after = try await ble.fileList(hardTimeout: 8)
            let saved = after.entries.first(where: { normalized($0.name) == normalized(name) })
            note("saved_file", ["found": String(saved != nil), "seconds": saved.map { String($0.time) } ?? "unknown",
                                "bytes": saved.map { String($0.size) } ?? "unknown", "complete": String(after.gotDone)])
            let success = reconnectedState == RecorderState.recording.rawValue &&
                current.map(normalized) == normalized(name) && finalState == RecorderState.idle.rawValue && saved != nil
            status = success ? "开始、断连续录、保存均已确认" : "验证完成，需要检查兼容性"
            note("end", ["success": String(success)])
        } catch {
            note("error", ["description": String(describing: error)])
            if ownedName != nil, !stopSent {
                do {
                    if !ble.isConnected { try await connect() }
                    try await stopOwnedRecording()
                } catch { note("cleanup_error", ["description": String(describing: error)]) }
            }
            status = "验证中断，请查看录音卡状态"
        }
    }
}

struct RecorderHardwareProbeView: View {
    @ObservedObject var probe: RecorderHardwareProbe
    var body: some View {
        VStack(spacing: 20) {
            if !probe.finished { ProgressView() }
            Text(probe.status).font(.headline)
            Text("本机诊断 · 不上传分析").font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .task { await probe.run() }
    }
}
#endif

// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import SwiftUI
import Observation
import LuyinbiCore
import AVFoundation

@available(macOS 14, *)
@MainActor @Observable
final class LabModel {
    var state: HeartballState?
    var message: String?
    var connectionMessage: String?
    var connected = false
    var captureConnected = false
    var usingSharedWorkspace = false
    var sharedAddress = ""
    var busy = false
    var agentState: HeartballAgentState?
    var lastUpdated: Date?
    var processing = true
    var sourceKind = "live_conversation"
    var draftText = ""
    var selectedDay: Date?
    #if DEBUG
    private(set) var timelinePreview = false
    #endif
    var memoryQuestion = ""
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var client: HeartballClient?
    @ObservationIgnored private let runtime: URL
    @ObservationIgnored private let sharedFile: URL
    @ObservationIgnored private var sharedClient: SharedWorkspaceClient?
    @ObservationIgnored private var sharedLoadError: String?
    @ObservationIgnored private var workspaceGeneration = 0
    private var workspaceClient: HeartballClient? { usingSharedWorkspace ? sharedClient?.content : client }

    init() {
        let args = CommandLine.arguments
        let path: String
        if let index = args.firstIndex(of: "--runtime"), args.indices.contains(index + 1) {
            path = args[index + 1]
        } else if let configured = Bundle.main.object(forInfoDictionaryKey: "HeartballRuntimePath") as? String {
            path = configured
        } else {
            path = FileManager.default.currentDirectoryPath + "/.build/heartball-lab/runtime.json"
        }
        runtime = URL(fileURLWithPath: path)
        if let index = args.firstIndex(of: "--workspace-runtime"), args.indices.contains(index + 1) {
            sharedFile = URL(fileURLWithPath: args[index + 1])
        } else if let configured = Bundle.main.object(forInfoDictionaryKey: "HeartballSharedRuntimePath") as? String {
            sharedFile = URL(fileURLWithPath: configured)
        } else { sharedFile = SharedWorkspaceConnection.file }
        #if DEBUG
        let previewIndex=args.firstIndex(of: "--timeline-preview")
        let previewPath=previewIndex.flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? (Bundle.main.object(forInfoDictionaryKey:"HeartballTimelinePreviewPath") as? String)
        if let previewPath {
            timelinePreview = true
            do {
                let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
                agentState=try decoder.decode(HeartballAgentState.self,from:Data(contentsOf:URL(fileURLWithPath:previewPath)))
                let f=DateFormatter();f.calendar=Calendar(identifier:.gregorian);f.locale=Locale(identifier:"en_US_POSIX");f.timeZone = .current;f.dateFormat="yyyy-MM-dd"
                selectedDay=agentState?.today.flatMap { f.date(from:$0.date) }
            } catch { message="离线界面回放无法读取" }
            return // No runtime/config reads, service connection or capture actions.
        }
        #endif
        if FileManager.default.fileExists(atPath: sharedFile.path) {
            usingSharedWorkspace = true
            do {
                let connection = try JSONDecoder().decode(SharedWorkspaceConnection.self, from: Data(contentsOf: sharedFile))
                sharedClient = try SharedWorkspaceClient(connection)
                sharedAddress = connection.baseURL.absoluteString
            } catch { sharedLoadError = "共享连接配置无法读取，请重新连接。" }
        }
    }

    var activeFocus: HeartballState.FocusRecord? { state?.focuses.first { $0.status == "recording" } }
    var recording: Bool { state?.session?.status == "recording" }
    var running: Bool { ["starting", "recording", "stopping", "reconciling"].contains(state?.session?.status ?? "") }

    func refresh(allowBusy: Bool = false) async {
        #if DEBUG
        if timelinePreview { return }
        #endif
        guard allowBusy || !busy else { return }
        let generation = workspaceGeneration
        var localFailure: String?
        do {
            if client == nil {
                // File access on removable volumes can wait on macOS permission prompts.
                // Keep that synchronous read off the UI actor so navigation remains usable.
                let location = runtime
                client = try await Task.detached(priority: .userInitiated) {
                    try HeartballClient(runtimeFile: location)
                }.value
            }
            let nextState = try await client!.state()
            if state != nextState { state = nextState; lastUpdated = .now }
            captureConnected = true
        } catch is CancellationError { return }
        catch {
            captureConnected = false; client = nil
            localFailure = "本机采集服务未连接。"
        }
        do {
            if usingSharedWorkspace {
                guard let sharedClient else { throw NSError(domain: "XinlikaShared", code: 0, userInfo: [NSLocalizedDescriptionKey: sharedLoadError ?? "请重新设置共享连接"]) }
                let next = try await sharedClient.refresh(on: selectedDay)
                guard generation == workspaceGeneration else { return }
                if let next, next != agentState { agentState = next; lastUpdated = .now }
            } else if captureConnected, state?.agentConfigured == true {
                let nextAgentState = try await client!.agentState(on: selectedDay)
                guard generation == workspaceGeneration else { return }
                if agentState != nextAgentState { agentState = nextAgentState; lastUpdated = .now }
            } else if let localFailure {
                throw NSError(domain: "XinlikaLocal", code: 0, userInfo: [NSLocalizedDescriptionKey: localFailure])
            }
            connectionMessage = nil
            connected = true
        } catch is CancellationError { }
        catch {
            guard generation == workspaceGeneration else { return }
            connectionMessage = usingSharedWorkspace ? "共享服务未连接，保留上次记录。\(error.localizedDescription)" : "本机服务未连接，采集状态尚未确认。"
            connected = false
        }
    }

    func selectDay(_ day: Date?) async {
        selectedDay=day;workspaceGeneration += 1
        await refresh()
    }

    func configureShared(address: String, token: String) async -> Bool {
        guard !busy, let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        busy = true; defer { busy = false }
        workspaceGeneration += 1
        do {
            let connection = SharedWorkspaceConnection(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let next = try SharedWorkspaceClient(connection)
            try await next.validate()
            let snapshot = try await next.refresh()
            try connection.save(to: sharedFile)
            sharedClient = next; usingSharedWorkspace = true; sharedAddress = url.absoluteString
            sharedLoadError = nil; agentState = snapshot; message = nil; connectionMessage = nil; connected = true
            return true
        } catch { message = "无法连接共享工作区：\(error.localizedDescription)"; return false }
    }

    func useLocalWorkspace() async {
        guard !busy else { return }
        workspaceGeneration += 1
        do {
            if FileManager.default.fileExists(atPath: sharedFile.path) { try FileManager.default.removeItem(at: sharedFile) }
            sharedClient = nil; usingSharedWorkspace = false; sharedAddress = ""; agentState = nil
            await refresh()
        } catch { message = "连接配置未能更新。" }
    }

    func start() async {
        let enabled = processing && state?.processingConfigured == true && state?.agentConfigured == true
        await perform { try await $0.startCapture(id: UUID(), processing: enabled, sourceKind: sourceKind) }
    }
    func stop() async {
        guard let id = state?.session?.id else { return }
        await perform { try await $0.stopCapture(id: id) }
    }
    func toggleFocus() async {
        if let focus = activeFocus { await perform { try await $0.endFocus(id: focus.id) } }
        else if let session = state?.session, recording {
            await perform { try await $0.startFocus(id: UUID(), sessionID: session.id) }
        }
    }
    func feedback(target: String, action: String, version: Int? = nil, values: [String: String]? = nil) async -> Bool {
        guard !busy, let client = workspaceClient else { return false }
        busy = true
        workspaceGeneration += 1
        defer { busy = false }
        do { agentState = try await client.feedback(target: target, action: action, version: version, values: values); message = nil; return true }
        catch { message = error.localizedDescription; await refresh(allowBusy: true); return false }
    }
    func submitText() async {
        guard !busy, !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let client = workspaceClient else { return }
        busy = true
        workspaceGeneration += 1
        defer { busy = false }
        do { agentState = try await client.submitText(draftText); draftText = ""; message = nil }
        catch { message = error.localizedDescription }
    }
    func askMemory() async {
        guard !busy, !memoryQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, memoryQuestion.count <= 1000, let client = workspaceClient else { return }
        busy = true
        workspaceGeneration += 1
        defer { busy = false }
        do { agentState = try await client.askMemory(memoryQuestion); memoryQuestion = ""; message = nil }
        catch { message = error.localizedDescription }
    }
    func play(batchID: String) async {
        guard let client = workspaceClient else { return }
        do {
            let data = try await client.audio(batchID: batchID)
            player = try AVAudioPlayer(data: data)
            player?.prepareToPlay(); player?.play()
        } catch { message = "原声暂时无法播放，请核对本地证据。" }
    }
    private func perform(_ action: (HeartballClient) async throws -> HeartballState) async {
        guard !busy, captureConnected, let client else { return }
        busy = true
        defer { busy = false }
        do { state = try await action(client); message = nil }
        catch {
            // Read authoritative state after an uncertain POST before accepting another action.
            let original = error.localizedDescription
            await refresh(allowBusy: true)
            message = original
        }
    }
}

@main
struct HeartballLab: App {
    var body: some Scene {
        WindowGroup("心力卡") {
            if #available(macOS 14, *) { LabView() }
            else { Text("心力卡需要 macOS 14 或更新版本。") }
        }.defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
    }
}

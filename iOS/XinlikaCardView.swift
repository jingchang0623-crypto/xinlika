import SwiftUI

struct XinlikaCardView: View {
    @Bindable var model: XinlikaModel

    private var waitingJobs: [HeartballAgentState.Job] {
        model.agent?.processingJobs.filter { !["completed", "superseded"].contains($0.status) } ?? []
    }
    private var failedJobs: [HeartballAgentState.Job] {
        waitingJobs.filter { ["failed", "blocked_provider"].contains($0.status) }
    }
    private var serviceNeedsAttention: Bool {
        model.connection == nil || model.serviceResultsUnavailable || model.uploadQueue?.phase == .blocked
            || model.uploadQueue?.phase == .waiting
    }
    private var hasSyncNotice: Bool {
        serviceNeedsAttention || model.pending > 0 || model.held > 0
            || model.message != nil || model.capture.error != nil
    }

    var body: some View {
        Form {
            if let session = model.session {
                XinlikaCurrentRecordingSection(model: model, session: session)
            }
            if !model.recording {
                XinlikaRecordingSetupSection(model: model)
            }
            if hasSyncNotice {
                Section("同步状态") {
                    if model.pending > 0 {
                        LabeledContent("待上传", value: "\(model.pending) 项")
                            .accessibilityIdentifier("capture-pending")
                    }
                    if model.held > 0 {
                        LabeledContent("校验冲突保留", value: "\(model.held) 项")
                            .foregroundStyle(.orange)
                    }
                    if serviceNeedsAttention {
                        Text(model.serviceMessage).foregroundStyle(.secondary)
                    }
                    // The existing message channel contains both progress and errors.
                    // Keep it visible until the model supplies structured severity.
                    if let message = model.message {
                        Text(message).foregroundStyle(.orange)
                    }
                    if let error = model.capture.error, error != model.message {
                        Text(error).foregroundStyle(.orange)
                    }
                    if model.connection == nil || [401, 403].contains(model.uploadQueue?.lastHTTPStatus) {
                        NavigationLink("检查处理服务") { XinlikaConnectionView(model: model) }
                    } else if model.uploadQueue?.phase == .blocked || model.serviceResultsUnavailable
                                || model.capture.error != nil || model.message != nil {
                        Button("重试连接与上传") { model.retryUploads() }
                    }
                }
            }
            if !failedJobs.isEmpty {
                Section("整理需处理") {
                    ForEach(failedJobs) { job in
                        XinlikaProcessingJobRow(model: model, job: job)
                    }
                }
            }
            XinlikaSyncDetailsSection(model: model, jobs: waitingJobs)
            Section {
                NavigationLink { WatchCaptureView() } label: {
                    Label("Apple Watch 录音", systemImage: "applewatch")
                }
                NavigationLink { XinlikaVoiceView(model: model) } label: {
                    Label("我的声音", systemImage: "person.wave.2")
                }
            }
        }
        .navigationTitle("录音")
    }
}

private struct XinlikaCurrentRecordingSection: View {
    @Bindable var model: XinlikaModel
    let session: XinlikaCaptureStore.Session

    var body: some View {
        Section("本次记录") {
            LabeledContent("状态", value: model.captureLabel)
                .accessibilityIdentifier("capture-status")
            if model.recording {
                Button(session.focus == nil ? "标记片段" : "结束标记", systemImage: "bookmark") {
                    model.focus()
                }
                .accessibilityIdentifier("capture-mark")
                Button("结束并保存", role: .destructive) { Task { await model.stop() } }
                    .disabled(model.busy)
                    .accessibilityIdentifier("capture-stop")
            }
            if !model.cardAligned {
                if session.referenceQueued == true {
                    LabeledContent("原声", value: "等待服务核对")
                } else if !model.recording && session.automaticReference == true {
                    LabeledContent("原声", value: "正在补齐原声")
                }
                if session.gaps > 0 {
                    Text(model.gapLabel).foregroundStyle(.orange)
                        .accessibilityIdentifier("capture-gap")
                }
            }
        }
    }
}

private struct XinlikaRecordingSetupSection: View {
    @Bindable var model: XinlikaModel

    var body: some View {
        Section("录音卡") {
            if let name = model.capturePreferences.deviceName {
                LabeledContent("已选录音卡", value: name)
            }
            if model.selectedDevice == nil {
                XinlikaRecordingDeviceChoices(model: model)
            } else {
                DisclosureGroup("更换录音卡") {
                    XinlikaRecordingDeviceChoices(model: model)
                }
            }
            Picker("声音来源", selection: $model.capturePreferences.source) {
                Text("现场对话").tag("live_conversation")
                Text("背景播放").tag("background_playback")
                Text("尚未确定").tag("unknown")
            }
            Text(model.capturePreferences.automaticHardwareCapture ? model.hardwareStatus : "机身录音自动接入已关闭")
                .font(.caption).foregroundStyle(.secondary)
            Button("开始录音", systemImage: "record.circle") {
                Task { await model.start(source: model.capturePreferences.source, processing: model.capturePreferences.processing) }
            }
            .disabled(model.selectedDevice == nil || !model.canStartCapture || model.store == nil)
            .accessibilityIdentifier("capture-start")
            DisclosureGroup("录音设置") {
                Toggle("自动转写并整理", isOn: $model.capturePreferences.processing)
                Toggle("自动接入机身录音", isOn: $model.capturePreferences.automaticHardwareCapture)
                Text("机身开始录音后，沿用这里的声音来源和整理设置。App 需已连接录音卡；强制退出后无法实时接收，重新打开会检查正在进行的录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct XinlikaRecordingDeviceChoices: View {
    @Bindable var model: XinlikaModel

    var body: some View {
        Button("查找附近录音卡") { Task { await model.scan() } }.disabled(model.busy)
        ForEach(model.devices, id: \.peripheral.identifier) { device in
            Button {
                Task { await model.selectDevice(device.peripheral.identifier) }
            } label: {
                HStack {
                    Text(device.name)
                    Spacer()
                    if model.selectedDevice == device.peripheral.identifier {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(model.busy)
        }
    }
}

private struct XinlikaSyncDetailsSection: View {
    @Bindable var model: XinlikaModel
    let jobs: [HeartballAgentState.Job]

    var body: some View {
        Section {
            DisclosureGroup {
                if let session = model.session {
                    if let origin = session.captureOrigin {
                        LabeledContent("采集入口", value: origin == "hardware" ? "机身录音自动接入" : "App 发起")
                    }
                    LabeledContent("已收原声", value: "\(session.streams.reduce(0) { $0 + $1.received } / 2000) 秒")
                    if model.cardAligned {
                        LabeledContent("原声", value: "当前文件已对齐")
                        if let segments = session.recoveredSegments, !segments.isEmpty {
                            LabeledContent("后续分段", value: "已发现 \(segments.count) 份")
                        }
                        if session.gaps > 0 {
                            Text(model.gapLabel).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("history-gap")
                        }
                    }
                }
                LabeledContent("待传", value: "\(model.pending) 项")
                Text(model.serviceMessage).foregroundStyle(.secondary)
                Button("重试连接与上传") { model.retryUploads() }
                NavigationLink("处理服务") { XinlikaConnectionView(model: model) }
                if !jobs.isEmpty {
                    DisclosureGroup("整理任务 · \(jobs.count) 项") {
                        ForEach(jobs) { job in
                            XinlikaProcessingJobRow(model: model, job: job)
                        }
                    }
                }
                if model.historicalMessages > 0 {
                    DisclosureGroup("历史服务记录 · \(model.historicalMessages) 项") {
                        Text("旧服务的待传与校验记录已保留，不影响当前服务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("同步详情").accessibilityIdentifier("capture-sync-details")
            }
        }
    }
}

private struct XinlikaProcessingJobRow: View {
    @Bindable var model: XinlikaModel
    let job: HeartballAgentState.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.kind == "asr_audio" ? "语音转写" : "内容整理")
            Text(job.error == "provider_busy" ? "语音服务忙，稍后继续" : job.status == "blocked_provider" ? "服务凭据或额度需检查" : job.status == "failed" ? "暂未完成，原声保留" : "等待处理")
                .font(.caption).foregroundStyle(.secondary)
            if ["failed", "blocked_provider"].contains(job.status) {
                Button("重试") { Task { await model.retryProcessing(job.id) } }
            }
        }
    }
}

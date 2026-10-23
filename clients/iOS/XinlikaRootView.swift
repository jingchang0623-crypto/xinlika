// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import SwiftUI
import AVFoundation

struct XinlikaRootView: View {
    @State private var model: XinlikaModel?
    var body: some View {
        Group {
            if let model { XinlikaWorkspaceView(model: model) }
            else { ProgressView("正在恢复记录") }
        }
        .task { if model == nil { model = XinlikaModel.shared } }
    }
}

private struct XinlikaWorkspaceView: View {
    @Bindable var model: XinlikaModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { XinlikaTodayView(model: model) }
                .tabItem { Label("今天", systemImage: "sun.max") }.tag(0)
            NavigationStack {
                List(model.agent?.topics ?? []) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(topic.title).font(.headline)
                        Text(topic.summary).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(topic.conversationCount) 段对话").font(.caption).foregroundStyle(.secondary)
                    }
                }.navigationTitle("主题")
            }.tabItem { Label("主题", systemImage: "square.stack") }.tag(1)
            NavigationStack { XinlikaMemoryView(model: model) }
                .tabItem { Label("Agent", systemImage: "bubble.left.and.bubble.right") }.tag(2)
            NavigationStack { XinlikaCardView(model: model) }
                .tabItem { Label("录音卡", systemImage: "waveform") }.tag(3)
        }
        .tint(Color.accentColor)
        .onChange(of: scenePhase, initial: true) { _, value in model.sceneChanged(active: value == .active) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BackgroundUploader.finished)) { _ in
            model.reload(); model.pumpUploads()
        }
    }
}

private struct XinlikaTodayView: View {
    @Bindable var model: XinlikaModel
    @State private var search = ""
    @State private var showDates = false
    @State private var focusOnly = false
    @State private var showTextEntry = false
    @State private var draft = ""
    private var events: [HeartballAgentState.SemanticEvent] {
        guard model.agent?.today?.date == dateKey else { return [] }
        var seen = Set<String>()
        return (model.agent?.today?.groups.flatMap(\.events) ?? [])
            .filter { seen.insert($0.id).inserted }
            .filter { !focusOnly || $0.kind == "focus" }
            .filter { search.isEmpty || ($0.title + $0.summary).localizedStandardContains(search) }
            .sorted { ($0.recordingDate ?? .distantPast, $0.id) > ($1.recordingDate ?? .distantPast, $1.id) }
    }
    private enum Item: Identifiable {
        case event(HeartballAgentState.SemanticEvent)
        case activity(HeartballAgentState.Day.Group)
        var id: String { switch self { case .event(let e): return "event:" + e.id; case .activity(let g): return g.id } }
        var date: Date { switch self { case .event(let e): return e.recordingDate ?? .distantPast; case .activity(let g): return xinlikaTimelineDate(g.startLocal) ?? .distantPast } }
    }
    private var items: [Item] {
        guard model.agent?.today?.date == dateKey else { return [] }
        guard !focusOnly && search.isEmpty else { return events.map(Item.event) }
        var used = Set<String>(), output: [Item] = []
        for group in model.agent?.today?.groups ?? [] {
            let ordinary = group.events.filter { $0.kind != "focus" }
            // Only an actual AI activity is a container. A physical session is not a scene.
            if let kind = group.activityKind, kind != "unclassified", kind != "unknown", ordinary.count > 1 {
                output.append(.activity(group)); used.formUnion(ordinary.map(\.id))
            }
        }
        output += events.filter { !used.contains($0.id) }.map(Item.event)
        return output.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
    private var date: Date { model.selectedDay ?? .now }
    private var dateKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Button { showDates = true } label: {
                        HStack(spacing: 6) {
                            Text(date.formatted(.dateTime.month(.twoDigits).day().weekday(.wide)))
                            Image(systemName: "chevron.down").font(.caption)
                        }.font(.headline)
                    }.tint(.primary)
                    Spacer()
                    Menu {
                        Button("全部事件") { focusOnly = false }
                        Button("重点片段") { focusOnly = true }
                    } label: {
                        Label(focusOnly ? "重点" : "全部", systemImage: "line.3.horizontal.decrease").font(.subheadline)
                    }.tint(.secondary)
                }
                if model.recording || model.pending > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: model.recording ? "waveform" : "arrow.up.circle")
                        Text(model.recording ? model.captureLabel : "正在同步")
                        Spacer()
                        if model.pending > 0 { Text("\(model.pending)").monospacedDigit() }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 14) {
                    ForEach(items) { item in
                        switch item {
                        case .event(let event):
                            NavigationLink { XinlikaEventView(model: model, event: event) } label: { XinlikaTimelineRow(event: event) }.buttonStyle(.plain)
                        case .activity(let group):
                            NavigationLink { XinlikaActivityView(model: model, group: group) } label: { XinlikaActivityRow(group: group) }.buttonStyle(.plain)
                        }
                    }
                }
                if model.connection == nil {
                    ContentUnavailableView("连接你的心力卡服务", systemImage: "network", description: Text("点右上角设置，填写自己的服务地址和设备凭据。"))
                } else if model.agent?.today?.date != dateKey {
                    ProgressView("载入记录").frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if events.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "还没有整理好的事件" : "没有找到事件", systemImage: "waveform")
                }
                if let unknown = model.agent?.today?.unknownTimeCount, unknown > 0 {
                    Text("\(unknown) 项录制时间待核对").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("今天")
        .searchable(text: $search, prompt: "搜索这一天")
        .toolbar {
            Button("补充记录", systemImage: "plus") { showTextEntry = true }
                .disabled(model.connection == nil).accessibilityIdentifier("addTextRecord")
            NavigationLink { XinlikaConnectionView(model: model) } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("设置").accessibilityIdentifier("connectionSettings")
        }
        .sheet(isPresented: $showTextEntry) {
            NavigationStack {
                Form {
                    TextEditor(text: $draft).frame(minHeight: 160).accessibilityIdentifier("recordText")
                    if let message = model.message { Text(message).foregroundStyle(.orange) }
                }.navigationTitle("补充记录")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showTextEntry = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("整理") { Task { if await model.submitText(draft) { draft = ""; showTextEntry = false } } }
                                .disabled(model.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 4000)
                                .accessibilityIdentifier("submitTextRecord")
                        }
                    }
            }
        }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showDates) {
            NavigationStack {
                DatePicker("记录日期", selection: Binding(get: { date }, set: { model.selectedDay = $0 }), in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("今天") { model.selectedDay = nil; showDates = false; Task { await model.refresh() } } }
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showDates = false; Task { await model.refresh() } } }
                    }
            }.presentationDetents([.medium, .large])
        }
    }
}

private func xinlikaTimelineDate(_ text: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = f.date(from: text) { return date }
    f.formatOptions = [.withInternetDateTime]; return f.date(from: text)
}
private struct XinlikaActivityRow: View {
    let group: HeartballAgentState.Day.Group
    private var clock: String {
        guard let a = xinlikaTimelineDate(group.startLocal), let b = xinlikaTimelineDate(group.endLocal) else { return "时间待核对" }
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return a.formatted(style) + "–" + b.formatted(style)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 10) {
                Circle().fill(Color.brown.opacity(0.7)).frame(width: 9, height: 9)
                Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 12).padding(.top, 24)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title).font(.headline).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(clock).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let summary = group.summary, !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }.accessibilityElement(children: .combine)
    }
}
private struct XinlikaActivityView: View {
    @Bindable var model: XinlikaModel
    let group: HeartballAgentState.Day.Group
    @State private var summaryExpanded = false
    private var current: HeartballAgentState.Day.Group { model.agent?.today?.groups.first { $0.id == group.id } ?? group }
    private var events: [HeartballAgentState.SemanticEvent] {
        current.events.filter { $0.kind != "focus" }
            .sorted { ($0.recordingDate ?? .distantFuture, $0.id) < ($1.recordingDate ?? .distantFuture, $1.id) }
    }
    private var recordingTime: String {
        guard let start = xinlikaTimelineDate(current.startLocal), let end = xinlikaTimelineDate(current.endLocal) else { return "录制时间待核对" }
        let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let day = start.formatted(.dateTime.month().day())
        let endDay = Calendar.current.isDate(start, inSameDayAs: end) ? "" : end.formatted(.dateTime.month().day()) + " "
        return day + " · 约 " + start.formatted(clock) + "–" + endDay + end.formatted(clock)
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(recordingTime).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let summary = current.summary, !summary.isEmpty {
                        Text(summary).foregroundStyle(.secondary).lineLimit(summaryExpanded ? nil : 3)
                        if summary.count > 60 {
                            Button(summaryExpanded ? "收起概览" : "展开概览") { summaryExpanded.toggle() }
                                .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            ForEach(events) { event in
                NavigationLink { XinlikaEventView(model: model, event: event) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.title).font(.headline)
                            Spacer(minLength: 8)
                            if let date = event.recordingDate {
                                Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text(event.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }.navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
    }
}

private struct XinlikaTimelineRow: View {
    let event: HeartballAgentState.SemanticEvent
    private var clock: String {
        if let date = event.recordingDate {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        if let raw = event.recordedLocalTime { return String(raw.dropFirst(11).prefix(5)) }
        return "时间待核对"
    }
    private var rich: Bool { event.kind == "focus" || (event.sources.count >= 3 && event.summary.count > 65) }
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 10) {
                Circle().fill(event.kind == "focus" ? Color.orange : Color.brown.opacity(0.7)).frame(width: 9, height: 9)
                Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 12).padding(.top, 24)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(event.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(clock).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if event.kind == "focus" { Label("重点", systemImage: "bookmark.fill").font(.caption).foregroundStyle(.orange) }
                if rich { Text(event.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }.accessibilityElement(children: .combine)
    }
}

private struct XinlikaEventView: View {
    @Bindable var model: XinlikaModel
    let event: HeartballAgentState.SemanticEvent
    @State private var player: AVAudioPlayer?
    @State private var editing: HeartballAgentState.Document?
    private var currentEvent: HeartballAgentState.SemanticEvent? {
        let events = (model.agent?.today?.groups.flatMap(\.events) ?? []) + (model.agent?.events ?? [])
        return events.first { $0.id == event.id }
    }
    private var documents: [HeartballAgentState.Document] {
        guard let currentEvent else { return [] }
        return (model.agent?.documents.filter { doc in doc.status != "superseded" && currentEvent.sources.contains { $0.documentId == doc.id } } ?? [])
            .sorted { ($0.recordingDate ?? .distantPast, $0.id) < ($1.recordingDate ?? .distantPast, $1.id) }
    }
    private func sourceText(for document: HeartballAgentState.Document) -> String {
        (currentEvent?.sources.filter { $0.documentId == document.id }.map(\.quote) ?? []).joined(separator: "\n…\n")
    }
    private func sourceTime(for document: HeartballAgentState.Document) -> String {
        if let raw = document.occurredAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
                return "约 " + date.formatted(.dateTime.month().day().hour().minute())
            }
        }
        if let raw = document.recordedLocalTime { return "设备时间 " + raw.replacingOccurrences(of: "T", with: " ").prefix(16) }
        return "录制时间未知"
    }
    var body: some View {
        List {
            if let currentEvent {
                Section {
                    Text(currentEvent.summary).textSelection(.enabled)
                    if let date = currentEvent.recordingDate {
                        Text("约 " + date.formatted(.dateTime.month().day().hour().minute()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("记录已更新", systemImage: "arrow.triangle.2.circlepath",
                    description: Text("返回今天查看最新内容。"))
            }
            ForEach(documents) { doc in
                Section {
                    DisclosureGroup("原文和原声") {
                        Text(sourceText(for: doc)).textSelection(.enabled)
                        if sourceText(for: doc) != doc.text {
                            DisclosureGroup("完整转写") { Text(doc.text).textSelection(.enabled) }
                        }
                        ForEach(Array(Set(doc.evidence.compactMap(\.batchId))).sorted(), id: \.self) { bid in
                            Button("回听原声", systemImage: "play.circle") {
                                Task {
                                    guard let connection = model.connection else { return }
                                    do {
                                        let client = try HeartballClient(baseURL: connection.baseURL, token: connection.token, allowPrivateHTTP: true)
                                        let data = try await client.audio(batchID: bid)
                                        try AVAudioSession.sharedInstance().setCategory(.playback)
                                        player = try AVAudioPlayer(data: data); player?.play()
                                    } catch { model.message = "原声暂不可用" }
                                }
                            }
                        }
                    }
                    Button("纠正内容或来源") { editing = doc }
                } header: { Text(sourceTime(for: doc)) }
            }
        }.navigationTitle(currentEvent?.title ?? "记录已更新").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { doc in XinlikaCorrectionView(model: model, document: doc) }
        .onDisappear { player?.stop() }
    }
}

private struct XinlikaCorrectionView: View {
    @Bindable var model: XinlikaModel
    let document: HeartballAgentState.Document
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var source = "unknown"
    var body: some View {
        NavigationStack {
            Form {
                Section("原文") { TextEditor(text: $text).frame(minHeight: 220).accessibilityIdentifier("correctionText") }
                Picker("声音来源", selection: $source) {
                    Text("现场对话").tag("live_conversation")
                    Text("背景播放").tag("background_playback")
                    Text("尚未确定").tag("unknown")
                    Text("文字记录").tag("verified_text")
                }
                if let message = model.message { Text(message).foregroundStyle(.orange) }
            }.navigationTitle("纠正记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await model.feedback(target: document.id, action: "correct_document", version: document.revision,
                                values: ["text": text, "source_kind": source]) { dismiss() }
                        }
                    }.accessibilityIdentifier("saveCorrection")
                }
            }
        }.onAppear { text = document.text; source = document.sourceKind }
    }
}

private struct XinlikaMemoryView: View {
    @Bindable var model: XinlikaModel
    @State private var section = "聊天"
    @State private var question = ""
    var body: some View {
        VStack(spacing: 0) {
            Picker("内容", selection: $section) { ForEach(["聊天", "记忆", "约定"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented).padding()
            List {
                if section == "聊天" {
                    ForEach(model.agent?.answers ?? []) { answer in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(answer.question).font(.headline)
                            Text(answer.answer.isEmpty ? "正在查询…" : answer.answer).textSelection(.enabled)
                            if answer.status == "stale" { Text("依据已有更新，请重新查询").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    ForEach((model.agent?.claims ?? []).filter { claim in
                        !["rejected", "superseded"].contains(claim.status) && (section != "约定" || claim.kind == "commitment")
                    }) { claim in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(claim.statement)
                            Text([claim.owner, claim.dueAt ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(claim.quote).font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                if claim.status != "completed" {
                                    Button("完成") { Task { await model.feedback(target: claim.id, action: "complete", version: claim.version) } }
                                }
                                Button("归属有误") { Task { await model.feedback(target: claim.id, action: "reject", version: claim.version) } }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            if section == "聊天" {
                HStack {
                    TextField("问问你的记录", text: $question, axis: .vertical).lineLimit(1...4).accessibilityIdentifier("agentQuestion")
                    Button("发送", systemImage: "arrow.up.circle.fill") {
                        let sent = question; question = ""; Task { await model.ask(sent) }
                    }.labelStyle(.iconOnly).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("sendQuestion")
                }.padding().background(.bar)
            }
        }.navigationTitle("Agent")
    }
}

private struct XinlikaCardView: View {
    @Bindable var model: XinlikaModel
    @State private var source = "unknown"
    @State private var processing = true
    var body: some View {
        Form {
            if let session = model.session {
                Section("本次记录") {
                    LabeledContent("状态", value: model.captureLabel)
                    LabeledContent("已收原声", value: "\(session.streams.reduce(0) { $0 + $1.received } / 2000) 秒")
                    LabeledContent("待传", value: "\(model.pending) 项")
                    if model.held > 0 { LabeledContent("校验冲突保留", value: "\(model.held) 项") }
                    if model.cardAligned {
                        LabeledContent("原声", value: "当前文件已对齐")
                        if let segments = session.recoveredSegments, !segments.isEmpty { LabeledContent("后续分段", value: "已发现 \(segments.count) 份") }
                    } else if session.referenceQueued == true {
                        LabeledContent("原声", value: "等待服务核对")
                    }
                    if session.gaps > 0 { Text(model.gapLabel).foregroundStyle(.orange) }
                    if model.recording {
                        Button(session.focus == nil ? "开始重点" : "结束重点", systemImage: "bookmark") { model.focus() }
                        Button("结束并保存", role: .destructive) { Task { await model.stop() } }.disabled(model.busy)
                    } else if session.automaticReference == true && session.referenceQueued != true {
                        LabeledContent("原声", value: "自动补齐中，支持断点续传")
                    }
                }
            }
            if !model.recording {
                Section("录音卡") {
                    Button("查找附近录音卡") { Task { await model.scan() } }.disabled(model.busy)
                    ForEach(model.devices, id: \.peripheral.identifier) { device in
                        Button {
                            model.selectedDevice = device.peripheral.identifier
                        } label: {
                            HStack { Text(device.name); Spacer(); if model.selectedDevice == device.peripheral.identifier { Image(systemName: "checkmark") } }
                        }
                    }
                    Picker("声音来源", selection: $source) {
                        Text("现场对话").tag("live_conversation")
                        Text("背景播放").tag("background_playback")
                        Text("尚未确定").tag("unknown")
                    }
                    Toggle("自动转写并整理", isOn: $processing)
                    Button("开始持续记录", systemImage: "record.circle") { Task { await model.start(source: source, processing: processing) } }
                        .disabled(model.selectedDevice == nil || model.busy || model.store == nil)
                }
            }
            Section {
                Text(model.serviceMessage).foregroundStyle(.secondary)
                if model.connection != nil {
                    LabeledContent("文字整理", value: model.agentConfigured ? "已配置" : "未配置")
                    LabeledContent("语音识别", value: model.asrConfigured ? "已配置" : "未配置")
                }
                if let message = model.message ?? model.capture.error { Text(message).foregroundStyle(.orange) }
                Button("重试连接和待传录音") { model.retryUploads() }
                NavigationLink("处理服务") { XinlikaConnectionView(model: model) }
                NavigationLink { XinlikaVoiceView(model: model) } label: { Label("我的声音", systemImage: "person.wave.2") }
            }
            if model.historicalMessages > 0 {
                Section {
                    DisclosureGroup("历史服务记录 · \(model.historicalMessages) 项") {
                        Text("旧服务的待传与校验记录已保留，不影响当前服务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            let waiting = model.agent?.processingJobs.filter { !["completed", "superseded"].contains($0.status) } ?? []
            if !waiting.isEmpty {
                Section("正在整理") {
                    ForEach(waiting) { job in
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
            }
        }.navigationTitle("录音卡")
    }
}

private struct XinlikaVoiceView: View {
    @Bindable var model: XinlikaModel
    @State private var solo = false
    var body: some View {
        Form {
            Section {
                if model.voiceStatus?.profileVersion != nil {
                    Label("声纹已登记", systemImage: "checkmark.circle")
                    Text("声音相近仍可能来自回放，系统会结合会议和内容判断。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("用录音卡录三段自己的声音，每段约 45–60 秒。请在安静环境，关闭音乐和视频。").foregroundStyle(.secondary)
                }
            }
            if model.voiceStatus?.status == "collecting" {
                Section("登记样本") {
                    Toggle("当前只有我说话，没有设备播放", isOn: $solo)
                    ForEach([1, 2, 3], id: \.self) { slot in
                        let sample = model.voiceStatus?.samples.first { $0.slot == slot }
                        HStack {
                            Text(slot == 3 ? "独立复核" : "第 \(slot) 段")
                            Spacer()
                            if sample?.status == "ready" {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("样本已通过质量检查")
                            } else if sample?.status == "waiting_audio" {
                                Text("等待原声处理").foregroundStyle(.secondary)
                            } else {
                                Button(sample?.status == "rejected" ? "重新录制" : "开始录制") { Task { await model.startVoiceSample(slot: slot) } }
                                    .disabled(!solo || model.recording || model.busy || model.selectedDevice == nil)
                            }
                        }
                    }
                    if model.recording, model.voiceSessionID == model.session?.id {
                        Text("自然说 45–60 秒，说完点完成这段。").foregroundStyle(.secondary)
                        Button("完成这段") { Task { await model.stop(); await model.refreshVoice() } }.disabled(model.busy)
                    }
                    if model.selectedDevice == nil { Text("先在录音卡页选择设备。").font(.caption).foregroundStyle(.secondary) }
                }
            } else if model.voiceStatus?.profileVersion == nil {
                Button("开始登记我的声音") { Task { await model.beginVoiceEnrollment() } }.disabled(model.recording || model.busy)
            }
            if model.voiceStatus?.enrollmentId != nil {
                Button("停用声纹", role: .destructive) { Task { await model.revokeVoice() } }.disabled(model.recording)
            }
            Button("只读核对录音卡") { Task { await model.inspectCardForVoice() } }.disabled(model.busy || model.recording)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .navigationTitle("我的声音")
        .task {
            while !Task.isCancelled {
                await model.refreshVoice()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
}

private struct XinlikaConnectionView: View {
    @Bindable var model: XinlikaModel
    @State private var address = ""
    @State private var token = ""
    var body: some View {
        Form {
            Section("处理服务") {
                TextField("服务地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("serverAddress")
                SecureField("访问凭据", text: $token).textInputAutocapitalization(.never).accessibilityIdentifier("deviceToken")
                Button("连接并保存") { Task { await model.configure(address: address, token: token) } }.accessibilityIdentifier("saveConnection")
                Text(model.serviceMessage).foregroundStyle(.secondary)
                if let message = model.message { Text(message).foregroundStyle(.orange) }
            }
        }.navigationTitle("设置")
        .onAppear { address = model.connection?.baseURL.absoluteString ?? ""; token = model.connection?.token ?? "" }
    }
}

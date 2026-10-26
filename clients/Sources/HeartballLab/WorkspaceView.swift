// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import SwiftUI
import LuyinbiCore

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case today = "今天", topics = "主题", agent = "Agent", records = "记录", actions = "行动", memory = "记忆", processing = "处理中心", device = "录音卡"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .topics: return "square.stack"
        case .agent: return "bubble.left.and.bubble.right"
        case .records: return "waveform"
        case .actions: return "checklist"
        case .memory: return "square.stack.3d.up"
        case .processing: return "arrow.triangle.2.circlepath"
        case .device: return "externaldrive"
        }
    }
    var subtitle: String {
        switch self {
        case .today: return "这一天发生的事。"
        case .topics: return "跨对话的进展。"
        case .agent: return "随时问问你的记录。"
        case .records: return "按录音会话归集，重点片段独立留下。"
        case .actions: return "从对话里确认的承诺，跟进到完成。"
        case .memory: return "事实、承诺与依赖，由你核对和纠正。"
        case .processing: return "转写、整理和问答的实际处理状态。"
        case .device: return "录音卡的采集状态，以及声音的去向。"
        }
    }
}

@available(macOS 14, *)
@MainActor
struct LabView: View {
    @State private var model = LabModel()
    @AppStorage("xinlika.appearance") private var appearance = "system"
    @State private var page: WorkspacePage = .today
    @State private var claimStatus = "all"
    @State private var claimKind = "all"
    @State private var project = "all"
    @State private var recordFilter = "all"
    @State private var jobFilter = "all"
    @State private var search = ""
    @State private var selectedClaimID: String?
    @State private var selectedRecordID: String?
    @State private var selectedTopicID: String?
    @State private var selectedEvent: HeartballAgentState.SemanticEvent?
    @State private var showingCaptureSetup = false
    @State private var agentSection = "聊天"
    @State private var sharedServerAddress = ""
    @State private var sharedDeviceToken = ""
    @State private var showingText = false
    @State private var showingDayPicker = false
    @State private var editingClaim: HeartballAgentState.Claim?
    @State private var editingDocument: HeartballAgentState.Document?

    private var documents: [HeartballAgentState.Document] { model.agentState?.documents.filter { $0.status != "superseded" } ?? [] }
    private var events: [HeartballAgentState.SemanticEvent] {
        let recent = model.agentState?.events ?? []
        let ids = Set(recent.map(\.id))
        return recent + (model.agentState?.today?.groups.flatMap(\.events).filter { !ids.contains($0.id) } ?? [])
    }
    private var topics: [HeartballAgentState.Topic] { model.agentState?.topics ?? [] }
    private func audioBatches(_ event: HeartballAgentState.SemanticEvent) -> Set<String> {
        Set(documents.filter { doc in event.sources.contains { $0.documentId == doc.id } }.flatMap(\.evidence).compactMap(\.batchId))
    }
    private func attachedFocuses(_ event: HeartballAgentState.SemanticEvent) -> [HeartballAgentState.SemanticEvent] {
        guard event.kind != "focus" else { return [] }
        let batches = audioBatches(event)
        return events.filter { $0.kind == "focus" && $0.sessionId == event.sessionId && !batches.isDisjoint(with: audioBatches($0)) }
    }
    private var timelineEvents: [HeartballAgentState.SemanticEvent] {
        let attached = Set(events.filter { $0.kind != "focus" }.flatMap { attachedFocuses($0).map(\.id) })
        return events.filter { !attached.contains($0.id) }
    }
    private var currentClaims: [HeartballAgentState.Claim] { model.agentState?.claims.filter { !["rejected", "superseded"].contains($0.status) } ?? [] }
    private var viewingActions: Bool { page == .actions || (page == .agent && agentSection == "约定") }
    private var viewingMemory: Bool { page == .memory || (page == .agent && agentSection == "记忆") }
    private var pending: [HeartballAgentState.Claim] { currentClaims.filter { $0.status == "proposed" } }
    private var advice: [HeartballAgentState.Advice] { model.agentState?.advice.filter { $0.status == "active" } ?? [] }
    private var jobs: [HeartballAgentState.Job] { model.agentState?.processingJobs ?? [] }
    private var needsAttention: [HeartballAgentState.Job] { jobs.filter { ["failed", "blocked_provider", "blocked_quality_review"].contains($0.status) } }
    private var filteredJobs: [HeartballAgentState.Job] {
        jobs.filter { jobFilter == "all" || (jobFilter == "running" ? ["queued", "running", "retryable"].contains($0.status) : ["failed", "blocked_provider", "blocked_quality_review"].contains($0.status)) }
    }
    private var waitingJobs: [HeartballAgentState.Job] { jobs.filter { ["queued", "running", "retryable"].contains($0.status) } }
    private var projects: [String] { Array(Set(currentClaims.map { $0.project.isEmpty ? "未关联项目" : $0.project })).sorted() }
    private var collections: [RecordCollection] { RecordCollection.make(documents, focusOnly: recordFilter == "focus") }
    private var visibleRecords: [RecordCollection] {
        collections.filter { group in matches([group.title] + group.documents.map(\.text) + group.documents.map(\.summary)) }
    }
    private var visibleClaims: [HeartballAgentState.Claim] {
        currentClaims.filter {
            (!viewingActions || $0.kind == "commitment") &&
            (claimStatus == "all" || $0.status == claimStatus) &&
            (claimKind == "all" || $0.kind == claimKind) &&
            (project == "all" || ($0.project.isEmpty ? "未关联项目" : $0.project) == project) &&
            matches([$0.statement, $0.owner, $0.project, $0.quote])
        }
    }
    private var selectedRecord: RecordCollection? { visibleRecords.first { $0.id == selectedRecordID } ?? visibleRecords.first }
    private var selectedClaim: HeartballAgentState.Claim? { visibleClaims.first { $0.id == selectedClaimID } ?? visibleClaims.first }
    private var status: String {
        guard model.captureConnected else { return "本机采集未连接" }
        switch model.state?.session?.status {
        case "starting": return "正在连接录音卡"
        case "recording": return "持续记录中"
        case "stopping": return "正在保存录音"
        case "reconciling": return "核对卡上录音中"
        case "completed": return "本次录音已归档"
        case "error", "interrupted": return "录音需要检查"
        default: return "录音卡待机"
        }
    }
    private func matches(_ values: [String]) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedStandardContains(query) }
    }
    private func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 184)
            Divider()
            VStack(spacing: 0) {
                header
                notices
                switch page {
                case .today: today
                case .topics: topicWorkspace
                case .agent: agentWorkspace
                case .records: records
                case .memory, .actions: memory
                case .processing: processing
                case .device: device
                }
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.primary)
        .background(XinlikaPalette.ground)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .tint(.primary)
        .groupBoxStyle(XinlikaGroupStyle())
        // At 1040pt: 184 navigation + 1 divider + 855 workspace.
        // Detail screens split the workspace 42/58; Today is a single event timeline.
        .frame(minWidth: 1040, minHeight: 700)
        .toolbar { ToolbarItem(placement: .automatic) { captureControls } }
        .sheet(item: $editingClaim) { claim in
            ClaimCorrection(claim: claim) { values in
                await model.feedback(target: claim.id, action: "correct", version: claim.version, values: values)
            }
        }
        .sheet(item: Binding(get: { selectedEvent == nil ? editingDocument : nil }, set: { editingDocument = $0 })) { doc in
            DocumentCorrection(document: doc) { text in
                await model.feedback(target: doc.id, action: "correct_document", version: doc.revision, values: ["text": text])
            }
        }
        .sheet(item: $selectedEvent) { event in eventDetail(event) }
        .onChange(of: model.agentState?.events) {
            if let selected = selectedEvent { selectedEvent = events.first { $0.id == selected.id } }
        }
        .onChange(of: model.agentState?.today) {
            if let selected = selectedEvent { selectedEvent = events.first { $0.id == selected.id } }
        }
        .sheet(isPresented: $showingText) { textEntry }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                XinlikaMark()
                VStack(alignment: .leading, spacing: 4) {
                    Text("心力卡").font(.system(size: 18, weight: .medium))
                    Text("个人空间").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                }
            }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 8)
            VStack(spacing: 4) {
                ForEach([WorkspacePage.today, .topics, .agent]) { item in nav(item) }
            }
            Spacer()
            nav(.device)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(model.connected ? Color.primary.opacity(0.7) : Color.orange).frame(width: 5, height: 5)
                    Text(model.connected ? (model.usingSharedWorkspace ? "共享工作区已连接" : "本机工作区可用") : "等待连接")
                }
            }.font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted).padding(.horizontal, 10)
        }.padding(12)
    }
    private func nav(_ item: WorkspacePage) -> some View {
        Button { go(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 18)
                Text(item.rawValue)
                Spacer()
                if item == .processing, !needsAttention.isEmpty { Text("\(needsAttention.count)").font(.system(size: 12)).monospacedDigit() }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(page == item ? XinlikaPalette.active : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("nav-\(item.id)")
    }
    private func go(_ destination: WorkspacePage) {
        if destination == .memory || destination == .actions {
            page = .agent; agentSection = destination == .actions ? "约定" : "记忆"
        } else {
            page = destination
            if destination == .agent { agentSection = "聊天" }
        }
        search = ""; project = "all"; claimKind = "all"
        if destination == .actions { claimStatus = "all" }
    }
    private func openClaim(_ id: String) {
        if let event = events.first(where: { $0.id == id }) { selectedEvent = event }
        else if topics.contains(where: { $0.id == id }) { go(.topics); selectedTopicID = id }
        else if let doc = documents.first(where: { $0.id == id }) {
            openRecord(doc.kind == "focus" ? "focus:" + doc.id : "session:" + (doc.sessionId ?? doc.id), focus: doc.kind == "focus")
        } else { go(.memory); claimStatus = "all"; selectedClaimID = id }
    }
    private func openRecord(_ id: String, focus: Bool = false) {
        go(.records); recordFilter = focus ? "focus" : "all"; selectedRecordID = id
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(page.rawValue).font(.system(size: 24, weight: .medium))
                    if page == .today {
                        Button { showingDayPicker = true } label: {
                            HStack(spacing: 5) {
                                Text(model.selectedDay ?? .now, format: .dateTime.month().day().weekday(.wide))
                                Image(systemName: "chevron.down").font(.caption)
                            }.foregroundStyle(XinlikaPalette.muted)
                        }.buttonStyle(.plain)
                        .popover(isPresented: $showingDayPicker) {
                            VStack(spacing: 14) {
                                DatePicker("记录日期", selection: Binding(get:{model.selectedDay ?? .now},set:{value in Task { await model.selectDay(value) }}),in: ...Date.now,displayedComponents: .date)
                                    .datePickerStyle(.graphical)
                                HStack {
                                    Button("今天") { showingDayPicker = false; Task { await model.selectDay(nil) } }
                                    Spacer()
                                    Button("完成") { showingDayPicker = false }
                                }
                            }.padding(18).frame(width: 300)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if page == .today { Button("全部记录") { go(.records) } }
            if page == .records || page == .today {
                Button("补充对话", systemImage: "plus") { showingText = true }.disabled(!model.connected || model.agentState == nil)
            }
        }.padding(24)
    }
    @ViewBuilder private var notices: some View {
        if page == .today {
            if model.connectionMessage != nil || (model.running && model.state?.session?.error != nil) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text("记录同步需要处理")
                    Spacer()
                    Button("查看") { go(.device) }
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal,24).padding(.bottom,12)
            }
        } else {
            if let message = model.connectionMessage { notice(message) }
            if let message = model.message { notice(message) }
            if let error = model.state?.session?.error { notice(error) }
            if let gaps = model.state?.session?.gapCount, gaps > 0 { notice("本次检测到 \(gaps) 次断连，已保留缺口信息。") }
        }
    }
    private func notice(_ message: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !model.connected { Button("重试") { Task { await model.refresh() } } }
        }.font(.system(size: 12)).padding(12).background(XinlikaPalette.surface, in: .rect(cornerRadius: 8))
            .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var captureControls: some View {
        HStack(spacing: 14) {
            Label(status, systemImage: model.recording ? "waveform" : "record.circle")
                .font(.system(size: 12)).foregroundStyle(model.recording ? XinlikaPalette.signal : XinlikaPalette.muted)
            if model.busy { ProgressView().controlSize(.small) }
            if model.running {
                Text(duration(model.state?.session?.audioSeconds ?? 0)).monospacedDigit().font(.system(size: 12))
                Button(model.activeFocus == nil ? "记下重点" : "结束重点", systemImage: "bookmark") { Task { await model.toggleFocus() } }
                    .disabled(!model.recording || model.busy || !model.captureConnected).accessibilityIdentifier("focusToggle")
                    .help("结束重点后，持续录音继续。")
                Button("结束录音", role: .destructive) { Task { await model.stop() } }
                    .disabled(model.busy || !model.captureConnected || !["starting", "recording"].contains(model.state?.session?.status ?? ""))
                    .accessibilityIdentifier("captureStop")
            } else {
                Button("开始记录", systemImage: "plus") { Task { await model.start() } }
                    .disabled(model.busy || !model.captureConnected).accessibilityIdentifier("captureSetup")
                    .popover(isPresented: $showingCaptureSetup) {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("开始一次持续记录").font(.system(size: 18, weight: .medium))
                            captureSettings
                            Button("开始本次记录") { showingCaptureSetup = false; Task { await model.start() } }
                                .buttonStyle(.borderedProminent).disabled(model.busy || !model.captureConnected || model.running)
                                .accessibilityIdentifier("captureStart")
                        }.padding(24).frame(width: 440).tint(.primary)
                    }
            }
        }.labelStyle(.titleAndIcon)
    }

    private var today: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !waitingJobs.isEmpty { Label("正在整理新内容", systemImage: "sparkle").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12) }
                if let day = model.agentState?.today, day.date == selectedDayKey {
                    if day.timelineEvents.isEmpty { WorkspaceEmpty(title: "今天还没有整理好的事项", detail: "开始记录后，会自动出现在这里。") }
                    ForEach(day.timelineEvents) { event in
                        Button { selectedEvent = event } label: { eventRow(event) }
                            .buttonStyle(.plain).accessibilityIdentifier("today-event-" + event.id)
                    }
                    if day.unknownTimeCount > 0 {
                        Button("\(day.unknownTimeCount) 条录制时间待核对", systemImage: "clock.badge.questionmark") { go(.records) }
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                } else { ProgressView("载入今天的记录").padding(.vertical, 24) }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }
    private var selectedDayKey: String {
        let f=DateFormatter();f.calendar=Calendar(identifier:.gregorian);f.locale=Locale(identifier:"en_US_POSIX");f.timeZone = .current;f.dateFormat="yyyy-MM-dd"
        return f.string(from:model.selectedDay ?? .now)
    }
    private var agentWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Agent", selection: $agentSection) {
                Text("聊天").tag("聊天")
                Text("记忆").tag("记忆")
                Text("约定").tag("约定")
            }.pickerStyle(.segmented).fixedSize().padding(.horizontal, 24)
            if agentSection == "聊天" {
                XinlikaConversation(model: model, openClaim: openClaim)
            } else {
                memory
            }
        }
    }
    private func eventDate(_ event: HeartballAgentState.SemanticEvent) -> String {
        XinlikaCopy.recordingDate(event.occurredAt, local: event.recordedLocalTime, basis: event.recordingTimeBasis)
    }
    private func eventRow(_ event: HeartballAgentState.SemanticEvent, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                Circle().fill(event.kind == "focus" ? Color.orange : Color.brown.opacity(0.7)).frame(width: 8, height: 8)
                Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 12).padding(.top, 20)
            VStack(alignment: .leading, spacing: 8) {
                if !compact, event.showsTimelineSummary, let category = event.categoryLabel {
                    Text(category).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(event.title).font(.system(size: 16, weight: .medium)).multilineTextAlignment(.leading).lineLimit(2)
                    Spacer(minLength: 12)
                    Text(event.recordingDate?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) ?? "时间待核对")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
                if !compact && event.showsTimelineSummary {
                    Text(event.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                if event.kind == "focus" || !attachedFocuses(event).isEmpty {
                    Label("重点", systemImage: "bookmark.fill").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(XinlikaPalette.surface, in: .rect(cornerRadius: 16))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(.rect)
    }
    private func eventDetail(_ event: HeartballAgentState.SemanticEvent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(event.title).font(.title2); Spacer(); Button("关闭") { selectedEvent = nil }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(event.summary).textSelection(.enabled)
                    Text(eventDate(event)).font(.caption).foregroundStyle(.secondary)
                    if event.recordingTimeBasis == "device_clock_unverified" {
                        Text("时间来自录音文件的设备时钟，尚未校准。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let topic = topics.first(where: { $0.id == event.topicId }) {
                        Button("查看主题 · " + topic.title) { selectedEvent = nil; go(.topics); selectedTopicID = topic.id }
                    }
                    ForEach(attachedFocuses(event)) { focus in
                        Button("重点 · " + focus.title, systemImage: "bookmark") { selectedEvent = focus }
                    }
                    DisclosureGroup("事项原句") {
                        Text(event.sources.map(\.quote).joined(separator: "\n…\n")).textSelection(.enabled)
                    }
                    DisclosureGroup("完整转写与原声") {
                        panelForDocuments(documents.filter { doc in event.sources.contains { $0.documentId == doc.id } })
                    }
                    Button("问问这件事", systemImage: "bubble.left") { selectedEvent = nil; go(.agent); model.memoryQuestion = "关于“\(event.title)”，有哪些进展和相关记录？" }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 680, height: 640)
            .sheet(item: $editingDocument) { doc in
                DocumentCorrection(document: doc) { text in
                    await model.feedback(target: doc.id, action: "correct_document", version: doc.revision, values: ["text": text])
                }
            }
    }
    private var topicWorkspace: some View {
        HSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if topics.isEmpty { WorkspaceEmpty(title: "还没有持续的话题", detail: "相关对话会自动关联到这里。") }
                    ForEach(topics) { topic in
                        Button { selectedTopicID = topic.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(topic.title).fontWeight(.medium)
                                Text("\(topic.conversationCount) 段记录").font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background((selectedTopicID ?? topics.first?.id) == topic.id ? XinlikaPalette.active : .clear, in: .rect(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            ScrollView {
                if let topic = topics.first(where: { $0.id == selectedTopicID }) ?? topics.first {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(topic.title).font(.title2)
                        Text(topic.summary).textSelection(.enabled)
                        Button("问问这个主题", systemImage: "bubble.left") { go(.agent); model.memoryQuestion = "\(topic.title)目前进展如何，有哪些变化？" }
                        Divider()
                        ForEach(topic.eventIds.compactMap { id in timelineEvents.first(where: { $0.id == id }) }) { event in
                            Button { selectedEvent = event } label: { eventRow(event) }.buttonStyle(.plain)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(minWidth: 360)
        }
    }
    private func sectionHeading(_ title: String, trailing: String, action: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.system(size: 16, weight: .medium)); Spacer(); Button(trailing, action: action).buttonStyle(.plain).font(.system(size: 12)) }
    }

    private var records: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("记录范围", selection: $recordFilter) {
                        Text("录音会话").tag("all"); Text("重点片段").tag("focus")
                    }.pickerStyle(.segmented).fixedSize()
                    searchField("搜索记录或转写")
                    Text("\(visibleRecords.count) \(recordFilter == "focus" ? "段重点" : "个会话")").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                    if model.activeFocus != nil { Text("正在记录重点，持续录音继续。").font(.system(size: 12)).foregroundStyle(XinlikaPalette.signal) }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleRecords) { group in
                                Button { selectedRecordID = group.id } label: {
                                    recordRow(group).background(selectedRecord?.id == group.id ? XinlikaPalette.active : .clear, in: .rect(cornerRadius: 6))
                                }.buttonStyle(.plain).accessibilityIdentifier("record-\(group.id)")
                            }
                            if visibleRecords.isEmpty {
                                WorkspaceEmpty(title: search.isEmpty ? "还没有这类记录" : "没有找到匹配记录", detail: search.isEmpty ? "录音会话会按同一条采集流归集。重点单独整理，不会停止持续录音。" : "换一个词，或清空搜索查看全部。")
                            }
                        }
                    }
                }.padding(.leading, 24).padding(.trailing, 16)
                    .frame(width: visibleRecords.isEmpty ? geometry.size.width : geometry.size.width * 0.42)
                if let group = selectedRecord {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text(group.isFocus ? "独立重点" : "录音会话").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                                Spacer()
                                Text(XinlikaCopy.dateLabel(group.representative)).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                            }
                            if group.isFocus, let sid = group.representative.sessionId {
                                Button("查看所属持续记录", systemImage: "arrow.turn.up.left") { openRecord("session:" + sid) }
                            }
                            panelForDocuments(group.documents)
                            if !group.isFocus, !group.focuses.isEmpty {
                                Text("独立重点 · \(group.focuses.count) 段").font(.system(size: 16, weight: .medium))
                                ForEach(group.focuses) { focus in
                                    Button { openRecord("focus:" + focus.id, focus: true) } label: {
                                        Label(focus.title, systemImage: "bookmark").multilineTextAlignment(.leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
    private func recordRow(_ group: RecordCollection, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.isFocus ? "重点片段" : "\(group.documents.count) 段记录 · \(group.focuses.count) 段重点")
                Spacer(minLength: 6)
                if !compact { Image(systemName: "chevron.right") }
            }.font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            Text(group.title).font(.system(size: 14, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
            Text(group.source + " · " + XinlikaCopy.dateLabel(group.representative))
                .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted).lineLimit(2)
        }.padding(.horizontal, 12).padding(.vertical, compact ? 14 : 16).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }

    private var memory: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("确认状态", selection: $claimStatus) {
                        if !viewingActions { Text("自动整理").tag("proposed") }
                        Text("已核实").tag("confirmed")
                        Text("已完成").tag("completed")
                        Text("全部").tag("all")
                    }.pickerStyle(.segmented).fixedSize()
                    searchField(viewingActions ? "搜索承诺或负责人" : "搜索事实、人物或项目")
                    HStack {
                        if viewingMemory {
                            Picker("类型", selection: $claimKind) {
                                Text("全部类型").tag("all"); Text("事实").tag("fact"); Text("承诺").tag("commitment"); Text("依赖").tag("dependency")
                            }.labelsHidden()
                        }
                        Picker("项目", selection: $project) {
                            Text("全部项目").tag("all")
                            ForEach(projects, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    Text("\(visibleClaims.count) 条\(viewingActions ? "承诺" : "记忆")").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleClaims) { claim in
                                Button { selectedClaimID = claim.id } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(claim.statement).lineLimit(3).multilineTextAlignment(.leading)
                                        HStack {
                                            Text(XinlikaCopy.kind(claim.kind) + " · " + (claim.owner == "unknown" ? "归属未识别" : claim.owner))
                                            Spacer(minLength: 4)
                                            Text(claim.status == "proposed" ? "自动整理" : XinlikaCopy.status(claim.status))
                                        }.font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selectedClaim?.id == claim.id ? XinlikaPalette.active : .clear, in: .rect(cornerRadius: 6)).contentShape(.rect)
                                }.buttonStyle(.plain).accessibilityIdentifier("claim-\(claim.id)")
                            }
                            if visibleClaims.isEmpty {
                                WorkspaceEmpty(title: viewingActions ? (claimStatus == "completed" ? "这里还没有已完成的承诺" : "这里还没有待跟进的承诺") : "这里还没有匹配的记忆",
                                               detail: viewingActions ? "对话里的约定会自动归集到这里。" : "换个筛选条件，或开始一次记录。")
                            }
                        }
                    }
                }.padding(.leading, 24).padding(.trailing, 16)
                    .frame(width: visibleClaims.isEmpty ? geometry.size.width : geometry.size.width * 0.42)
                if let claim = selectedClaim, let agent = model.agentState {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("记忆依据与修订").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                            panel(agent, section: .memory, claims: [claim.id], heading: false)
                            if let doc = agent.documents.first(where: { $0.id == claim.documentId }) {
                                Button("打开来源录音", systemImage: "arrow.up.right") {
                                    openRecord(doc.kind == "focus" ? "focus:" + doc.id : "session:" + (doc.sessionId ?? doc.id), focus: doc.kind == "focus")
                                }
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
    private func searchField(_ title: String) -> some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(XinlikaPalette.muted)
            TextField(title, text: $search).textFieldStyle(.plain).accessibilityLabel(title)
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
        }.padding(9).background(XinlikaPalette.surface, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(XinlikaPalette.border) }
    }

    private var processing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    processingCount("正在处理", waitingJobs.count)
                    processingCount("需要检查", needsAttention.count)
                    processingCount("已完成", jobs.filter { $0.status == "completed" }.count)
                }
                Picker("处理范围", selection: $jobFilter) {
                    Text("全部").tag("all"); Text("进行中").tag("running"); Text("需检查").tag("attention")
                }.pickerStyle(.segmented).fixedSize()
                Text("符合当前筛选：\(filteredJobs.count) 项").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                VStack(spacing: 0) {
                    ForEach(filteredJobs) { job in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(XinlikaCopy.job(job.kind))
                                if let error = job.error { Text(error).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted).textSelection(.enabled) }
                            }
                            Spacer()
                            Text("尝试 \(job.attempts) 次").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted).monospacedDigit()
                            Text(XinlikaCopy.status(job.status)).frame(width: 80, alignment: .trailing)
                                .foregroundStyle(["failed", "blocked_provider"].contains(job.status) ? .orange : .primary)
                        }.padding(.vertical, 14)
                        Divider()
                    }
                }
                if filteredJobs.isEmpty { WorkspaceEmpty(title: jobs.isEmpty ? "还没有后台处理任务" : "当前筛选下没有任务", detail: "转写、重点整理和记忆问答的进度会显示在这里。") }
                Text("这里只显示最近 100 项后台任务。处理成功表示技术步骤完成，不代表承诺已履行或事实已经确认。")
                    .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                if let agent = model.agentState, agent.advice.contains(where: { $0.status != "active" }) {
                    DisclosureGroup("已处理与失效的提醒") {
                        ForEach(agent.advice.filter { $0.status != "active" }) { item in
                            Text(item.title + (item.status == "invalidated" ? " · 依据已修订" : " · 已处理")).font(.system(size: 12))
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
    }
    private func processingCount(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            Text(model.agentState == nil ? "—" : "\(count)").font(.system(size: 24)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var device: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("工作区").font(.system(size: 16, weight: .medium))
                        Text(model.usingSharedWorkspace ? "共享服务 · \(model.sharedAddress)" : "本机记录").foregroundStyle(.secondary)
                        DisclosureGroup("连接共享服务") {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("服务器地址", text: $sharedServerAddress, prompt: Text("https://你的域名"))
                                    .accessibilityIdentifier("sharedServerAddress")
                                SecureField("设备凭据", text: $sharedDeviceToken).accessibilityIdentifier("sharedDeviceToken")
                                Button("连接") {
                                    Task { if await model.configureShared(address: sharedServerAddress, token: sharedDeviceToken) { sharedDeviceToken = "" } }
                                }.disabled(model.busy || sharedDeviceToken.isEmpty || sharedServerAddress.isEmpty)
                                    .accessibilityIdentifier("connectSharedWorkspace")
                                Text("连接后，事件、记忆和纠正使用共享工作区。本机录音控制独立保留。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(.top, 10)
                        }
                        if model.usingSharedWorkspace {
                            Button("查看本机记录") { Task { await model.useLocalWorkspace() } }.disabled(model.busy)
                        }
                    }
                }.onAppear { if sharedServerAddress.isEmpty { sharedServerAddress = model.sharedAddress } }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CB08 录音卡").font(.system(size: 16, weight: .medium))
                        Text(status).foregroundStyle(model.recording ? XinlikaPalette.signal : .primary)
                        LabeledContent("设备时间", value: model.state?.session?.clockStatus == "new_filename_matches_host_start" ? "已自动校准" : "本次未验证")
                        if let progress = model.agentState?.workspaceProgress {
                            LabeledContent("最近收到音频", value: XinlikaCopy.date(progress.receivedAt)?.formatted(.dateTime.month().day().hour().minute()) ?? "—")
                            LabeledContent("最近完成整理", value: XinlikaCopy.date(progress.organizedAt)?.formatted(.dateTime.month().day().hour().minute()) ?? "—")
                        }
                        HStack { Text("已接收音频"); Spacer(); Text(model.state.map { duration($0.session?.audioSeconds ?? 0) } ?? "—").monospacedDigit() }
                        HStack { Text("已保存批次"); Spacer(); Text(model.state.map { "\($0.session?.batchCount ?? 0)" } ?? "—").monospacedDigit() }
                        Text("默认每 60 秒封批，结束时提交尾段。本机验证每次最多 \((model.state?.captureLimitSeconds ?? 1800) / 60) 分钟。")
                            .foregroundStyle(XinlikaPalette.muted)
                        Text("机身亮屏短按保存仍可能结束整条录音。请用应用中的“记下重点”保留重点片段。")
                            .foregroundStyle(XinlikaPalette.muted)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("下一次记录").font(.system(size: 16, weight: .medium))
                        captureSettings.disabled(model.running)
                        if model.running { Text("本次记录使用开始时选定的设置；结束后可修改下一次记录。").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted) }
                    }
                }
                if let focuses = model.state?.focuses, !focuses.isEmpty {
                    Text("本次独立重点").font(.system(size: 16, weight: .medium))
                    ForEach(focuses) { focus in
                        HStack { Text(focus.status == "needs_review" ? "范围需要核对" : XinlikaCopy.status(focus.processingStatus ?? focus.status)); Spacer(); Text(duration(focus.audioSeconds)).monospacedDigit() }
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("外观").font(.system(size: 16, weight: .medium))
                        Picker("应用外观", selection: $appearance) {
                            Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                        }.pickerStyle(.segmented).fixedSize()
                    }
                }
                Button("处理记录") { go(.processing) }
                HStack { Button("原始记录") { go(.records) }; Button("记忆与约定") { go(.memory) } }
                HStack { Text("心力卡 · 工作台 0.4.4"); Spacer(); if let updated = model.lastUpdated { Text(updated, format: .dateTime.hour().minute()) } }
                    .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
    }
    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.state?.processingConfigured == true && model.state?.agentConfigured == true {
                Toggle("转写并整理本次录音", isOn: $model.processing)
            } else { Text("处理服务尚未就绪，本次仅采集音频。").foregroundStyle(XinlikaPalette.muted) }
            Text("声音来源").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            Picker("声音来源", selection: $model.sourceKind) {
                Text("尚未确认").tag("unknown"); Text("现场对话").tag("live_conversation"); Text("背景播放").tag("background_playback")
            }.pickerStyle(.segmented).labelsHidden()
            Text("开启整理后，分钟音频发送到已配置的语音服务，转写发送到模型服务。未知来源与背景播放只整理，不写入个人事实。")
                .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted).fixedSize(horizontal: false, vertical: true)
            Text("卡上原录音保留。打开应用不会自动开始录音。").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
        }
    }
    private var textEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("补充已核对的对话").font(.system(size: 18, weight: .medium))
            Text("对话正文").font(.system(size: 12))
            TextEditor(text: $model.draftText).frame(height: 240).accessibilityLabel("补充对话正文")
            Text("文字将发送到模型整理。历史日期请直接写明，未注明时不自动推算。")
                .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            HStack {
                Button("取消") { showingText = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("整理这段对话") { Task { await model.submitText(); if model.draftText.isEmpty { showingText = false } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || !model.connected || model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draftText.count > 4000)
            }
        }.padding(24).frame(width: 600).tint(.primary)
    }

    @ViewBuilder private func panelForDocuments(_ docs: [HeartballAgentState.Document]) -> some View {
        if let agent = model.agentState {
            let speech = docs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let empty = docs.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if speech.isEmpty {
                panel(agent, section: .documents, documents: Set(docs.map(\.id)), heading: false)
            } else {
                panel(agent, section: .documents, documents: Set(speech.map(\.id)), heading: false)
                if !empty.isEmpty {
                    DisclosureGroup("\(empty.count) 段未返回文字 · 原声已保留") {
                        panel(agent, section: .documents, documents: Set(empty.map(\.id)), heading: false)
                    }.font(.system(size: 12))
                }
            }
        }
    }
    private func panel(_ agent: HeartballAgentState, section: HeartballAgentPanel.Section,
                       claims: Set<String>? = nil, documents: Set<String>? = nil, heading: Bool = true) -> some View {
        HeartballAgentPanel(state: agent, section: section, claimIDs: claims, documentIDs: documents, showSectionHeading: heading, busy: model.busy,
            feedback: { target, action, version in Task { await model.feedback(target: target, action: action, version: version) } },
            editClaim: { editingClaim = $0 }, editDocument: { editingDocument = $0 },
            play: { bid in Task { await model.play(batchID: bid) } },
            sourceCorrection: { doc, source in Task { await model.feedback(target: doc.id, action: "reclassify_document", version: doc.revision, values: ["source_kind": source]) } })
    }
}

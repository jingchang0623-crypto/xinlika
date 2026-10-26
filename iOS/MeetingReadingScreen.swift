import SwiftUI

enum ReportMode: String, CaseIterable, Identifiable {
    case overview = "概览", analysis = "完整分析"
    var id: String { rawValue }
}

private struct ReportSource: Equatable {
    let summary: String
    let analysis: String
}

private struct ParsedReport {
    let source: ReportSource
    let summary: ReadingDocument
    let analysis: ReadingDocument
}

struct MeetingReadingScreen: View {
    private enum Sheet: Identifiable {
        case contents, information, source, transcript(URL)
        var id: String {
            switch self { case .contents: "contents"; case .information: "information"; case .source: "source"; case .transcript: "transcript" }
        }
    }
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let record: LedgerItem
    @State private var mode: ReportMode = .overview
    @State private var loader = ReadingDocumentLoader()
    @State private var parsed: ParsedReport?
    @State private var sheet: Sheet?
    @State private var selectedChapter: String?
    @State private var position: String?
    @State private var lastReadingPosition: String?
    @State private var confirmAnalysis = false
    @State private var openingWeb = false
    @State private var webError: String?
    @State private var formattingError: String?
    @AppStorage private var bookmark: String

    init(record: LedgerItem) {
        self.record = record
        _bookmark = AppStorage(wrappedValue: "", "reading.bookmark." + LedgerStore.sha256("\(record.ownerKey ?? record.orgId)|\(record.id)"))
    }
    private var source: ReportSource {
        .init(summary: record.meeting?.summary ?? "", analysis: record.meeting?.analysis?.markdown ?? "")
    }
    private var current: ParsedReport? { parsed?.source == source ? parsed : nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                MeetingHeader(title: record.title, recordedAt: record.recordedAt, duration: record.displayDuration)
                    .id("reader-top")
                RecordResultStatus(record: record)
                if let meeting = record.meeting {
                    ReportModePicker(mode: $mode)
                    if let current {
                        if mode == .overview {
                            MeetingOverview(meeting: meeting, summary: current.summary)
                            if !current.analysis.blocks.isEmpty {
                                Button { mode = .analysis } label: {
                                    Label("阅读完整分析", systemImage: "arrow.right")
                                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                                }.buttonStyle(.bordered).controlSize(.large)
                            }
                        } else if !current.analysis.blocks.isEmpty {
                            ForEach(current.analysis.blocks) { block in
                                ReadingBlockView(block: block).id(block.id)
                            }
                        } else {
                            NoticeView(title: meeting.analysisLabel,
                                message: meeting.analysisAbsentReason ?? (meeting.analysis?.status == "failed" ? "分析未完成。录音仍然保留，可以重试分析。" : "尚无完整分析内容。可以先查看概览，稍后刷新结果。"))
                        }
                    } else if let formattingError {
                        NoticeView(title: "阅读版式暂不可用", message: formattingError, symbol: "exclamationmark.circle")
                    } else {
                        ProgressView("正在整理阅读版式…").frame(maxWidth: .infinity, minHeight: 80)
                    }
                    if meeting.analysis == nil || meeting.analysis?.status == "failed" {
                        VStack(alignment: .leading, spacing: 8) {
                            if mode == .overview, let reason = meeting.analysisAbsentReason {
                                Text(reason).font(.subheadline).foregroundStyle(ShennaoTheme.supportingText)
                            }
                            Button(model.analyzingIDs.contains(record.id) ? "正在提交…" : meeting.analysis == nil ? "开始分析" : "重试分析") {
                                confirmAnalysis = true
                            }
                            .frame(minHeight: 44)
                            .disabled(!model.isSignedIn || model.analyzingIDs.contains(record.id))
                        }
                    }
                } else {
                    NoticeView(title: record.transcriptId == nil ? record.resultLabel : "结果尚未取回",
                        message: record.transcriptId == nil ? "录音处理完成后，分析与转写会显示在这里。" : "已保存的录音不会因此丢失。请检查网络后刷新结果，无需重新上传。")
                    if record.transcriptId != nil {
                        Button("重新获取结果") { Task { await model.refreshRecord(record.id) } }
                            .frame(minHeight: 44).disabled(model.isRefreshing || !model.isSignedIn)
                    }
                }
                if record.canRetry && model.hasLocalAudio(record) {
                    Button("从手机重试上传") { model.retry(record.id) }
                        .accessibilityIdentifier("retry-\(record.id)")
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(model.isUploading || !model.isSignedIn)
                }
                if record.state == .paused {
                    Text("请到“设备”页连接灵魂卡，继续同步已保留进度的录音。")
                        .font(.subheadline).foregroundStyle(ShennaoTheme.supportingText)
                }
                if let webError {
                    NoticeView(title: "转写暂时无法打开", message: webError, symbol: "exclamationmark.circle")
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)
        }
        .background(ShennaoTheme.canvas)
        .scrollPosition(id: $position, anchor: .top)
        .refreshable { await model.refreshRecord(record.id) }
        .task(id: source) { await prepare(source) }
        .onChange(of: mode) {
            position = mode == .analysis ? (lastReadingPosition ?? "reader-top") : "reader-top"
        }
        .onChange(of: position) {
            if mode == .analysis, let position, current?.analysis.blocks.contains(where: { $0.id == position }) == true {
                lastReadingPosition = position
            }
        }
        .onDisappear { saveReadingPosition() }
        .onChange(of: scenePhase) { if scenePhase != .active { saveReadingPosition() } }
        .toolbar {
            if record.transcriptId != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(openingWeb ? "正在打开转写" : "转写与回听", systemImage: "waveform") { openTranscript() }
                        .disabled(openingWeb || !model.isSignedIn)
                        .accessibilityIdentifier("open-transcript")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("目录", systemImage: "list.bullet") { mode = .analysis; sheet = .contents }
                    .disabled(current?.analysis.headings.isEmpty != false)
                    .accessibilityIdentifier("open-contents")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("更多", systemImage: "ellipsis") {
                    Button("录音与分析信息", systemImage: "info.circle") { sheet = .information }
                    if !source.analysis.isEmpty { Button("查看 Markdown 原文", systemImage: "doc.plaintext") { sheet = .source } }
                }
            }
        }
        .confirmationDialog("开始分析可能消耗账号额度，是否继续？", isPresented: $confirmAnalysis, titleVisibility: .visible) {
            Button("确认开始分析") { Task { await model.analyze(record.id) } }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $sheet, onDismiss: {
            if let selectedChapter {
                position = selectedChapter
                self.selectedChapter = nil
            }
        }) { destination in
            switch destination {
            case .contents:
                ReadingContentsSheet(headings: current?.analysis.headings ?? [], selection: $selectedChapter)
            case .information: RecordInformationSheet(record: record, localAudio: model.hasLocalAudio(record))
            case .source: MarkdownSourceSheet(source: source.analysis)
            case .transcript(let url): TranscriptSheet(url: url)
            }
        }
    }

    private func prepare(_ requested: ReportSource) async {
        do {
            let summary = try await loader.load(requested.summary)
            let analysis = try await loader.load(requested.analysis)
            guard !Task.isCancelled else { return }
            parsed = ParsedReport(source: requested, summary: summary, analysis: analysis)
            formattingError = nil
            let saved = bookmark.components(separatedBy: "\n")
            if saved.count == 2, saved[0] == analysis.revision, analysis.blocks.contains(where: { $0.id == saved[1] }) {
                lastReadingPosition = saved[1]
            } else if let lastReadingPosition, !analysis.blocks.contains(where: { $0.id == lastReadingPosition }) {
                self.lastReadingPosition = nil
            }
            if mode == .analysis, let lastReadingPosition { position = lastReadingPosition }
        } catch is CancellationError {
            // The next source owns the UI update; never publish a cancelled parse.
        } catch {
            formattingError = "可通过“更多”查看 Markdown 原文。"
        }
    }
    private func saveReadingPosition() {
        guard let current, let lastReadingPosition else { return }
        bookmark = current.analysis.revision + "\n" + lastReadingPosition
    }
    private func openTranscript() {
        openingWeb = true
        webError = nil
        let owner = record.ownerKey
        Task {
            defer { openingWeb = false }
            do {
                let url = try await model.webEntry(record.id)
                guard model.records.contains(where: { $0.id == record.id && $0.ownerKey == owner }) else { return }
                sheet = .transcript(url)
            } catch { webError = "请检查网络与登录状态后重试。" }
        }
    }
}

private struct ReportModePicker: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var mode: ReportMode
    var body: some View {
        if typeSize.isAccessibilitySize {
            Picker("阅读模式", selection: $mode) {
                ForEach(ReportMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).font(.body)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).readingCard()
                .accessibilityIdentifier("reading-mode-accessible")
        } else {
            Picker("阅读模式", selection: $mode) {
                ForEach(ReportMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("reading-mode")
        }
    }
}

private struct MeetingHeader: View {
    let title: String
    let recordedAt: Date?
    let duration: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recordedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "录音时间未标注")
                .font(.subheadline).foregroundStyle(ShennaoTheme.supportingText)
            Text(title).font(.title.bold()).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            Text(duration).font(.subheadline).foregroundStyle(ShennaoTheme.supportingText)
        }
    }
}

private struct RecordResultStatus: View {
    let record: LedgerItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(record.resultLabel, systemImage: record.meeting?.analysis?.status == "done" ? "checkmark.circle" : "clock")
                .font(.footnote.weight(.medium)).foregroundStyle(ShennaoTheme.supportingText)
            if let error = record.resultError {
                NoticeView(title: "最新结果暂未取回", message: error + (record.meeting != nil ? "\n当前展示上次保存的内容。" : ""), symbol: "wifi.exclamationmark")
            }
            if let error = record.lastError, !error.isEmpty {
                NoticeView(title: record.state == .paused ? "同步待恢复" : "录音需要处理", message: error, symbol: "exclamationmark.circle")
            }
            if record.isCloudOnly, record.cloud?.stage == "failed", let problem = record.cloud?.problem {
                Text(problem).font(.subheadline).foregroundStyle(.secondary)
            }
            if let updated = record.resultUpdatedAt, record.resultError != nil {
                Text("缓存更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(ShennaoTheme.supportingText)
            }
        }
    }
}

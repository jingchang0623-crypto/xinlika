import SwiftUI

struct RecordsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedTab: AppTab
    @State private var path: [String] = []
    @State private var query = ""
    @State private var rows: [RecordPresentation] = []
    @State private var groups: [RecordDateGroup] = []
    @State private var showQueue = false
    @State private var showRecorder = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = model.cloudListError {
                    HStack {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("重试") { model.refreshStatuses() }.disabled(model.isRefreshing)
                    }.accessibilityIdentifier("cloud-catalog-error")
                }
                if model.showRecordingBanner {
                    Button { showRecorder = true } label: {
                        HStack {
                            Label(model.recordingStatusText, systemImage: model.recordingState == .recording ? "record.circle.fill" : "waveform")
                                .foregroundStyle(model.recordingState == .recording ? Color.red : Color.primary)
                            Spacer()
                            if let duration = model.recordingDurationText {
                                Text(duration).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("recorder-banner")
                }
                if model.isSignedIn && (model.processingPaused || model.isBusy || model.isUploading || model.isStoppingProcessing) {
                    DeviceSyncStatusView(compact: true)
                        .listRowSeparator(.hidden)
                }
                if !model.visibleRecords.isEmpty {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                NavigationLink(value: row.id) { RecordRowView(row: row) }
                                    .accessibilityIdentifier("result-\(row.id)")
                                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .contextMenu {
                                        Button("忽略录音", systemImage: "eye.slash") { model.ignoreRecordings([row.id]) }
                                    }
                            }
                        } header: {
                            Text(group.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(ShennaoTheme.supportingText).textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain).listSectionSpacing(12)
            .overlay {
                if model.visibleRecords.isEmpty {
                    ContentUnavailableView {
                        Label(model.isSignedIn ? "还没有录音" : "登录后查看记录", systemImage: "waveform")
                    } actions: {
                        Button(model.reviewCount > 0 ? "查看待确认录音" : model.isSignedIn ? "连接设备" : "前往登录") {
                            if model.reviewCount > 0 { showQueue = true }
                            else { selectedTab = model.isSignedIn ? .device : .settings }
                        }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else if groups.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("记录")
            .navigationDestination(for: String.self) { MeetingView(recordID: $0) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或摘要")
            .refreshable { await model.refreshAllResults() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncSimulationBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.recordingEnabled, model.recordingTargetID != nil {
                        Button("录音控制", systemImage: "record.circle") { showRecorder = true }
                            .accessibilityIdentifier("open-recorder-controls")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.reviewCount > 0 {
                        Button("待确认 \(model.reviewCount)") { showQueue = true }
                            .accessibilityIdentifier("open-pending-recordings")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("录音管理", systemImage: "checklist") { showQueue = true }
                        if model.processingPaused {
                            Button("恢复同步", systemImage: "play") { model.resumeAutomaticSync() }
                                .disabled(!model.canResumeProcessing)
                        } else { Button("暂停同步", systemImage: "pause") { model.cancelSync() } }
                        Button("刷新结果", systemImage: "arrow.clockwise") { model.refreshStatuses() }
                            .disabled(model.isRefreshing)
                    }.disabled(!model.isSignedIn).accessibilityIdentifier("records-menu")
                }
            }
            .sheet(isPresented: $showQueue) { RecordingQueueView() }
            .sheet(isPresented: $showRecorder) { RecorderControlSheet() }
            .alert("操作未完成", isPresented: Binding(get: { model.queueMessage != nil && !showQueue }, set: { if !$0 { model.queueMessage = nil } })) {
                Button("好") { model.queueMessage = nil }
            } message: { Text(model.queueMessage ?? "") }
            .task(id: model.records) {
                rows = model.visibleRecords.map(RecordPresentation.init)
                groups = RecordDateGroup.make(rows, query: query)
            }
            .onChange(of: query) { groups = RecordDateGroup.make(rows, query: query) }
            .onChange(of: model.isSignedIn) { path = []; query = "" }
        }
    }
}

private struct RecordRowView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: RecordPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.headline).foregroundStyle(.primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Text(row.metadata).font(.subheadline).foregroundStyle(ShennaoTheme.supportingText)
            if !row.excerpt.isEmpty {
                Text(row.excerpt).font(.subheadline).lineSpacing(4)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(ShennaoTheme.supportingText)
            }
            HStack(spacing: 6) {
                Image(systemName: row.symbol).accessibilityHidden(true)
                Text(row.status)
                if row.needsAttention && row.symbol != "exclamationmark.circle" { Text("· 需检查更新") }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(row.needsAttention ? Color.red : row.isWorking ? ShennaoTheme.blue : ShennaoTheme.supportingText)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI

struct RecordingQueueView: View {
    private let focusedRecordID: String?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: RecordingQueueSection = .review
    @State private var selection = Set<String>()
    @State private var approvalIDs = Set<String>()
    @State private var showApproval = false

    init(focusedRecordID: String? = nil) { self.focusedRecordID = focusedRecordID }

    private var items: [LedgerItem] {
        var sorted = section.sortedItems(in: model.records)
        if let focusedRecordID, let index = sorted.firstIndex(where: { $0.id == focusedRecordID }) {
            sorted.insert(sorted.remove(at: index), at: 0)
        }
        return sorted
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(item)).font(.headline)
                            Text(metadata(item)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .tag(item.id)
                        .accessibilityIdentifier("queue-item-\(item.fileBase)")
                    }
                } footer: {
                    if !items.isEmpty { Text(footer) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(section == .review ? "没有待确认录音" : section == .ignored ? "没有已忽略录音" : "没有处理中的录音",
                                           systemImage: section == .review ? "checkmark.circle" : "waveform")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("录音分类", selection: $section) {
                    ForEach(RecordingQueueSection.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding().background(.bar)
            }
            .safeAreaInset(edge: .bottom) {
                if !items.isEmpty {
                    HStack {
                        if section == .ignored {
                            Button("恢复 \(selection.count) 条") { model.restoreIgnoredRecordings(selection); selection = [] }
                                .accessibilityIdentifier("restore-recordings")
                        } else {
                            Button("忽略") { model.ignoreRecordings(selection); selection = [] }
                                .accessibilityIdentifier("ignore-recordings")
                            Spacer()
                            if section == .review {
                                Button("导入并分析") { approvalIDs = selection; showApproval = true }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("approve-recordings")
                            }
                        }
                    }
                    .disabled(selection.isEmpty || model.isStoppingProcessing)
                    .padding().background(.bar)
                }
            }
            .navigationTitle("录音管理").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selection.count == items.count && !items.isEmpty ? "取消全选" : "全选") {
                        selection = selection.count == items.count ? [] : Set(items.map(\.id))
                    }.disabled(items.isEmpty).accessibilityIdentifier("select-all-recordings")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .onChange(of: section) { selection = [] }
            .onChange(of: model.records) { selection.formIntersection(Set(items.map(\.id))) }
            .task { model.refreshRecordingCatalog() }
            .alert("导入并分析 \(approvalIDs.count) 条录音？", isPresented: $showApproval) {
                Button("确认导入并分析") { model.approveRecordings(approvalIDs); selection = [] }
                Button("取消", role: .cancel) { approvalIDs = [] }
            } message: {
                Text("共 \(RecordPresentation.duration(model.records.filter { approvalIDs.contains($0.id) }.reduce(0) { $0 + $1.durationSec }))，将上传到深脑并使用账号分析额度。")
            }
            .alert("录音管理", isPresented: Binding(get: { model.queueMessage != nil }, set: { if !$0 { model.queueMessage = nil } })) {
                Button("好") { model.queueMessage = nil }
            } message: { Text(model.queueMessage ?? "") }
        }
    }

    private var footer: String {
        switch section {
        case .review: "确认后才会继续下载、上传和分析。"
        case .active: "忽略会停止后续传输；已提交的云端分析无法撤回。"
        case .ignored: "原录音仍保留。恢复后，未完成的录音需再次确认。"
        }
    }
    private func metadata(_ item: LedgerItem) -> String {
        let date = Continuation.startedAt(base: item.fileBase)?.formatted(date: .abbreviated, time: .shortened)
        let reason = item.importReviewReason?.label ?? item.resultLabel
        return [item.title == item.fileBase ? nil : date, RecordPresentation.duration(item.durationSec), section == .review ? reason : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func title(_ item: LedgerItem) -> String {
        if item.title == item.fileBase {
            return Continuation.startedAt(base: item.fileBase)?.formatted(.dateTime.month().day().hour().minute().second()) ?? "未命名录音"
        }
        return item.meeting?.title ?? item.title
    }
}

import SwiftUI

struct RecordInformationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: LedgerItem
    let localAudio: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("录音") {
                    LabeledContent("名称", value: record.title)
                    LabeledContent("时长", value: record.displayDuration)
                    LabeledContent("手机音频", value: localAudio ? "已完整保存" : record.isCloudOnly ? "音频在云端" : "未保存完整音频")
                    LabeledContent("处理状态", value: record.state.label)
                }
                if let meeting = record.meeting {
                    Section("分析") {
                        LabeledContent("状态", value: meeting.analysisLabel)
                        if let analysis = meeting.analysis {
                            if !analysis.methods.isEmpty {
                                LabeledContent("分析方法", value: analysis.methods.joined(separator: "、"))
                            }
                            if let reason = analysis.routingReason { Text(reason) }
                        }
                        if let reason = meeting.analysisAbsentReason { Text(reason) }
                        if let updated = record.resultUpdatedAt {
                            LabeledContent("本机缓存更新", value: updated.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                Section("技术信息") {
                    LabeledContent("文件", value: record.fileBase)
                    LabeledContent("记录 ID", value: record.id)
                    if let id = record.transcriptId { LabeledContent("转写 ID", value: id) }
                    Text("接收 \(record.receivedBytes) / \(record.expectedBytes) 字节")
                }.font(.footnote)
            }
            .textSelection(.enabled)
            .navigationTitle("录音与分析信息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct MarkdownSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: String
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: source).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .navigationTitle("Markdown 原文").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct TranscriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var body: some View {
        NavigationStack {
            SecureTranscriptWebView(url: url)
                .navigationTitle("转写与回听").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

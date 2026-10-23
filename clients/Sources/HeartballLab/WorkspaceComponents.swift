// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import SwiftUI
import LuyinbiCore

// Native equivalents of the taste-skill achromatic-ledger tokens. SF/PingFang
// remains the system typeface; only data/status carries colour.
enum XinlikaPalette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static var ground: Color { adaptive(0xF5F6F7, 0x111111) }
    static var surface: Color { adaptive(0xFFFFFF, 0x191919) }
    static var active: Color { adaptive(0xE7E9EB, 0x2B2B2B) }
    static var border: Color { adaptive(0xE4E6E8, 0x2D2D2D) }
    static var muted: Color { adaptive(0x60646A, 0xB4B4B4) }
    static var signal: Color { adaptive(0x1D5FBF, 0x83B3F2) }
}

struct XinlikaMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).strokeBorder(lineWidth: 1.6)
            HStack(spacing: 3) {
                ForEach([8.0, 15.0, 11.0, 6.0], id: \.self) { height in
                    Capsule().frame(width: 2, height: height)
                }
            }
        }.frame(width: 32, height: 24).accessibilityHidden(true)
    }
}

struct XinlikaGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
            configuration.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(XinlikaPalette.surface, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(XinlikaPalette.border, lineWidth: 1) }
    }
}

typealias RecordCollection = HeartballRecordCollection

extension HeartballRecordCollection {
    var source: String { XinlikaCopy.source(representative.sourceKind) }
}

enum XinlikaCopy {
    static func source(_ value: String) -> String {
        ["live_conversation": "现场对话", "background_playback": "背景播放", "verified_text": "文字补充",
         "test_unverified": "测试 · 未核对", "unknown": "来源待核对"][value] ?? "来源待核对"
    }
    static func kind(_ value: String) -> String {
        ["fact": "事实", "commitment": "承诺", "dependency": "依赖"][value] ?? "其他"
    }
    static func status(_ value: String) -> String {
        ["proposed": "待确认", "confirmed": "已确认", "completed": "已完成", "queued": "排队中", "running": "处理中",
         "retryable": "等待重试", "failed": "需要检查", "blocked_provider": "服务受阻", "blocked_quality_review": "待审核",
         "no_text": "未返回文字", "superseded": "已有新版本", "rejected": "已排除", "recording": "记录中"] [value] ?? value
    }
    static func job(_ value: String) -> String {
        ["asr_audio": "语音转写", "ambient_analysis": "对话整理", "focus_analysis": "重点整理", "text_analysis": "文字整理",
         "memory_query": "记忆问答", "semantic_analysis": "事件与主题整理", "event_consolidate": "事项归并", "topic_reconcile": "跨对话主题关联", "personal_analysis": "Agent 分析", "activity_analysis": "活动归集", "audio_repair_review": "尾音核对"][value] ?? value
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) { return date }
        parser.formatOptions.insert(.withFractionalSeconds)
        return parser.date(from: value)
    }
    static func dateLabel(_ document: HeartballAgentState.Document) -> String {
        recordingDate(document.occurredAt, local: document.recordedLocalTime, basis: document.recordingTimeBasis)
    }
    static func recordingDate(_ occurred: String?, local: String?, basis: String?) -> String {
        if let date = date(occurred) {
            return (basis == "host_capture_start_estimate" ? "约 " : "") + date.formatted(.dateTime.month().day().hour().minute())
        }
        if let local {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let value = parser.date(from: String(local.prefix(19))) {
                parser.dateFormat = "M月d日 HH:mm"
                return "设备时间 · " + parser.string(from: value)
            }
        }
        return "录制时间未知"
    }
}

struct WorkspaceEmpty: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).foregroundStyle(XinlikaPalette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(XinlikaPalette.surface, in: .rect(cornerRadius: 8))
    }
}

@available(macOS 14, *)
@MainActor
struct XinlikaConversation: View {
    @Bindable var model: LabModel
    let openClaim: (String) -> Void
    private var disabled: Bool {
        model.busy || !model.connected || model.agentState == nil ||
        model.memoryQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.memoryQuestion.count > 1000
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("心力卡").font(.system(size: 16, weight: .medium))
                Text("记忆与对话").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.agentState?.answers.isEmpty != false {
                        Text("今天想聊点什么？")
                            .lineSpacing(5)
                        suggestion("我有哪些还没完成的承诺？")
                        suggestion("最近有哪些重要进展？")
                    }
                    ForEach(Array((model.agentState?.answers ?? []).reversed())) { answer in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(answer.question).padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(XinlikaPalette.active, in: .rect(cornerRadius: 8))
                            Text(answer.status == "pending" ? "正在查找相关记录…" : answer.status == "outdated" ? "记录有了更新，可以重新问我。" : answer.answer)
                                .lineSpacing(5).textSelection(.enabled)
                            if answer.status == "outdated" {
                                Button("重新查询") { model.memoryQuestion = answer.question; Task { await model.askMemory() } }.disabled(model.busy || !model.connected)
                            }
                            ForEach(answer.refs, id: \.id) { ref in
                                if let event = model.agentState?.events?.first(where: { $0.id == ref.id }) {
                                    Button { openClaim(event.id) } label: {
                                        Label(event.title, systemImage: "text.bubble").font(.system(size: 12)).lineLimit(2)
                                    }.buttonStyle(.plain)
                                } else if let topic = model.agentState?.topics?.first(where: { $0.id == ref.id }) {
                                    Button { openClaim(topic.id) } label: {
                                        Label(topic.title, systemImage: "square.stack").font(.system(size: 12)).lineLimit(2)
                                    }.buttonStyle(.plain)
                                } else if let claim = model.agentState?.claims.first(where: { $0.id == ref.id }) {
                                    Button { openClaim(claim.id) } label: {
                                        Label("依据 v\(ref.version)：\(claim.statement)", systemImage: "link")
                                            .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                    }.buttonStyle(.plain).foregroundStyle(XinlikaPalette.muted)
                                } else if let doc = model.agentState?.documents.first(where: { $0.id == ref.id }) {
                                    Button { openClaim(doc.id) } label: {
                                        Label(doc.title, systemImage: "waveform").font(.system(size: 12)).lineLimit(2)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.defaultScrollAnchor(.bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text("聊聊记录").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("问问心力卡…", text: $model.memoryQuestion, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(2...5)
                        .onSubmit { if !disabled { Task { await model.askMemory() } } }
                        .accessibilityIdentifier("memoryQuestion")
                    Button { Task { await model.askMemory() } } label: {
                        Image(systemName: "arrow.up").frame(width: 20, height: 22)
                    }.buttonStyle(.borderedProminent).disabled(disabled).accessibilityLabel("发送记忆问题")
                }.padding(12).background(XinlikaPalette.surface, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(XinlikaPalette.border) }
            }.padding(16)
        }.background(XinlikaPalette.ground)
    }
    private func suggestion(_ question: String) -> some View {
        Button { model.memoryQuestion = question } label: {
            HStack(alignment: .top) { Text(question).multilineTextAlignment(.leading); Spacer(minLength: 8); Image(systemName: "arrow.up.left") }
                .font(.system(size: 12)).padding(.vertical, 10)
        }.buttonStyle(.plain)
    }
}

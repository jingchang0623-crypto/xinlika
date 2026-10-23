// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import SwiftUI
import LuyinbiCore

@available(macOS 14, *)
struct HeartballAgentPanel: View {
    enum Section { case all, advice, memory, documents, activity }
    let state: HeartballAgentState
    var section: Section = .all
    var claimFilter = "all"
    var documentFilter = "all"
    var claimIDs: Set<String>? = nil
    var documentIDs: Set<String>? = nil
    var showSectionHeading = true
    let busy: Bool
    let feedback: (String, String, Int?) -> Void
    let editClaim: (HeartballAgentState.Claim) -> Void
    let editDocument: (HeartballAgentState.Document) -> Void
    let play: (String) -> Void

    private var activeAdvice: [HeartballAgentState.Advice] { state.advice.filter { $0.status == "active" } }
    private var currentClaims: [HeartballAgentState.Claim] { state.claims.filter { !["rejected", "superseded"].contains($0.status) && (claimFilter == "all" || $0.status == claimFilter) && (claimIDs?.contains($0.id) ?? true) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if section == .all {
            ForEach(state.answers) { answer in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(answer.question).font(.system(size: 16, weight: .medium))
                        Text(answer.status == "pending" ? "正在查询已确认的记忆…" : answer.answer).textSelection(.enabled)
                        if answer.status == "outdated" {
                            Text("相关记忆已被纠正，此回答已过期，请重新查询。").font(.system(size: 12)).foregroundStyle(.orange)
                        }
                        ForEach(answer.refs, id: \.id) { ref in
                            if let claim = state.claims.first(where: { $0.id == ref.id }) {
                                Text("依据 v\(ref.version)：\(claim.statement)").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            }
            if section == .all || section == .advice {
            if showSectionHeading { Text("主动反馈").font(.system(size: 16, weight: .medium)) }
            if activeAdvice.isEmpty { Text("暂无需要介入的新变化。").foregroundStyle(XinlikaPalette.muted) }
            ForEach(activeAdvice) { advice in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(advice.title, systemImage: advice.kind == "review_intent" ? "questionmark.bubble" : "lightbulb").font(.system(size: 16, weight: .medium))
                        Text(advice.body)
                        ForEach(advice.evidence, id: \.id) { reference in
                            if let claim = state.claims.first(where: { $0.id == reference.id }) {
                                Text("依据 v\(reference.version)：\(claim.quote)").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                            }
                        }
                        HStack {
                            Button("知道了") { feedback(advice.id, "dismiss", nil) }
                            Button("少提醒这类事") { feedback(advice.id, "mute_kind", nil) }
                        }.disabled(busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            }
            if section == .all || section == .memory {
            if showSectionHeading { Text("跨对话记忆 · 已确认 \(state.confirmedMemoryCount) 条").font(.system(size: 16, weight: .medium)) }
            if currentClaims.isEmpty && section == .all { Text("对话中的事实和承诺会先请你核对；不会把所有“我”都记成你。").foregroundStyle(XinlikaPalette.muted) }
            ForEach(currentClaims) { claim in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(claim.project.isEmpty ? "未关联项目" : claim.project).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                            Spacer()
                            Text(claim.status == "proposed" ? "自动整理" : claim.status == "completed" ? "已完成" : "已核实 · v\(claim.version)")
                                .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                        }
                        Text(claim.statement).font(.system(size: 16, weight: .medium))
                        Text("归属：\(claim.owner == "unknown" ? "尚不确定" : claim.owner)" + (claim.dueAt.map { " · 时间：\($0)" } ?? ""))
                            .font(.system(size: 14)).foregroundStyle(XinlikaPalette.muted)
                        DisclosureGroup("查看原话与来源") {
                            Text(claim.quote).textSelection(.enabled)
                            if let doc = state.documents.first(where: { $0.id == claim.documentId }) {
                                Text(doc.title).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                                audioButtons(doc)
                            }
                        }
                        HStack {
                            if claim.status == "proposed" { Button("标为准确") { feedback(claim.id, "confirm", claim.version) }.buttonStyle(.borderedProminent) }
                            Button("纠正") { editClaim(claim) }
                            if ["confirmed", "proposed"].contains(claim.status), claim.kind == "commitment" {
                                Button("已完成") { feedback(claim.id, "complete", claim.version) }
                            }
                            Button("忽略这条", role: .destructive) { feedback(claim.id, "reject", claim.version) }
                        }.disabled(busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            }
            if section == .all || section == .documents {
            if showSectionHeading { Text("对话与独立重点").font(.system(size: 16, weight: .medium)) }
            ForEach(state.documents.filter { $0.status != "superseded" && (documentFilter == "all" || $0.kind == documentFilter) && (documentIDs?.contains($0.id) ?? true) }) { doc in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(doc.title, systemImage: doc.kind == "focus" ? "bookmark.fill" : "waveform").font(.system(size: 16, weight: .medium))
                        HStack {
                            Text(doc.kind == "focus" ? "独立重点" : "对话整理")
                            Spacer()
                            Text(sourceLabel(doc.sourceKind))
                        }.font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                        Text(doc.summary).textSelection(.enabled)
                        if !doc.validationNotes.isEmpty {
                            DisclosureGroup("整理详情") {
                                ForEach(doc.validationNotes, id: \.self) { note in Text(note).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted) }
                            }
                        }
                        if doc.boundaryQuality == "includes_boundary_context" {
                            Text("此重点包含边界前后的声音，尚未精确定位到每个词。").font(.system(size: 12)).foregroundStyle(.orange)
                        }
                        DisclosureGroup("转写与原声") {
                            Text(doc.text.isEmpty ? "此批次没有返回可显示的转写。" : doc.text).textSelection(.enabled)
                            audioButtons(doc)
                            Button("纠正这段文字") { editDocument(doc) }.disabled(busy)
                            if doc.sourceKind != "background_playback" {
                                Button("来源是视频或背景播放") { reclassify(doc, "background_playback") }.disabled(busy)
                            }
                            if doc.sourceKind == "unknown" || doc.sourceKind == "test_unverified" {
                                Button("确认为现场对话") { reclassify(doc, "live_conversation") }.disabled(busy)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            }
            if section == .all || section == .activity {
            DisclosureGroup("处理进度与修订记录") {
                ForEach(state.processingJobs.prefix(30)) { job in
                    HStack { Text(label(job.kind)); Spacer(); Text(label(job.status)); if let error = job.error { Text(error).foregroundStyle(.orange) } }
                        .font(.system(size: 12))
                }
                ForEach(state.advice.filter { $0.status != "active" }) { advice in
                    Text("\(advice.title) · \(advice.status == "invalidated" ? "依据已修订，建议失效" : "已处理")").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
                }
            }
            }
        }
    }

    @ViewBuilder private func audioButtons(_ doc: HeartballAgentState.Document) -> some View {
        let ids = doc.evidence.compactMap(\.batchId)
        if !ids.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading) {
                ForEach(Array(ids.enumerated()), id: \.element) { item in
                    Button("试听原声 \(item.offset + 1)") { play(item.element) }
                }
            }
        }
    }
    private func sourceLabel(_ source: String) -> String {
        ["live_conversation": "现场对话", "background_playback": "背景播放", "test_unverified": "测试 · 未核对", "unknown": "来源待核对"][source] ?? "来源待核对"
    }
    private func label(_ value: String) -> String {
        ["asr_audio": "转写", "ambient_analysis": "对话整理", "focus_analysis": "重点整理", "text_analysis": "文字整理", "memory_query": "记忆查询",
         "audio_repair_review": "尾音上下文核对", "queued": "排队中", "running": "处理中", "completed": "完成",
         "retryable": "等待重试", "failed": "需要检查", "blocked_provider": "模型服务需要处理",
         "blocked_quality_review": "待开启或审核" ][value] ?? value
    }
    private func reclassify(_ document: HeartballAgentState.Document, _ source: String) {
        // Parent owns asynchronous API state; this callback carries source correction.
        sourceCorrection(document, source)
    }
    var sourceCorrection: (HeartballAgentState.Document, String) -> Void = { _, _ in }
}

@available(macOS 14, *)
struct ClaimCorrection: View {
    let claim: HeartballAgentState.Claim
    let save: ([String: String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var statement: String
    @State private var owner: String
    @State private var due: Date
    @State private var hasDue: Bool
    @State private var saving = false
    @State private var failed = false
    init(claim: HeartballAgentState.Claim, save: @escaping ([String: String]) async -> Bool) {
        self.claim = claim; self.save = save
        _statement = State(initialValue: claim.statement)
        _owner = State(initialValue: claim.owner == "unknown" ? "" : claim.owner)
        _due = State(initialValue: XinlikaCopy.date(claim.dueAt) ?? .now)
        _hasDue = State(initialValue: claim.dueAt != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("纠正这条记忆").font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 8) {
                Text("事实或承诺").font(.system(size: 12))
                TextField("内容", text: $statement, axis: .vertical).lineLimit(2...4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("归属或负责人").font(.system(size: 12))
                TextField("留空表示尚不确定", text: $owner)
            }
            Toggle("设定截止时间", isOn: $hasDue)
            if hasDue {
                DatePicker("截止时间", selection: $due, displayedComponents: [.date, .hourAndMinute])
                Text("时区：" + TimeZone.current.identifier).font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            }
            Text("原话保留。纠正会更新记忆，并使依赖旧版本的建议失效。")
                .font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            if failed { Text("未能保存，输入已保留。可能有新版本，请取消后刷新核对。").foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存纠正") {
                    saving = true
                    Task {
                        let person = owner.trimmingCharacters(in: .whitespacesAndNewlines)
                        let values = ["statement": statement, "owner": person.isEmpty ? "unknown" : person,
                                      "due_at": hasDue ? ISO8601DateFormatter().string(from: due) : ""]
                        let saved = await save(values); saving = false
                        if saved { dismiss() } else { failed = true }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 560).tint(.primary)
    }
}

@available(macOS 14, *)
struct DocumentCorrection: View {
    let document: HeartballAgentState.Document
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var failed = false
    init(document: HeartballAgentState.Document, save: @escaping (String) async -> Bool) {
        self.document = document; self.save = save; _text = State(initialValue: document.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("纠正转写").font(.system(size: 18, weight: .medium))
            Text("转写正文").font(.system(size: 12))
            TextEditor(text: $text).frame(height: 260)
            Text("保留原始版本与原声，仅重新整理纠正后的文字，不再转写音频。").font(.system(size: 12)).foregroundStyle(XinlikaPalette.muted)
            if failed { Text("未能保存，文字已保留。请核对服务或刷新后的版本。").foregroundStyle(.orange) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存并重新整理") {
                saving = true; Task { let saved = await save(text); saving = false; if saved { dismiss() } else { failed = true } }
            }.buttonStyle(.borderedProminent).disabled(saving || text.isEmpty || text.count > 4000) }
        }.padding(24).frame(width: 620)
    }
}

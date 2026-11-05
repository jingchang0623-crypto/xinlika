import SwiftUI

struct WatchCaptureView: View {
    @State private var model = WatchCapturePhoneModel.shared
    @State private var confirmCloud = false
    @State private var confirmingRecord: WatchCaptureArchive.Record?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                Toggle("手表云端整理", isOn: Binding(get: { model.enabled }, set: { value in
                    if value { confirmCloud = true } else { Task { await model.setEnabled(false) } }
                }))
                Text(model.notice).font(.footnote).foregroundStyle(.secondary)
                if model.needsServiceBinding {
                    Button("重新连接处理服务") { confirmCloud = true }
                }
                if model.uploading { ProgressView("正在上传手表原声") }
                LabeledContent("手机暂存", value: ByteCountFormatter.string(fromByteCount: model.localStorageBytes, countStyle: .file))
            } footer: {
                Text("原声保留在手表和云端。手机仅中转，云端核验后释放暂存；未上传成功的片段继续保留。播放时按需从云端读取。")
            }
            if model.records.isEmpty {
                ContentUnavailableView("还没有手表录音", systemImage: "applewatch",
                    description: Text("在配对 Apple Watch 上打开心力卡，点开始录音。离开手机也能先保存。"))
            }
            ForEach(model.records) { record in
                Section {
                    LabeledContent(record.header.startedAt.formatted(date: .abbreviated, time: .shortened),
                        value: "\(Int(record.seconds)) 秒")
                    Text(model.status(record)).font(.footnote).foregroundStyle(.secondary)
                    let focuses = record.events.filter { $0.kind == .focus }.count
                    let gaps = record.events.filter { $0.kind == .interrupted }.count
                    if focuses > 0 { Label("\(focuses) 段重点", systemImage: "star") }
                    if gaps > 0 { Label("\(gaps) 次录音中断，已录内容保留", systemImage: "exclamationmark.circle").font(.footnote) }
                    DisclosureGroup("原声 · \(record.segments.count) 段") {
                        ForEach(record.segments.sorted(by: { $0.sequence < $1.sequence })) { segment in
                            Button(model.loadingPlayerID == segment.id ? "取消读取" : model.playerID == segment.id ? "停止播放" : "\(model.hasLocalAudio(segment) ? "播放" : "从云端播放")第 \(segment.sequence + 1) 段 · \(Int(segment.duration)) 秒",
                                systemImage: model.playerID == segment.id ? "stop.circle" : "play.circle") { model.play(record, segment: segment) }
                        }
                    }
                    if record.cloudGrant == nil, record.complete, !record.segments.isEmpty {
                        Button("整理这条录音", systemImage: "sparkles") { confirmingRecord = record }
                            .disabled(!model.enabled)
                    }
                }
            }
        }
        .navigationTitle("Apple Watch")
        .toolbar { Button("重试", systemImage: "arrow.clockwise") { model.resume() } }
        .task { model.resume() }
        .onChange(of: scenePhase) { _, value in if value == .active { model.resume() } }
        .confirmationDialog("启用手表云端整理？", isPresented: $confirmCloud, titleVisibility: .visible) {
            Button("上传新录音并自动整理") { Task { await model.setEnabled(true) } }
        } message: { Text("新录音的原声将发送给当前处理服务，云端核验后清理手机暂存，手表原声保留。此前本地录音仍由你逐条选择。") }
        .confirmationDialog("上传这条录音并整理？", isPresented: Binding(get: { confirmingRecord != nil }, set: { if !$0 { confirmingRecord = nil } }), titleVisibility: .visible) {
            Button("上传并整理") { if let record = confirmingRecord { model.grant(record) }; confirmingRecord = nil }
        } message: { Text("原声将发送给当前处理服务，云端核验后释放手机暂存，手表原声保留。整理结果可在“今天”查看。") }
    }
}

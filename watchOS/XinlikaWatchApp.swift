import SwiftUI

@main
struct XinlikaWatchApp: App {
    @State private var model = WatchCaptureModel()
    var body: some Scene { WindowGroup { WatchRecordingView(model: model) } }
}

struct WatchRecordingView: View {
    let model: WatchCaptureModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Label(model.recording ? "正在记录" : "心力卡", systemImage: model.recording ? "mic.fill" : "waveform")
                    .font(.headline).foregroundStyle(model.recording ? .orange : .primary)
                Text(Duration.seconds(model.seconds).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.title2.monospacedDigit()).accessibilityLabel("已录制时长")
                if model.recording {
                    ProgressView(value: Double(model.level)).tint(.orange).accessibilityLabel("麦克风音量")
                    Button(model.focusStart == nil ? "开始重点" : "结束重点", systemImage: "star.fill") { model.toggleFocus() }
                        .tint(model.focusStart == nil ? .gray : .orange)
                    Button("结束并保存", systemImage: "stop.fill", role: .destructive) { model.stop() }
                } else {
                    Button("开始录音", systemImage: "mic.fill") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent).tint(.orange).disabled(model.busy)
                }
                Text(model.notice).font(.footnote).foregroundStyle(.secondary)
                if model.pending > 0 { Button("待同步 \(model.pending) 项", systemImage: "arrow.triangle.2.circlepath") { model.retry() }.font(.footnote) }
            }.padding(.horizontal, 8)
        }
        .sensoryFeedback(.start, trigger: model.recording) { !$0 && $1 }
        .sensoryFeedback(.selection, trigger: model.focusStart)
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.retry() } }
    }
}

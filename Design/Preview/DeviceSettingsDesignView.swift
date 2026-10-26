import SwiftUI

struct DeviceDesignView: View {
    @State private var paused = false
    @State private var showTechnical = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(systemName: "waveform")
                            .font(.largeTitle).foregroundStyle(DesignTheme.accent)
                            .frame(width: 64, height: 72)
                            .background(DesignTheme.accent.opacity(0.08), in: .rect(cornerRadius: 16))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("灵魂卡").font(.title2.weight(.bold))
                            Label("已连接 · 示例", systemImage: "checkmark.circle.fill")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Label("电量 81%", systemImage: "battery.75percent")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("最近同步  今天 09:32")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTheme.surface, in: .rect(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: paused ? "同步已暂停" : "正在同步录音")
                    Text("产品讨论 · 第 2 段，共 3 段")
                        .font(.body)
                    ProgressView(value: 0.64).accessibilityLabel("示例同步进度")
                    HStack {
                        Text("64% 已保存").monospacedDigit()
                        Spacer()
                        Text("演示进度")
                    }.font(.subheadline).foregroundStyle(.secondary)
                    Text(paused ? "已保存的内容会保留。恢复后从上次进度继续。" : "同步中断时会保留已保存内容，返回 App 后可恢复。")
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                    Button(paused ? "恢复演示" : "暂停演示", systemImage: paused ? "play.fill" : "pause.fill") {
                        paused.toggle()
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("toggle-demo-sync")
                }
                .padding(20).background(DesignTheme.surface, in: .rect(cornerRadius: 16))

                DisclosureGroup("设备详细信息", isExpanded: $showTechnical) {
                    VStack(spacing: 14) {
                        LabeledContent("型号", value: "CB08（示例）")
                        Text("正式版本在这里提供固件、连接信息与诊断入口。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 16)
                }
                .padding(20).background(DesignTheme.surface, in: .rect(cornerRadius: 16))
                PreviewNote()
            }
            .padding(20)
        }
        .background(DesignTheme.grouped)
        .navigationTitle("设备")
    }
}

struct SettingsDesignView: View {
    @Binding var appearance: PreviewAppearance
    @State private var showAbout = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("深脑").font(.title2.weight(.bold))
                    Text("让每一次对话，留下清晰的思考。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section {
                Picker("外观", selection: $appearance) {
                    ForEach(PreviewAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("文字大小", value: "跟随系统")
            } header: { Text("阅读") } footer: {
                Text("支持系统动态字体。预览中的外观选择仅保留到本次运行结束。")
            }
            Section {
                Label("不会连接真实设备", systemImage: "waveform")
                Label("不会上传录音或发起分析", systemImage: "lock")
                Button("关于设计预览") { showAbout = true }
            } header: { Text("预览范围") }
            Section {
                PreviewNote()
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showAbout) { PreviewExplanation() }
    }
}

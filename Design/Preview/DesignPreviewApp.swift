import SwiftUI

// This target deliberately has no dependency on the production app or its services.
@main
struct ShennaoDesignPreviewApp: App {
    var body: some Scene {
        WindowGroup { PreviewRoot() }
    }
}

enum PreviewTab: Hashable { case records, device, settings }
enum PreviewRoute: Hashable { case record(String) }
enum ReadingMode: String, CaseIterable, Identifiable {
    case overview = "概览", analysis = "完整分析"
    var id: String { rawValue }
}

enum PreviewAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统", light = "浅色", dark = "深色"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum DesignTheme {
    static let canvas = Color(uiColor: .systemBackground)
    static let grouped = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let quiet = Color(uiColor: .secondarySystemBackground)
    static let accent = Color.blue
    static let supportingText = Color.primary.opacity(0.68)
    static let page: CGFloat = 20
}

struct PreviewRoot: View {
    @State private var tab: PreviewTab
    @State private var recordsPath: [PreviewRoute]
    @State private var appearance: PreviewAppearance = .system
    private let initialMode: ReadingMode
    private let scene: String

    init(scene: String? = nil) {
        let requested = scene ?? ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--screen=") })?.replacingOccurrences(of: "--screen=", with: "") ?? "records"
        self.scene = requested
        _tab = State(initialValue: requested == "device" ? .device : requested == "settings" ? .settings : .records)
        _recordsPath = State(initialValue: ["overview", "analysis"].contains(requested) ? [.record("product-review")] : [])
        initialMode = requested == "analysis" ? .analysis : .overview
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $tab) {
                    Tab("记录", systemImage: "text.page", value: .records) { records }
                    Tab("设备", systemImage: "waveform", value: .device) { device }
                    Tab("设置", systemImage: "gearshape", value: .settings) { settings }
                }
            } else {
                TabView(selection: $tab) {
                    records.tabItem { Label("记录", systemImage: "doc.text") }.tag(PreviewTab.records)
                    device.tabItem { Label("设备", systemImage: "waveform") }.tag(PreviewTab.device)
                    settings.tabItem { Label("设置", systemImage: "gearshape") }.tag(PreviewTab.settings)
                }
            }
        }
        .tint(DesignTheme.accent)
        .preferredColorScheme(appearance.scheme)
    }

    private var records: some View {
        NavigationStack(path: $recordsPath) {
            RecordsDesignView(initialState: scene)
                .navigationDestination(for: PreviewRoute.self) { route in
                    switch route {
                    case .record(let id):
                        if let record = PreviewFixtures.records.first(where: { $0.id == id }) {
                            RecordDesignView(record: record, initialMode: initialMode)
                        } else {
                            ContentUnavailableView("找不到记录", systemImage: "doc.questionmark")
                        }
                    }
                }
        }
    }
    private var device: some View { NavigationStack { DeviceDesignView() } }
    private var settings: some View { NavigationStack { SettingsDesignView(appearance: $appearance) } }
}

struct PreviewNote: View {
    var body: some View {
        Text("设计预览 · 全部为示例内容")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeading: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    var caption: String? = nil
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let caption { Text(caption).font(.subheadline).foregroundStyle(.secondary) }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let caption { Text(caption).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }
}

struct PreviewExplanation: View {
    @Environment(\.dismiss) private var dismiss
    var title = "关于设计预览"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("先体验阅读，再接入真实数据。")
                        .font(.title2.weight(.semibold))
                    Text("这是独立的原生设计样机。所有录音、分析、电量和进度均为示例，不会读取手机里的录音，也不会连接设备、上传文件或消耗分析额度。")
                    Text("可以体验记录搜索、概览与完整分析切换、目录跳转、引用展开和外观切换。转写、回听与真实同步将在正式 App 中继续接入。")
                }
                .font(.body).lineSpacing(5).padding(20)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

#Preview("记录") { PreviewRoot(scene: "records") }
#Preview("概览") { PreviewRoot(scene: "overview") }
#Preview("完整分析") { PreviewRoot(scene: "analysis") }
#Preview("空状态") { PreviewRoot(scene: "empty") }

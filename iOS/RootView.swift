import SwiftUI

enum AppTab: Hashable { case records, device, settings }

struct RootView: View {
    @State private var selectedTab: AppTab = .records
    @AppStorage("reading.appearance") private var appearance = ReadingAppearance.system

    var body: some View {
        if ProcessInfo.processInfo.environment["SHENNAO_UI_FIXTURE"] == "1" || ProcessInfo.processInfo.environment["SHENNAO_SYNC_FIXTURE"] == "1" || ProcessInfo.processInfo.environment["SHENNAO_LEGACY"] == "1" {
            legacyContent
        } else {
            XinlikaRootView()
        }
    }

    private var legacyContent: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $selectedTab) {
                    Tab("记录", systemImage: "doc.text", value: .records) { RecordsView(selectedTab: $selectedTab) }
                    Tab("设备", systemImage: "waveform", value: .device) { DeviceView(selectedTab: $selectedTab) }
                    Tab("设置", systemImage: "gearshape", value: .settings) { AccountView() }
                }
            } else {
                TabView(selection: $selectedTab) {
                    RecordsView(selectedTab: $selectedTab).tabItem { Label("记录", systemImage: "doc.text") }.tag(AppTab.records)
                    DeviceView(selectedTab: $selectedTab).tabItem { Label("设备", systemImage: "waveform") }.tag(AppTab.device)
                    AccountView().tabItem { Label("设置", systemImage: "gearshape") }.tag(AppTab.settings)
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
    }
}

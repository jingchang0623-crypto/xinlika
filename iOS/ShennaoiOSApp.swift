import SwiftUI

@main
struct ShennaoiOSApp: App {
    @UIApplicationDelegateAdaptor(ShennaoAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let probe = model.hardwareProbe {
                RecorderHardwareProbeView(probe: probe)
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
    }

    private var appContent: some View {
        Group {
            if ProcessInfo.processInfo.environment["SHENNAO_UI_FIXTURE"] == "1" || ProcessInfo.processInfo.environment["SHENNAO_SYNC_FIXTURE"] == "1" || ProcessInfo.processInfo.environment["SHENNAO_LEGACY"] == "1" {
                legacyContent
            } else {
                XinlikaRootView()
            }
        }
    }

    private var legacyContent: some View {
        RootView()
            .environmentObject(model)
            .tint(ShennaoTheme.blue)
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.sceneChanged(active: phase == .active)
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await model.foregroundLoop() }
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await model.recordingMonitorLoop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: BackgroundUploader.finished)) { _ in
                model.backgroundTransferFinished()
            }
    }
}

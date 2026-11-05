import SwiftUI

/// A single status and a single pause control for both transfer queues.
struct DeviceSyncStatusView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var compact = false

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    statusLabel
                    accessibleSyncAction
                }
            } else {
                HStack {
                    statusLabel
                    Spacer()
                    accessibleSyncAction
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLabel: some View {
        Label(model.compactSyncStatus, systemImage: model.processingPaused ? "pause.circle" : "arrow.triangle.2.circlepath")
            .font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var syncAction: some View {
        if model.processingPaused {
            Button("恢复") { model.resumeAutomaticSync() }
                .disabled(!model.canResumeProcessing)
                .accessibilityLabel("恢复同步").accessibilityIdentifier("resume-automatic-sync")
        } else {
            Button("暂停") { model.cancelSync() }
                .disabled(model.isStoppingProcessing)
                .accessibilityLabel("暂停同步").accessibilityIdentifier("pause-automatic-sync")
        }
    }

    private var accessibleSyncAction: some View {
        syncAction
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct SyncSimulationBadge: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.isSyncSimulation {
            Text("演示").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("模拟设备调用：\(model.syncSimulationCalls)")
                .accessibilityValue("下载：\(model.syncSimulationDownloads) 上传：\(model.syncSimulationUploads)" + (model.recordingEnabled ? " 录音指令：\(model.recordingSimulationCommandCount) 设备任务：\(model.canPauseDownload ? "运行" : "空闲")" : ""))
                .accessibilityIdentifier("sync-simulation-calls")
                .id("\(model.syncSimulationCalls)-\(model.syncSimulationDownloads)-\(model.syncSimulationUploads)-\(model.recordingSimulationCommandCount)")
        }
    }
}

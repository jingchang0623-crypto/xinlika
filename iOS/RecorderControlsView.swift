import SwiftUI

struct RecorderControlsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    let onShowSavedRecording: (LedgerItem) -> Void

    var body: some View {
        Section {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { stateLabel; durationLabel }
            } else {
                HStack(alignment: .firstTextBaseline) { stateLabel; Spacer(minLength: 8); durationLabel }
            }
            if model.isRecordingControlBusy {
                HStack { ProgressView(); Text("正在确认设备状态…").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("recorder-working")
            } else {
                switch model.recordingState {
                case .idle:
                    Button("开始录音", systemImage: "record.circle") { model.controlRecording(.start) }
                        .tint(.red).accessibilityIdentifier("recorder-start")
                        .disabled(!model.canControlRecording)
                case .recording, .paused:
                    // V1.0.0 does not reliably report pause state. Expose only the
                    // start/save operations verified on the physical recorder.
                    Button("结束并保存", systemImage: "stop.circle") { model.controlRecording(.save) }
                        .accessibilityIdentifier("recorder-save").disabled(!model.canControlRecording)
                case nil:
                    Button("刷新录音状态", systemImage: "arrow.clockwise") { model.controlRecording() }
                        .accessibilityIdentifier("recorder-refresh").disabled(!model.canControlRecording)
                }
            }
            if let message = model.recordingMessage {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("recorder-message")
            }
            if model.recordingState == .idle, !model.isRecordingControlBusy, let item = model.lastSavedRecording {
                Button { onShowSavedRecording(item) } label: {
                    HStack {
                        Label("查看录音", systemImage: "checkmark.circle")
                        Spacer()
                        Text(RecordPresentation.duration(item.durationSec)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("recorder-show-saved")
            }
        } header: { Text("录音卡") }
    }

    private var stateLabel: some View {
        Label(model.recordingStatusText, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(model.recordingState == .recording ? Color.red : Color.primary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.recordingStatusText)
            .accessibilityIdentifier("recorder-state")
    }

    @ViewBuilder private var durationLabel: some View {
        if let duration = model.recordingDurationText {
            Text(duration).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("已录制 \(duration)")
                .accessibilityIdentifier("recorder-duration")
        } else if model.isRecordingChecking && !model.recordingIsFresh {
            ProgressView().accessibilityLabel("正在读取录音状态")
        }
    }

    private var symbol: String {
        switch model.recordingState {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle"
        case .idle: "record.circle"
        case nil: "questionmark.circle"
        }
    }
}

struct RecorderControlSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var savedRecording: LedgerItem?

    var body: some View {
        NavigationStack {
            Form { RecorderControlsView { savedRecording = $0 } }
                .navigationTitle(model.deviceDisplayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $savedRecording) { SavedRecordingSheet(item: $0) }
    }
}

/// Keep presentation on the stable container, outside the Form's changing rows.
struct SavedRecordingSheet: View {
    let item: LedgerItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if item.isHeldForReview {
            RecordingQueueView(focusedRecordID: item.id)
        } else {
            NavigationStack {
                MeetingView(recordID: item.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }
        }
    }
}

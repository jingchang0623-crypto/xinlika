import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedTab: AppTab
    @State private var showDetails = false
    @State private var showQueue = false
    @State private var savedRecording: LedgerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.deviceDisplayName).font(.headline)
                            Text(model.connectionStatus).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "waveform").foregroundStyle(.tint) }
                    if let battery = model.battery {
                        LabeledContent("电量", value: battery == 110 ? "充电中" : "\(battery)%")
                    }
                    if !model.isSignedIn {
                        Button("先登录深脑账号") { selectedTab = .settings }
                    }
                }
                if model.recordingEnabled, model.recordingTargetID != nil {
                    RecorderControlsView { savedRecording = $0 }
                }
                if !model.devices.isEmpty {
                    Section("附近设备") {
                        ForEach(model.devices, id: \.peripheral.identifier) { device in
                            Button {
                                model.selectedDeviceId = device.peripheral.identifier
                            } label: {
                                HStack {
                                    Text(device.name).foregroundStyle(.primary)
                                    Spacer()
                                    if device.peripheral.identifier == model.selectedDeviceId {
                                        Image(systemName: "checkmark").accessibilityLabel("已选择")
                                    }
                                }
                            }.disabled(!model.canResumeProcessing)
                        }
                    }
                }
                if model.isSignedIn {
                    Section("同步") {
                        DeviceSyncStatusView()
                        if let progress = model.progress { ProgressView(value: min(1, max(0, progress))) }
                        if model.canRememberSelectedDevice {
                            Button("记住并自动同步") { model.rememberAndSyncSelected() }
                                .disabled(!model.canResumeProcessing)
                                .accessibilityIdentifier("remember-and-sync")
                        }
                        Button("录音管理\(model.reviewCount > 0 ? " · \(model.reviewCount) 条待确认" : "")") { showQueue = true }
                            .accessibilityIdentifier("open-recording-queue")
                    }
                }
                Section {
                    Button(model.selectedDevice == nil && model.rememberedDevice == nil && !model.isSyncSimulation ? "寻找灵魂卡" : "检查录音") {
                        if model.selectedDevice == nil && model.rememberedDevice == nil && !model.isSyncSimulation { model.scan() }
                        else { model.syncSelected() }
                    }.disabled(!model.canResumeProcessing).accessibilityIdentifier("manual-device-sync")
                }
                Section {
                    DisclosureGroup(isExpanded: $showDetails) {
                        Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("automatic-sync-status")
                        if let checked = model.rememberedDevice?.lastCheckedAt {
                            LabeledContent("最近检查", value: checked.formatted(date: .abbreviated, time: .shortened))
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("automatic-sync-last-check")
                        }
                        if let count = model.fileCount { LabeledContent("设备录音", value: "\(count) 条") }
                        if let firmware = model.firmware { LabeledContent("固件", value: firmware) }
                        if let device = model.selectedDevice { LabeledContent("信号", value: "\(device.rssi) dBm") }
                    } label: {
                        Text("设备详情").accessibilityIdentifier("device-details")
                    }
                }
            }
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncSimulationBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("寻找设备", systemImage: "arrow.clockwise") { model.scan() }.disabled(!model.canResumeProcessing)
                }
            }
            .sheet(isPresented: $showQueue) { RecordingQueueView() }
            .sheet(item: $savedRecording) { SavedRecordingSheet(item: $0) }
        }
    }
}

import CoreBluetooth
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var config = AppConfig.load()
    @Published var email = DeepBrain.signedInEmail ?? ""
    @Published var password = ""
    @Published var isSignedIn = false
    @Published var accountMessage = ""
    @Published var devices: [Discovered] = []
    @Published var selectedDeviceId: UUID? {
        didSet { if oldValue != selectedDeviceId { resetRecordingTarget() } }
    }
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var status = "准备连接灵魂卡"
    @Published var progress: Double?
    @Published var battery: UInt8?
    @Published var firmware: String?
    @Published var fileCount: Int?
    @Published var records: [LedgerItem] = []

    @Published var isUploading = false
    @Published var isRefreshing = false
    @Published var cloudStatus = "等待同步"
    @Published private(set) var cloudListError: String?
    private var cloudCatalogScope: RecordScope?
    private var nextCloudCatalogCheck = Date.distantPast
    private var pendingResultID: String?
    @Published var connectionStatus = "尚未连接"
    @Published private(set) var rememberedDevice: RememberedDevice?
    @Published private(set) var syncSimulationCalls = 0
    @Published private(set) var minimumRecordingSeconds = ImportPolicy.defaultMinimumSeconds
    @Published private(set) var processingPaused = false
    @Published private(set) var isStoppingProcessing = false
    @Published private(set) var syncSimulationDownloads = 0
    @Published private(set) var syncSimulationUploads = 0
    @Published var queueMessage: String?
    @Published private(set) var recordingReading: RecorderReading?
    @Published private(set) var recordingIsFresh = false
    @Published private(set) var recordingNeedsAttention = false
    @Published private(set) var isRecordingChecking = false
    @Published private(set) var isRecordingControlBusy = false
    @Published private(set) var recordingSimulationCommandCount = 0
    @Published var recordingMessage: String?
    @Published private(set) var lastSavedRecordingID: String?
    private var recordingTask: Task<Void, Never>?
    private var recordingControlTask: Task<Void, Never>?
    private var recordingConnectionID: UUID?
    private var recordingReadDeviceID: UUID?
    private var isDownloadingFile = false
    private var nextRecordingCheck = Date.distantPast
    #if DEBUG
    var hardwareProbe: RecorderHardwareProbe?
    private lazy var recordingSimulation = RecorderSimulation(scenario: ProcessInfo.processInfo.environment["SHENNAO_RECORDING_SCENARIO"] ?? "idle")
    #endif
    @Published var analyzingIDs = Set<String>()
    var accountLocked: Bool { isBusy || restoringAuth || isScanning || isRecordingControlBusy || isUploading || isStoppingProcessing || isRefreshing || !analyzingIDs.isEmpty }
    var canPauseDownload: Bool { syncTask != nil }

    private var syncTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var uploadRecordID: String?
    private var activeCheckpoint: DownloadCheckpoint?
    private var activeRecordID: String?
    private var isForeground = true
    private var nextAuthRestore = Date.distantPast
    private var restoringAuth = false
    private var controlPaused = false
    private var importStorageBlocked = false
    private var restartAfterIgnore = false
    private var approvedDevicePending: UUID?
    private var lastProgressSave = Date.distantPast
    private lazy var ble = BLEClient()
    private lazy var ledger = LedgerStore()
    private var deviceSync = DeviceSyncCoordinator()
    private var brain: DeepBrain?
    private var scope: RecordScope?
    private var activeConfig = AppConfig.load()
    private var legacyOwnerKey: String? = nil
    static let simulatedDeviceID = UUID(uuidString: "E6F5823B-83D7-48E0-AD25-D8571E557AB0")!
    var isSyncSimulation: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SHENNAO_SYNC_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    #if DEBUG
    private func configureSyncSimulation() {
        // Isolated preferences and ledger; no Bluetooth, credentials or cloud requests.
        let env = ProcessInfo.processInfo.environment
        let suite = "Shennao.SyncSimulation." + (env["SHENNAO_SYNC_SUITE"] ?? "preview")
        let defaults = UserDefaults(suiteName: suite)!
        deviceSync = DeviceSyncCoordinator(defaults: defaults)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShennaoSimulation/" + LedgerStore.sha256(suite))
        ledger = LedgerStore(directory: directory)
        let testScope = RecordScope(orgId: "simulation", email: "sync@example.test", config: activeConfig)
        scope = testScope
        email = "sync@example.test"
        isSignedIn = true
        let scenario = env["SHENNAO_SYNC_SCENARIO"] ?? "ready"
        if !defaults.bool(forKey: "seeded") {
            if scenario != "unbound" {
                deviceSync.remember(id: Self.simulatedDeviceID, name: "灵魂卡（模拟设备）", for: testScope)
                if scenario == "paused" { deviceSync.pause(for: testScope) }
            }
            defaults.set(true, forKey: "seeded")
        }
        selectedDeviceId = Self.simulatedDeviceID
        reloadDevicePreference()
        if ledger.items.isEmpty {
            do { try ledger.upsert(UIReadingFixtures.records(scenario: "default", scope: testScope)) }
            catch { importStorageBlocked = true }
        }
        reloadRecords()
        status = "演示模式"
        cloudStatus = "显示本地测试样例"
    }
    #endif

    private func runSyncSimulation() async throws -> DeviceSyncResult {
        #if DEBUG
        syncSimulationCalls += 1
        let scenario = ProcessInfo.processInfo.environment["SHENNAO_SYNC_SCENARIO"] ?? "ready"
        connectionStatus = "正在检查模拟设备"
        status = "检查录音中"
        if recordingEnabled, scenario == "working" {
            activeRecordID = "simulation-download"
            isDownloadingFile = true
        }
        try await Task.sleep(for: .seconds(scenario == "working" ? 30 : 0.5))
        if scenario == "unavailable" { throw BLEError.notFound }
        if scenario == "review", let scope {
            let entries = (0..<5).map { index in
                FileEntry(time: index < 3 ? 10800 : index == 3 ? 15 : 600, size: 21600000,
                          name: "note20260907-10000\(index).", rawName: [])
            }
            try save(ImportPolicy.discover(entries, records: records, scope: scope,
                                           deviceID: Self.simulatedDeviceID.uuidString, minimumSeconds: minimumRecordingSeconds))
            for original in records where original.isLocallyControllable && original.importDisposition?.allowsTransfer == true {
                try Task.checkCancellation()
                guard !processingPaused else { break }
                // A counter replaces each transport. Admission and durable decisions are production code.
                syncSimulationDownloads += 1
                var item = original
                item.state = .downloaded
                guard ImportPolicy.allowsUpload(item) else { continue }
                syncSimulationUploads += 1
                item.state = .processing
                item.autoUpload = false
                try save(item)
            }
        }
        connectionStatus = "待机"
        status = reviewCount > 0 ? "\(reviewCount) 条待确认" : "没有新录音"
        return DeviceSyncResult(complete: true, checked: true)
        #else
        throw BLEError.notConnected
        #endif
    }
    private var isInterfaceTest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SHENNAO_UI_FIXTURE"] == "1" || isSyncSimulation || RecorderHardwareProbe.targetID != nil
        #else
        return false
        #endif
    }

    init() {
        // The primary phone route owns continuous capture. Legacy fixtures keep
        // their isolated path; launching Xinlika must not restore old cloud/BLE jobs.
        if !isInterfaceTest && ProcessInfo.processInfo.environment["SHENNAO_LEGACY"] != "1" { return }
        #if DEBUG
        if CloudCatalogProbe.enabled {
            Task { status = await CloudCatalogProbe.run(config: activeConfig) }
            return
        }
        if let id = RecorderHardwareProbe.targetID {
            hardwareProbe = RecorderHardwareProbe(id: id)
            return
        }
        if isSyncSimulation {
            configureSyncSimulation()
            return
        }
        if isInterfaceTest {
            email = ""
            records = UIReadingFixtures.records(scenario: ProcessInfo.processInfo.environment["SHENNAO_UI_SCENARIO"] ?? "default")
            return
        }
        #endif
        // Pin legacy ownership once, before another account can sign in.
        let defaults = UserDefaults.standard
        let migrationKey = "ledgerOwnerMigration.v1"
        if !defaults.bool(forKey: migrationKey) {
            if DeepBrain.hasCredentials, let oldEmail = DeepBrain.signedInEmail {
                let owner = RecordScope(orgId: "", email: oldEmail, config: config).ownerKey
                defaults.set(owner, forKey: migrationKey + ".owner")
            }
            defaults.set(true, forKey: migrationKey)
        }
        legacyOwnerKey = defaults.string(forKey: migrationKey + ".owner")
        do {
            if try ledger.holdLegacyImportQueue() { cancelUploadTransfers() }
        } catch {
            importStorageBlocked = true
            cancelUploadTransfers()
            status = AppError.persistence.description
        }
        configureBrain()
        ble.onDisconnect = { [weak self] error in
            Diagnostics.event("ble_disconnected", error: error)
            Task { @MainActor in
                self?.connectionStatus = "蓝牙连接已断开"
                self?.recordingIsFresh = false
                self?.recordingConnectionID = nil
            }
        }
        ble.onRestore = { [weak self] id in
            Diagnostics.event("ble_system_restored")
            Task { @MainActor in self?.resumeDevice(id) }
        }
        BackgroundUploader.shared.restore()
        if ledger.loadError != nil { status = AppError.persistence.description }
        if DeepBrain.hasCredentials && config.isComplete {
            run {
                try await self.reconnect()
                self.status = "账号已恢复，可以同步或重试"
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--retry-record"), args.indices.contains(index + 1) {
                    try await self.retryRecord(args[index + 1])
                }
                if let index = args.firstIndex(of: "--verify-ble-record"), args.indices.contains(index + 1) {
                    try await self.verifyBLERecord(args[index + 1])
                }
                #endif
            }
        }
    }

    var selectedDevice: Discovered? {
        devices.first { $0.peripheral.identifier == selectedDeviceId }
    }

    var automaticSyncIsPaused: Bool {
        guard let scope else { return false }
        return deviceSync.isPaused(for: scope)
    }

    var visibleRecords: [LedgerItem] { records.filter(\.isVisibleRecord) }
    var reviewCount: Int { records.filter(\.isHeldForReview).count }
    var ignoredCount: Int { records.filter(\.isIgnored).count }
    var canResumeProcessing: Bool { !isBusy && !isScanning && !isRecordingControlBusy && !isStoppingProcessing && !importStorageBlocked }
    var compactSyncStatus: String {
        if isStoppingProcessing { return "正在暂停" }
        if processingPaused { return "同步已暂停" }
        if isUploading { return "正在上传" }
        if isBusy { return activeRecordID == nil ? "检查录音中" : "正在下载" }
        return "同步就绪"
    }

    func setMinimumRecordingSeconds(_ seconds: Int) {
        guard let scope else { return }
        deviceSync.setMinimumRecordingSeconds(seconds, for: scope)
        minimumRecordingSeconds = deviceSync.minimumRecordingSeconds(for: scope)
    }

    var deviceDisplayName: String { selectedDevice?.name ?? rememberedDevice?.name ?? "灵魂卡" }

    var canRememberSelectedDevice: Bool {
        if isSyncSimulation { return rememberedDevice == nil }
        return selectedDevice != nil && selectedDeviceId != rememberedDevice?.id
    }

    var automaticSyncSummary: String {
        guard isSignedIn else { return "登录后，选择自己的灵魂卡并开启自动同步。" }
        guard let device = rememberedDevice else { return "首次记住设备，以后打开 App 自动带回新录音。" }
        if automaticSyncIsPaused { return "自动同步已暂停，恢复后才会继续。" }
        if !device.automaticSyncEnabled { return "已记住设备，自动同步未开启。" }
        return "已记住 \(device.name)，打开 App 自动检查新录音。"
    }

    private func reloadDevicePreference() {
        rememberedDevice = scope.flatMap { deviceSync.device(for: $0) }
        processingPaused = scope.map { deviceSync.isPaused(for: $0) } ?? false
        minimumRecordingSeconds = scope.map { deviceSync.minimumRecordingSeconds(for: $0) } ?? ImportPolicy.defaultMinimumSeconds
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, !isScanning, !isRecordingControlBusy else { return }
        isBusy = true
        Task {
            let wasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = wasDisabled
                isBusy = false
                progress = nil
                reloadRecords()
                kickUploads()
                resumePendingDownload()
                // Fetching old cloud results must not hold the device queue after login.
                Task { await self.reconcile(force: true) }
            }
            do { try await action() }
            catch {
                status = readable(error)
                if !isSignedIn { accountMessage = status }
            }
        }
    }

    private func reloadRecords() {
        records = scope.map { scope in ledger.items.filter(scope.contains) } ?? []
    }

    private func save(_ item: LedgerItem) throws {
        do { try ledger.upsert(item) }
        catch {
            importStorageBlocked = true
            cancelSync()
            throw AppError.persistence
        }
        reloadRecords()
    }

    private func save(_ items: [LedgerItem]) throws {
        guard !items.isEmpty else { return }
        do { try ledger.upsert(items) }
        catch {
            importStorageBlocked = true
            cancelSync()
            throw AppError.persistence
        }
        reloadRecords()
    }

    func hasLocalAudio(_ item: LedgerItem) -> Bool {
        ledger.fileExists(for: item) && item.receivedBytes > 0 &&
        item.receivedBytes == item.expectedBytes && !item.contentHash.isEmpty
    }

    func saveConfiguration() {
        guard !accountLocked else { return }
        guard config.isComplete else {
            accountMessage = "请填写有效的 HTTPS 地址和 anon key"
            return
        }
        signOut()
        config.save()
        activeConfig = AppConfig.load()
        config = activeConfig
        configureBrain()
        accountMessage = "连接参数已保存，请重新登录"
    }

    func signIn() {
        guard !isInterfaceTest else { accountMessage = "演示模式不连接真实账号"; return }
        guard !restoringAuth else { return }
        guard config == activeConfig else { accountMessage = "请先保存修改后的连接参数"; return }
        guard config.isComplete else { accountMessage = "请先补全连接参数"; return }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty, !password.isEmpty else {
            accountMessage = "请输入邮箱和密码"; return
        }
        run {
            self.scope = nil
            self.isSignedIn = false
            self.reloadRecords()
            self.configureBrain()
            guard let brain = self.brain else { throw AppError.configuration }
            try await brain.signIn(email: cleanEmail, password: self.password)
            self.password = ""
            try self.acceptSession(brain)
            self.accountMessage = "已登录 \(cleanEmail)"
        }
    }

    func signOut() {
        guard !accountLocked else { return }
        brain?.signOut()
        scope = nil
        isSignedIn = false
        password = ""
        records = []
        cloudListError = nil
        cloudCatalogScope = nil
        nextCloudCatalogCheck = .distantPast
        pendingResultID = nil
        rememberedDevice = nil
        processingPaused = false
        minimumRecordingSeconds = ImportPolicy.defaultMinimumSeconds
        selectedDeviceId = nil
        approvedDevicePending = nil
        devices = []
        battery = nil
        firmware = nil
        fileCount = nil
        connectionStatus = "尚未连接"
        accountMessage = "已退出"
    }

    func scan() {
        guard !isInterfaceTest else { status = "演示模式不扫描真实硬件，请使用标明的模拟设备。"; return }
        guard !isScanning, !isBusy, !isRecordingControlBusy else { return }
        isScanning = true
        status = "正在寻找附近的灵魂卡…"
        Task {
            defer { isScanning = false }
            do {
                await stopRecordingObservation(disconnect: true)
                devices = (try await ble.scan(seconds: 6, nameHint: "CB08")).filter {
                    $0.byService || $0.name.localizedCaseInsensitiveContains("CB08")
                }
                if selectedDevice == nil { selectedDeviceId = devices.first?.peripheral.identifier }
                status = devices.isEmpty ? "没有找到设备。请确认灵魂卡已开机并在附近。" : "找到 \(devices.count) 台设备"
            } catch { status = readable(error) }
        }
    }

    func syncSelected() {
        guard isSignedIn, let scope, canResumeProcessing else { return }
        guard let id = selectedDeviceId ?? rememberedDevice?.id else { status = "请先寻找并选择自己的灵魂卡"; return }
        guard let request = deviceSync.claimManual(for: scope, deviceID: id) else { return }
        startSync(request, device: selectedDevice)
    }

    func rememberAndSyncSelected() {
        guard isSignedIn, let scope, canResumeProcessing else { return }
        let id: UUID
        let name: String
        if isSyncSimulation {
            id = Self.simulatedDeviceID; name = "灵魂卡（模拟设备）"
        } else {
            guard let device = selectedDevice else { return }
            id = device.peripheral.identifier; name = device.name
        }
        deviceSync.remember(id: id, name: name, for: scope)
        selectedDeviceId = id
        reloadDevicePreference()
        requestAutomaticSync()
    }

    func resumeAutomaticSync() {
        guard isSignedIn, let scope, canResumeProcessing else { return }
        deviceSync.resume(for: scope)
        UserDefaults.standard.removeObject(forKey: "uploadPaused." + scope.ownerKey)
        controlPaused = false
        reloadDevicePreference()
        status = "同步就绪"
        kickUploads()
        if let id = records.first(where: { $0.isLocallyControllable && $0.importDisposition?.allowsTransfer == true && !hasLocalAudio($0) })
            .flatMap({ UUID(uuidString: $0.deviceId) }) {
            selectedDeviceId = id
            syncSelected()
        } else { requestAutomaticSync() }
    }

    func cancelSync() {
        if let scope { deviceSync.pause(for: scope) }
        restartAfterIgnore = false
        approvedDevicePending = nil
        reloadDevicePreference()
        syncTask?.cancel()
        if syncTask != nil, !isSyncSimulation { ble.disconnect(); recordingIsFresh = false }
        cancelUploadTransfers()
        connectionStatus = "同步已暂停"
        status = "同步已暂停"
        cloudStatus = "上传已暂停"
    }

    private func cancelUploadTransfers() {
        uploadTask?.cancel()
        guard !isInterfaceTest, !isStoppingProcessing else { return }
        isStoppingProcessing = true
        Task {
            await BackgroundUploader.shared.cancelAll()
            isStoppingProcessing = false
            kickUploads()
            if isSignedIn && !processingPaused { resumePendingDownload() }
        }
    }

    func ignoreRecordings(_ ids: Set<String>) {
        guard isSignedIn, let scope else { return }
        let changes = records.filter { ids.contains($0.id) && scope.contains($0) }.map { original in
            var item = original
            item.importDisposition = .ignored
            item.autoUpload = false
            item.nextRetryAt = nil
            return item
        }
        do {
            try save(changes)
            if let activeRecordID, ids.contains(activeRecordID) {
                restartAfterIgnore = !processingPaused
                syncTask?.cancel()
                if !isSyncSimulation { ble.disconnect() }
            }
            cancelUploadTransfers()
        } catch { queueMessage = readable(error) }
    }

    func restoreIgnoredRecordings(_ ids: Set<String>) {
        guard isSignedIn else { return }
        let changes = records.filter { ids.contains($0.id) && $0.isIgnored }.map { original in
            var item = original
            item.importDisposition = item.isLocallyControllable ? .review : .approved
            item.importReviewReason = item.isLocallyControllable ? .existingQueue : nil
            item.autoUpload = false
            return item
        }
        do { try save(changes) }
        catch { queueMessage = readable(error) }
    }

    func approveRecordings(_ ids: Set<String>) {
        guard isSignedIn, let scope, !isStoppingProcessing, !importStorageBlocked else { return }
        let changes = records.filter { ids.contains($0.id) && scope.contains($0) && $0.isHeldForReview }.map { original in
            var item = original
            item.importDisposition = .approved
            item.importReviewReason = nil
            item.autoUpload = true
            item.retryCount = 0
            item.nextRetryAt = nil
            item.lastError = nil
            return item
        }
        do {
            try save(changes)
            guard !processingPaused else { return }
            kickUploads()
            if let device = changes.first(where: { !hasLocalAudio($0) }).flatMap({ UUID(uuidString: $0.deviceId) }) {
                if isBusy { approvedDevicePending = device }
                else {
                    selectedDeviceId = device
                    syncSelected()
                }
            }
        } catch { queueMessage = readable(error) }
    }

    private func startSync(_ request: DeviceSyncRequest, device: Discovered? = nil) {
        guard !isBusy, !isScanning, !isRecordingControlBusy, scope == request.scope else {
            deviceSync.finish(request, result: nil); return
        }
        isBusy = true
        battery = nil; firmware = nil; fileCount = nil
        status = request.reason == .recovery ? "正在接续已保存的任务…" : "正在检查灵魂卡中的新录音…"
        connectionStatus = "正在连接"
        Diagnostics.event("ble_sync_claimed")
        syncTask = Task {
            var result: DeviceSyncResult?
            defer {
                isDownloadingFile = false
                recordingTask?.cancel()
                recordingIsFresh = false
                recordingConnectionID = nil
                if !isSyncSimulation { ble.disconnect() }
                deviceSync.finish(request, result: result)
                if scope == request.scope { reloadDevicePreference() }
                activeCheckpoint = nil
                activeRecordID = nil
                progress = nil
                isBusy = false
                syncTask = nil
                if !isInterfaceTest { kickUploads() }
                if let pending = approvedDevicePending, !processingPaused {
                    approvedDevicePending = nil
                    selectedDeviceId = pending
                    syncSelected()
                } else if restartAfterIgnore {
                    restartAfterIgnore = false
                    if !processingPaused { syncSelected() }
                }
            }
            do {
                await stopRecordingObservation(disconnect: true)
                try Task.checkCancellation()
                if isSyncSimulation {
                    result = try await runSyncSimulation()
                } else {
                    let resolved = try await resolveDevice(request.deviceID, discovered: device)
                    try Task.checkCancellation()
                    guard scope == request.scope else { throw CancellationError() }
                    result = try await sync(resolved)
                }
            } catch {
                if error is CancellationError {
                    connectionStatus = automaticSyncIsPaused ? "自动同步已暂停" : "同步已暂停"
                } else {
                    status = readable(error)
                    connectionStatus = "连接未完成，请重试"
                }
                Diagnostics.event("ble_sync_paused", error: error)
            }
        }
    }

    private func resolveDevice(_ id: UUID, discovered: Discovered?) async throws -> Discovered {
        try await ble.waitPoweredOn()
        try Task.checkCancellation()
        if let discovered, discovered.peripheral.identifier == id { return discovered }
        if let known = ble.knownDevice(id) { return known }
        guard isForeground else { throw BLEError.notFound }
        // Match the saved identifier only. A nearby device with the same name is not a substitute.
        let found = try await ble.scan(seconds: 4)
        try Task.checkCancellation()
        guard let match = found.first(where: { $0.peripheral.identifier == id }) else { throw BLEError.notFound }
        return match
    }

    private func requestAutomaticSync(restoredDevice: UUID? = nil) {
        guard !isInterfaceTest || isSyncSimulation, isSignedIn, !isStoppingProcessing, !importStorageBlocked,
              let request = deviceSync.claimAutomatic(for: scope, foreground: isForeground,
                busy: isBusy || isScanning || isRecordingControlBusy || recordingPreventsSync,
                restoredDevice: restoredDevice) else { return }
        selectedDeviceId = request.deviceID
        startSync(request)
    }

    private func resumeDevice(_ id: UUID) {
        requestAutomaticSync(restoredDevice: id)
    }

    private func resumePendingDownload() {
        // Restoration can arrive before account recovery finishes. Retain that exact identity
        // until the verified scope is available; background recovery still requires a pending task.
        requestAutomaticSync(restoredDevice: isForeground ? nil : ble.restoredIdentifier)
    }

    func retry(_ id: String) {
        guard var item = ledger.item(id: id), scope?.contains(item) == true,
              item.canRetry, hasLocalAudio(item), uploadRecordID != id,
              !item.isIgnored, !item.isHeldForReview, !processingPaused else { return }
        do {
            item.importDisposition = .approved
            item.autoUpload = true
            item.retryCount = 0
            item.nextRetryAt = nil
            item.lastError = nil
            item.state = .downloaded
            try save(item)
            kickUploads()
        } catch { status = readable(error) }
    }

    private func retryRecord(_ id: String) async throws {
        // Debug recovery uses the same persisted queue as a user's retry button.
        retry(id)
    }

    func refreshStatuses() {
        Task { await reconcile(force: true) }
    }

    /// Awaitable UI entry point using the existing reconciliation policy.
    func refreshAllResults() async {
        await reconcile(force: true)
    }

    func refreshRecord(_ id: String) async {
        await reconcile(force: true, only: id)
    }

    func sceneChanged(active: Bool) {
        isForeground = active
        if !active {
            recordingIsFresh = false
            recordingTask?.cancel()
            recordingControlTask?.cancel()
            if recordingEnabled, syncTask == nil, !isSyncSimulation {
                ble.disconnect()
                recordingConnectionID = nil
            }
        } else { nextRecordingCheck = .distantPast }
        if isInterfaceTest {
            if isSyncSimulation, active { requestAutomaticSync() }
            return
        }
        Diagnostics.event(active ? "app_foreground" : "app_background",
                          record: activeRecordID, bytes: activeCheckpoint?.received)
        if active {
            controlPaused = false
            kickUploads()
            resumePendingDownload()
        } else if let checkpoint = activeCheckpoint {
            do {
                try checkpoint.flush()
                try updateDownloadProgress(checkpoint, force: true)
            } catch {
                status = readable(error)
                syncTask?.cancel()
            }
        }
    }

    func foregroundLoop() async {
        if isInterfaceTest { return }
        var delay = 8
        var first = true
        while !Task.isCancelled && isForeground {
            await restoreSessionIfNeeded()
            await reconcile(force: first)
            first = false
            kickUploads()
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            delay = min(60, delay * 2)
        }
    }

    /// Retry a transient foreground refresh failure instead of leaving the
    /// user stranded on the login screen. The durable refresh token remains in
    /// Keychain and the login form stays editable while this backs off.
    private func restoreSessionIfNeeded() async {
        guard !isSignedIn, DeepBrain.hasCredentials, !isBusy,
              !restoringAuth, Date() >= nextAuthRestore else { return }
        restoringAuth = true
        defer { restoringAuth = false }
        do {
            if brain == nil { configureBrain() }
            guard brain != nil else { throw AppError.configuration }
            try await reconnect()
            nextAuthRestore = .distantPast
            accountMessage = ""
            status = "账号已恢复，可以同步或重试"
        } catch {
            nextAuthRestore = Date().addingTimeInterval(60)
            if case DeepBrainError.http(_, let code, _) = error, [400, 401, 403].contains(code) {
                accountMessage = "登录凭证已失效，请重新登录"
            }
        }
    }

    func backgroundTransferFinished() {
        // Relaunch can be due to a completed background PUT; resume the control plane.
        controlPaused = false
        kickUploads()
    }

    private func reconcile(force: Bool, only id: String? = nil) async {
        guard isSignedIn, let brain, let verified = scope else { return }
        if isRefreshing {
            if let id { pendingResultID = id }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if let pending = pendingResultID {
                pendingResultID = nil
                Task { await self.reconcile(force: true, only: pending) }
            }
        }
        do {
            try await brain.connect()
            guard scope == verified else { return }
            if id == nil, force || cloudCatalogScope != verified || Date() >= nextCloudCatalogCheck {
                do {
                    let cloud = try await brain.cloudRecords()
                    try Task.checkCancellation()
                    guard scope == verified, brain.org == verified.orgId else { return }
                    try ledger.mergeCloudRecords(cloud, scope: verified)
                    reloadRecords()
                    cloudCatalogScope = verified
                    nextCloudCatalogCheck = Date().addingTimeInterval(60)
                    cloudListError = nil
                    Diagnostics.event("cloud_catalog_registered")
                } catch is CancellationError { return }
                catch {
                    guard scope == verified else { return }
                    cloudListError = "云端记录暂未更新"
                    nextCloudCatalogCheck = Date().addingTimeInterval(60)
                    Diagnostics.event("cloud_catalog_failed", error: error)
                }
            }
            let candidates = records.filter { !$0.isHeldForReview && !$0.isIgnored && (id == nil || $0.id == id) }
                .sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
            var failed = 0
            var cloudDetailsRead = 0
            for original in candidates {
                guard !Task.isCancelled, scope == verified else { return }
                if original.id == uploadRecordID || ledger.item(id: original.id)?.isVisibleRecord != true { continue }
                do {
                    var item = ledger.item(id: original.id) ?? original
                    if let sid = item.serverSessionId, item.state != .ready, !item.isCloudOnly {
                        let remote = try await brain.sessionState(sid)
                        guard scope == verified else { return }
                        item = applying(remote, to: ledger.item(id: item.id) ?? item)
                        try save(item)
                    }
                    if let tid = item.transcriptId,
                       force || item.meeting == nil || item.resultUpdatedAt == nil || item.meeting?.needsPolling == true || item.resultError != nil {
                        // Publish the entire catalogue first; bound background detail reads.
                        // Opening an older record explicitly retrieves its analysis.
                        if id == nil, item.isCloudOnly {
                            guard cloudDetailsRead < 8 else { continue }
                            cloudDetailsRead += 1
                        }
                        let result = try await brain.meeting(tid)
                        guard scope == verified else { return }
                        item = ledger.item(id: item.id) ?? item
                        item.meeting = result
                        item.title = result.title
                        item.resultUpdatedAt = Date()
                        item.resultError = nil
                        try save(item)
                    }
                } catch {
                    failed += 1
                    if var item = ledger.item(id: original.id), scope == verified {
                        item.resultError = readable(error)
                        try save(item)
                    }
                }
            }
            cloudStatus = failed == 0 ? "云端状态已更新" : "\(failed) 条结果暂未更新，已保留上次内容"
        } catch {
            guard scope == verified else { return }
            cloudStatus = readable(error)
            if id == nil { cloudListError = "云端记录暂未更新" }
        }
    }

    func analyze(_ id: String) async {
        guard let item = ledger.item(id: id), scope?.contains(item) == true,
              let tid = item.transcriptId, let brain,
              item.isVisibleRecord, !analyzingIDs.contains(id) else { return }
        analyzingIDs.insert(id)
        defer { analyzingIDs.remove(id) }
        do {
            try await brain.connect()
            guard scope?.contains(item) == true, ledger.item(id: id)?.isVisibleRecord == true else { return }
            try await brain.startAnalysis(tid)
            await reconcile(force: true, only: id)
        } catch {
            if var latest = ledger.item(id: id), scope?.contains(latest) == true {
                latest.resultError = readable(error)
                try? save(latest)
            }
        }
    }

    func webEntry(_ id: String) async throws -> URL {
        guard let item = ledger.item(id: id), scope?.contains(item) == true,
              let tid = item.transcriptId, let brain else { throw AppError.unavailableRecord }
        try await brain.connect()
        return try await brain.webEntry(tid)
    }

    private func kickUploads() {
        guard !isInterfaceTest else { return }
        guard uploadTask == nil, isSignedIn, !controlPaused, !processingPaused,
              !isStoppingProcessing, !importStorageBlocked, let scope else { return }
        let pending = records.filter {
            scope.contains($0) && hasLocalAudio($0) &&
            ImportPolicy.allowsUpload($0)
        }
        guard !pending.isEmpty else { return }
        isUploading = true
        uploadTask = Task {
            let lease = BackgroundLease(name: "ShennaoUploadControl") { [weak self] in
                self?.controlPaused = true
                Diagnostics.event("upload_control_suspended")
            }
            defer {
                lease.end()
                isUploading = false
                uploadTask = nil
                uploadRecordID = nil
                kickUploads()
            }
            for candidate in pending {
                guard !Task.isCancelled, self.scope == scope, !controlPaused, !processingPaused,
                      !isStoppingProcessing, let brain else { break }
                guard let current = ledger.item(id: candidate.id), ImportPolicy.allowsUpload(current) else { continue }
                uploadRecordID = candidate.id
                do {
                    try await brain.connect()
                    try ensureUploadControl(candidate.id)
                    guard let latest = ledger.item(id: candidate.id) else { continue }
                    try await upload(latest, brain: brain)
                    cloudStatus = "已提交分析"
                } catch {
                    Diagnostics.event("upload_interrupted", record: candidate.id, error: error)
                    guard var latest = ledger.item(id: candidate.id) else { continue }
                    if error is CancellationError || Task.isCancelled || processingPaused || isStoppingProcessing ||
                        latest.importDisposition?.allowsTransfer != true {
                        if latest.isLocallyControllable {
                            latest.state = .downloaded
                            latest.lastError = nil
                            do { try save(latest) } catch { status = readable(error) }
                        }
                        if Task.isCancelled || processingPaused || isStoppingProcessing { break }
                        continue
                    }
                    let retryable = RetryPolicy.isTransient(error)
                    let attempts = (latest.retryCount ?? 0) + 1
                    latest.retryCount = attempts
                    latest.autoUpload = retryable && attempts < 6
                    latest.nextRetryAt = Date().addingTimeInterval(RetryPolicy.delay(attempt: attempts))
                    latest.state = controlPaused ? .uploading : .failed
                    latest.lastError = readable(error)
                    do { try save(latest) } catch { status = readable(error); break }
                    cloudStatus = latest.lastError ?? "等待重试"
                }
            }
            uploadRecordID = nil
            if isForeground { await reconcile(force: true) }
        }
    }

    private func configureBrain() {
        brain = activeConfig.isComplete ? DeepBrain(config: activeConfig.deepBrain,
                                              captureClient: DeepBrain.fileImportClient) : nil
    }

    func pauseUploads() {
        cancelSync()
    }

    private func acceptSession(_ brain: DeepBrain) throws {
        guard let orgId = brain.org, let signedEmail = DeepBrain.signedInEmail else {
            throw AppError.notSignedIn
        }
        let verifiedScope = RecordScope(orgId: orgId, email: signedEmail, config: activeConfig)
        if verifiedScope.ownerKey == legacyOwnerKey {
            do { try ledger.adoptLegacyRecords(scope: verifiedScope) }
            catch { throw AppError.persistence }
        }
        scope = verifiedScope
        email = signedEmail
        isSignedIn = true
        reloadRecords()
        deviceSync.migrateLegacyIntent(for: verifiedScope, records: records)
        if UserDefaults.standard.bool(forKey: "uploadPaused." + verifiedScope.ownerKey) {
            deviceSync.pause(for: verifiedScope)
        }
        reloadDevicePreference()
        if processingPaused || records.contains(where: { $0.isIgnored || $0.isHeldForReview }) {
            cancelUploadTransfers()
        }
    }

    private func reconnect() async throws {
        guard activeConfig.isComplete else { throw AppError.configuration }
        if brain == nil { configureBrain() }
        guard let brain else { throw AppError.configuration }
        do {
            try await brain.connect()
            try acceptSession(brain)
        } catch {
            if case DeepBrainError.http(_, let code, _) = error, [400, 401, 403].contains(code) {
                isSignedIn = false
                scope = nil
                rememberedDevice = nil
                reloadRecords()
            }
            throw error
        }
    }

    private func sync(_ device: Discovered) async throws -> DeviceSyncResult {
        guard ledger.loadError == nil else { throw AppError.persistence }
        guard let scope else { throw AppError.notSignedIn }
        connectionStatus = "正在连接 \(device.name)…"
        try await ble.connect(device)
        recordingConnectionID = device.peripheral.identifier
        connectionStatus = "已连接"
        battery = (try? await ble.battery()) ?? nil
        firmware = (try? await ble.firmware()) ?? nil
        let recordStatus = (try? await ble.recordStatus()) ?? nil
        try Task.checkCancellation()
        guard let recordStatus, let state = RecorderState(rawValue: recordStatus) else { throw AppError.deviceStateUnknown }
        publishRecording(RecorderReading(state: state, seconds: nil, confirmedAt: Date()), deviceID: device.peripheral.identifier)
        // Give recording priority; do not compete for the device's storage while it is recording.
        guard state == .idle else {
            status = "录音结束后同步"
            return DeviceSyncResult(complete: false, checked: false)
        }
        let (entries, gotDone) = try await ble.fileList()
        try Task.checkCancellation()
        Diagnostics.event("ble_file_list_received")
        fileCount = entries.count
        let deviceId = device.peripheral.identifier.uuidString
        var completed = 0
        var failures = 0
        let eligible = entries
        // Register the entire batch before admitting any transfer; ignored identities survive rediscovery.
        try save(ImportPolicy.discover(eligible, records: records, scope: scope, deviceID: deviceId,
                                       minimumSeconds: minimumRecordingSeconds, listComplete: gotDone))
        for entry in DeviceSyncPlan.prioritizeRecovery(eligible, records: records, scope: scope, deviceID: deviceId) {
            try Task.checkCancellation()
            if processingPaused { break }
            let base = normalize(entry.name)
            guard var item = records.first(where: {
                $0.deviceId == deviceId && $0.fileBase == base && $0.expectedBytes == Int(entry.size)
            }), item.importDisposition?.allowsTransfer == true, item.isLocallyControllable else { continue }
            if hasLocalAudio(item) { kickUploads(); continue }
            let id = item.id
            item.state = .downloading
            try save(item)
            activeRecordID = id
            do {
                let raw = try await downloadWithRecovery(entry, item: item, device: device)
                try Task.checkCancellation()
                guard !processingPaused, ledger.item(id: id)?.importDisposition?.allowsTransfer == true else {
                    throw CancellationError()
                }
                guard OggWrap.looksRaw([UInt8](raw)) else { throw AppError.audioFormat }
                let wrapped = Data(try OggWrap.wrap([UInt8](raw)))
                item = ledger.item(id: id) ?? item
                item.receivedBytes = raw.count
                item.contentHash = LedgerStore.sha256(raw)
                item.audioHash = LedgerStore.sha256(wrapped)
                item.durationSec = OggWrap.durationSeconds(rawLength: raw.count)
                item.state = .downloaded
                item.autoUpload = true
                if item.importDisposition == .automatic,
                   let reason = ImportPolicy.reviewReason(duration: item.durationSec, newCount: 1,
                                                          minimumSeconds: minimumRecordingSeconds) {
                    item.importDisposition = .review
                    item.importReviewReason = reason
                    item.autoUpload = false
                }
                item.lastError = nil
                item.updatedAt = Date()
                do {
                    try wrapped.write(to: ledger.fileURL(for: item),
                                      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch { throw AppError.persistence }
                try save(item)
                completed += 1
                activeCheckpoint = nil
                activeRecordID = nil
                kickUploads()
            } catch {
                var latest = ledger.item(id: id) ?? item
                latest.receivedBytes = activeCheckpoint?.manifest.committed ?? latest.receivedBytes
                latest.state = .paused
                latest.lastError = readable(error)
                latest.updatedAt = Date()
                try save(latest)
                activeCheckpoint = nil
                failures += 1
                // Loss of connection affects the whole device queue, not just this file.
                if error is CancellationError || !ble.isConnected { throw error }
                if case AppError.persistence = error { throw error }
                if case DownloadFailure.storage = error { throw error }
            }
        }
        activeRecordID = nil
        connectionStatus = failures == 0 ? "检查完成" : "部分录音待重试"
        status = reviewCount > 0 ? "\(reviewCount) 条待确认" : completed > 0 ? "已保存 \(completed) 条录音" : "没有新录音"
        if !gotDone { status = "列表未完整，请重试" }
        Diagnostics.event("ble_sync_finished")
        return DeviceSyncResult(complete: failures == 0 && gotDone, checked: gotDone)
    }

    private func downloadWithRecovery(_ entry: FileEntry, item: LedgerItem,
                                      device: Discovered) async throws -> Data {
        guard let filename = entry.candidates.first(where: { $0.lowercased().hasSuffix(".opus") }) else {
            throw AppError.audioFormat
        }
        var lastError: Error = DownloadFailure.incomplete
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                if !ble.isConnected {
                    await stopRecordingObservation(disconnect: true)
                    try Task.checkCancellation()
                    connectionStatus = "正在重连（\(attempt + 1)/4）"
                    try await ble.connect(device)
                    let (fresh, _) = try await ble.fileList()
                    guard fresh.contains(where: { $0.name == entry.name && $0.size == entry.size && $0.time == entry.time }) else {
                        throw DownloadFailure.wrongFile
                    }
                    recordingConnectionID = device.peripheral.identifier
                }
                let checkpoint = try DownloadCheckpoint(recordID: item.id, expected: item.expectedBytes, filename: filename)
                activeCheckpoint = checkpoint
                status = "正在下载 \(item.fileBase)"
                connectionStatus = checkpoint.received > 0 ? "已连接，从保存的断点继续" : "已连接，正在下载"
                isDownloadingFile = true
                try await ble.download(checkpoint: checkpoint) { [weak self] received, expected in
                    guard let self else { return }
                    self.progress = Double(received) / Double(expected)
                    do { try self.updateDownloadProgress(checkpoint, force: false) }
                    catch { self.syncTask?.cancel(); self.status = self.readable(error) }
                }
                isDownloadingFile = false
                return try checkpoint.readComplete()
            } catch {
                isDownloadingFile = false
                lastError = error
                Diagnostics.event("ble_download_interrupted", record: item.id,
                                  bytes: activeCheckpoint?.manifest.committed, error: error)
                if error is CancellationError { throw error }
                if let error = error as? DownloadFailure {
                    switch error {
                    case .storage, .corruptCheckpoint, .wrongFile, .deviceRejected: throw error
                    case .incomplete: break
                    }
                }
                activeCheckpoint = nil
                await stopRecordingObservation(disconnect: true)
                if attempt < 3 {
                    connectionStatus = "进度已保存，稍后重连（\(attempt + 1)/3）"
                    try await Task.sleep(for: .seconds([2, 5, 12][attempt]))
                }
            }
        }
        throw lastError
    }

    private func updateDownloadProgress(_ checkpoint: DownloadCheckpoint, force: Bool) throws {
        guard force || Date().timeIntervalSince(lastProgressSave) >= 1 else { return }
        guard var item = ledger.item(id: checkpoint.manifest.recordID) else { return }
        item.receivedBytes = checkpoint.manifest.committed
        item.updatedAt = Date()
        try save(item)
        lastProgressSave = Date()
    }

    private func upload(_ original: LedgerItem, brain: DeepBrain) async throws {
        guard scope?.contains(original) == true, brain.org == original.orgId else {
            throw AppError.unavailableRecord
        }
        var item = original
        guard hasLocalAudio(item), let data = try? Data(contentsOf: ledger.fileURL(for: item)) else {
            throw AppError.missingAudio
        }
        let hash = LedgerStore.sha256(data)
        guard data.starts(with: Data("OggS".utf8)), item.audioHash == nil || item.audioHash == hash else {
            throw AppError.audioFormat
        }
        item.audioHash = hash
        item.state = .uploading
        item.lastError = nil
        item.updatedAt = Date()
        try save(item)
        // Preserve the deployed v2 key so retrying does not create a second session.
        try ensureUploadControl(original.id)
        let requestId = "ble-v2-\(LedgerStore.sha256("\(item.orgId)|\(item.contentHash)").prefix(48))"
        let result = try await brain.upload(
            audio: [UInt8](data), title: item.title, durationSec: item.durationSec,
            clientRequestId: requestId, mime: "audio/ogg",
            startedAt: Continuation.startedAt(base: item.fileBase),
            onSessionCreated: { sid in
                try self.persistSession(sid, for: original.id)
                try self.ensureUploadControl(original.id)
            },
            uploadPart: { data, url, mime, key in
                try self.ensureUploadControl(original.id)
                let code = try await BackgroundUploader.shared.put(data, to: url, mime: mime,
                    identity: (original.ownerKey ?? "") + "|" + key, recordID: original.id)
                try self.ensureUploadControl(original.id)
                return code
            },
            checkContinuation: { try self.ensureUploadControl(original.id) })
        var latest = ledger.item(id: item.id) ?? item
        latest.serverSessionId = result.sessionId
        latest.state = .processing
        latest.autoUpload = false
        latest.lastError = nil
        latest.updatedAt = Date()
        try save(latest)
        if let remote = try? await brain.sessionState(result.sessionId) {
            try save(applying(remote, to: ledger.item(id: item.id) ?? latest))
        }
    }

    private func ensureUploadControl(_ id: String) throws {
        try Task.checkCancellation()
        guard !processingPaused, !isStoppingProcessing, !importStorageBlocked,
              let item = ledger.item(id: id), scope?.contains(item) == true,
              item.importDisposition?.allowsTransfer == true, item.autoUpload == true else { throw CancellationError() }
        if controlPaused { throw TransferError.interrupted(-999) }
    }

    private func persistSession(_ sid: String, for id: String) throws {
        guard var latest = ledger.item(id: id), scope?.contains(latest) == true else {
            throw AppError.unavailableRecord
        }
        latest.serverSessionId = sid
        latest.updatedAt = Date()
        try save(latest)
    }

    private func recordFailure(_ id: String, error: Error) throws {
        if case AppError.persistence = error { throw error }
        guard var latest = ledger.item(id: id) else { throw AppError.unavailableRecord }
        latest.state = .failed
        latest.lastError = readable(error)
        latest.updatedAt = Date()
        try save(latest)
    }

    private func applying(_ remote: DeepBrain.SessionState, to original: LedgerItem) -> LedgerItem {
        var item = original
        item.transcriptId = remote.transcriptId
        item.lastError = remote.errorCode
        switch remote.status {
        case "ready" where remote.transcriptId != nil: item.state = .ready
        case "failed", "deleted", "deleting":
            item.state = .failed
            item.lastError = remote.errorCode ?? "云端处理未完成，请重试或联系支持"
        case "recording", "uploading":
            item.state = .downloaded
            item.lastError = "云端尚未收到完整录音，可从本地重试上传"
        default: item.state = .processing
        }
        item.updatedAt = Date()
        return item
    }

    private func normalize(_ name: String) -> String {
        DeviceSyncPlan.fileBase(name)
    }

    #if DEBUG
    /// Read-only hardware regression: distinct partial file, never creates a cloud session.
    private func verifyBLERecord(_ id: String) async throws {
        guard let original = ledger.item(id: id), scope?.contains(original) == true,
              let deviceID = UUID(uuidString: original.deviceId),
              let device = ble.knownDevice(deviceID) else { throw AppError.unavailableRecord }
        await stopRecordingObservation(disconnect: true)
        defer {
            recordingTask?.cancel(); recordingIsFresh = false; recordingConnectionID = nil
            ble.disconnect(); activeCheckpoint = nil; activeRecordID = nil
        }
        Diagnostics.event("ble_verification_started", record: id)
        status = "验证模式：仅从设备读取，不重复上传"
        connectionStatus = "正在连接灵魂卡"
        try await ble.connect(device)
        recordingConnectionID = deviceID
        let (entries, _) = try await ble.fileList()
        guard let entry = entries.first(where: { normalize($0.name) == original.fileBase && Int($0.size) == original.expectedBytes }) else {
            throw DownloadFailure.wrongFile
        }
        let verificationID = "verification-" + id
        activeRecordID = verificationID
        let verification = LedgerItem(id: verificationID, orgId: original.orgId, deviceId: original.deviceId,
            fileBase: original.fileBase, title: "仅验证，不上传", durationSec: original.durationSec,
            expectedBytes: original.expectedBytes, receivedBytes: 0, localFilename: "verification.ogg",
            contentHash: "", serverSessionId: nil, transcriptId: nil, state: .downloading,
            lastError: nil, updatedAt: Date(), ownerKey: original.ownerKey)
        let raw = try await downloadWithRecovery(entry, item: verification, device: device)
        guard LedgerStore.sha256(raw) == original.contentHash else { throw DownloadFailure.corruptCheckpoint }
        Diagnostics.event("ble_verification_hash_matched", record: id, bytes: raw.count)
        status = "验证完成：字节和内容校验一致，未重新上传"
        connectionStatus = "设备待机"
    }
    #endif

    private func readable(_ error: Error) -> String {
        if error is CancellationError { return "任务已暂停，已保存的进度仍保留" }
        if let error = error as? DownloadFailure { return error.description }
        if let error = error as? TransferError { return error.description }
        if let error = error as? AppError { return error.description }
        if case DeepBrainError.http(_, let code, let body) = error {
            if code == 409 && body.contains("额度") { return body }
            if code == 401 { return "登录已失效，请重新登录；手机里的录音仍保留" }
            if code == 400 && body.contains("采集端类型无效") {
                return "当前上传类型不被服务端支持，请更新 App 后重试；本地录音仍保留"
            }
            return "云端请求失败（HTTP \(code)），请重试；本地录音仍保留"
        }
        if error is URLError { return "网络暂不可用，请检查连接后重试；本地录音仍保留" }
        return String(describing: error)
    }
}

// Recording controls share the existing BLE connection. Read-only TYPE=3 replies are routed
// separately from file data; mutations drain the download task before issuing a command.
extension AppModel {
    var recordingTargetID: UUID? { selectedDeviceId ?? rememberedDevice?.id }
    var recordingEnabled: Bool {
        #if DEBUG
        if isInterfaceTest {
            return isSyncSimulation && ProcessInfo.processInfo.environment["SHENNAO_RECORDING_SCENARIO"] != nil
        }
        #endif
        return true
    }
    var canControlRecording: Bool {
        recordingEnabled && recordingTargetID != nil && isForeground && !isRecordingControlBusy &&
        !isScanning && (!isBusy || syncTask != nil)
    }
    var recordingState: RecorderState? {
        recordingIsFresh && recordingReadDeviceID == recordingTargetID && recordingReading?.isFresh(at: Date()) == true
        ? recordingReading?.state : nil
    }
    var recordingPreventsSync: Bool { recordingState == .recording || recordingState == .paused }
    var showRecordingBanner: Bool {
        recordingEnabled && recordingTargetID != nil &&
        (recordingNeedsAttention || (recordingReading?.state != nil && recordingReading?.state != .idle))
    }
    var recordingStatusText: String {
        guard let state = recordingState else { return "状态待确认" }
        switch state {
        case .recording: return "录音中"
        case .idle: return "未录音"
        case .paused: return "录音已暂停"
        }
    }
    var recordingDurationText: String? {
        guard recordingIsFresh, let seconds = recordingReading?.seconds else { return nil }
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func resetRecordingTarget() {
        lastSavedRecordingID = nil
        recordingTask?.cancel()
        recordingControlTask?.cancel()
        recordingReading = nil
        recordingReadDeviceID = nil
        recordingIsFresh = false
        recordingMessage = nil
        recordingNeedsAttention = false
        nextRecordingCheck = .distantPast
        if recordingEnabled, syncTask == nil, !isSyncSimulation {
            ble.disconnect()
            recordingConnectionID = nil
        }
    }

    private func publishRecording(_ reading: RecorderReading, deviceID: UUID) {
        guard recordingTargetID == deviceID, isForeground else { return }
        let wasActive = recordingReading?.state == .recording || recordingReading?.state == .paused
        if recordingReading?.state != reading.state || recordingReadDeviceID != deviceID {
            switch reading.state {
            case .recording: Diagnostics.event("recorder_state_recording")
            case .idle: Diagnostics.event("recorder_state_idle")
            case .paused: Diagnostics.event("recorder_state_paused")
            }
        }
        recordingReading = reading
        recordingReadDeviceID = deviceID
        recordingIsFresh = reading.isFresh(at: Date())
        recordingNeedsAttention = false
        recordingMessage = nil
        // A physical stop is discovered by the same polling path as an app-initiated stop.
        if wasActive, reading.state == .idle, !isRecordingControlBusy, !processingPaused,
           rememberedDevice?.id == deviceID, rememberedDevice?.automaticSyncEnabled == true {
            syncSelected()
        }
    }

    private func stopRecordingObservation(disconnect: Bool) async {
        let task = recordingTask
        task?.cancel()
        if disconnect {
            recordingIsFresh = false
            recordingConnectionID = nil
            if !isSyncSimulation { ble.disconnect() }
        }
        await task?.value
    }

    func recordingMonitorLoop() async {
        guard recordingEnabled else { return }
        while !Task.isCancelled && isForeground {
            if recordingIsFresh, recordingReading?.isFresh(at: Date()) != true { recordingIsFresh = false }
            // During a download we reuse the connection for small read-only queries.
            // Connection setup / file-list retrieval remain exclusive to the sync task.
            let canObserve = !isBusy || (isDownloadingFile && (isSyncSimulation || ble.isConnected))
            if canObserve, !isScanning, !isRecordingControlBusy, recordingTask == nil,
               let id = recordingTargetID, Date() >= nextRecordingCheck {
                observeRecording(id)
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func connectForRecording(_ id: UUID) async throws {
        #if DEBUG
        if isSyncSimulation { try recordingSimulation.connect(); return }
        #endif
        if ble.isConnected, recordingConnectionID == id { return }
        // Only the sync task may replace a connection while a transfer owns it.
        guard syncTask == nil else { throw BLEError.notConnected }
        let device = try await resolveDevice(id, discovered: selectedDevice)
        try Task.checkCancellation()
        guard id == recordingTargetID, isForeground else { throw CancellationError() }
        try await ble.connect(device)
        recordingConnectionID = id
        connectionStatus = "蓝牙已连接"
    }

    private func recordingExchange(_ command: UInt8, _ reply: UInt8) async throws -> [UInt8]? {
        #if DEBUG
        if isSyncSimulation {
            let response = try await recordingSimulation.exchange(command, reply)
            return response
        }
        #endif
        return try await ble.recordingExchange(command, reply: reply)
    }

    private func sendRecordingCommand(_ action: RecorderAction) async throws {
        try Task.checkCancellation()
        #if DEBUG
        if isSyncSimulation {
            try await recordingSimulation.send(action)
            recordingSimulationCommandCount = recordingSimulation.actions.count
            return
        }
        #endif
        try ble.sendRecording(action)
    }

    var lastSavedRecording: LedgerItem? {
        records.first { $0.id == lastSavedRecordingID && $0.deviceId == recordingTargetID?.uuidString && !$0.isIgnored }
    }

    /// Reading a card's catalogue never approves a recording or starts a transfer.
    func refreshRecordingCatalog() {
        guard isSignedIn else { return }
        controlRecording(refreshCatalog: true)
    }

    private func currentRecordingFilename() async throws -> String? {
        #if DEBUG
        if isSyncSimulation { return recordingSimulation.filename }
        #endif
        return try await ble.currentFilename(timeout: 2)
    }

    private func registerRecordingCatalog(deviceID: UUID, savedFilename: String? = nil) async throws -> LedgerItem? {
        guard let catalogScope = scope, isSignedIn else { return nil }
        let entries: [FileEntry]
        let complete: Bool
        #if DEBUG
        if isSyncSimulation {
            entries = recordingSimulation.files
            complete = true
        } else {
            (entries, complete) = try await ble.fileList(hardTimeout: 8)
        }
        #else
        (entries, complete) = try await ble.fileList(hardTimeout: 8)
        #endif
        try Task.checkCancellation()
        guard scope == catalogScope, recordingTargetID == deviceID else { throw CancellationError() }
        try save(ImportPolicy.discover(entries, records: records, scope: catalogScope,
                                       deviceID: deviceID.uuidString, minimumSeconds: minimumRecordingSeconds,
                                       listComplete: complete))
        fileCount = entries.count
        Diagnostics.event("recorder_catalog_registered", bytes: entries.count)
        guard let savedFilename,
              let entry = entries.first(where: { DeviceSyncPlan.fileBase($0.name) == DeviceSyncPlan.fileBase(savedFilename) }) else { return nil }
        return records.first {
            catalogScope.contains($0) && $0.deviceId == deviceID.uuidString &&
            $0.fileBase == DeviceSyncPlan.fileBase(entry.name) && $0.expectedBytes == Int(entry.size)
        }
    }

    private func observeRecording(_ id: UUID) {
        isRecordingChecking = true
        recordingTask = Task {
            defer { recordingTask = nil; isRecordingChecking = false }
            do {
                try await connectForRecording(id)
                let reading = try await RecordingControl.read(exchange: recordingExchange)
                try Task.checkCancellation()
                publishRecording(reading, deviceID: id)
                nextRecordingCheck = reading.confirmedAt.addingTimeInterval(5)
                if reading.state != .idle, activeRecordID != nil {
                    // Hardware recording wins over imports. Cancellation commits the checkpoint.
                    syncTask?.cancel()
                    if !isSyncSimulation { ble.disconnect() }
                    status = "录音结束后同步"
                }
            } catch {
                guard recordingTargetID == id else { return }
                recordingIsFresh = false
                if !(error is CancellationError) {
                    nextRecordingCheck = Date().addingTimeInterval(30)
                    if !isSyncSimulation { ble.disconnect(); recordingConnectionID = nil }
                    connectionStatus = "蓝牙状态待确认"
                }
            }
        }
    }

    /// nil refreshes status; it never starts/stops recording or changes the user's sync pause.
    func controlRecording(_ action: RecorderAction? = nil, refreshCatalog: Bool = false) {
        // A read-only refresh must not tear down connection setup or file-list retrieval.
        // The active sync already publishes state and registers its file list.
        if action == nil, syncTask != nil {
            nextRecordingCheck = .distantPast
            return
        }
        guard canControlRecording, let id = recordingTargetID else { return }
        isRecordingControlBusy = true
        recordingMessage = nil
        if action == .start { lastSavedRecordingID = nil }
        recordingControlTask = Task {
            var saved = false
            let diagnosticRun = UUID().uuidString
            if !isSyncSimulation {
                ble.onRecordingDiagnostic = { event in Diagnostics.recordingExchange(event, run: diagnosticRun) }
                Diagnostics.recordingOperation("begin", run: diagnosticRun, action: action,
                                               state: recordingState, firmware: firmware)
            }
            defer {
                if !isSyncSimulation {
                    Diagnostics.recordingOperation("end", run: diagnosticRun, action: action,
                                                   state: recordingState, firmware: firmware)
                    ble.onRecordingDiagnostic = nil
                }
                isRecordingControlBusy = false
                recordingControlTask = nil
                nextRecordingCheck = Date().addingTimeInterval(5)
                if saved, isForeground, !processingPaused, recordingTargetID == id { syncSelected() }
            }
            do {
                await stopRecordingObservation(disconnect: false)
                let transfer = syncTask
                transfer?.cancel()
                if transfer != nil, !isSyncSimulation { ble.disconnect(); recordingConnectionID = nil }
                await transfer?.value
                try Task.checkCancellation()
                guard id == recordingTargetID, isForeground else { throw CancellationError() }
                try await connectForRecording(id)
                if let action {
                    let savedFilename = action == .save ? try? await currentRecordingFilename() : nil
                    let result = try await RecordingControl.perform(action, send: sendRecordingCommand, exchange: recordingExchange)
                    try Task.checkCancellation()
                    publishRecording(result.reading, deviceID: id)
                    recordingMessage = result.message
                    if action != .save, result.message == nil, result.reading.state == .recording, !isSyncSimulation {
                        // TYPE=1 also starts live OPUS notifications. The card keeps recording
                        // across disconnect (physically verified); reconnecting for status leaves
                        // that stream behind instead of receiving unused audio for hours.
                        ble.disconnect()
                        recordingConnectionID = nil
                        connectionStatus = "录音中"
                    }
                    Diagnostics.event(result.message == nil ? "recorder_control_confirmed" : "recorder_control_unconfirmed")
                    saved = result.saved
                    if saved {
                        do {
                            let item = try await registerRecordingCatalog(deviceID: id, savedFilename: savedFilename)
                            lastSavedRecordingID = item?.id
                            if item == nil { recordingMessage = "录音已结束，文件列表待确认" }
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            // State confirmation remains valid even if catalogue retrieval fails.
                            recordingMessage = "录音已结束，文件列表待更新"
                            Diagnostics.event("recorder_catalog_failed", error: error)
                        }
                    }
                } else {
                    let reading = try await RecordingControl.read(exchange: recordingExchange)
                    try Task.checkCancellation()
                    publishRecording(reading, deviceID: id)
                    if refreshCatalog, reading.state == .idle {
                        do { _ = try await registerRecordingCatalog(deviceID: id) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            queueMessage = "录音列表未更新，请靠近录音卡后重试"
                            Diagnostics.event("recorder_catalog_failed", error: error)
                        }
                    }
                }
            } catch {
                guard recordingTargetID == id else { return }
                recordingIsFresh = false
                if action != nil { recordingNeedsAttention = true }
                if action != nil { Diagnostics.event("recorder_control_unconfirmed", error: error) }
                if !(error is CancellationError) {
                    recordingMessage = (error as? LocalizedError)?.errorDescription ?? "连接未完成，请靠近录音卡后重试"
                }
                if !isSyncSimulation { ble.disconnect(); recordingConnectionID = nil }
            }
        }
    }
}

private enum AppError: Error, CustomStringConvertible {
    case configuration, notSignedIn, unavailableRecord, persistence, missingAudio, audioFormat, deviceStateUnknown
    case incomplete(expected: Int, received: Int)

    var description: String {
        switch self {
        case .configuration: return "连接参数还没有配置完整"
        case .notSignedIn: return "登录状态已失效，请重新登录"
        case .unavailableRecord: return "此记录不属于当前账号，或当前状态不支持重试"
        case .persistence: return "本地保存失败，已停止同步以保护录音。请检查可用空间，勿卸载 App"
        case .missingAudio: return "本地录音不完整或不存在，请连接灵魂卡重新同步"
        case .audioFormat: return "录音格式或完整性检查未通过，未上传。请连接灵魂卡重新同步或联系支持"
        case .deviceStateUnknown: return "无法确认设备正在录制哪个文件，请停止录音后重试"
        case .incomplete(let expected, let received):
            return "设备下载不完整：收到 \(received)/\(expected) 字节，请连接灵魂卡重新同步"
        }
    }
}

import Foundation

struct RememberedDevice: Codable, Equatable {
    let id: UUID
    var name: String
    var automaticSyncEnabled = true
    var isPaused = false
    var lastCheckedAt: Date?
}

struct DeviceSyncRequest: Equatable {
    enum Reason { case automatic, recovery, manual }
    let token = UUID()
    let scope: RecordScope
    let deviceID: UUID
    let reason: Reason
}

struct DeviceSyncResult {
    let complete: Bool
    let checked: Bool
}

enum DeviceSyncPlan {
    static func fileBase(_ name: String) -> String {
        let last = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return last.hasSuffix(".") ? String(last.dropLast()) : last
    }

    /// Keep firmware order within each group. Hardware dates are not trusted for ordering.
    static func prioritizeRecovery(_ entries: [FileEntry], records: [LedgerItem],
                                   scope: RecordScope, deviceID: String) -> [FileEntry] {
        let pending = records.filter {
            scope.contains($0) && $0.deviceId == deviceID && [.downloading, .paused].contains($0.state)
        }
        var recovering: [FileEntry] = [], remaining: [FileEntry] = []
        for entry in entries {
            if pending.contains(where: { $0.fileBase == fileBase(entry.name) && $0.expectedBytes == Int(entry.size) }) {
                recovering.append(entry)
            } else {
                remaining.append(entry)
            }
        }
        return recovering + remaining
    }
}

/// Owns the durable preference and pending intent separately. It never opens Bluetooth.
/// All callers claim a request before asynchronous work; only that token can finish it.
@MainActor
final class DeviceSyncCoordinator {
    private let defaults: UserDefaults
    private let cooldown: TimeInterval
    private var attemptedAt: [String: Date] = [:]
    private(set) var active: DeviceSyncRequest?

    init(defaults: UserDefaults = .standard, cooldown: TimeInterval = 60) {
        self.defaults = defaults
        self.cooldown = cooldown
    }

    private func key(_ scope: RecordScope) -> String {
        "deviceSync.v1." + LedgerStore.sha256(scope.orgId + "|" + scope.ownerKey)
    }

    func device(for scope: RecordScope) -> RememberedDevice? {
        guard let data = defaults.data(forKey: key(scope) + ".device") else { return nil }
        return try? JSONDecoder().decode(RememberedDevice.self, from: data)
    }

    func save(_ device: RememberedDevice, for scope: RecordScope) {
        guard let data = try? JSONEncoder().encode(device) else { return }
        defaults.set(data, forKey: key(scope) + ".device")
    }

    func pendingDevice(for scope: RecordScope) -> UUID? {
        defaults.string(forKey: key(scope) + ".pending").flatMap(UUID.init(uuidString:))
    }

    func minimumRecordingSeconds(for scope: RecordScope) -> Int {
        (defaults.object(forKey: key(scope) + ".minimumSeconds") as? Int) ?? ImportPolicy.defaultMinimumSeconds
    }

    func setMinimumRecordingSeconds(_ seconds: Int, for scope: RecordScope) {
        guard [0, 30, 60, 120].contains(seconds) else { return }
        defaults.set(seconds, forKey: key(scope) + ".minimumSeconds")
    }

    func remember(id: UUID, name: String, for scope: RecordScope) {
        clearPending(for: scope)
        defaults.removeObject(forKey: key(scope) + ".paused")
        save(RememberedDevice(id: id, name: name), for: scope)
        attemptedAt[key(scope)] = nil
    }

    func pause(for scope: RecordScope) {
        if var device = device(for: scope) {
            device.isPaused = true
            save(device, for: scope)
        }
        // Also works for a legacy manual task with no remembered device.
        defaults.set(true, forKey: key(scope) + ".paused")
        clearPending(for: scope)
    }

    func resume(for scope: RecordScope) {
        if var device = device(for: scope) {
            device.isPaused = false
            device.automaticSyncEnabled = true
            save(device, for: scope)
        }
        defaults.removeObject(forKey: key(scope) + ".paused")
        attemptedAt[key(scope)] = nil
    }

    func isPaused(for scope: RecordScope) -> Bool {
        defaults.bool(forKey: key(scope) + ".paused") || device(for: scope)?.isPaused == true
    }

    func clearPending(for scope: RecordScope) {
        defaults.removeObject(forKey: key(scope) + ".pending")
        defaults.removeObject(forKey: "syncIntent." + scope.ownerKey)
    }

    /// Old intents did not include organization identity. Adopt only with a matching local task.
    func migrateLegacyIntent(for scope: RecordScope, records: [LedgerItem]) {
        guard pendingDevice(for: scope) == nil, !isPaused(for: scope),
              let raw = defaults.string(forKey: "syncIntent." + scope.ownerKey),
              let id = UUID(uuidString: raw),
              records.contains(where: { scope.contains($0) && $0.deviceId == raw &&
                  [.downloading, .paused].contains($0.state) }) else { return }
        defaults.set(id.uuidString, forKey: key(scope) + ".pending")
        defaults.removeObject(forKey: "syncIntent." + scope.ownerKey)
    }

    func claimAutomatic(for scope: RecordScope?, foreground: Bool, busy: Bool,
                        restoredDevice: UUID? = nil, now: Date = Date()) -> DeviceSyncRequest? {
        guard let scope, !busy, active == nil, !isPaused(for: scope) else { return nil }
        let pending = pendingDevice(for: scope)
        // A system restore may resume an existing task in the background, never start a new scan.
        guard foreground || (restoredDevice != nil && restoredDevice == pending) else { return nil }
        if let restoredDevice, restoredDevice != pending { return nil }
        let remembered = device(for: scope)
        guard let id = pending ?? (remembered?.automaticSyncEnabled == true ? remembered?.id : nil) else { return nil }
        if let last = attemptedAt[key(scope)], now.timeIntervalSince(last) < cooldown { return nil }
        return claim(scope: scope, deviceID: id, reason: pending == nil ? .automatic : .recovery, now: now)
    }

    func claimManual(for scope: RecordScope, deviceID: UUID, now: Date = Date()) -> DeviceSyncRequest? {
        guard active == nil else { return nil }
        // A one-off manual sync does not silently re-enable a paused automatic preference.
        return claim(scope: scope, deviceID: deviceID, reason: .manual, now: now)
    }

    private func claim(scope: RecordScope, deviceID: UUID, reason: DeviceSyncRequest.Reason,
                       now: Date) -> DeviceSyncRequest {
        let request = DeviceSyncRequest(scope: scope, deviceID: deviceID, reason: reason)
        active = request
        attemptedAt[key(scope)] = now
        defaults.set(deviceID.uuidString, forKey: key(scope) + ".pending")
        return request
    }

    func finish(_ request: DeviceSyncRequest, result: DeviceSyncResult?, now: Date = Date()) {
        guard active?.token == request.token else { return }
        active = nil
        if result?.checked == true, var device = device(for: request.scope), device.id == request.deviceID {
            device.lastCheckedAt = now
            save(device, for: request.scope)
        }
        if result?.complete == true || isPaused(for: request.scope) { clearPending(for: request.scope) }
    }
}

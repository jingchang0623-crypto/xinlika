import XCTest
@testable import Shennao

@MainActor
final class DeviceSyncTests: XCTestCase {
    private let config = AppConfig(apiBase: "https://api.test", supabaseURL: "https://auth.test", supabaseAnonKey: "public")
    private func scope(_ email: String = "alice@test.com", org: String = "org") -> RecordScope {
        RecordScope(orgId: org, email: email, config: config)
    }
    private func isolated(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "DeviceSyncTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }
    private func claim(_ c: DeviceSyncCoordinator, _ s: RecordScope, at: TimeInterval = 1000) -> DeviceSyncRequest? {
        c.claimAutomatic(for: s, foreground: true, busy: false, now: Date(timeIntervalSince1970: at))
    }

    func testSuccessfulTaskClearsIntentButNextVisitChecksRememberedDevice() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            c.remember(id: id, name: "My recorder", for: s)
            let first = try XCTUnwrap(claim(c, s))
            c.finish(first, result: DeviceSyncResult(complete: true, checked: true), now: Date(timeIntervalSince1970: 1001))
            XCTAssertNil(c.pendingDevice(for: s))
            XCTAssertEqual(c.device(for: s)?.id, id)
            XCTAssertEqual(c.device(for: s)?.lastCheckedAt, Date(timeIntervalSince1970: 1001))
            XCTAssertNil(claim(c, s, at: 1059))
            XCTAssertEqual(claim(c, s, at: 1060)?.reason, .automatic)
        }
    }

    func testPreferenceSurvivesRecreationWithoutPromotingUnknownDevices() {
        isolated { defaults in
            let s = scope(), id = UUID()
            DeviceSyncCoordinator(defaults: defaults).remember(id: id, name: "CB08", for: s)
            let reopened = DeviceSyncCoordinator(defaults: defaults)
            XCTAssertEqual(claim(reopened, s)?.deviceID, id)
            XCTAssertNil(DeviceSyncCoordinator(defaults: defaults).device(for: scope("bob@test.com")))
        }
    }

    func testPauseDuringWorkSurvivesFinishRelaunchAndForeground() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope()
            c.remember(id: UUID(), name: "CB08", for: s)
            let request = try XCTUnwrap(claim(c, s))
            c.pause(for: s)
            c.finish(request, result: nil)
            let reopened = DeviceSyncCoordinator(defaults: defaults)
            XCTAssertTrue(reopened.isPaused(for: s))
            XCTAssertNil(reopened.pendingDevice(for: s))
            XCTAssertNil(claim(reopened, s, at: 9000))
            reopened.resume(for: s)
            XCTAssertNotNil(claim(reopened, s, at: 9000))
        }
    }

    func testManualSyncDoesNotReenablePausedAutomaticSync() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            c.remember(id: id, name: "CB08", for: s)
            c.pause(for: s)
            let request = try XCTUnwrap(c.claimManual(for: s, deviceID: id))
            c.finish(request, result: DeviceSyncResult(complete: true, checked: true))
            XCTAssertTrue(c.isPaused(for: s))
            XCTAssertNil(c.claimAutomatic(for: s, foreground: true, busy: false))
        }
    }

    func testRepeatedForegroundTriggersHaveOneActiveRequest() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope()
            c.remember(id: UUID(), name: "CB08", for: s)
            _ = try XCTUnwrap(claim(c, s))
            for _ in 0..<10 { XCTAssertNil(claim(c, s, at: 2000)) }
            XCTAssertNil(c.claimManual(for: s, deviceID: UUID()))
        }
    }

    func testFailureIsBoundedAndNextAttemptRecoversSameDevice() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            c.remember(id: id, name: "CB08", for: s)
            let first = try XCTUnwrap(claim(c, s))
            c.finish(first, result: nil)
            XCTAssertNil(c.device(for: s)?.lastCheckedAt)
            XCTAssertNil(claim(c, s, at: 1001))
            let next = try XCTUnwrap(claim(c, s, at: 1061))
            XCTAssertEqual(next.reason, .recovery)
            XCTAssertEqual(next.deviceID, id)
        }
    }

    func testIncompleteOrRecordingFileKeepsRecoveryIntent() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            c.remember(id: id, name: "CB08", for: s)
            let first = try XCTUnwrap(claim(c, s))
            c.finish(first, result: DeviceSyncResult(complete: false, checked: true))
            XCTAssertEqual(c.pendingDevice(for: s), id)
            XCTAssertNotNil(c.device(for: s)?.lastCheckedAt)
            XCTAssertEqual(claim(c, s, at: 1061)?.reason, .recovery)
        }
    }

    func testPendingTaskTakesPriorityOverPreferredDeviceAfterRestart() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), pending = UUID()
            c.remember(id: UUID(), name: "Preferred", for: s)
            _ = try XCTUnwrap(c.claimManual(for: s, deviceID: pending))
            let reopened = DeviceSyncCoordinator(defaults: defaults)
            XCTAssertEqual(claim(reopened, s)?.deviceID, pending)
        }
    }

    func testNoNewTaskWithoutSessionForegroundOrWhenBusy() {
        isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope()
            c.remember(id: UUID(), name: "CB08", for: s)
            XCTAssertNil(c.claimAutomatic(for: nil, foreground: true, busy: false))
            XCTAssertNil(c.claimAutomatic(for: s, foreground: false, busy: false))
            XCTAssertNil(c.claimAutomatic(for: s, foreground: true, busy: true))
            XCTAssertNil(c.claimAutomatic(for: scope("unknown@test.com"), foreground: true, busy: false))
        }
    }

    func testRestorationOnlyResumesMatchingPendingTaskEvenInBackground() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            c.remember(id: id, name: "CB08", for: s)
            XCTAssertNil(c.claimAutomatic(for: s, foreground: false, busy: false, restoredDevice: id))
            _ = try XCTUnwrap(claim(c, s))
            let reopened = DeviceSyncCoordinator(defaults: defaults)
            XCTAssertNil(reopened.claimAutomatic(for: s, foreground: false, busy: false, restoredDevice: UUID()))
            XCTAssertEqual(reopened.claimAutomatic(for: s, foreground: false, busy: false, restoredDevice: id)?.reason, .recovery)
        }
    }

    func testSettingsAndPendingIntentsAreIsolatedByAccountOrganizationAndEnvironment() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope()
            c.remember(id: UUID(), name: "Private", for: s)
            _ = try XCTUnwrap(claim(c, s))
            var otherConfig = config; otherConfig.apiBase = "https://staging.test"
            let otherEnvironment = RecordScope(orgId: "org", email: "alice@test.com", config: otherConfig)
            for other in [scope("bob@test.com"), scope(org: "other-org"), otherEnvironment] {
                XCTAssertNil(c.device(for: other)); XCTAssertNil(c.pendingDevice(for: other))
            }
            c.pause(for: scope("bob@test.com"))
            XCTAssertFalse(c.isPaused(for: s))
        }
    }

    func testLateFinishCannotEndANewerRequest() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope()
            c.remember(id: UUID(), name: "CB08", for: s)
            let old = try XCTUnwrap(claim(c, s))
            c.finish(old, result: nil)
            let current = try XCTUnwrap(claim(c, s, at: 2000))
            c.finish(old, result: DeviceSyncResult(complete: true, checked: true))
            XCTAssertEqual(c.active?.token, current.token)
            XCTAssertEqual(c.pendingDevice(for: s), current.deviceID)
        }
    }

    func testChoosingAnotherDeviceExplicitlyResetsPauseAndCheckDate() {
        isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), new = UUID()
            c.remember(id: UUID(), name: "Old", for: s); c.pause(for: s)
            c.remember(id: new, name: "New", for: s)
            XCTAssertFalse(c.isPaused(for: s))
            XCTAssertNil(c.device(for: s)?.lastCheckedAt)
            XCTAssertEqual(claim(c, s)?.deviceID, new)
        }
    }

    func testLegacyIntentRequiresMatchingAccountOrganizationAndUnfinishedLocalTask() {
        isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            let legacyKey = "syncIntent." + s.ownerKey
            defaults.set(id.uuidString, forKey: legacyKey)
            c.migrateLegacyIntent(for: s, records: [])
            XCTAssertNil(c.pendingDevice(for: s))
            func item(_ owner: RecordScope, state: LedgerState = .paused) -> LedgerItem {
                LedgerItem(id: "legacy", orgId: owner.orgId, deviceId: id.uuidString,
                           fileBase: "record", title: "record", durationSec: 10, expectedBytes: 100,
                           receivedBytes: 50, localFilename: "record.ogg", contentHash: "",
                           state: state, updatedAt: Date(), ownerKey: owner.ownerKey)
            }
            for invalid in [item(scope(org: "other")), item(scope("bob@test.com")), item(s, state: .ready)] {
                c.migrateLegacyIntent(for: s, records: [invalid])
                XCTAssertNil(c.pendingDevice(for: s))
            }
            c.migrateLegacyIntent(for: s, records: [item(s)])
            XCTAssertEqual(c.pendingDevice(for: s), id)
            XCTAssertNil(defaults.string(forKey: legacyKey))
            XCTAssertNil(c.device(for: s), "恢复旧任务不能擅自授权今后自动同步")
        }
    }

    func testDisabledPreferenceDoesNotStartNewWorkButPreservesExplicitPendingTask() throws {
        try isolated { defaults in
            let c = DeviceSyncCoordinator(defaults: defaults), s = scope(), id = UUID()
            c.save(RememberedDevice(id: id, name: "CB08", automaticSyncEnabled: false), for: s)
            XCTAssertNil(claim(c, s))
            let manual = try XCTUnwrap(c.claimManual(for: s, deviceID: id, now: Date(timeIntervalSince1970: 1000)))
            c.finish(manual, result: nil)
            XCTAssertEqual(claim(c, s, at: 1061)?.reason, .recovery)
        }
    }

    func testInterruptedFilesComeBeforeNewFilesWithoutTrustingClockDates() {
        let s = scope(), id = UUID().uuidString
        let entries = ["note20260906-100000.", "note20000101-000000.", "note20260906-100100."]
            .map { FileEntry(time: 10, size: 100, name: $0, rawName: []) }
        let interrupted = LedgerItem(id: "partial", orgId: s.orgId, deviceId: id,
                                     fileBase: "note20000101-000000", title: "partial", durationSec: 10,
                                     expectedBytes: 100, receivedBytes: 40, localFilename: "partial.ogg",
                                     contentHash: "", state: .paused, updatedAt: Date(), ownerKey: s.ownerKey)
        XCTAssertEqual(DeviceSyncPlan.prioritizeRecovery(entries, records: [interrupted], scope: s, deviceID: id),
                       [entries[1], entries[0], entries[2]])
        XCTAssertEqual(DeviceSyncPlan.prioritizeRecovery(entries, records: [interrupted], scope: scope("bob@test.com"), deviceID: id), entries)
        XCTAssertEqual(DeviceSyncPlan.prioritizeRecovery(entries, records: [interrupted], scope: s, deviceID: UUID().uuidString), entries)
        var changedSize = interrupted; changedSize.expectedBytes = 120
        XCTAssertEqual(DeviceSyncPlan.prioritizeRecovery(entries, records: [changedSize], scope: s, deviceID: id), entries)
    }
    func testImportPreferencePersistsAndIsAccountScoped() {
        isolated { defaults in
            let coordinator = DeviceSyncCoordinator(defaults: defaults), current = scope()
            XCTAssertEqual(coordinator.minimumRecordingSeconds(for: current), 60)
            coordinator.setMinimumRecordingSeconds(0, for: current)
            XCTAssertEqual(DeviceSyncCoordinator(defaults: defaults).minimumRecordingSeconds(for: current), 0)
            XCTAssertEqual(coordinator.minimumRecordingSeconds(for: scope("other@test.com")), 60)
            coordinator.setMinimumRecordingSeconds(-1, for: current)
            XCTAssertEqual(coordinator.minimumRecordingSeconds(for: current), 0)
        }
    }

}

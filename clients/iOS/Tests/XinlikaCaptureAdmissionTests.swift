// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import XCTest
@testable import Xinlika

final class XinlikaCaptureAdmissionTests: XCTestCase {
    private let filename = "note20261025-120000.opus"
    private let device = UUID()
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func reading(_ state: UInt8? = 1, name: String? = "note20261025-120000.opus", seconds: Int? = 20) -> XinlikaCaptureAdmission.Reading {
        .init(state: state, filename: name, seconds: seconds)
    }
    private func adopt(_ store: XinlikaCaptureStore, file: String? = nil) throws -> Bool {
        try store.adoptHardwareRecording(device: device, filename: file ?? filename, source: "live_conversation",
            processing: true, serviceURL: "https://capture.example.com")
    }
    func testRequiresTwoRunningReadingsSameFileAndMonotonicCounter() {
        XCTAssertEqual(XinlikaCaptureAdmission.confirmedFile(first: reading(), second: reading(name: filename.uppercased(), seconds: 21)), filename.uppercased())
        for second in [reading(2), reading(3), reading(nil), reading(name: nil), reading(name: "note20261025-130000.opus"), reading(seconds: nil), reading(seconds: 19), reading(seconds: 20)] {
            XCTAssertNil(XinlikaCaptureAdmission.confirmedFile(first: reading(), second: second))
        }
        XCTAssertNil(XinlikaCaptureAdmission.confirmedFile(first: reading(seconds: nil), second: reading()))
        XCTAssertNil(XinlikaCaptureAdmission.confirmedFile(first: reading(2), second: reading()))
    }
    func testMalformedFilenameNeverEntersLedger() throws {
        let store = try XinlikaCaptureStore(root: root)
        for name in ["", "../bad.opus", "a/b.opus", "a\\b.opus", ".", "a\0.opus", String(repeating: "a", count: 25)] {
            XCTAssertFalse(XinlikaCaptureAdmission.validFilename(name))
            XCTAssertThrowsError(try adopt(store, file: name))
        }
        XCTAssertTrue(store.snapshot().sessions.isEmpty)
    }
    func testIdlePausedUnknownReadOnceWithoutAdmission() async throws {
        for state: UInt8? in [2, 3, nil] {
            var reads = 0
            let name = try await XinlikaCaptureAdmission.confirm(read: {
                reads += 1; return self.reading(state)
            }, settle: { XCTFail("Must not settle a non-recording state") })
            XCTAssertNil(name); XCTAssertEqual(reads, 1)
        }
    }
    func testCancelledAdmissionCannotCreateTaskAfterFirstRead() async {
        var reads = 0
        let task = Task {
            try await XinlikaCaptureAdmission.confirm(read: { reads += 1; return self.reading() }, settle: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 1)
    }
    func testRepeatedReadOnlyDetectionsCreateOneSessionWithoutAnyRecorderMutation() async throws {
        let store = try XinlikaCaptureStore(root: root)
        for _ in 0..<3 {
            var seconds = 30
            let name = try await XinlikaCaptureAdmission.confirm(read: {
                seconds += 1; return self.reading(seconds: seconds)
            }, settle: {})
            XCTAssertNotNil(name)
            _ = try adopt(store, file: name)
        }
        XCTAssertEqual(store.snapshot().sessions.count, 1)
        XCTAssertEqual(store.snapshot().outbox.count, 1)
    }
    func testStableObservationCreatesOneTaskAndRetainsCaptureSettings() throws {
        let store = try XinlikaCaptureStore(root: root)
        XCTAssertTrue(try adopt(store))
        XCTAssertFalse(try adopt(store, file: filename.uppercased()))
        let session = try XCTUnwrap(store.active())
        XCTAssertEqual(store.snapshot().sessions.count, 1)
        XCTAssertEqual(session.captureOrigin, "hardware")
        XCTAssertEqual(session.sourceKind, "live_conversation")
        XCTAssertEqual(session.serviceURL, "https://capture.example.com")
        XCTAssertEqual(session.status, "waiting_audio")
        XCTAssertEqual(session.automaticReference, true)
        XCTAssertEqual(session.gaps, 1)
        XCTAssertTrue(session.streams.isEmpty) // No claim of received audio before the first frame.
    }
    func testConcurrentDetectionsDeduplicateAtomically() throws {
        let store = try XinlikaCaptureStore(root: root)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in _ = try? self.adopt(store) }
        XCTAssertEqual(store.snapshot().sessions.count, 1)
        XCTAssertEqual(store.snapshot().outbox.count, 1)
    }
    func testAnotherRunningTaskCannotBeReplacedOrMerged() throws {
        let store = try XinlikaCaptureStore(root: root)
        XCTAssertTrue(try adopt(store))
        XCTAssertThrowsError(try adopt(store, file: "note20261025-130000.opus"))
        XCTAssertEqual(store.active()?.cardFile, filename)
        XCTAssertEqual(store.snapshot().sessions.count, 1)
    }
    func testFirstAudioSaveAndRelaunchKeepOneHardwareTask() throws {
        var store: XinlikaCaptureStore? = try XinlikaCaptureStore(root: root)
        XCTAssertTrue(try adopt(store!))
        let id = store!.active()!.id
        store!.receive(.init(connectionID: UUID(), source: "AE22", frame: .init(seq: 1, data: [1, 1] + Array(repeating: 7, count: 80))))
        XCTAssertEqual(store!.active()?.status, "recording")
        XCTAssertEqual(store!.active()?.streams.first?.received, 80)
        try store!.finish(saved: true)
        store = nil
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertFalse(try adopt(reopened))
        XCTAssertEqual(reopened.active()?.id, id)
        XCTAssertEqual(reopened.active()?.captureOrigin, "hardware")
        XCTAssertEqual(reopened.active()?.status, "completed")
        XCTAssertTrue(try adopt(reopened, file: "note20261025-130000.opus"))
        XCTAssertEqual(reopened.snapshot().sessions.count, 2)
        XCTAssertNotEqual(reopened.active()?.id, id)
    }
    func testAppAdmissionKeepsAppOriginAndDoesNotAllowDuplicateTask() throws {
        let store = try XinlikaCaptureStore(root: root)
        try store.begin(device: device, source: "background_playback", processing: false)
        try store.ownedFile(filename)
        XCTAssertEqual(store.active()?.captureOrigin, "app")
        XCTAssertFalse(try adopt(store))
        XCTAssertFalse(store.active()!.processing)
        XCTAssertEqual(store.active()?.sourceKind, "background_playback")
    }
    func testLegacyLedgerWithoutOriginStillLoads() throws {
        var store: XinlikaCaptureStore? = try XinlikaCaptureStore(root: root)
        try store!.begin(device: device, source: "unknown", processing: true)
        try store!.ownedFile(filename); try store!.finish(saved: true)
        store = nil
        let ledger = root.appendingPathComponent("capture.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        var sessions = obj["sessions"] as! [[String: Any]]
        sessions[0].removeValue(forKey: "captureOrigin"); obj["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: obj).write(to: ledger)
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertNil(reopened.active()?.captureOrigin)
        XCTAssertFalse(try adopt(reopened))
    }
    func testPreferencesRestoreSelectedDeviceSourceAndOptOut() {
        let suite = "XinlikaCaptureTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = XinlikaCapturePreferences.load(from: defaults)
        XCTAssertNil(preferences.deviceID)
        preferences.deviceID = device; preferences.deviceName = "CB08"
        preferences.source = "background_playback"; preferences.processing = false; preferences.automaticHardwareCapture = false
        preferences.save(to: defaults)
        XCTAssertEqual(XinlikaCapturePreferences.load(from: defaults), preferences)
    }
    func testAdoptedFileUsesVendorKeyResponsesWithConnectionAndIdentityGuards() {
        let handshake = RecorderButtonHandshake(mode: .vendor), connection = UUID()
        handshake.connected(connection)
        handshake.adoptConfirmedRecording(filename, at: 100)
        let save = Proto.Frame(seq: 0, data: [3, 3])
        XCTAssertNil(handshake.response(connection: UUID(), source: "AE23", frame: save, at: 101))
        XCTAssertNil(handshake.response(connection: connection, source: "AE22", frame: save, at: 101))
        handshake.update(state: 1, filename: "other.opus", at: 101)
        XCTAssertNil(handshake.response(connection: connection, source: "AE23", frame: save, at: 101))
        handshake.update(state: 1, filename: filename, at: 102)
        let response = handshake.response(connection: connection, source: "AE23", frame: save, at: 102)
        XCTAssertEqual(response?.type, 3); XCTAssertEqual(response?.command, 4); XCTAssertEqual(response?.result, 1)
        XCTAssertNil(handshake.response(connection: connection, source: "AE23", frame: save, at: 102))
    }
    func testSelectedIdleCardCanGrantPhysicalStartButCannotSaveAnUnadmittedOldFile() {
        let handshake = RecorderButtonHandshake(mode: .vendor), connection = UUID()
        handshake.connected(connection); handshake.prepareSelectedIdle(at: 100)
        XCTAssertNil(handshake.response(connection: connection, source: "AE23", frame: .init(seq: 0, data: [3, 3]), at: 101))
        let start = handshake.response(connection: connection, source: "AE23", frame: .init(seq: 0, data: [3, 1]), at: 101)
        XCTAssertEqual(start?.type, 3); XCTAssertEqual(start?.command, 2); XCTAssertEqual(start?.result, 1)
        XCTAssertNil(handshake.response(connection: connection, source: "AE23", frame: .init(seq: 0, data: [3, 1]), at: 101))
    }
    func testAppStartReservationPreventsSimultaneousPhysicalStartGrant() {
        let handshake = RecorderButtonHandshake(mode: .vendor), connection = UUID()
        handshake.connected(connection); handshake.armFromIdle(baselineNames: [], at: 100)
        handshake.reserveAppStart()
        XCTAssertNil(handshake.response(connection: connection, source: "AE23", frame: .init(seq: 0, data: [3, 1]), at: 101))
        handshake.claimAppCreatedFile(filename)
        handshake.update(state: 1, filename: filename, at: 102)
        XCTAssertEqual(handshake.response(connection: connection, source: "AE23", frame: .init(seq: 0, data: [3, 3]), at: 102)?.command, 4)
    }
}

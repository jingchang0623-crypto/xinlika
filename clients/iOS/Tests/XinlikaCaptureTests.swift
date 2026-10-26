// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import XCTest
@testable import Xinlika

final class XinlikaCaptureTests: XCTestCase {
    func testDiscoveredSegmentOutboxIsCanonicalOrderedAndSurvivesRestart() throws {
        var s: XinlikaCaptureStore? = try store()
        try s!.bindLegacyUploads(to: "https://cloud.example.com"); try s!.finish(saved: true)
        let id = try XCTUnwrap(s!.active()?.id); s = nil
        let ledger = root.appendingPathComponent("capture.json")
        var state = try JSONDecoder().decode(XinlikaCaptureStore.State.self, from: Data(contentsOf: ledger))
        state.sessions[0].startedAt = "2026-10-21T18:00:00.000Z"
        state.sessions[0].endedAt = "2026-10-21T23:00:00.000Z"
        try JSONEncoder().encode(state).write(to: ledger)
        s = try XinlikaCaptureStore(root: root)
        let before = s!.snapshot().outbox.count, raw = Data(repeating: 7, count: 12000)
        let file = "note20261021-210001.opus"
        try s!.enqueueSegment(raw, filename: file, previous: "note20261021-180000.opus", previousHash: String(repeating: "a", count: 64), sessionID: id)
        let queued = Array(s!.snapshot().outbox.dropFirst(before))
        XCTAssertEqual(queued.count, 3)
        let messages = try queued.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent($0.file))) as? [String: Any]) }
        XCTAssertEqual(messages.compactMap { $0["kind"] as? String }, ["finish", "reference_chunk", "reference_complete"])
        let child = try XCTUnwrap(messages[0]["session"] as? [String: Any])
        XCTAssertEqual(child["id"] as? String, CardSegmentDiscovery.id(root: id, filename: file))
        XCTAssertEqual(child["started_at"] as? String, "2026-10-21T21:00:01.000Z")
        try s!.enqueueSegment(raw, filename: file, previous: "note20261021-180000.opus", previousHash: String(repeating: "a", count: 64), sessionID: id)
        XCTAssertEqual(s!.snapshot().outbox.count, before + 3)
        try s!.completeDiscovery(id); s = nil
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertEqual(reopened.active()?.recoveredSegments?.count, 1)
        XCTAssertEqual(reopened.active()?.discoveryComplete, true)
        XCTAssertTrue(reopened.snapshot().outbox.suffix(3).allSatisfy { $0.serviceURL == "https://cloud.example.com" && $0.sessionID == id })
    }
    func testCloudKnownSegmentDoesNotQueueAudioAgain() throws {
        let s = try store(); try s.finish(saved: true); let id = try XCTUnwrap(s.active()?.id)
        let count = s.snapshot().outbox.count
        let known = XinlikaCaptureStore.RecoveredSegment(filename: "note20261021-210001.opus", bytes: 21602000, sha256: String(repeating: "a", count: 64), startedAt: "2026-10-21T21:00:01.000Z")
        try s.retainCloudSegment(known, sessionID: id); try s.retainCloudSegment(known, sessionID: id)
        XCTAssertEqual(s.snapshot().outbox.count, count)
        XCTAssertEqual(s.active()?.recoveredSegments?.count, 1)
    }
    func testCloudSwitchKeepsHeldLegacyMessagesBoundToOriginalService() throws {
        var s: XinlikaCaptureStore? = try store()
        audio(s!, connection: UUID(), count: 80); try s!.finish(saved: true)
        let old = try XCTUnwrap(s!.nextUpload())
        let bytes = try Data(contentsOf: root.appendingPathComponent(old.file))
        try s!.acknowledge(old.id, status: "blocked")
        try s!.bindLegacyUploads(to: "http://192.168.0.114:18777")
        try s!.begin(device: UUID(), source: "unknown", processing: true, serviceURL: "https://xinlika.apps.zaowuyun.com")
        try s!.ownedFile("note20261021-190000.opus")
        audio(s!, connection: UUID(), count: 80); try s!.finish(saved: true)
        let cloud = try XCTUnwrap(s!.nextUpload(serviceURL: "https://xinlika.apps.zaowuyun.com"))
        XCTAssertNotEqual(cloud.sessionID, old.sessionID)
        try s!.acknowledge(old.id, status: "pending")
        XCTAssertEqual(s!.nextUpload(serviceURL: "https://xinlika.apps.zaowuyun.com")?.id, cloud.id)
        XCTAssertEqual(s!.nextUpload(serviceURL: "http://192.168.0.114:18777")?.id, old.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(old.file)), bytes)
        s = nil
        let reopened = try XinlikaCaptureStore(root: root)
        try reopened.bindLegacyUploads(to: "https://xinlika.apps.zaowuyun.com")
        XCTAssertEqual(reopened.nextUpload(serviceURL: "http://192.168.0.114:18777")?.id, old.id)
    }
    func testCurrentServiceCountsDoNotIncludeHeldLegacySession() {
        let old = "http://old.example.com", cloud = "https://xinlika.apps.zaowuyun.com"
        let state = XinlikaCaptureStore.State(outbox: [
            .init(id: "old1", file: "a", sessionID: "old", status: "blocked", serviceURL: old),
            .init(id: "old2", file: "b", sessionID: "old", status: "pending", serviceURL: old),
            .init(id: "new", file: "c", sessionID: "new", status: "pending", serviceURL: cloud)])
        XCTAssertEqual(state.counts(for: cloud).pending, 1)
        XCTAssertEqual(state.counts(for: cloud).held, 0)
        XCTAssertEqual(state.counts(for: old).held, 2)
        XCTAssertEqual(state.historicalCount(excluding: cloud), 2)
        XCTAssertEqual(state.outbox.count, 3)
    }
    func testSavedReferenceRetrySurvivesRelaunchAndDoesNotFollowServerSwitch() throws {
        var s: XinlikaCaptureStore? = try store()
        try s!.bindLegacyUploads(to: "https://old.example.com")
        audio(s!, connection: UUID(), count: 80); try s!.finish(saved: true)
        let now = Date(), id = try XCTUnwrap(s!.active()?.id)
        XCTAssertEqual(s!.nextReference(serviceURL: "https://old.example.com", now: now)?.id, id)
        XCTAssertNil(s!.nextReference(serviceURL: "https://new.example.com", now: now))
        try s!.referenceAttempt(id, now: now)
        XCTAssertNil(s!.nextReference(serviceURL: "https://old.example.com", now: now.addingTimeInterval(14)))
        s = nil
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertEqual(reopened.nextReference(serviceURL: "https://old.example.com", now: now.addingTimeInterval(15))?.id, id)
        XCTAssertEqual(reopened.active()?.referenceAttempts, 1)
        try reopened.referenceAttempt(id, now: now.addingTimeInterval(15))
        XCTAssertNil(reopened.nextReference(serviceURL: "https://old.example.com", now: now.addingTimeInterval(44)))
        XCTAssertNotNil(reopened.nextReference(serviceURL: "https://old.example.com", now: now.addingTimeInterval(45)))
    }
    func testOlderSavedReferenceCanFinishAfterANewerRecordingWithoutStealingIdentity() throws {
        let s = try store(); try s.bindLegacyUploads(to: "https://old.example.com")
        audio(s, connection: UUID(), count: 80); try s.finish(saved: true)
        let saved = try XCTUnwrap(s.active())
        let count = s.snapshot().outbox.count
        try s.finish(saved: true)
        XCTAssertEqual(s.snapshot().outbox.count, count) // Save is idempotent.
        try s.begin(device: UUID(), source: "unknown", processing: true, serviceURL: "https://old.example.com")
        try s.ownedFile("note20261021-190000.opus"); try s.finish(saved: true)
        XCTAssertThrowsError(try s.enqueueReference(Data(repeating: 1, count: 80), expected: 80,
            filename: saved.cardFile, endCode: 0, sessionID: "unknown"))
        try s.enqueueReference(Data(repeating: 1, count: 80), expected: 80, filename: saved.cardFile, endCode: 0, sessionID: saved.id)
        let after = s.snapshot().outbox.count
        try s.enqueueReference(Data(repeating: 1, count: 80), expected: 80, filename: saved.cardFile, endCode: 0, sessionID: saved.id)
        XCTAssertEqual(s.snapshot().outbox.count, after)
        XCTAssertEqual(s.snapshot().sessions.first?.referenceQueued, true)
        XCTAssertNil(s.active()?.referenceQueued)
        XCTAssertEqual(s.snapshot().outbox.suffix(2).map(\.sessionID), [saved.id, saved.id])
    }
    func testWatchdogDetectsMissingAudioOnceAndRecoveryStartsANewStream() throws {
        let s = try store(), connection = UUID()
        s.receive(BLEFrameObservation(connectionID: connection, source: "AE22",
            frame: Proto.Frame(seq: 1, data: [1, 1] + [UInt8](repeating: 42, count: 80)), uptime: 10))
        XCTAssertFalse(try s.detectStall(uptime: 19))
        XCTAssertTrue(try s.detectStall(uptime: 20))
        XCTAssertFalse(try s.detectStall(uptime: 30))
        try s.gap("bluetooth_disconnect_unresolved")
        XCTAssertEqual(s.active()?.gaps, 1)
        try s.ownedFile("note20261021-180000.opus", waiting: true)
        s.receive(BLEFrameObservation(connectionID: connection, source: "AE22",
            frame: Proto.Frame(seq: 2, data: [1, 1] + [UInt8](repeating: 42, count: 80)), uptime: 40))
        XCTAssertEqual(s.active()?.gaps, 1)
        XCTAssertEqual(s.active()?.status, "recording")
        XCTAssertEqual(s.active()?.streams.count, 2)
        XCTAssertTrue(try s.detectStall(uptime: 50))
        XCTAssertEqual(s.active()?.gaps, 2)
    }
    func testFocusCanCloseWhenTransportIsMissingBeforeSave() throws {
        let s = try store()
        audio(s, connection: UUID(), count: 80); try s.toggleFocus()
        audio(s, connection: UUID(), count: 80); try s.gap("disconnect")
        try s.finish(saved: true)
        XCTAssertEqual(s.active()?.status, "completed")
        XCTAssertNil(s.active()?.focus)
        XCTAssertEqual(s.active()?.automaticReference, true)
    }
    func testLegacyCompletedRecordsAreNotSilentlyImported() throws {
        var s: XinlikaCaptureStore? = try store()
        try s!.bindLegacyUploads(to: "https://old.example.com"); try s!.finish(saved: true)
        s = nil
        let file = root.appendingPathComponent("capture.json")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var sessions = try XCTUnwrap(body["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "automaticReference"); body["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertNil(reopened.nextReference(serviceURL: "https://old.example.com"))
    }
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func store(seconds: Int = 60) throws -> XinlikaCaptureStore {
        let s = try XinlikaCaptureStore(root: root)
        try s.begin(device: UUID(), seconds: seconds, source: "unknown", processing: true)
        try s.ownedFile("note20261021-180000.opus")
        return s
    }
    func audio(_ s: XinlikaCaptureStore, connection: UUID, count: Int, time: Date = .now) {
        s.receive(BLEFrameObservation(connectionID: connection, source: "AE22",
            frame: Proto.Frame(seq: 1, data: [1, 1] + [UInt8](repeating: 42, count: count)), receivedAt: time))
    }
    func envelope(_ s: XinlikaCaptureStore, _ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(s.snapshot().outbox[index].file))) as? [String: Any])
    }
    func testSixtySecondSealAndExactTailSurviveRestart() throws {
        var s: XinlikaCaptureStore? = try store()
        let connection = UUID()
        audio(s!, connection: connection, count: 120000)
        audio(s!, connection: connection, count: 80)
        try s!.finish(saved: true)
        XCTAssertEqual(s!.snapshot().outbox.count, 3)
        XCTAssertEqual(try envelope(s!, 0)["end_byte"] as? Int, 120000)
        XCTAssertEqual(try envelope(s!, 1)["start_byte"] as? Int, 120000)
        XCTAssertEqual(try envelope(s!, 1)["end_byte"] as? Int, 120080)
        s = nil
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertEqual(reopened.snapshot().outbox.count, 3)
        XCTAssertEqual(reopened.active()?.status, "completed")
    }
    func testProcessDeathRecoversUnsealedJournalAndRecordsGap() throws {
        var s: XinlikaCaptureStore? = try store()
        audio(s!, connection: UUID(), count: 2040)
        s = nil
        let reopened = try XinlikaCaptureStore(root: root)
        XCTAssertEqual(reopened.active()?.streams.last?.received, 2040)
        XCTAssertEqual(reopened.active()?.gaps, 1)
        XCTAssertEqual(reopened.active()?.status, "interrupted")
        XCTAssertEqual(try envelope(reopened, 0)["end_byte"] as? Int, 2040)
        XCTAssertEqual(try envelope(reopened, 1)["kind"] as? String, "gap")
    }
    func testFocusBoundaryDoesNotChangePhysicalFileAndReferencesBatches() throws {
        let s = try store(), connection = UUID()
        audio(s, connection: connection, count: 2000)
        try s.toggleFocus()
        audio(s, connection: connection, count: 4000)
        try s.toggleFocus()
        XCTAssertEqual(s.active()?.status, "recording")
        XCTAssertEqual(s.active()?.cardFile, "note20261021-180000.opus")
        XCTAssertEqual(try envelope(s, 2)["kind"] as? String, "focus")
        let ranges = try XCTUnwrap(try envelope(s, 2)["ranges"] as? [[String: Any]])
        XCTAssertEqual(ranges[0]["start_byte"] as? Int, 2000)
        XCTAssertEqual(ranges[0]["end_byte"] as? Int, 6000)
    }
    func testDifferentConnectionsNeverJoinPartialCodecPackets() throws {
        let s = try store()
        audio(s, connection: UUID(), count: 81)
        try s.gap("disconnect")
        audio(s, connection: UUID(), count: 400) // Unverified reconnect is quarantined.
        XCTAssertEqual(s.active()?.streams.count, 1)
        try s.ownedFile("note20261021-180000.opus")
        audio(s, connection: UUID(), count: 79)
        try s.finish(saved: true)
        let batches = try s.snapshot().outbox.indices.compactMap { i -> [String: Any]? in
            let row = try envelope(s, i); return row["kind"] as? String == "batch" ? row : nil
        }
        XCTAssertEqual(batches.count, 2)
        guard batches.count == 2 else { return }
        XCTAssertEqual(batches[0]["end_byte"] as? Int, 80)
        XCTAssertEqual(batches[1]["end_byte"] as? Int, 40)
        XCTAssertNotEqual(batches[0]["stream_id"] as? String, batches[1]["stream_id"] as? String)
    }
    func testInvalidBatchLimitAndCorruptLedgerFailClosed() throws {
        XCTAssertThrowsError(try store(seconds: 301))
        try Data("broken".utf8).write(to: root.appendingPathComponent("capture.json"))
        XCTAssertThrowsError(try XinlikaCaptureStore(root: root))
    }
    func testOnlyTrustedConnectionSchemesAreAdmitted() {
        XCTAssertTrue(XinlikaConnection.isAllowed(URL(string: "http://192.168.1.3:18776/v1/mobile/ingest")!))
        XCTAssertFalse(XinlikaConnection.isAllowed(URL(string: "http://example.com")!))
        XCTAssertFalse(XinlikaConnection.isAllowed(URL(string: "https://user:secret@example.com")!))
        XCTAssertTrue(XinlikaConnection.isAllowed(URL(string: "https://processing.example.com")!))
    }
    func testSecondWriterCannotMarkAnActiveReceiverInterrupted() throws {
        let s = try store()
        XCTAssertThrowsError(try XinlikaCaptureStore(root: root))
        XCTAssertEqual(s.active()?.status, "recording")
        XCTAssertEqual(s.active()?.gaps, 0)
    }
    func testConflictedSessionCannotBlockANewRecordingOrReorderItsOwnMessages() throws {
        let s = try store()
        audio(s, connection: UUID(), count: 80); try s.finish(saved: true)
        let old = try XCTUnwrap(s.nextUpload())
        try s.acknowledge(old.id, status: "blocked")
        XCTAssertNil(s.nextUpload()) // Its finish cannot overtake the rejected audio.
        XCTAssertEqual(s.snapshot().heldCount, 2)
        XCTAssertEqual(s.snapshot().pendingCount, 0)
        try s.begin(device: UUID(), source: "unknown", processing: true)
        try s.ownedFile("note20261021-181000.opus")
        audio(s, connection: UUID(), count: 80); try s.finish(saved: true)
        XCTAssertEqual(s.snapshot().heldCount, 2)
        XCTAssertEqual(s.snapshot().pendingCount, 2)
        let next = try XCTUnwrap(s.nextUpload())
        XCTAssertNotEqual(next.sessionID, old.sessionID)
        try s.acknowledge(next.id, status: "accepted")
        XCTAssertEqual(s.nextUpload()?.sessionID, next.sessionID)
    }
    func testFiveMinuteMaximumAndTailAreNeverOversized() throws {
        let s = try store(seconds: 300)
        audio(s, connection: UUID(), count: 640080)
        try s.finish(saved: true)
        XCTAssertEqual(try envelope(s, 0)["end_byte"] as? Int, 600000)
        XCTAssertEqual(try envelope(s, 1)["start_byte"] as? Int, 600000)
        XCTAssertEqual(try envelope(s, 1)["end_byte"] as? Int, 640080)
    }
    func testArrivalSilenceIsAnUnresolvedGapWithoutJoiningStreams() throws {
        let s = try store(), connection = UUID(), now = Date()
        func observed(_ uptime: Double) -> BLEFrameObservation {
            BLEFrameObservation(connectionID: connection, source: "AE22", frame: Proto.Frame(seq: 1, data: [1, 1] + [UInt8](repeating: 42, count: 80)), receivedAt: now.addingTimeInterval(uptime), uptime: uptime)
        }
        s.receive(observed(1)); s.receive(observed(5))
        XCTAssertEqual(s.active()?.streams.count, 2)
        XCTAssertEqual(s.active()?.gaps, 1)
        XCTAssertEqual(try envelope(s, 1)["kind"] as? String, "gap")
    }
    func testReconnectDoesNotCountTheSameMissingIntervalTwice() throws {
        let s = try store()
        s.receive(BLEFrameObservation(connectionID: UUID(), source: "AE22", frame: Proto.Frame(seq: 1, data: [1, 1] + [UInt8](repeating: 42, count: 80)), uptime: 1))
        try s.gap("disconnect"); try s.ownedFile("note20261021-180000.opus")
        s.receive(BLEFrameObservation(connectionID: UUID(), source: "AE22", frame: Proto.Frame(seq: 1, data: [1, 1] + [UInt8](repeating: 42, count: 80)), uptime: 10))
        XCTAssertEqual(s.active()?.gaps, 1)
        XCTAssertEqual(s.active()?.streams.count, 2)
    }
    func testSubscriptionReadbackIsNotMarkedLiveUntilAudioArrives() throws {
        let s = try store()
        audio(s, connection: UUID(), count: 80)
        try s.gap("disconnect")
        try s.ownedFile("note20261021-180000.opus", waiting: true)
        XCTAssertEqual(s.active()?.status, "waiting_audio")
        audio(s, connection: UUID(), count: 80)
        XCTAssertEqual(s.active()?.status, "recording")
    }
    func testFailedLedgerCommitCannotReleaseUncommittedUploads() throws {
        let s = try store()
        try FileManager.default.removeItem(at: root.appendingPathComponent("capture.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("capture.json"), withIntermediateDirectories: true)
        audio(s, connection: UUID(), count: 120000)
        XCTAssertNotNil(s.snapshot().error)
        XCTAssertNil(s.nextUpload())
    }
    func testCardReferenceRequiresSavedIdentityAndQueuesAfterLiveAudio() throws {
        let s = try store()
        let raw = Data(repeating: 42, count: 80)
        XCTAssertThrowsError(try s.enqueueReference(raw, expected: 80, filename: "note20261021-180000.opus", endCode: 0))
        audio(s, connection: UUID(), count: 80); try s.finish(saved: true)
        XCTAssertThrowsError(try s.enqueueReference(raw, expected: 80, filename: "note20261021-180000.opus", endCode: 3))
        try s.enqueueReference(raw, expected: 80, filename: "note20261021-180000.opus", endCode: 0)
        XCTAssertEqual(try envelope(s, 1)["kind"] as? String, "finish")
        XCTAssertEqual(try envelope(s, 2)["kind"] as? String, "reference_chunk")
        XCTAssertEqual(try envelope(s, 3)["kind"] as? String, "reference_complete")
    }
}

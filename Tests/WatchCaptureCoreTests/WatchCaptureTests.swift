import XCTest
#if canImport(Shennao)
@testable import Shennao
#else
@testable import WatchCaptureCore
#endif

final class WatchCaptureTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func archive(_ name: String, recovery: Bool = false, relay: Bool = false) throws -> WatchCaptureArchive {
        try WatchCaptureArchive(root: root.appendingPathComponent(name), recoverDrafts: recovery, allowsCloudEviction: relay)
    }
    private func captured(_ store: WatchCaptureArchive, bytes: Int = 32000) throws -> WatchCaptureArchive.Record {
        let header = try store.begin(bindingID: nil)
        try store.append(Data(repeating: 17, count: bytes), recording: header.id, offsetMilliseconds: 0)
        try store.end(header.id, offset: bytes / 32)
        return try store.record(header.id)
    }
    func testContinuousAudioSplitsWithoutMissingOrDuplicatingSamples() throws {
        let store = try archive("watch")
        let r = try captured(store, bytes: 1_920_000 + 32000)
        XCTAssertEqual(r.segments.map(\.frameCount), [960000, 16000])
        XCTAssertEqual(r.segments.map(\.offsetMilliseconds), [0, 60000])
        XCTAssertTrue(r.complete); XCTAssertEqual(r.seconds, 61)
        for s in r.segments { try WatchCaptureProtocol.validate(Data(contentsOf: store.file(s)), segment: s) }
    }
    func testProcessDeathSealsDraftAndReportsAnInterruption() throws {
        let store = try archive("watch")
        let h = try store.begin(bindingID: nil)
        try store.append(Data(repeating: 23, count: 32000), recording: h.id, offsetMilliseconds: 0)
        let reopened = try archive("watch", recovery: true), r = try reopened.record(h.id)
        XCTAssertTrue(r.complete); XCTAssertEqual(r.seconds, 1)
        XCTAssertEqual(r.events.filter { $0.kind == .interrupted }.count, 1)
        XCTAssertNil(r.draft)
        let twice = try archive("watch", recovery: true)
        XCTAssertEqual(try twice.record(h.id).events.count, r.events.count)
    }
    func testEndMayArriveBeforeAudioButIsNotCompleteUntilAllSegmentsArrive() throws {
        let watch = try archive("watch"), phone = try archive("phone")
        let r = try captured(watch, bytes: 1_920_000 + 32000)
        _ = try phone.receive(WatchEventEnvelope(recording: r.header, event: r.ended!))
        XCTAssertFalse(try phone.record(r.id).complete)
        for s in r.segments.reversed() { _ = try phone.receive(.init(recording: r.header, segment: s), temporaryFile: watch.file(s)) }
        XCTAssertTrue(try phone.record(r.id).complete)
    }
    func testDuplicateReceiveAndAckSurviveRestart() throws {
        let watch = try archive("watch"), phone = try archive("phone"), r = try captured(watch)
        let s = r.segments[0], envelope = WatchFileEnvelope(recording: r.header, segment: r.segments[0])
        let receipt = try phone.receive(envelope, temporaryFile: watch.file(s))
        XCTAssertEqual(try phone.receive(envelope, temporaryFile: watch.file(s)).sha256, receipt.sha256)
        try watch.acknowledge(receipt); try watch.acknowledge(receipt)
        XCTAssertEqual(try archive("phone").record(r.id).segments.count, 1)
        XCTAssertEqual(try archive("watch").record(r.id).receipts.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.file(s).path))
    }
    func testChangedSameIdentityOrSequenceCannotOverwriteOriginal() throws {
        let watch = try archive("watch"), phone = try archive("phone"), r = try captured(watch), s = r.segments[0]
        _ = try phone.receive(.init(recording: r.header, segment: s), temporaryFile: watch.file(s))
        let collision = WatchAudioSegment(id: UUID(), sequence: s.sequence, offsetMilliseconds: s.offsetMilliseconds,
            frameCount: s.frameCount, byteCount: s.byteCount, sha256: s.sha256)
        XCTAssertThrowsError(try phone.receive(.init(recording: r.header, segment: collision), temporaryFile: watch.file(s)))
        XCTAssertEqual(try Data(contentsOf: phone.file(s)), try Data(contentsOf: watch.file(s)))
    }
    func testInvalidAudioDoesNotGetReceiptOrAdmission() throws {
        let watch = try archive("watch"), phone = try archive("phone"), r = try captured(watch), s = r.segments[0]
        let invalid = root.appendingPathComponent("invalid.wav")
        try Data(repeating: 0, count: s.byteCount).write(to: invalid)
        XCTAssertThrowsError(try phone.receive(.init(recording: r.header, segment: s), temporaryFile: invalid))
        XCTAssertTrue(phone.snapshot().recordings.isEmpty)
        XCTAssertThrowsError(try watch.acknowledge(.init(recordingID: r.id, itemID: s.id, sha256: String(repeating: "0", count: 64))))
        XCTAssertTrue(try watch.record(r.id).receipts.isEmpty)
    }
    func testHistoricalUnboundAudioRequiresGrantAndCannotChangeWorkspace() throws {
        let watch = try archive("watch"), r = try captured(watch)
        XCTAssertNil(r.cloudGrant)
        let a = WatchCaptureArchive.CloudGrant(bindingID: String(repeating: "a", count: 64), serviceURL: "https://a.example", sourceKind: "unknown")
        try watch.grant(r.id, a)
        XCTAssertThrowsError(try watch.grant(r.id, .init(bindingID: String(repeating: "b", count: 64), serviceURL: "https://b.example", sourceKind: "unknown")))
        XCTAssertEqual(try archive("watch").record(r.id).cloudGrant, a)
    }
    func testBoundRecordingCannotBeGrantedToAnotherWorkspace() throws {
        let store = try archive("watch"), header = try store.begin(bindingID: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try store.grant(header.id, .init(bindingID: String(repeating: "b", count: 64), serviceURL: "https://b.example", sourceKind: "unknown")))
    }
    func testFocusCanArriveAfterEndAndDuplicateEventCannotChange() throws {
        let watch = try archive("watch"), phone = try archive("phone"), r = try captured(watch)
        _ = try phone.receive(.init(recording: r.header, event: r.ended!))
        let e = WatchCaptureEvent(id: UUID(), kind: .focus, offsetMilliseconds: 100, endMilliseconds: 800, finalSegmentCount: nil, reason: nil)
        let receipt = try phone.receive(.init(recording: r.header, event: e))
        XCTAssertEqual(try phone.receive(.init(recording: r.header, event: e)).sha256, receipt.sha256)
        XCTAssertThrowsError(try phone.receive(.init(recording: r.header,
            event: .init(id: e.id, kind: .focus, offsetMilliseconds: 200, endMilliseconds: 800, finalSegmentCount: nil, reason: nil))))
    }
    func testCorruptedLedgerFailsClosedInsteadOfResettingSavedRecords() throws {
        let store = try archive("watch"); _ = try captured(store)
        try Data("broken".utf8).write(to: store.root.appendingPathComponent("archive.json"))
        XCTAssertThrowsError(try archive("watch"))
    }
    func testProcessDeathClosesPersistedFocusAtSavedAudioBoundary() throws {
        let store = try archive("watch"), h = try store.begin(bindingID: nil)
        _ = try store.toggleFocus(h.id, offset: 200)
        try store.append(Data(repeating: 17, count: 32000), recording: h.id, offsetMilliseconds: 0)
        let r = try archive("watch", recovery: true).record(h.id)
        let focus = try XCTUnwrap(r.events.first { $0.kind == .focus })
        XCTAssertEqual(focus.offsetMilliseconds, 200); XCTAssertEqual(focus.endMilliseconds, 1000)
        XCTAssertNil(r.focusDraft)
    }
    func testUploadPlanWaitsForMissingAudioAndPutsEndLast() throws {
        let watch = try archive("watch"), phone = try archive("phone"), r = try captured(watch, bytes: 1_920_000 + 32000)
        let target = WatchCloudTarget(bindingID: String(repeating: "a", count: 64), serviceURL: "https://a.example", workspaceID: UUID().uuidString)
        _ = try phone.receive(.init(recording: r.header, event: r.ended!))
        try phone.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        _ = try phone.receive(.init(recording: r.header, segment: r.segments[1]), temporaryFile: watch.file(r.segments[1]))
        XCTAssertNil(try WatchUploadPlanner.next(in: phone, target: target))
        _ = try phone.receive(.init(recording: r.header, segment: r.segments[0]), temporaryFile: watch.file(r.segments[0]))
        for s in r.segments {
            let message = try XCTUnwrap(WatchUploadPlanner.next(in: phone, target: target))
            XCTAssertEqual(message.key, s.id.uuidString.lowercased())
            try phone.cloudAccepted(r.id, key: message.key)
        }
        let end = try XCTUnwrap(WatchUploadPlanner.next(in: phone, target: target))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: end.body) as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "ended")
        try phone.cloudAccepted(r.id, key: end.key)
        XCTAssertNil(try WatchUploadPlanner.next(in: phone, target: target))
    }
    func testUploadPlanCannotAdoptUnboundHistoryOrAnotherServerGrant() throws {
        let store = try archive("watch"), r = try captured(store)
        let target = WatchCloudTarget(bindingID: String(repeating: "a", count: 64), serviceURL: "https://a.example", workspaceID: UUID().uuidString)
        XCTAssertNil(try WatchUploadPlanner.next(in: store, target: target))
        try store.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        XCTAssertNotNil(try WatchUploadPlanner.next(in: store, target: target))
        XCTAssertNil(try WatchUploadPlanner.next(in: store, target: .init(bindingID: String(repeating: "b", count: 64), serviceURL: target.serviceURL, workspaceID: target.workspaceID)))
        XCTAssertNil(try WatchUploadPlanner.next(in: store, target: .init(bindingID: target.bindingID, serviceURL: "https://b.example", workspaceID: target.workspaceID)))
    }
    func testUploadReplayIsIdenticalAfterRestartAndBlockedAudioCannotBeOvertaken() throws {
        let store = try archive("watch"), r = try captured(store)
        let target = WatchCloudTarget(bindingID: String(repeating: "a", count: 64), serviceURL: "https://a.example", workspaceID: UUID().uuidString)
        try store.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        let first = try XCTUnwrap(WatchUploadPlanner.next(in: store, target: target))
        XCTAssertEqual(first.body, try WatchUploadPlanner.next(in: archive("watch"), target: target)?.body)
        XCTAssertNil(try WatchUploadPlanner.next(in: store, target: target, blocked: [first.key]))
        XCTAssertThrowsError(try store.cloudAccepted(r.id, key: UUID().uuidString.lowercased()))
    }

    private func storageTarget() -> WatchCloudStorageTarget {
        .init(bindingID: String(repeating: "a", count: 64), serviceURL: "https://a.example", workspaceID: UUID().uuidString, deviceID: UUID().uuidString)
    }
    private func cloudReceipt(_ r: WatchCaptureArchive.Record, target: WatchCloudStorageTarget) -> WatchCloudAudioReceipt {
        let s = r.segments[0]
        return .init(schemaVersion: 1, workspaceID: UUID(uuidString: target.workspaceID)!, deviceID: UUID(uuidString: target.deviceID)!,
            recordingID: r.id, segmentID: s.id, sequence: s.sequence, offsetMilliseconds: s.offsetMilliseconds,
            frameCount: s.frameCount, byteCount: s.byteCount, sha256: s.sha256, verified: true)
    }
    func testVerifiedRelayEvictionKeepsSourceAndIndexAndCanFinishUploadAfterReopen() throws {
        let watch = try archive("watch"), phone = try archive("phone", relay: true), r = try captured(watch)
        let target = storageTarget(), s = r.segments[0], key = s.id.uuidString.lowercased()
        _ = try phone.receive(.init(recording: r.header, segment: s), temporaryFile: watch.file(s))
        _ = try phone.receive(.init(recording: r.header, event: r.ended!))
        try phone.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        let uploadTarget = WatchCloudTarget(bindingID: target.bindingID, serviceURL: target.serviceURL, workspaceID: target.workspaceID)
        let body = try XCTUnwrap(WatchUploadPlanner.next(in: phone, target: uploadTarget))
        let envelope = phone.root.appendingPathComponent(key + ".upload.json")
        try body.body.write(to: envelope); try phone.cloudAccepted(r.id, key: key)
        XCTAssertThrowsError(try phone.removeAcceptedUpload(r.id, key: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        try phone.releasePhoneAudio(cloudReceipt(r, target: target), target: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.file(s).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.file(s).path))
        let reopened = try archive("phone", relay: true), saved = try reopened.record(r.id)
        XCTAssertEqual(try WatchCaptureProtocol.encode(saved.header), try WatchCaptureProtocol.encode(r.header))
        XCTAssertEqual(saved.segments, r.segments); XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.cloudAudioReceipts?.count, 1)
        let end = try XCTUnwrap(WatchUploadPlanner.next(in: reopened, target: uploadTarget))
        XCTAssertEqual(end.key, r.ended!.id.uuidString.lowercased())
        try end.body.write(to: reopened.root.appendingPathComponent(end.key + ".upload.json"))
        try reopened.cloudAccepted(r.id, key: end.key); try reopened.removeAcceptedUpload(r.id, key: end.key)
        XCTAssertNil(try WatchUploadPlanner.next(in: reopened, target: uploadTarget)); XCTAssertEqual(reopened.localStorageBytes(), 0)
    }
    func testUnacceptedOrWrongWorkspaceDeviceAndHashCannotReleasePhoneAudio() throws {
        let watch = try archive("watch"), phone = try archive("phone", relay: true), r = try captured(watch), target = storageTarget()
        let s = r.segments[0]; _ = try phone.receive(.init(recording: r.header, segment: s), temporaryFile: watch.file(s))
        try phone.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        let good = cloudReceipt(r, target: target)
        XCTAssertThrowsError(try phone.releasePhoneAudio(good, target: target))
        try phone.cloudAccepted(r.id, key: s.id.uuidString.lowercased())
        for (key, value) in [("sha256", String(repeating: "0", count: 64) as Any), ("workspace_id", UUID().uuidString),
                             ("device_id", UUID().uuidString), ("session_id", UUID().uuidString), ("segment_id", UUID().uuidString),
                             ("frame_count", s.frameCount + 1), ("verified", false), ("schema_version", 2)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any]); json[key] = value
            let bad = try JSONDecoder().decode(WatchCloudAudioReceipt.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try phone.releasePhoneAudio(bad, target: target))
            XCTAssertTrue(FileManager.default.fileExists(atPath: phone.file(s).path))
        }
        let otherService = WatchCloudStorageTarget(bindingID: target.bindingID, serviceURL: "https://other.example", workspaceID: target.workspaceID, deviceID: target.deviceID)
        XCTAssertThrowsError(try phone.releasePhoneAudio(good, target: otherService))
        XCTAssertNil(try phone.record(r.id).cloudAudioReceipts)
    }
    func testSourceArchiveCannotEvictEvenWithValidCloudEvidence() throws {
        let watch = try archive("watch"), r = try captured(watch), target = storageTarget()
        try watch.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        try watch.cloudAccepted(r.id, key: r.segments[0].id.uuidString.lowercased())
        XCTAssertThrowsError(try watch.releasePhoneAudio(cloudReceipt(r, target: target), target: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.file(r.segments[0]).path))
    }
    func testEvictionIsIdempotentAndDuplicateDeliveryRetainsRecoverableAudio() throws {
        let watch = try archive("watch"), phone = try archive("phone", relay: true), r = try captured(watch), target = storageTarget()
        let s = r.segments[0], envelope = WatchFileEnvelope(recording: r.header, segment: s)
        _ = try phone.receive(envelope, temporaryFile: watch.file(s))
        try phone.grant(r.id, .init(bindingID: target.bindingID, serviceURL: target.serviceURL, sourceKind: "unknown"))
        try phone.cloudAccepted(r.id, key: s.id.uuidString.lowercased())
        let receipt = cloudReceipt(r, target: target)
        try phone.releasePhoneAudio(receipt, target: target); try phone.releasePhoneAudio(receipt, target: target)
        _ = try phone.receive(envelope, temporaryFile: watch.file(s))
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.file(s).path))
        try archive("phone", relay: true).releasePhoneAudio(receipt, target: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.file(s).path))
        XCTAssertEqual(try phone.record(r.id).segments.count, 1)
    }
}

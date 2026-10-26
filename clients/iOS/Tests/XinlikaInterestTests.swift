// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import XCTest
@testable import Xinlika

@MainActor
final class XinlikaInterestTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private let server = "https://example.com"
    private func queue() throws -> XinlikaInterestQueue { try .init(file: root.appendingPathComponent("feedback.json")) }
    private func receipt(_ item: XinlikaInterestQueue.Change) -> HeartballClient.InterestReceipt {
        .init(eventId: item.eventID, interest: item.value, interestVersion: item.interestVersion + 1)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func testOfflineIntentAndUndoSurviveRestartAndKeepOrdering() throws {
        let first = try queue()
        try first.enqueue(eventID: "one", eventVersion: 2, interestVersion: 0, value: "important", server: server)
        try first.enqueue(eventID: "one", eventVersion: 2, interestVersion: 0, value: "neutral", server: server)
        let restored = try queue()
        XCTAssertEqual(restored.changes.map(\.value), ["important", "neutral"])
        XCTAssertEqual(restored.changes.map(\.interestVersion), [0,1])
        XCTAssertEqual(restored.localValue(eventID: "one", eventVersion: 2, version: 0, server: server), "neutral")
        XCTAssertNil(restored.localValue(eventID: "one", eventVersion: 3, version: 0, server: server))
        XCTAssertNil(restored.next(server: "https://another.example.com"))
    }
    func testLostReceiptRetriesSameRequestBeforeSendingUndo() async throws {
        let queue = try queue(); var requests: [String] = []; var committed: [String:HeartballClient.InterestReceipt] = [:]
        try queue.enqueue(eventID: "one", eventVersion: 2, interestVersion: 0, value: "important", server: server)
        let originalID = queue.changes[0].id
        queue.wake(server: server) { item in
            requests.append(item.id)
            if let prior = committed[item.id] { return prior }
            let value = self.receipt(item); committed[item.id] = value
            if item.id == originalID { throw URLError(.networkConnectionLost) }
            return value
        }
        try await until { requests.count == 1 && queue.sendingID == nil }
        try queue.enqueue(eventID: "one", eventVersion: 2, interestVersion: 0, value: "neutral", server: server)
        try await until { queue.changes.allSatisfy { $0.status == "accepted" } }
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[0],requests[1]); XCTAssertNotEqual(requests[1],requests[2])
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(try self.queue().changes.map(\.receiptVersion), [1,2])
        await queue.stop()
    }
    func testConflictBlocksOnlyThatEventAndExplicitRefreshCanResolveIt() async throws {
        let queue = try queue(); var sent: [String] = []
        for id in ["one","two"] { try queue.enqueue(eventID: id, eventVersion: 2, interestVersion: 0, value: "important", server: server) }
        queue.wake(server: server) { item in
            sent.append(item.eventID)
            if item.eventID == "one" { throw NSError(domain: "Heartball", code: 409) }
            return self.receipt(item)
        }
        try await until { queue.changes[0].status == "blocked" && queue.changes[1].status == "accepted" && queue.sendingID == nil }
        XCTAssertEqual(sent,["one","two"])
        XCTAssertNotNil(queue.notice(server: server))
        XCTAssertNotNil(try self.queue().notice(server: server))
        XCTAssertNil(queue.notice(server: "https://other.example.com"))
        XCTAssertNil(queue.localValue(eventID: "one", eventVersion: 2, version: 0, server: server))
        try queue.enqueue(eventID: "one", eventVersion: 3, interestVersion: 7, value: "unimportant", server: server)
        XCTAssertEqual(queue.next(server: server)?.interestVersion,7)
        XCTAssertEqual(queue.next(server: server)?.eventVersion,3)
        await queue.stop()
    }
    func testMalformedOrWrongReceiptCannotAcceptIntent() throws {
        let queue = try queue()
        try queue.enqueue(eventID: "one", eventVersion: 2, interestVersion: 0, value: "important", server: server)
        let item = try XCTUnwrap(queue.next(server: server))
        XCTAssertThrowsError(try queue.acknowledge(item, receipt: .init(eventId: "other", interest: "important", interestVersion: 1)))
        XCTAssertEqual(queue.changes[0].status,"pending")
    }
    func testAcceptedOverlayRemainsUntilServerSnapshotHasCaughtUp() throws {
        let queue = try queue()
        try queue.enqueue(eventID: "one", eventVersion: 2, interestVersion: 0, value: "important", server: server)
        let item = try XCTUnwrap(queue.next(server: server));try queue.acknowledge(item, receipt: receipt(item))
        XCTAssertEqual(queue.localValue(eventID: "one", eventVersion: 2, version: 0, server: server),"important")
        XCTAssertNil(queue.localValue(eventID: "one", eventVersion: 2, version: 1, server: server))
        XCTAssertFalse(queue.pending(eventID: "one", server: server))
    }
}

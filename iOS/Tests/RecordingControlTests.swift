import XCTest
@testable import Shennao

final class RecordingControlTests: XCTestCase {
    private final class Script {
        var steps: [(String, [UInt8]?)]
        var commands: [String] = []
        var failWrite = false
        init(_ steps: [(String, [UInt8]?)]) { self.steps = steps }
        private func consume(_ command: String) -> [UInt8]? {
            commands.append(command)
            guard !steps.isEmpty else { XCTFail("Unexpected command \(command)"); return nil }
            let step = steps.removeFirst()
            XCTAssertEqual(command, step.0)
            return step.1
        }
        func exchange(_ request: UInt8, _ reply: UInt8) async throws -> [UInt8]? {
            XCTAssertEqual(reply, request + 1)
            return consume("3-\(request)")
        }
        func send(_ action: RecorderAction) async throws {
            _ = consume("1-\(action.request)")
            if failWrite { throw BLEError.notConnected }
        }
        func perform(_ action: RecorderAction, attempts: Int = 1) async throws -> RecordingControl.Result {
            try await RecordingControl.perform(action, policy: .init(attempts: attempts, interval: .zero),
                                               send: send, exchange: exchange)
        }
    }

    func testAttachRequiresVerifiedHardwareSameRecordingAndBothSubscriptions() {
        func permits(name: String = "CB08", firmware: String? = "V1.0.0", state: UInt8? = 1,
                     current: String? = "note20261021-180000.opus", quiet: Double = 10,
                     notifications: [String: Bool] = ["AE22": true, "AE23": true]) -> Bool {
            LiveStreamAttachPolicy.permits(recorderName: name, firmware: firmware, state: state,
                ownedFile: "note20261021-180000.opus", currentFile: current, quietSeconds: quiet, notifications: notifications)
        }
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(name: "unrelated recorder"))
        XCTAssertFalse(permits(firmware: nil))
        XCTAssertFalse(permits(firmware: "V2.0.0"))
        XCTAssertFalse(permits(state: 2))
        XCTAssertFalse(permits(state: 3))
        XCTAssertFalse(permits(state: nil))
        XCTAssertFalse(permits(current: nil))
        XCTAssertFalse(permits(current: "note20261021-190000.opus"))
        XCTAssertFalse(permits(quiet: 9.9))
        XCTAssertFalse(permits(notifications: ["AE22": true]))
        XCTAssertFalse(permits(notifications: ["AE22": true, "AE23": false]))
    }
    func testControlFramesUsePhysicallyVerifiedTypeOneCommands() {
        // CRC vectors independently calculated with Python binascii.crc_hqx.
        XCTAssertEqual(RecorderAction.start.frame(sequence: 42), [0x5a, 42, 0x59, 0xde, 2, 0, 1, 0])
        XCTAssertEqual(RecorderAction.save.frame(sequence: 42), [0x5a, 42, 0x1b, 0xfe, 2, 0, 1, 2])
        XCTAssertEqual(RecorderAction.resume.frame(sequence: 42), [0x5a, 42, 0xb1, 0x8c, 3, 0, 1, 3, 0])
    }
    func testThreeHourTimeAndLittleEndianSize() {
        let time = RecorderReading.decodeTime([0x30, 0x2A, 0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(time?.seconds, 10800)
        XCTAssertEqual(time?.bytes, 0x12345678)
        for length in 0..<6 { XCTAssertNil(RecorderReading.decodeTime(Array(repeating: 0, count: length))) }
    }
    func testStartChecksBeforeAndAfterSendingExactlyOnce() async throws {
        let script = Script([("3-19", [2]), ("1-0", nil), ("3-19", [1]), ("3-21", [0, 0, 0, 0, 0, 0])])
        let result = try await script.perform(.start)
        XCTAssertEqual(result.reading.state, .recording)
        XCTAssertNil(result.message)
        XCTAssertFalse(result.saved)
        XCTAssertTrue(script.steps.isEmpty)
    }
    func testAlreadyRecordingNeverStartsAnotherFile() async throws {
        let script = Script([("3-19", [1])])
        let result = try await script.perform(.start)
        XCTAssertEqual(result.reading.state, .recording)
        XCTAssertEqual(script.commands, ["3-19"])
    }
    func testPausedCannotBeOverwrittenByStart() async throws {
        let script = Script([("3-19", [3])])
        let result = try await script.perform(.start)
        XCTAssertNotNil(result.message)
        XCTAssertEqual(script.commands, ["3-19"])
    }
    func testResumePreservesCurrentRecording() async throws {
        let script = Script([("3-19", [3]), ("1-3", nil), ("3-19", [1]), ("3-21", nil)])
        let result = try await script.perform(.resume)
        XCTAssertEqual(result.reading.state, .recording)
        XCTAssertNil(result.message)
        XCTAssertTrue(script.steps.isEmpty)
    }
    func testSaveWorksWithoutAckFromRecordingAndPaused() async throws {
        for state: UInt8 in [1, 3] {
            let script = Script([("3-19", [state]), ("1-2", nil), ("3-19", [2])])
            let result = try await script.perform(.save)
            XCTAssertTrue(result.saved)
            XCTAssertNil(result.message)
            XCTAssertEqual(script.commands.filter { $0.hasPrefix("3-") }, ["3-19", "3-19"])
        }
    }
    func testSaveWhenIdleDoesNotSendOrTriggerImport() async throws {
        let script = Script([("3-19", [2])])
        let result = try await script.perform(.save)
        XCTAssertFalse(result.saved)
        XCTAssertEqual(script.commands, ["3-19"])
    }
    func testUnknownOrMalformedStateNeverSendsMutation() async {
        for body: [UInt8]? in [nil, [], [0], [4], [255]] {
            let script = Script([("3-19", body)])
            do { _ = try await script.perform(.start); XCTFail("Must refuse") }
            catch { XCTAssertEqual(script.commands, ["3-19"]) }
        }
    }
    func testUnchangedStateDoesNotClaimSuccessOrTryLegacyCommands() async throws {
        let script = Script([("3-19", [2]), ("1-0", nil), ("3-19", [2]), ("3-19", [2])])
        let result = try await script.perform(.start, attempts: 2)
        XCTAssertEqual(result.reading.state, .idle)
        XCTAssertEqual(result.message, "录音卡未执行操作，请使用机身按键")
        XCTAssertEqual(script.commands, ["3-19", "1-0", "3-19", "3-19"])
    }
    func testDelayedStartReadbackOnlyRetriesQueries() async throws {
        let script = Script([("3-19", [2]), ("1-0", nil), ("3-19", [2]), ("3-19", [2]), ("3-19", [1]), ("3-21", nil)])
        let result = try await script.perform(.start, attempts: 3)
        XCTAssertEqual(result.reading.state, .recording)
        XCTAssertNil(result.message)
        XCTAssertEqual(script.commands.filter { $0 == "1-0" }.count, 1)
        XCTAssertTrue(script.steps.isEmpty)
    }
    func testDelayedSaveIsConfirmedWithoutSecondSave() async throws {
        let script = Script([("3-19", [1]), ("1-2", nil), ("3-19", [1]), ("3-19", [1]), ("3-19", [2])])
        let result = try await script.perform(.save, attempts: 3)
        XCTAssertTrue(result.saved)
        XCTAssertNil(result.message)
        XCTAssertEqual(script.commands.filter { $0 == "1-2" }.count, 1)
    }
    func testTransientMissingReadbackCanRecoverWithoutRepeatingCommand() async throws {
        let script = Script([("3-19", [1]), ("1-2", nil), ("3-19", nil), ("3-19", [2])])
        let result = try await script.perform(.save, attempts: 2)
        XCTAssertTrue(result.saved)
        XCTAssertEqual(script.commands.filter { $0 == "1-2" }.count, 1)
    }
    func testUnreadablePostStateIsUnconfirmedAndDoesNotRepeatCommand() async {
        let script = Script([("3-19", [2]), ("1-0", nil), ("3-19", nil), ("3-19", nil)])
        do { _ = try await script.perform(.start, attempts: 2); XCTFail("Must not claim success") }
        catch { XCTAssertEqual(error as? RecordingControlError, .unconfirmed) }
        XCTAssertEqual(script.commands, ["3-19", "1-0", "3-19", "3-19"])
    }
    func testWriteErrorNeverRetriesMutation() async {
        let script = Script([("3-19", [2]), ("1-0", nil)])
        script.failWrite = true
        do { _ = try await script.perform(.start); XCTFail("Must not claim success") }
        catch { XCTAssertEqual(error as? RecordingControlError, .unconfirmed) }
        XCTAssertEqual(script.commands, ["3-19", "1-0"])
    }
    func testCancellationBetweenPreflightAndWriteSendsNoCommand() async {
        let task = Task {
            try await RecordingControl.perform(.start, send: { _ in XCTFail("Must not send") }) { request, _ in
                XCTAssertEqual(request, 19)
                withUnsafeCurrentTask { $0?.cancel() }
                return [2]
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled operation must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCancellationAfterWriteNeverRepeatsOrClaimsSuccess() async {
        let task = Task {
            try await RecordingControl.perform(.start, send: { action in
                XCTAssertEqual(action, .start)
                withUnsafeCurrentTask { $0?.cancel() }
            }) { request, _ in
                XCTAssertEqual(request, 19)
                return [2]
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled operation must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testFreshnessExpiresAndRejectsClockReversal() {
        let now = Date()
        let reading = RecorderReading(state: .recording, seconds: 10800, confirmedAt: now)
        XCTAssertTrue(reading.isFresh(at: now.addingTimeInterval(12)))
        XCTAssertFalse(reading.isFresh(at: now.addingTimeInterval(12.1)))
        XCTAssertFalse(reading.isFresh(at: now.addingTimeInterval(-1)))
    }
    func testDiagnosticExcludesAudioFilenamesAndNonControlFields() throws {
        XCTAssertNil(RecordingDiagnosticEvent(phase: "rx", source: "AE22", frame: .init(seq: 1, data: [1, 1, 65, 66])))
        XCTAssertNil(RecordingDiagnosticEvent(phase: "rx", source: "AE23", frame: .init(seq: 1, data: [3, 24, 65, 66])))
        XCTAssertNil(RecordingDiagnosticEvent(phase: "rx", source: "AE22", frame: .init(seq: 1, data: [0, 13, 65, 66])))
        let start = try XCTUnwrap(RecordingDiagnosticEvent(phase: "rx", source: "AE22", frame: .init(seq: 4, data: [1, 0, 65, 66])))
        XCTAssertEqual(start.type, 1)
        XCTAssertEqual(start.command, 0)
        XCTAssertEqual(start.body, [])
        let state = try XCTUnwrap(RecordingDiagnosticEvent(phase: "rx", source: "AE23", frame: .init(seq: 4, data: [3, 20, 1])))
        XCTAssertEqual(state.type, 3)
        XCTAssertEqual(state.body, [1])
    }
    func testLiveAudioIsDiscardedButFileAndControlFramesAreRetained() {
        XCTAssertTrue(RecordingFramePolicy.isLiveAudio(.init(seq: 1, data: [1, 1, 42])))
        for bytes: [UInt8] in [[2, 4, 42], [1, 0, 42], [1, 4, 2], [3, 20, 1]] {
            XCTAssertFalse(RecordingFramePolicy.isLiveAudio(.init(seq: 1, data: bytes)))
        }
    }
    func testReplyRoutingLeavesFileAndUnrelatedFramesForDownload() throws {
        let slot = RecordingReplySlot()
        let token = try slot.begin(command: 20)
        XCTAssertFalse(slot.receive(Proto.Frame(seq: 1, data: [2, 4, 9, 8])))
        XCTAssertFalse(slot.receive(Proto.Frame(seq: 1, data: [3, 22, 1, 0])))
        let state = Proto.Frame(seq: 99, data: [3, 20, 1])
        XCTAssertTrue(slot.receive(state))
        XCTAssertEqual(slot.reply(for: token), state)
        XCTAssertTrue(slot.receive(Proto.Frame(seq: 0, data: [3, 20, 2])))
        XCTAssertEqual(slot.reply(for: token), state)
    }
    func testReplySlotRejectsConcurrentRequestsAndOldCleanupCannotClearNewOne() throws {
        let slot = RecordingReplySlot()
        let first = try slot.begin(command: 20)
        XCTAssertThrowsError(try slot.begin(command: 22))
        slot.end(first)
        let second = try slot.begin(command: 22)
        slot.end(first)
        XCTAssertTrue(slot.receive(Proto.Frame(seq: 1, data: [3, 22, 0, 0, 0, 0, 0, 0])))
        XCTAssertNotNil(slot.reply(for: second))
        XCTAssertNil(slot.reply(for: first))
    }
}

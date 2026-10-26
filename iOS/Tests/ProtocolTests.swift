import XCTest
@testable import Shennao

final class ProtocolTests: XCTestCase {
    func testCRCVector() {
        XCTAssertEqual(Proto.crc16(Array("123456789".utf8)), 0x31C3)
    }

    func testImportRequestIsOneGattWrite() throws {
        let frame = try Proto.buildImportRequest("note20260710-162938.wav")
        XCTAssertEqual(frame.count, 36)
    }

    func testIncompletePacketIsRejectedByLengthRule() {
        XCTAssertFalse(7_200_666 % OggWrap.packetLen == 0)
    }

    func testTimeSyncMatchesReferenceWireFormat() throws {
        // Independent vector: Python struct.pack("<H5B", ...) + binascii.crc_hqx(..., 0).
        // 15:04:05 UTC = 23:04:05 in Shanghai; ordinary integers, not BCD.
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T15:04:05Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let frame = try Proto.buildTimeSync(date, timeZone: zone, seq: 0x2a)
        XCTAssertEqual(frame, [0x5a, 0x2a, 0x5c, 0x8c, 0x09, 0x00, 0x00, 0x00,
                               0xea, 0x07, 0x09, 0x06, 0x17, 0x04, 0x05])
        let decoded = try XCTUnwrap(FrameParser().feed(frame).first)
        XCTAssertEqual(decoded.type, Proto.T.ctrl)
        XCTAssertEqual(decoded.cmd, Proto.CtrlCmd.syncTime)
        XCTAssertEqual(decoded.seq, 0x2a)
    }

    func testTimeSyncUsesLocalDateAcrossYearBoundary() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T20:30:40Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(Array(try Proto.buildTimeSync(date, timeZone: zone).dropFirst(8)),
                       [0xeb, 0x07, 1, 1, 4, 30, 40])
        XCTAssertEqual(Array(try Proto.buildTimeSync(date, timeZone: .gmt).dropFirst(8)),
                       [0xea, 0x07, 12, 31, 20, 30, 40])
    }

    func testTimeSyncUsesTimeZoneRulesAtDate() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let before = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T09:59:59Z"))
        let after = before.addingTimeInterval(1)
        XCTAssertEqual(Array(try Proto.buildTimeSync(before, timeZone: zone).dropFirst(8)),
                       [0xea, 0x07, 3, 8, 1, 59, 59])
        XCTAssertEqual(Array(try Proto.buildTimeSync(after, timeZone: zone).dropFirst(8)),
                       [0xea, 0x07, 3, 8, 3, 0, 0])
    }

    func testTimeSyncPreservesGregorianLeapDay() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2028-02-29T23:59:59Z"))
        XCTAssertEqual(Array(try Proto.buildTimeSync(date, timeZone: .gmt).dropFirst(8)),
                       [0xec, 0x07, 2, 29, 23, 59, 59])
    }

    func testTimeSyncEncodesANewTimestamp() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T15:04:05Z"))
        let first = try Proto.buildTimeSync(date, timeZone: .gmt, seq: 1)
        let later = try Proto.buildTimeSync(date.addingTimeInterval(70), timeZone: .gmt, seq: 2)
        XCTAssertEqual(Array(first.dropFirst(8)), [0xea, 0x07, 9, 6, 15, 4, 5])
        XCTAssertEqual(Array(later.dropFirst(8)), [0xea, 0x07, 9, 6, 15, 5, 15])
    }

    func testTimeSyncRejectsUnrepresentableDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let overflow = try XCTUnwrap(calendar.date(from: DateComponents(year: 65536, month: 1, day: 1)))
        XCTAssertThrowsError(try Proto.buildTimeSync(overflow, timeZone: .gmt))
        XCTAssertThrowsError(try Proto.buildTimeSync(Date(timeIntervalSinceReferenceDate: .infinity)))
    }
}

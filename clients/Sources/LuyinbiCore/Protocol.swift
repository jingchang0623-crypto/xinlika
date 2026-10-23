// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// CB08 录音笔 BLE 协议层。
///
/// 从已验证的 Python 实现移植（importer/protocol.py），行为必须逐字节一致：
/// 自测里保留了同样的标准向量和厂商文档里那条真机成功帧。
public enum Proto {
    public static let magic: UInt8 = 0x5A
    public static let headerLen = 6
    public static let nameFieldLen = 20      // 文件列表里的名字字段，会截断扩展名
    public static let filenameFieldLen = 24  // 下载/删除请求里的名字字段
    public static let entryLen = 28

    // MARK: - UUID
    private static func u16(_ short: UInt16) -> String {
        String(format: "0000%04x-0000-1000-8000-00805f9b34fb", short)
    }
    public static let serviceMain = u16(0xAE20)
    public static let charWrite = u16(0xAE21)   // App → Dev
    public static let charNotify = u16(0xAE22)  // Dev → App 控制/音频/列表/文件
    public static let charKey = u16(0xAE23)     // Dev → App 按键与录音状态

    // MARK: - TYPE / CMD
    public enum T { public static let ctrl: UInt8 = 0, audio: UInt8 = 1, file: UInt8 = 2, key: UInt8 = 3 }

    public enum CtrlCmd {
        public static let syncTime: UInt8 = 0   // App → Dev，无应答
    }

    /// App → device recording controls, physically verified on CB08 V1.0.0.
    /// TYPE=3 start/save requests in the vendor table are ignored by this firmware.
    public enum AudioCmd {
        public static let start: UInt8 = 0, data: UInt8 = 1, stop: UInt8 = 2
        // App→Dev 01 01 from vendor startTranscribe; verified on CB08 V1.0.0.
        // Unlike 01 00 it attaches live notifications to the existing card file.
        public static let attachLive: UInt8 = 1
        public static let pauseResume: UInt8 = 3, status: UInt8 = 4
    }

    public enum FileCmd {
        public static let listReq: UInt8 = 0, listData: UInt8 = 1
        public static let importReq: UInt8 = 2, importBegin: UInt8 = 3
        public static let importData: UInt8 = 4, importEnd: UInt8 = 5
        public static let importAbort: UInt8 = 7
        public static let delOne: UInt8 = 8            // 破坏性
        public static let delOneAck: UInt8 = 13
        public static let importRange: UInt8 = 12
        public static let listDone: UInt8 = 18
        // 故意不定义 delAll(9)：批量删除发出去无法挽回，且旧固件不回应答。
    }

    public enum KeyCmd {
        public static let startReq: UInt8 = 1, startAck: UInt8 = 2
        public static let saveReq: UInt8 = 3, saveAck: UInt8 = 4
        public static let resumeReq: UInt8 = 7, resumeAck: UInt8 = 8
        public static let statusReq: UInt8 = 19, statusAck: UInt8 = 20   // 1录音中 2未录音 3暂停
        public static let timeReq: UInt8 = 21, timeAck: UInt8 = 22
        public static let curNameReq: UInt8 = 23, curNameAck: UInt8 = 24
        public static let gainReq: UInt8 = 25, gainAck: UInt8 = 26
    }

    public static let importEndMeaning: [UInt8: String] =
        [0: "完成", 1: "文件不存在", 2: "offset 过大", 3: "其他原因停止"]

    // MARK: - CRC-16/XMODEM
    /// poly 0x1021, init 0x0000, 不反转, xorout 0x0000
    public static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    // MARK: - 帧
    public struct Frame: Equatable, Sendable {
        public let seq: UInt8
        public let data: [UInt8]
        public var type: UInt8? { data.first }
        public var cmd: UInt8? { data.count >= 2 ? data[1] : nil }   // 只有 TYPE 一字节时按 ACK 处理
        public var body: [UInt8] { data.count > 2 ? Array(data[2...]) : [] }
        public init(seq: UInt8, data: [UInt8]) { self.seq = seq; self.data = data }
    }

    /// CRC 的输入是 LEN 的两个原始字节 + DATA，不含 MAGIC/SEQ/CRC 本身。
    public static func buildFrame(_ type: UInt8, _ cmd: UInt8,
                                  _ params: [UInt8] = [], seq: UInt8 = 0) -> [UInt8] {
        let data = [type, cmd] + params
        let len = UInt16(data.count)
        let lenBytes = [UInt8(len & 0xFF), UInt8(len >> 8)]        // LE
        let crc = crc16(lenBytes + data)
        return [magic, seq, UInt8(crc & 0xFF), UInt8(crc >> 8)] + lenBytes + data
    }

    /// 0-0 校时：公历年份 2B LE，随后月/日/时/分/秒各 1B（普通整数，非 BCD）。
    /// 设备存的是当地墙上时间，没有 UTC 偏移字段；不能发送 Unix 时间戳或固定北京时间。
    /// Payload fields are protocol facts cross-checked with the vendor example.
    public static func buildTimeSync(_ date: Date = Date(), timeZone: TimeZone = .current,
                                     seq: UInt8 = 0) throws -> [UInt8] {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw ProtoError.invalidClockDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        let components = [parts.month, parts.day, parts.hour, parts.minute, parts.second]
        let ranges = [1...12, 1...31, 0...23, 0...59, 0...59]
        guard parts.era == 1, let year = parts.year, year > 0, year <= 65535,
              zip(components, ranges).allSatisfy({ item, range in item.map(range.contains) ?? false }) else {
            throw ProtoError.invalidClockDate
        }
        let payload = [UInt8(year % 256), UInt8(year / 256)] + components.map { UInt8($0!) }
        return buildFrame(T.ctrl, CtrlCmd.syncTime, payload, seq: seq)
    }

    public static func buildImportRequest(_ filename: String, offset: UInt32 = 0,
                                          seq: UInt8 = 0) throws -> [UInt8] {
        let params = try le32(offset) + paddedName(filename)
        let frame = buildFrame(T.file, FileCmd.importReq, params, seq: seq)
        precondition(frame.count == 36, "2-2 帧长必须 36B，须一次 GATT 写入，拆包设备会解析错文件名")
        return frame
    }

    public static func buildImportRange(_ filename: String, start: UInt32, end: UInt32,
                                        seq: UInt8 = 0) throws -> [UInt8] {
        buildFrame(T.file, FileCmd.importRange,
                   try le32(start) + le32(end) + paddedName(filename), seq: seq)
    }

    /// 2-8 删除单个文件。**破坏性且不可逆。**
    ///
    /// 真机实测：厂商文档说参数是「与文件列表相同的 28B 条目」，**那是错的**——设备一律回
    /// 应答码 01 拒绝。实际要的是和下载请求 2-2 完全相同的格式：offset:4B LE + 文件名 24B 补零，
    /// 且文件名必须带完整扩展名。（2026-08-28 在 CB08 / V1.0.0 上逐一试过五种写法。）
    public static func buildDeleteOne(_ filename: String, seq: UInt8 = 0) throws -> [UInt8] {
        buildFrame(T.file, FileCmd.delOne, try le32(0) + paddedName(filename), seq: seq)
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    public enum ProtoError: Error, CustomStringConvertible {
        case filenameTooLong(String)
        case invalidClockDate
        public var description: String {
            switch self {
            case .filenameTooLong(let n): return "文件名超过 \(filenameFieldLen)B: \(n)"
            case .invalidClockDate: return "系统日期超出设备校时协议支持的范围"
            }
        }
    }

    private static func paddedName(_ filename: String) throws -> [UInt8] {
        let bytes = Array(filename.utf8)
        guard bytes.count <= filenameFieldLen else { throw ProtoError.filenameTooLong(filename) }
        return bytes + [UInt8](repeating: 0, count: filenameFieldLen - bytes.count)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// 流式帧重组。一个 notify 可能含半帧，也可能含多帧。
///
/// AE22 与 AE23 必须各用一个实例——两路字节交织会毁掉半帧。
public final class FrameParser {
    /// LEN 合理性上限。没有这道闸，坏帧后重同步会撞上音频数据里的假 0x5A，
    /// 读出一个荒唐的 LEN 而永久等数据——二进制码流里 0x5A 必然出现，不是小概率。
    public static let maxDataLen = 8192
    private static let maxBuf = 64 * 1024

    private var buf: [UInt8] = []
    public private(set) var crcErrors = 0
    public private(set) var resyncs = 0
    public let name: String

    public init(name: String = "") { self.name = name }

    public func feed(_ chunk: [UInt8]) -> [Proto.Frame] {
        buf.append(contentsOf: chunk)
        var out: [Proto.Frame] = []
        while true {
            if buf.isEmpty { return out }
            if buf[0] != Proto.magic {
                guard let idx = buf.firstIndex(of: Proto.magic) else {
                    buf.removeAll(); resyncs += 1; return out
                }
                buf.removeFirst(idx); resyncs += 1
            }
            if buf.count < Proto.headerLen { return out }
            let crc = UInt16(buf[2]) | (UInt16(buf[3]) << 8)
            let length = Int(UInt16(buf[4]) | (UInt16(buf[5]) << 8))
            if length > Self.maxDataLen {
                resyncs += 1; buf.removeFirst(); continue      // 假帧头
            }
            let total = Proto.headerLen + length
            if buf.count < total {
                if buf.count > Self.maxBuf { buf.removeAll() }  // 兜底
                return out
            }
            let data = Array(buf[Proto.headerLen..<total])
            if Proto.crc16(Array(buf[4..<6]) + data) != crc {
                // CRC 不过：可能错位到了假 MAGIC 上，只前进一字节重找，不整帧丢
                crcErrors += 1; buf.removeFirst(); continue
            }
            out.append(Proto.Frame(seq: buf[1], data: data))
            buf.removeFirst(total)
        }
    }
}

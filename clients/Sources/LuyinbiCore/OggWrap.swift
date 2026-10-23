// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// 把设备吐的裸 OPUS 定长包封成 Ogg/Opus。
///
/// CB08 与 QS668 同一种码流：40 字节 = 一个 20ms 帧（config 9，16kHz 宽带）。
/// Ogg 的 granule 走 48kHz 时钟，所以每包推进 960。
public enum OggWrap {
    public static let packetLen = 40
    public static let frameMs = 20
    public static let granulePerPacket: UInt64 = 960     // 20ms @ 48kHz
    private static let crcPoly: UInt32 = 0x04C1_1DB7

    private static let crcTable: [UInt32] = {
        (0..<256).map { value -> UInt32 in
            var reg = UInt32(value) << 24
            for _ in 0..<8 {
                reg = (reg & 0x8000_0000) != 0 ? (reg << 1) ^ crcPoly : reg << 1
            }
            return reg
        }
    }()

    private static func oggCRC(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) & 0xFF) ^ UInt32(byte))]
        }
        return crc
    }

    private static func page(_ payloads: [[UInt8]], granule: UInt64,
                             serial: UInt32, seq: UInt32, flags: UInt8) -> [UInt8] {
        var laces: [UInt8] = []
        for payload in payloads {
            var remaining = payload.count
            while remaining >= 255 { laces.append(255); remaining -= 255 }
            laces.append(UInt8(remaining))
        }
        var header: [UInt8] = Array("OggS".utf8) + [0, flags]
        header += (0..<8).map { UInt8((granule >> ($0 * 8)) & 0xFF) }
        header += (0..<4).map { UInt8((serial >> ($0 * 8)) & 0xFF) }
        header += (0..<4).map { UInt8((seq >> ($0 * 8)) & 0xFF) }
        header += [0, 0, 0, 0]                       // CRC 占位
        header += [UInt8(laces.count)] + laces
        var p = header + payloads.flatMap { $0 }
        let crc = oggCRC(p)
        for i in 0..<4 { p[22 + i] = UInt8((crc >> (i * 8)) & 0xFF) }
        return p
    }

    public enum WrapError: Error { case noCompletePacket }

    /// 裸包 → Ogg/Opus。长度不是 40 的整数倍时截掉尾部残包。
    public static func wrap(_ raw: [UInt8], sampleRate: UInt32 = 16000,
                            tag: String = "CB08") throws -> [UInt8] {
        let usable = raw.count - (raw.count % packetLen)
        guard usable >= packetLen else { throw WrapError.noCompletePacket }
        let packets = stride(from: 0, to: usable, by: packetLen).map {
            Array(raw[$0..<($0 + packetLen)])
        }

        let serial: UInt32 = 0x5153_3638
        var seq: UInt32 = 0
        var pages: [[UInt8]] = []

        var head: [UInt8] = Array("OpusHead".utf8) + [1, 1]
        head += [UInt8(312 & 0xFF), UInt8(312 >> 8)]                 // pre-skip, LE
        head += (0..<4).map { UInt8((sampleRate >> ($0 * 8)) & 0xFF) }
        head += [0, 0, 0]                                            // output gain(2) + mapping(1)
        let tagBytes = Array(tag.utf8)
        var tags: [UInt8] = Array("OpusTags".utf8)
        tags += (0..<4).map { UInt8((UInt32(tagBytes.count) >> ($0 * 8)) & 0xFF) }
        tags += tagBytes + [0, 0, 0, 0]

        pages.append(page([head], granule: 0, serial: serial, seq: seq, flags: 0x02)); seq += 1
        pages.append(page([tags], granule: 0, serial: serial, seq: seq, flags: 0x00)); seq += 1

        var granule: UInt64 = 0
        for start in stride(from: 0, to: packets.count, by: 50) {
            let group = Array(packets[start..<min(start + 50, packets.count)])
            granule += granulePerPacket * UInt64(group.count)
            let last = start + 50 >= packets.count
            pages.append(page(group, granule: granule, serial: serial, seq: seq,
                              flags: last ? 0x04 : 0x00))
            seq += 1
        }
        return pages.flatMap { $0 }
    }

    public static func durationSeconds(rawLength: Int) -> Double {
        Double(rawLength / packetLen * frameMs) / 1000
    }

    public static func looksRaw(_ data: [UInt8]) -> Bool {
        data.count >= packetLen && data.count % packetLen == 0
            && Array(data.prefix(4)) != Array("OggS".utf8)
    }
}

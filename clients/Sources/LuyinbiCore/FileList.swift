// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// 文件列表条目。注意：帧头的 LEN/CRC 是小端，而这里的 time/size 是**大端**。
public struct FileEntry: Equatable {
    public let time: UInt32        // 录音时长，秒
    public let size: UInt32        // 设备内压缩体积，Byte
    public let name: String        // 20B 截断名，扩展名可能不全
    public let rawName: [UInt8]

    public init(time: UInt32, size: UInt32, name: String, rawName: [UInt8]) {
        self.time = time; self.size = size; self.name = name; self.rawName = rawName
    }

    /// 列表字段只有 20B，note20260828-205856.opus 会被截成 note20260828-205856.
    /// 下载和删除都必须用重建出的完整名。长文件优先 .opus——设备转码出的 wav
    /// 走 BLE 会慢一个数量级（1 小时录音 opus 7.2MB vs wav 115MB）。
    public var candidates: [String] {
        let base = name.hasSuffix(".") ? String(name.dropLast()) : name
        var out: [String] = []
        for ext in [".opus", ".wav"] {
            out.append(base.lowercased().hasSuffix(ext) ? base : base + ext)
        }
        out.append(name)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public var base: String { name.hasSuffix(".") ? String(name.dropLast()) : name }
}

public enum FileListDecoder {
    /// body = count:4B BE + N × 28B。count 是本帧条目数，不是文件总数。
    public static func decode(_ body: [UInt8]) -> [FileEntry] {
        guard body.count >= 4 else { return [] }
        let declared = Int(be32(body, 0))
        let available = (body.count - 4) / Proto.entryLen
        let count = min(declared, available)          // 声明数与实际字节不符时以实际为准
        var out: [FileEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let off = 4 + i * Proto.entryLen
            let raw = Array(body[(off + 8)..<(off + 8 + Proto.nameFieldLen)])
            let nameBytes = Array(raw.prefix(while: { $0 != 0 }))
            out.append(FileEntry(
                time: be32(body, off), size: be32(body, off + 4),
                name: String(decoding: nameBytes, as: UTF8.self), rawName: raw))
        }
        return out
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
}

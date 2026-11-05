import Foundation
import AVFoundation
import LuyinbiCore

// 本地归档体检的离线单测。
// 纯命令行工具链没有 XCTest，所以跑成可执行目标：失败即非零退出。
//
// 这套断言要守的东西：体检报告是人决定「重导设备 / 从深脑重下 / 什么都不用做」的唯一依据。
// 分类错一格，人就会去做错的事——最贵的一种是把「iCloud 没下载」当成「丢了」，
// 于是跑去动设备，而那份文件其实在云上好好的。

var passed = 0, failed = 0

func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)\n        得到 \(got)\n        期望 \(want)") }
}

func checkContains(_ name: String, _ text: String, _ needle: String) {
    if text.contains(needle) { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)\n        「\(text)」里没有「\(needle)」") }
}

// MARK: - 造现场

/// 1000 个 40B 定长包 = 40000 字节 = 20 秒。所有用例都以这条"标准录音"为基准。
let packets = 1000
let nominalBytes = packets * OggWrap.packetLen
let nominalSecs = 20
let defaultBase = "note20260801-100000"

// 440 Hz 合成正弦波经系统 afconvert 编码的 20ms / 16kHz 单声道 Opus 帧。
// 按 RFC 6716 §3.2.5 的 code 3 padding 补到 CB08 的 40B 定长；不含真实录音。
// 旧全零夹具的实际包时钟与这里声明的 20ms 不一致。
let syntheticPacket: [UInt8] = [
    0x4b, 0x41, 0x09, 0x3d, 0x1e, 0xce, 0x03, 0x54, 0xdf, 0x9c,
    0x12, 0xd1, 0x48, 0x93, 0x84, 0xab, 0xda, 0x1d, 0x7f, 0xa6,
    0x37, 0x3b, 0x4c, 0x9f, 0x82, 0xff, 0xf3, 0xc9, 0xa6, 0xd5,
    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]
func syntheticAudio(_ count: Int) -> [UInt8] {
    (0..<count).flatMap { _ in syntheticPacket }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("audit-selftest-\(UUID().uuidString)")
var caseNo = 0

/// **每个用例一个独立临时目录。** 共用目录会让上一个用例造的文件把「缺失」这类断言
/// 变成假阳性——CleanupSelfTest 就是踩过这个坑才加的 case 编号，这里照抄。
func makeCase(base: String = defaultBase,
              rawPackets: Int? = packets,
              rawExtraBytes: Int = 0,
              rawPlaceholder: Bool = false,
              oggPackets: Int? = packets,
              oggData: Data? = nil,
              oggPlaceholder: Bool = false) -> (dest: URL, rawDir: URL) {
    caseNo += 1
    let dir = root.appendingPathComponent("case\(caseNo)")
    let dest = dir.appendingPathComponent("导入")
    let rawDir = dest.appendingPathComponent("原始包")
    let fm = FileManager.default
    try! fm.createDirectory(at: rawDir, withIntermediateDirectories: true)

    if let n = rawPackets {
        let bytes = syntheticAudio(n) + [UInt8](repeating: 0, count: rawExtraBytes)
        try! Data(bytes).write(to: rawDir.appendingPathComponent("\(base).opus"))
    }
    if rawPlaceholder {
        // iCloud 老式占位：真名在 POSIX 层根本不存在，只留一个 .<name>.icloud
        try! Data("placeholder".utf8)
            .write(to: rawDir.appendingPathComponent(".\(base).opus.icloud"))
    }

    let oggURL = dest.appendingPathComponent("\(base).ogg")
    if let data = oggData {
        try! data.write(to: oggURL)
    } else if let n = oggPackets {
        let wrapped = try! OggWrap.wrap(syntheticAudio(n))
        try! Data(wrapped).write(to: oggURL)
    }
    if oggPlaceholder {
        try! Data("placeholder".utf8)
            .write(to: dest.appendingPathComponent(".\(base).ogg.icloud"))
    }
    return (dest, rawDir)
}

func audit(base: String = defaultBase,
           bytes: Int = nominalBytes,
           secs: Int = nominalSecs,
           recordedBytes: Int? = nil,
           rawPackets: Int? = packets,
           rawExtraBytes: Int = 0,
           rawPlaceholder: Bool = false,
           oggPackets: Int? = packets,
           oggData: Data? = nil,
           oggPlaceholder: Bool = false) -> ArchiveAudit.Item {
    let (dest, rawDir) = makeCase(base: base, rawPackets: rawPackets,
                                  rawExtraBytes: rawExtraBytes, rawPlaceholder: rawPlaceholder,
                                  oggPackets: oggPackets, oggData: oggData,
                                  oggPlaceholder: oggPlaceholder)
    return ArchiveAudit.audit(base: base, expectedBytes: bytes, expectedSeconds: secs,
                              recordedBytes: recordedBytes, dest: dest, rawDir: rawDir)
}

// MARK: - 0. 夹具校验
print("0. 合成 Opus 夹具实际解码")
check("每帧仍为 CB08 的 40 字节", syntheticPacket.count, OggWrap.packetLen)
let fixture = makeCase()
do {
    let file = try AVAudioFile(forReading: fixture.dest.appendingPathComponent("\(defaultBase).ogg"))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
    try file.read(into: buffer)
    check("合成夹具能实际读出 PCM 帧", buffer.frameLength > 0, true)
    check("1000 帧时长接近 20 秒", abs(Double(file.length) / file.processingFormat.sampleRate - 20) < 0.1, true)
} catch {
    failed += 1
    print("  FAIL  合成 Opus 夹具解码：\(error)")
}

// MARK: - 1. 清单键解析

print("1. 清单键解析")
if let k = ArchiveAudit.parseKey("note20260102-105203.|28|57240") {
    check("真实键 → base 去掉结尾的点", k.base, "note20260102-105203")
    check("真实键 → 秒数", k.seconds, 28)
    check("真实键 → 字节数", k.bytes, 57240)
} else {
    failed += 1; print("  FAIL  真实键解析不出来")
}
check("段数不对 → nil", ArchiveAudit.parseKey("note|28") == nil, true)
check("秒数不是数字 → nil", ArchiveAudit.parseKey("note.|x|100") == nil, true)
check("字节不是数字 → nil", ArchiveAudit.parseKey("note.|28|abc") == nil, true)
check("名字为空 → nil", ArchiveAudit.parseKey(".|28|100") == nil, true)

// MARK: - 2. 完好

print("\n2. 完好")
let good = audit()
check("两份留档齐全、字节时长都对 → 完好", good.status, .ok)
check("完好时 rawIntact", good.rawIntact, true)
check("完好时报出解码时长", good.decodedSeconds != nil, true)
check("完好时记下裸包字节", good.rawBytes, nominalBytes)

// MARK: - 3. 裸包侧的问题

print("\n3. 裸包（唯一的一份本体）")
let bothGone = audit(rawPackets: nil, oggPackets: nil)
check("裸包和 ogg 都没有 → 缺失", bothGone.status, .missing)
checkContains("要点破「可能彻底没了」", bothGone.detail, "30 天")

let rawGone = audit(rawPackets: nil)
check("裸包没了、只剩 ogg → 缺失", rawGone.status, .missing)
check("裸包没了时 rawIntact 必须为假", rawGone.rawIntact, false)
checkContains("要说清 ogg 还在", rawGone.detail, "只剩")

let short = audit(rawPackets: packets - 100)
check("裸包字节数少了 → 字节数不符", short.status, .sizeMismatch)
checkContains("说明里要有实际字节数", short.detail, "36000")

let long = audit(rawPackets: packets + 5)
check("裸包字节数多了 → 字节数不符", long.status, .sizeMismatch)

let ragged = audit(bytes: nominalBytes + 7, rawExtraBytes: 7)
check("裸包长度不是 40 的整数倍 → 损坏", ragged.status, .damaged)
checkContains("要说清尾部多出几字节", ragged.detail, "尾部多出 7 字节")

// MARK: - 4. ogg 侧的问题（裸包完好时一律可修）

print("\n4. ogg（派生物，裸包在就能重封装）")
let noOgg = audit(oggPackets: nil)
check("ogg 不在、裸包完好 → 需要人看一眼（不是缺失）", noOgg.status, .needsReview)
check("ogg 不在时 rawIntact 仍为真", noOgg.rawIntact, true)
checkContains("要告诉人不用重导", noOgg.detail, "不用重导")

let emptyOgg = audit(oggData: Data())
check("ogg 是 0 字节 → 损坏", emptyOgg.status, .damaged)
checkContains("0 字节要如实说", emptyOgg.detail, "0 字节")
check("ogg 坏了但裸包完好 → rawIntact", emptyOgg.rawIntact, true)

let badMagic = audit(oggData: Data("XXXXwhatever".utf8))
check("ogg 首四字节不是 OggS → 损坏", badMagic.status, .damaged)
checkContains("要点名 OggS", badMagic.detail, "OggS")

// 头是对的、后面全是垃圾：解码器打不开。这种情况我们**不**判损坏——
// 解码器对残缺流的行为不完全可预期，武断判死会让人白跑一趟重导。
let undecodable = audit(oggData: Data("OggS".utf8) + Data(repeating: 0x41, count: 4096))
check("有 OggS 头但解不开 → 需要人看一眼（不武断判损坏）", undecodable.status, .needsReview)

// ogg 是一段有效但长得多的流：能解开，时长对不上。
let wrongLen = audit(oggPackets: packets * 5)
check("ogg 能解开但时长对不上 → 需要人看一眼", wrongLen.status, .needsReview)
checkContains("说明里要给出解出来的时长", wrongLen.detail, "ogg 解出")

// MARK: - 5. 时长与清单自洽

print("\n5. 时长与清单自洽")
let secsOff = audit(secs: 300)
check("清单秒数与裸包字节算出的时长差太多 → 需要人看一眼", secsOff.status, .needsReview)
checkContains("要说清是清单和文件对不上", secsOff.detail, "清单和文件对不上")

check("容差内的秒数差异不算问题", audit(secs: nominalSecs + 1).status, .ok)

let inconsistent = audit(recordedBytes: nominalBytes + 1)
check("清单键与条目里的字节数打架 → 需要人看一眼", inconsistent.status, .needsReview)
checkContains("要说清是清单自身对不上", inconsistent.detail, "清单自身对不上")

// MARK: - 6. iCloud 未下载（最不能报错的一类）

print("\n6. iCloud 未下载：在云上，不是丢了")
let rawEvicted = audit(rawPackets: nil, rawPlaceholder: true)
check("裸包被驱逐成占位 → 未下载", rawEvicted.status, .notDownloaded)
check("未下载绝不能报成缺失", rawEvicted.status == .missing, false)
checkContains("要告诉人下载就行", rawEvicted.detail, "不用重导设备")

let bothEvicted = audit(rawPackets: nil, rawPlaceholder: true,
                        oggPackets: nil, oggPlaceholder: true)
check("两份都被驱逐 → 未下载", bothEvicted.status, .notDownloaded)
checkContains("要说清 ogg 也在云上", bothEvicted.detail, "ogg 也在云上")

let oggEvicted = audit(oggPackets: nil, oggPlaceholder: true)
check("只有 ogg 被驱逐、裸包完好 → 未下载", oggEvicted.status, .notDownloaded)
check("此时裸包仍算完好", oggEvicted.rawIntact, true)

let rawGoneOggEvicted = audit(rawPackets: nil, oggPackets: nil, oggPlaceholder: true)
check("裸包不在、ogg 是占位 → 未下载（先下回来再判）", rawGoneOggEvicted.status, .notDownloaded)

// MARK: - 7. 整体汇总

print("\n7. 整体汇总")
do {
    caseNo += 1
    let dir = root.appendingPathComponent("case\(caseNo)")
    let dest = dir.appendingPathComponent("导入")
    let rawDir = dest.appendingPathComponent("原始包")
    try! FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

    let wrapped = Data(try! OggWrap.wrap(syntheticAudio(packets)))
    // 一条完好
    try! Data(syntheticAudio(packets)).write(to: rawDir.appendingPathComponent("noteA-000001.opus"))
    try! wrapped.write(to: dest.appendingPathComponent("noteA-000001.ogg"))
    // 一条裸包字节数不符
    try! Data(count: nominalBytes - 40).write(to: rawDir.appendingPathComponent("noteB-000002.opus"))
    try! wrapped.write(to: dest.appendingPathComponent("noteB-000002.ogg"))
    // 一条彻底不在
    // （故意什么都不造）
    // 一条清单里没有的孤儿裸包
    try! Data(count: nominalBytes).write(to: rawDir.appendingPathComponent("noteZ-000009.opus"))

    var man = SyncManifest()
    for base in ["noteA-000001", "noteB-000002", "noteC-000003"] {
        man.imported["\(base).|\(nominalSecs)|\(nominalBytes)"] =
            SyncManifest.Imported(file: "\(base).ogg", bytes: nominalBytes, at: "2026-08-29 00:00:00")
    }
    man.imported["坏掉的键"] = SyncManifest.Imported(file: "x.ogg", bytes: 1, at: "")

    let report = ArchiveAudit.run(dest: dest, rawDir: rawDir, manifest: man)
    check("总条数 = 清单条数", report.total, 4)
    check("完好 1 条", report.healthy, 1)
    check("有问题 3 条", report.problems, 3)
    check("hasProblems", report.hasProblems, true)
    check("孤儿裸包被列出来", report.unlistedRawPackets, ["noteZ-000009"])
    check("认不出的键 → 需要人看一眼",
          report.items.first { $0.base == "坏掉的键" }?.status, .needsReview)
    check("倒序排列（最新在前）", report.items.first?.base, "坏掉的键")
    checkContains("汇总里带各类计数", report.summary, "共 4 条")

    let clean = ArchiveAudit.run(dest: dest, rawDir: rawDir, manifest: SyncManifest())
    check("空清单 → 没有条目", clean.total, 0)
    checkContains("空清单的汇总是人话", clean.summary, "无可体检")
}

try? FileManager.default.removeItem(at: root)

// MARK: - 8. 真实归档（不做断言，打出来给人核对）

print("\n8. 真实归档体检（\(SyncPaths.default.dest.path)）")
let realPaths = SyncPaths.default
if FileManager.default.fileExists(atPath: realPaths.manifest.path) {
    let started = Date()
    let report = ArchiveAudit.run(paths: realPaths)
    let cost = Date().timeIntervalSince(started)
    for item in report.items {
        print("  [\(item.status.label)] \(item.base)  \(item.detail)")
    }
    if !report.unlistedRawPackets.isEmpty {
        print("  清单里没有、磁盘上却有的裸包：\(report.unlistedRawPackets.joined(separator: "、"))")
    }
    print("  → \(report.summary)（耗时 \(String(format: "%.2f", cost))s）")
} else {
    print("  跳过：没找到 \(realPaths.manifest.path)")
}

print("\n\(String(repeating: "=", count: 46))\n通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)

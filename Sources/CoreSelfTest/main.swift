import Foundation
import LuyinbiCore

// 与 Python 版 importer/test_protocol.py 逐条对应的自测。
// 纯命令行工具链没有 XCTest，所以跑成可执行目标：失败即非零退出。

var passed = 0, failed = 0

func check(_ name: String, _ got: String, _ want: String) {
    if got == want { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)\n        得到 \(got)\n        期望 \(want)") }
}
func check(_ name: String, _ got: Int, _ want: Int) { check(name, "\(got)", "\(want)") }
func check(_ name: String, _ got: Bool, _ want: Bool) { check(name, "\(got)", "\(want)") }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

print("1. CRC-16/XMODEM 标准检验向量")
check("\"123456789\" -> 0x31C3",
      String(format: "0x%04X", Proto.crc16(Array("123456789".utf8))), "0x31C3")

print("\n2. 厂商文档 7.3 的真机成功帧（下载 note20260710-162938.wav）")
let docFrame: [UInt8] = [
    0x5a, 0x03, 0x9e, 0x20, 0x1e, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00, 0x00,
    0x6e, 0x6f, 0x74, 0x65, 0x32, 0x30, 0x32, 0x36, 0x30, 0x37, 0x31, 0x30,
    0x2d, 0x31, 0x36, 0x32, 0x39, 0x33, 0x38, 0x2e, 0x77, 0x61, 0x76, 0x00]
let built = try! Proto.buildImportRequest("note20260710-162938.wav", offset: 0, seq: 3)
check("整帧字节完全一致", hex(built), hex(docFrame))
check("帧长 36B", built.count, 36)
check("CRC=0x209E", String(format: "0x%04X", UInt16(built[2]) | (UInt16(built[3]) << 8)), "0x209E")
check("LEN=30", Int(UInt16(built[4]) | (UInt16(built[5]) << 8)), 30)

print("\n2a. 连接校时：与参考项目 <H5B 格式 / 独立 CRC 向量对照")
let clockDate = ISO8601DateFormatter().date(from: "2026-09-06T15:04:05Z")!
let shanghai = TimeZone(identifier: "Asia/Shanghai")!
let clockFrame = try Proto.buildTimeSync(clockDate, timeZone: shanghai, seq: 0x2a)
check("0-0 整帧（年份小端、普通整数、15B）", hex(clockFrame),
      "5a 2a 5c 8c 09 00 00 00 ea 07 09 06 17 04 05")
check("校时帧可通过解析器 CRC 校验", FrameParser().feed(clockFrame).count, 1)
let yearEnd = ISO8601DateFormatter().date(from: "2026-12-31T20:30:40Z")!
check("时区换算同时跨日跨年", hex(Array(try Proto.buildTimeSync(yearEnd, timeZone: shanghai).dropFirst(8))),
      "eb 07 01 01 04 1e 28")
check("UTC 无额外八小时偏移", hex(Array(try Proto.buildTimeSync(yearEnd, timeZone: .gmt).dropFirst(8))),
      "ea 07 0c 1f 14 1e 28")
let dst = ISO8601DateFormatter().date(from: "2026-03-08T10:00:00Z")!
check("洛杉矶夏令时切换", hex(Array(try Proto.buildTimeSync(dst, timeZone: TimeZone(identifier: "America/Los_Angeles")!).dropFirst(8))),
      "ea 07 03 08 03 00 00")
let leapDay = ISO8601DateFormatter().date(from: "2028-02-29T23:59:59Z")!
check("公历闰日", hex(Array(try Proto.buildTimeSync(leapDay, timeZone: .gmt).dropFirst(8))),
      "ec 07 02 1d 17 3b 3b")
check("再次构帧取新的时间", hex(Array(try Proto.buildTimeSync(clockDate.addingTimeInterval(70), timeZone: shanghai).dropFirst(8))),
      "ea 07 09 06 17 05 0f")
var invalidClockRejected = false
do { _ = try Proto.buildTimeSync(Date(timeIntervalSinceReferenceDate: .infinity)) }
catch { invalidClockRejected = true }
check("无效系统日期不触发整数转换崩溃", invalidClockRejected, true)

print("\n3. 流式解析：在每一个字节位置切开都要能重组")
let frames = [
    Proto.buildFrame(Proto.T.ctrl, 4, [87], seq: 1),
    Proto.buildFrame(Proto.T.file, Proto.FileCmd.importData, (0..<200).map { UInt8($0) }, seq: 2),
    Proto.buildFrame(Proto.T.file, Proto.FileCmd.importEnd, [0], seq: 3),
]
let stream = frames.flatMap { $0 }
let wantSeqs = [1, 2, 3]
var badCuts: [Int] = []
for cut in 1..<stream.count {
    let p = FrameParser()
    let got = p.feed(Array(stream[0..<cut])) + p.feed(Array(stream[cut...]))
    if got.map({ Int($0.seq) }) != wantSeqs { badCuts.append(cut) }
}
check("\(stream.count - 1) 个切点全部通过", badCuts.count, 0)

print("\n4. 一个 notify 含多帧 / 20B 分片喂入")
let p4 = FrameParser()
var got4: [Proto.Frame] = []
for i in stride(from: 0, to: stream.count, by: 20) {
    got4 += p4.feed(Array(stream[i..<min(i + 20, stream.count)]))
}
check("20B 分片喂入得到 3 帧", got4.count, 3)
check("末帧是 2-5 code=0",
      "\(got4[2].type!)-\(got4[2].cmd!)-\(got4[2].body)", "2-5-[0]")

print("\n5. 坏帧不能卡死解析器（音频里必然出现假帧头 0x5A）")
var corrupt = stream
corrupt[20] ^= 0xFF                     // 第 1 帧占 0..8，第 2 帧占 9..216
let p5 = FrameParser()
let got5 = p5.feed(corrupt)
check("坏帧之前的第 1 帧正常解出", got5.first.map { Int($0.seq) } ?? -1, 1)
check("坏帧被丢弃", got5.contains { $0.seq == 2 }, false)
check("坏帧之后的第 3 帧仍能解出", got5.contains { $0.seq == 3 }, true)
check("CRC 错误被计数", p5.crcErrors > 0, true)

print("\n6. 文件列表大端解码（帧头小端，条目大端）")
func entry(_ t: UInt32, _ s: UInt32, _ n: String) -> [UInt8] {
    var out: [UInt8] = []
    for v in [t, s] { out += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    let nb = Array(n.utf8)
    return out + nb + [UInt8](repeating: 0, count: 20 - nb.count)
}
let body6: [UInt8] = [0, 0, 0, 2] + entry(3600, 7_200_000, "note20260710-162938.")
                                  + entry(72, 144_000, "note20260711-090000.")
let list = FileListDecoder.decode(body6)
check("条目数", list.count, 2)
check("时长 3600s", Int(list[0].time), 3600)
check("体积 7.2MB", Int(list[0].size), 7_200_000)
check("截断名", list[0].name, "note20260710-162938.")
check("候选名 opus 优先", list[0].candidates[0], "note20260710-162938.opus")

print("\n7. 声明 count 大于实际字节时不越界")
check("截到实际条目数", FileListDecoder.decode([0, 0, 0, 99] + entry(1, 2, "a")).count, 1)

print("\n8. 长度护栏与删除帧")
var rejected = false
do { _ = try Proto.buildImportRequest("note20260710-162938-toolong.opus") }
catch { rejected = true }
check("超长文件名被拒绝", rejected, true)
check("2-12 分段导入帧长", try! Proto.buildImportRange("a.opus", start: 0, end: 262144).count, 6 + 2 + 8 + 24)

let del = try! Proto.buildDeleteOne("note20260828-170058.opus", seq: 7)
check("2-8 删除帧长 36B（同 2-2 格式，非文档说的 28B 条目）", del.count, 36)
check("2-8 TYPE/CMD", "\(del[6])-\(del[7])", "2-8")
check("2-8 前四字节参数是 offset=0", hex(Array(del[8..<12])), "00 00 00 00")

print("\n9. Ogg 封装：与已验证的 Python 版逐字节对照")
// 用项目里真实的 8 对（裸包 → Python 封出的 ogg）当黄金标尺。
let dest = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目/导入")
let rawDir = dest.appendingPathComponent("原始包")
let fm = FileManager.default
if let raws = try? fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension == "opus" }).sorted(by: { $0.path < $1.path }), !raws.isEmpty {
    var same = 0, diff = 0
    for r in raws {
        let base = r.deletingPathExtension().lastPathComponent
        let oggURL = dest.appendingPathComponent(base + ".ogg")
        guard let rawData = try? Data(contentsOf: r),
              let wantData = try? Data(contentsOf: oggURL) else { continue }
        let got = (try? OggWrap.wrap([UInt8](rawData))) ?? []
        if got == [UInt8](wantData) { same += 1 } else {
            diff += 1
            print("        \(base) 不一致：得到 \(got.count)B / 期望 \(wantData.count)B")
        }
    }
    check("\(same + diff) 个文件与 Python 输出逐字节一致", diff, 0)
    check("确实比对了文件（不是空跑）", same > 0, true)
    if let first = raws.first, let d = try? Data(contentsOf: first) {
        check("裸包识别", OggWrap.looksRaw([UInt8](d)), true)
        let ogg = (try? OggWrap.wrap([UInt8](d))) ?? []
        check("已封装的不再被当成裸包", OggWrap.looksRaw(ogg), false)
    }
} else {
    print("  跳过：本机没有可对照的样本（导入/原始包 为空）")
}


// MARK: - 补账与截断守卫
//
// 2026-08-29 出过一次：三条录音完整下到本地，清单却没记账，于是每轮重下、
// 一整天没进深脑。补账是对的，但补账的判据必须严——差一个字节都不能算完整，
// 否则就会把半截录音当成完整的推上去（那个事故我们已经吃过一次）。
print("\n补账与截断守卫")
do {
    func entry(_ name: String, _ secs: UInt32, _ size: UInt32) -> FileEntry {
        FileEntry(time: secs, size: size, name: name, rawName: Array(name.utf8))
    }
    let e = entry("note20260829-140354.", 10801, 21_602_000)
    var empty = SyncManifest()

    // 本地没有 → 该下
    check("本地没有就该下",
          SyncPlanner.pending(entries: [e], manifest: empty, status: nil, current: nil,
                              localRaw: [:]).count, 1)

    // 本地完整 → 不下，且可补账
    let full = ["note20260829-140354": 21_602_000]
    check("本地完整就别重下",
          SyncPlanner.pending(entries: [e], manifest: empty, status: nil, current: nil,
                              localRaw: full).count, 0)
    check("本地完整应被补账",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: nil, current: nil,
                                 localRaw: full).count, 1)

    // 少一个字节 → 必须重下，绝不补账
    let short = ["note20260829-140354": 21_601_999]
    check("差一个字节仍要重下",
          SyncPlanner.pending(entries: [e], manifest: empty, status: nil, current: nil,
                              localRaw: short).count, 1)
    check("差一个字节不许补账",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: nil, current: nil,
                                 localRaw: short).count, 0)

    // 大小对得上但除不尽 40（不可能是完整的裸包）→ 不补账
    let odd = entry("x.", 2, 101)
    check("除不尽 40 不许补账",
          SyncPlanner.unrecorded(entries: [odd], manifest: empty, status: nil, current: nil,
                                 localRaw: ["x": 101]).count, 0)

    // 0 字节不算完整
    let zero = entry("z.", 0, 0)
    check("0 字节不算完整",
          SyncPlanner.unrecorded(entries: [zero], manifest: empty, status: nil, current: nil,
                                 localRaw: ["z": 0]).count, 0)

    // 正在录的一律不碰——哪怕本地大小恰好对上
    check("正在录的不补账",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: 1,
                                 current: "note20260829-140354.", localRaw: full).count, 0)

    // 已经记过账的不重复补
    empty.imported[SyncPlanner.manifestKey(e)] =
        SyncManifest.Imported(file: "a.ogg", bytes: 1, at: "x")
    check("已记账的不重复补",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: nil, current: nil,
                                 localRaw: full).count, 0)
}

// MARK: - 下载完整性硬闸
//
// 2026-08-29：三小时录音只收到 7,200,666/21,602,000 字节，设备照样回 endCode 0，
// 于是半截文件落盘、被当成完整录音推进深脑，时长按裸包算成 3600.333 秒，
// 服务端 ffmpeg 一比对就 OUTPUT_INVALID。这道闸就是为了让这件事不再发生。
print("\n下载完整性硬闸")
do {
    check("一字不差才算完整",
          SyncPlanner.downloadComplete(got: 21_602_000, announced: 21_602_000), true)
    check("少一个字节不算",
          SyncPlanner.downloadComplete(got: 21_601_999, announced: 21_602_000), false)
    check("多一个字节也不算",
          SyncPlanner.downloadComplete(got: 21_602_001, announced: 21_602_000), false)
    check("那次真实的截断必须被拦下",
          SyncPlanner.downloadComplete(got: 7_200_666, announced: 21_602_000), false)
    check("零字节不算",
          SyncPlanner.downloadComplete(got: 0, announced: 0), false)
    check("除不尽 40 不算（截在半包上）",
          SyncPlanner.downloadComplete(got: 101, announced: 101), false)
    check("能被 40 整除且相等才算",
          SyncPlanner.downloadComplete(got: 120, announced: 120), true)
}


// MARK: - 设备切分的识别与拼接
//
// 录音笔有 3 小时上限，到点自动断开、隔 1 秒开下一条。实测 2026-08-29：
// 14:03:54 录 3:00:01，17:03:56 接着录 13:16，中间只差 1 秒——同一场会。
// 判宽了会把两场独立会议粘成一条（正文串了、比切开糟得多），所以判据要严。
print("\n设备切分识别")
do {
    let capped = 10801.0          // 顶满上限
    check("实测那一对：1 秒空档 + 顶满上限 → 合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: capped,
                                      nextBase: "note20260829-170356"), true)

    // 时长没顶满 → 是人手停的，不合
    check("时长没顶满就不合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: 600,
                                      nextBase: "note20260829-170356"), false)

    // 顶满了但隔了很久 → 是另一场会
    check("顶满但隔 1 小时不合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: capped,
                                      nextBase: "note20260829-180356"), false)

    // 空档 5 秒 = 边界，允许；6 秒不允许
    check("空档 5 秒（边界）合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: 10800,
                                      nextBase: "note20260829-170354"), true)

    // 时间倒流（后一条比前一条早）→ 不合
    check("时间倒流不合",
          Continuation.isContinuation(prevBase: "note20260829-170356", prevSeconds: capped,
                                      nextBase: "note20260829-140354"), false)

    // 文件名解析
    let d = Continuation.startedAt(base: "note20260829-170356")
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = .current
    check("文件名解析出真实时刻", d.map { f.string(from: $0) } ?? "nil", "2026-08-29 17:03:56")
    check("认不出的名字返回 nil", Continuation.startedAt(base: "mac-xyz") == nil, true)

    // 分组
    let g = Continuation.groupContinuations([
        ("note20260829-140354", capped),
        ("note20260829-170356", 796),
        ("note20260829-190146", 7),
    ])
    check("三条分成两组", g.count, 2)
    check("前两条合成一组", g[0].count, 2)
    check("第三条自己一组", g[1].count, 1)

    // 拼接
    let a = [UInt8](repeating: 1, count: 80), b = [UInt8](repeating: 2, count: 40)
    check("拼接长度相加", Continuation.concatRawPackets([a, b])?.count ?? -1, 120)
    check("除不尽 40 拒绝拼", Continuation.concatRawPackets([a, [UInt8](repeating: 3, count: 41)]) == nil, true)
    check("空段拒绝拼", Continuation.concatRawPackets([a, []]) == nil, true)
}

do {
    let start = ISO8601DateFormatter().date(from: "2026-10-22T10:00:26Z")!
    let end = ISO8601DateFormatter().date(from: "2026-10-22T19:53:01Z")!
    let root = CardSegmentDiscovery.File(name: "note20261022-100026.opus", bytes: 21602000)
    let next = CardSegmentDiscovery.File(name: "note20261022-130028.opus", bytes: 21602040)
    check("跨语言稳定分段身份", CardSegmentDiscovery.id(root: "a1cce652-94d0-486b-8938-208effd5d353", filename: "note20261022-130028.opus"), "087c2311-4b7f-5fe0-9402-8304e460afac")
    check("发现三小时续段", CardSegmentDiscovery.next(after: root, rootFile: root.name, startedAt: start, endedAt: end, files: [next]) == next, true)
    let short = CardSegmentDiscovery.File(name: "note20261022-160029.opus", bytes: 11814360)
    check("继续发现下午末段", CardSegmentDiscovery.next(after: next, rootFile: root.name, startedAt: start, endedAt: end, files: [short]) == short, true)
    let evening = CardSegmentDiscovery.File(name: "note20261022-195302.opus", bytes: 97480)
    check("长缺口不冒充续段", CardSegmentDiscovery.next(after: short, rootFile: root.name, startedAt: start, endedAt: end, files: [evening]) == nil, true)
    check("歧义目录拒绝", CardSegmentDiscovery.next(after: root, rootFile: root.name, startedAt: start, endedAt: end, files: [next,next]) == nil, true)
    check("非三小时文件不猜续段", CardSegmentDiscovery.next(after: .init(name: root.name, bytes: 8000), rootFile: root.name, startedAt: start, endedAt: end, files: [next]) == nil, true)
    check("结束之后的新文件不导入", CardSegmentDiscovery.next(after: root, rootFile: root.name, startedAt: start, endedAt: start.addingTimeInterval(100), files: [next]) == nil, true)
    check("错误日期拒绝", CardSegmentDiscovery.clock("note20260230-100026.opus") == nil, true)
    check("截断扩展名只规范格式", CardSegmentDiscovery.canonical("note20261022-130028.opu"), next.name)
}

print("\n\(String(repeating: "=", count: 46))\n通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)

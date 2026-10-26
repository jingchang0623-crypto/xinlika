import Foundation
import LuyinbiCore

// 真机验证工具。UI 出来之前用它跑通蓝牙层。
// 只读 + 下载；删除需要显式子命令，且不提供「删除全部」。

func hhmmss(_ sec: Int) -> String {
    sec >= 3600 ? String(format: "%d:%02d:%02d", sec/3600, sec%3600/60, sec%60)
                : String(format: "%d:%02d", sec/60, sec%60)
}
func human(_ n: Int) -> String {
    var v = Double(n)
    for u in ["B", "KB", "MB", "GB"] {
        if v < 1024 || u == "GB" { return u == "B" ? "\(n)B" : String(format: "%.1f%@", v, u) }
        v /= 1024
    }
    return "\(n)B"
}

func usage() -> Never {
    print("""
    用法: luyinbi-cli <命令>
      scan            扫描并列出附近设备
      info            连接后读电量/固件/容量/增益/录音状态
      list            列出设备内录音
      pull <序号|all> 下载到当前目录（.opus 裸包）
      delete <序号>   删除单个文件（不可逆，无「删除全部」）
      push <ogg文件>  把本地音频推给深脑（幂等：同名重推不会建重复会话）
      status <会话id> 查深脑会话状态
      speakers <转写id> 列出说话人 + 样本原话 + 可选人物
      name <转写id> <标签> <名字> [人物id]  指认说话人（走深脑接口）
      wave <base>     算一次波形（验证耗时与缓存）
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

// 按需创建：CBCentralManager 一实例化就会触发蓝牙权限检查，
// 不碰蓝牙的子命令（push / status）不该被它拖累。
var _client: BLEClient?
func ble() -> BLEClient {
    if _client == nil { _client = BLEClient() }
    return _client!
}

func deepbrain() throws -> DeepBrain {
    let cfg = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目/importer/deepbrain.json")
    return DeepBrain(config: try DeepBrainConfig.load(from: cfg))
}

func connected() async throws -> BLEClient {
    let client = ble()
    let dev = try await client.findRecorder(seconds: 8)
    print("目标 \(dev.name)  rssi=\(dev.rssi)\(dev.byService ? "  广播含 AE20" : "")")
    try await client.connect(dev)
    print("已连接，ATT_MTU ≈ \(client.mtu)")
    return client
}

func printList(_ entries: [FileEntry], _ done: Bool) {
    print("\(entries.count) 条\(done ? "，收到 2-18 结束帧" : "，未收到 2-18（靠空闲收尾）")")
    for (i, e) in entries.enumerated() {
        print(String(format: "  %-3d %-24@ %8@ %12@", i,
                     e.name as NSString, hhmmss(Int(e.time)) as NSString,
                     human(Int(e.size)) as NSString))
    }
}

do {
    switch cmd {
    case "scan":
        let found = try await ble().scan(seconds: 8)
        for d in found.prefix(15) {
            print("  \(d.byService ? "*" : " ") \(d.name)  rssi=\(d.rssi)")
        }
        print("\n（* = 广播含 AE20 服务）共 \(found.count) 个")

    case "info":
        let c = try await connected()
        let batt = try await c.battery()
        let fw = try await c.firmware()
        let cap = try await c.capacity()
        let g = try await c.gain()
        let st = try await c.recordStatus()
        let cur = try await c.currentFilename()
        print("电量      \(batt.map { $0 == 110 ? "充电中" : "\($0)%" } ?? "-")")
        print("固件      \(fw ?? "-")")
        print("容量      \(cap.map { "剩余 \($0.remain) / 总 \($0.total)（单位见固件）" } ?? "-")")
        print("增益      \(g.map { [1: "低", 2: "中", 3: "高"][$0] ?? "\($0)" } ?? "-")")
        print("录音状态  \(st.map { [1: "录音中", 2: "未录音", 3: "暂停"][$0] ?? "\($0)" } ?? "未知")")
        print("当前文件  \(cur ?? "无")")
        print("解析健康  \(c.parserStats)")

    case "list":
        let c = try await connected()
        let (entries, done) = try await c.fileList()
        printList(entries, done)

    case "pull":
        guard args.count >= 2 else { usage() }
        let c = try await connected()
        let (entries, _) = try await c.fileList()
        let targets = args[1] == "all" ? Array(entries.indices)
                                       : [Int(args[1])].compactMap { $0 }
        for i in targets {
            guard i < entries.count else { print("序号 \(i) 越界"); continue }
            let e = entries[i]
            print("\n[\(i)] \(e.base)  \(hhmmss(Int(e.time)))  \(human(Int(e.size)))")
            var lastPct = -1
            let res = try await c.download(candidates: e.candidates, expectSize: e.size) { got, expect in
                guard let expect, expect > 0 else { return }
                let pct = got * 10 / Int(expect)
                if pct > lastPct { lastPct = pct; print("    \(pct * 10)%  \(human(got))") }
            }
            guard res.ok else {
                print("    失败：\(Proto.importEndMeaning[res.endCode ?? 255] ?? "未知")（试过 \(res.tried)）")
                continue
            }
            let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(res.filename)
            try Data(res.data).write(to: out)
            print(String(format: "    -> %@  %@  %.1f KB/s", res.filename, human(res.data.count), res.kbps))
        }

    case "delete":
        guard args.count >= 2, let idx = Int(args[1]) else { usage() }
        let c = try await connected()
        let (entries, _) = try await c.fileList()
        guard idx < entries.count else { print("序号越界"); exit(1) }
        let e = entries[idx]
        let st = try await c.recordStatus()
        guard st == 2 else { print("设备不在「未录音」状态（\(st.map(String.init) ?? "未知")），中止"); exit(1) }
        print("删除 \(e.base) …（不可逆）")
        let (ok, note) = try await c.deleteOne(e)
        print(ok ? "已删除：\(note)" : "删除失败：\(note)")

    case "push":
        guard args.count >= 2 else { usage() }
        let url = URL(fileURLWithPath: args[1])
        let base = url.deletingPathExtension().lastPathComponent
        let audio = [UInt8](try Data(contentsOf: url))
        // 时长按同名裸包算；没有裸包就按 ogg 粗估
        let rawURL = url.deletingLastPathComponent()
            .appendingPathComponent("原始包/\(base).opus")
        let dur = (try? Data(contentsOf: rawURL)).map { OggWrap.durationSeconds(rawLength: $0.count) } ?? 0
        let db = try deepbrain()
        try await db.connect()
        print("推送 \(base)  \(human(audio.count))  \(String(format: "%.1f", dur))s")
        // 可选第二个参数：幂等键后缀。上一次推成了 failed 会话时，
        // 同一个键只会拿回那条 failed，永远重传不了——换个后缀开一条干净的。
        let suffix = args.count > 2 ? "-\(args[2])" : ""
        // 真实录音时刻从文件名解析，别让深脑记成上传时刻
        let started = Continuation.startedAt(base: base)
        if let started { print("  录音时刻 \(started)") }
        let r = try await db.upload(audio: audio, title: base, durationSec: dur,
                                    clientRequestId: "mac-ble-\(base)\(suffix)",
                                    startedAt: started, onStep: { print("  深脑：\($0)") })
        print("会话 \(r.sessionId)  分片 \(r.chunks)\(r.alreadyDone ? "（幂等重放，未重传）" : "")")
        let st = try await db.sessionState(r.sessionId)
        print("状态 \(st.status)  转写 \(st.transcriptId ?? "-")  错误 \(st.errorCode ?? "-")")

    case "status":
        guard args.count >= 2 else { usage() }
        let db = try deepbrain()
        try await db.connect()
        let st = try await db.sessionState(args[1])
        print("状态 \(st.status)  转写 \(st.transcriptId ?? "-")  错误 \(st.errorCode ?? "-")")

    case "speakers":
        guard args.count >= 2 else { usage() }
        let db = try deepbrain(); try await db.connect()
        let rows = try await db.speakers(transcriptId: args[1])
        let samples = try await db.speakerSamples(transcriptId: args[1])
        let people = try await db.personProfiles()
        print("说话人 \(rows.count) 个：")
        for r in rows {
            let named = r.inferredIdentity ?? "（未指认）"
            print("  \(r.label)  → \(named)\(r.confirmed ? " ✓已确认" : "")")
            print("     行id \(r.id)")
            if let s = samples[r.label] {
                print("     样本 [\(String(format: "%.1f", s.startSeconds))s] \(s.text.prefix(46))")
            }
        }
        print("\n深脑已有人物 \(people.count) 位：")
        for p in people.prefix(12) { print("  \(p.displayName)   id=\(p.id)") }

    case "name":
        guard args.count >= 3 else { usage() }
        let db = try deepbrain(); try await db.connect()
        // 参数是 <transcriptId> <标签> <名字> [profileId]
        guard args.count >= 4 else { usage() }
        let rows = try await db.speakers(transcriptId: args[1])
        guard let row = rows.first(where: { $0.label == args[2] }) else {
            print("这条转写里没有标签「\(args[2])」，现有：\(rows.map(\.label).joined(separator: "/"))")
            exit(1)
        }
        try await db.assignSpeaker(transcriptId: args[1], row: row, identity: args[3],
                                   profileId: args.count > 4 ? args[4] : nil)
        print("已指认：\(args[2]) → \(args[3])")

    case "wave":
        guard args.count >= 2 else { usage() }
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目")
        let audio = root.appendingPathComponent("导入/\(args[1]).ogg")
        let t0 = Date()
        let p1 = Waveform.load(base: args[1], audio: audio, root: root)
        print(String(format: "首次 %.0f ms，%d 根柱", Date().timeIntervalSince(t0) * 1000, p1?.count ?? 0))
        let t1 = Date()
        _ = Waveform.load(base: args[1], audio: audio, root: root)
        print(String(format: "命中缓存 %.1f ms", Date().timeIntervalSince(t1) * 1000))
        if let p1 { print("前 10 根:", p1.prefix(10).map { String(format: "%.2f", $0) }.joined(separator: " ")) }

    case "startest":
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m.json")
        var m = SyncManifest()
        m.starred = ["note20260828-205856"]
        m.uploaded = ["a": "b"]
        try m.save(to: tmp)
        let back = SyncManifest.load(from: tmp)
        print("写回读出 starred:", back.starred, "uploaded:", back.uploaded)
        print(back.starred == ["note20260828-205856"] && back.uploaded["a"] == "b"
              ? "PASS 收藏能持久化且没弄坏其他键" : "FAIL")
        try? FileManager.default.removeItem(at: tmp)

    default: usage()
    }
    _client?.disconnect()
} catch {
    print("出错：\(error)")
    _client?.disconnect()
    exit(1)
}

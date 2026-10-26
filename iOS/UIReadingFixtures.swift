#if DEBUG
import Foundation

/// Debug samples, kept in memory or an isolated simulation ledger; never sent to a server.
enum UIReadingFixtures {
    static let analysis = """
    # 产品复盘：从录音到洞察

    这是一份界面测试样例。**先确保录音安全，再让分析可见。** 用户需要知道内容是否保存、处理到哪一步，以及下一步能做什么。

    ## 核心判断

    1. 录音安全是信任的基础。
       - 锁屏后应保留已经完成的同步进度。
       - 失败提示需要给出可执行的下一步。
    2. 摘要帮助快速了解，完整分析保留推理过程。

    > “我更关心这段录音有没有保存下来，以及什么时候能看到结果。”

    ## 方案对照

    | 场景 | 用户需要 | 界面反馈 |
    | :--- | :--- | :--- |
    | 连接中断 | 已有内容不丢失 | 保留进度，说明恢复方式 |
    | 分析排队 | 能判断是否需要等待 | 显示真实处理状态 |
    | 结果已缓存 | 网络不佳也可继续阅读 | 内容保留，单独说明更新失败 |

    ## 验证清单

    - [ ] 在手机上复核长文的阅读体验。
    - [x] 保留引用、段落与标题的原始关系。

    ```text
    录音 → 同步 → 转写 → 分析 → 阅读
    ```

    更多规范见 [Apple 开发者文档](https://developer.apple.com/design/human-interface-guidelines)。
    """
    static var longAnalysis: String {
        let paragraph = "长期价值来自可重复的可靠体验。每次录音都应该有可理解的处理状态：已经保存、等待处理、分析完成或需要恢复。界面将内容与设备操作分开，让读者先读懂结论，再决定是否查看原始证据。不能用进度动画代替真实状态，也不能把转写完成当作分析完成。重要判断需要结合原始对话核实，界面不擅自生成新结论。"
        return analysis + (1...36).map { "\n\n## 深入章节 \($0)\n\n" + Array(repeating: paragraph, count: 4).joined(separator: "\n\n") }.joined() + "\n\n## 报告结尾\n\n长文末尾内容仍应完整可读。"
    }
    static func records(scenario: String, scope: RecordScope? = nil) -> [LedgerItem] {
        if scenario == "empty" { return [] }
        if scenario == "cloud" {
            let verified = scope ?? RecordScope(orgId: "30000000-0000-0000-0000-000000000001", email: "fixture@example.test",
                config: AppConfig(apiBase: "https://api.test", supabaseURL: "https://auth.test", supabaseAnonKey: "public"))
            let local = records(scenario: "default", scope: verified)[0]
            let imported = CloudRecord(transcriptID: "20000000-0000-0000-0000-000000000002", title: "云端上传样例 · 访谈",
                startedAt: CloudRecord.date("2026-09-07T08:30:00Z"), durationSeconds: 900, stage: "analyzed", headline: "直接上传的录音也能阅读现成分析")
            let linked = CloudRecord(transcriptID: local.transcriptId, title: local.title, stage: "analyzed")
            let failed = CloudRecord(sessionID: "10000000-0000-0000-0000-000000000003", title: "云端失败样例",
                startedAt: CloudRecord.date("2026-09-06T08:30:00Z"), stage: "failed", problem: "云端转写未完成")
            var combined = CloudLibrary.merging([imported, linked, failed], into: [local], scope: verified)
            if let index = combined.firstIndex(where: { $0.transcriptId == imported.transcriptID }) {
                var analysis = local.meeting!
                analysis.transcriptId = imported.transcriptID!
                analysis.title = imported.title
                analysis.summary = imported.headline
                combined[index].meeting = analysis
                combined[index].resultUpdatedAt = Date()
            }
            return combined
        }
        let sample = Meeting(transcriptId: "00000000-0000-0000-0000-000000000001",
            title: "界面测试样例 · 产品复盘", summary: "先确保录音安全，再让分析可见。\n\n这次讨论围绕同步稳定性、结果反馈和手机阅读体验展开，优先解决阻碍日常使用的问题。",
            speakers: ["测试参与者"], analysis: .init(status: "done", markdown: scenario == "long" ? longAnalysis : analysis,
                methods: ["第一性原理"], routingReason: "先识别基本需求，再确定最小改进范围。"), analysisAbsentReason: nil,
            judgments: [.init(id: "j", statement: "结果可见是完整体验的一部分。", quote: "需要直接看到分析", subject: "阅读体验")],
            commitments: [.init(id: "c", statement: "验证锁屏恢复", speaker: "测试参与者", dueDate: "2026-09-10")])
        let date = Date(timeIntervalSince1970: 1788571800)
        var record = LedgerItem(id: "ui-fixture", orgId: scope?.orgId ?? "ui-test", deviceId: "ui-test", fileBase: "note20260905-093000",
            title: sample.title, durationSec: 600, expectedBytes: 1200000, receivedBytes: 1200000,
            localFilename: "ui-test.ogg", contentHash: "", serverSessionId: "ui-test", transcriptId: sample.transcriptId,
            state: .ready, lastError: nil, updatedAt: date, ownerKey: scope?.ownerKey ?? "ui-test", meeting: sample, resultUpdatedAt: date)
        if scenario == "error" { record.resultError = "网络暂时不可用，请稍后刷新。" }
        if scenario == "absent" {
            record.meeting?.analysis = nil
            record.meeting?.analysisAbsentReason = "录音较短，未自动分析"
            record.meeting?.summary = nil
            record.meeting?.judgments = []
            record.meeting?.commitments = []
        }
        if ["long", "error", "absent"].contains(scenario) { return [record] }
        var pending = LedgerItem(id: "ui-pending", orgId: record.orgId, deviceId: record.deviceId, fileBase: "note20260904-143000",
            title: "界面测试样例 · 行走中的想法", durationSec: 420, expectedBytes: 800000, receivedBytes: 800000,
            localFilename: "ui-pending.ogg", contentHash: "", serverSessionId: "ui-test", transcriptId: record.transcriptId,
            state: .ready, lastError: nil, updatedAt: date, ownerKey: record.ownerKey, meeting: sample)
        pending.meeting?.title = pending.title
        pending.meeting?.analysis = .init(status: "analyzing", markdown: nil, methods: [], routingReason: nil)
        pending.meeting?.summary = "围绕专注与休息，记录下几个值得继续探索的问题。"
        return [record, pending]
    }
}
#endif

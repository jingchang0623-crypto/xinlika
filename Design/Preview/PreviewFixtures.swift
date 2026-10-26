import Foundation

struct DesignRecord: Identifiable {
    enum Status: String { case ready = "分析完成", processing = "分析中", failed = "上传失败" }
    let id: String
    let title: String
    let group: String
    let time: String
    let duration: String
    let excerpt: String
    let status: Status
    let summary: String
    let insights: [DesignInsight]
    let actions: [DesignAction]
    let chapters: [DesignChapter]
}

struct DesignInsight: Identifiable {
    let id: String
    let title: String
    let body: String
    let quote: String
}

struct DesignAction: Identifiable {
    let id: String
    let title: String
    let context: String
}

struct DesignChapter: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let paragraphs: [String]
    var bullets: [String] = []
    var comparison = false
}

enum PreviewFixtures {
    static let records: [DesignRecord] = [
        DesignRecord(
            id: "product-review", title: "让深脑成为值得回看的记录", group: "今天", time: "09:30", duration: "32 分钟",
            excerpt: "先让同步可靠，再让分析好读。下一版聚焦记录、概览和完整分析三个页面。", status: .ready,
            summary: "这一轮不增加新的分析能力，先让已有内容更容易找到、读懂和核对。把技术状态收回设备页，让记录与分析成为主角。",
            insights: [
                DesignInsight(id: "trust", title: "可靠，是阅读体验的前提", body: "用户需要知道录音已保存、分析在进行；离开 App 后，也能继续回来查看。", quote: "“我更关心这段录音有没有保存下来，以及什么时候能看到结果。”"),
                DesignInsight(id: "layers", title: "先抓重点，再保留完整上下文", body: "用概览帮助快速理解，用长文承载推理过程。两者不是重复，而是不同的阅读深度。", quote: "“先告诉我有什么值得关注，再让我决定要不要继续往下读。”")
            ],
            actions: [
                DesignAction(id: "reading-preview", title: "验证三屏阅读原型", context: "先看层级、字号和内容密度"),
                DesignAction(id: "long-report", title: "用长篇报告检验排版", context: "覆盖标题、列表、引用和表格"),
                DesignAction(id: "device-test", title: "保留同步链路回归测试", context: "继续验证锁屏、断连和恢复")
            ],
            chapters: [
                DesignChapter(id: "context", title: "这次讨论，真正要解决什么", subtitle: "从功能可用，到内容可读", paragraphs: [
                    "深脑已经能够保存录音并返回分析。接下来的关键，不是把更多信息塞进同一屏，而是让人一眼看见最值得关注的内容。",
                    "一次录音有多个不同的阅读时刻：刚结束时快速看结论，稍后回顾讨论细节，需要做决定时再核对原话。界面应当支持这种逐步深入的节奏。"
                ]),
                DesignChapter(id: "hierarchy", title: "把三种阅读深度分开", subtitle: "找到 · 理解 · 深入", paragraphs: [
                    "记录列表负责识别与检索，不承担展示整份报告的工作。标题、时间和摘要就足够帮助用户判断是否要打开。",
                    "概览组织已有的摘要、判断与行动建议；完整分析保留论证过程。卡片只用于独立观点，连续正文不需要反复被边框打断。"
                ], bullets: ["记录：找到想回顾的那一次对话。", "概览：理解结论，以及下一步可以做什么。", "完整分析：阅读依据、细节和未决问题。"]),
                DesignChapter(id: "choices", title: "不同内容，使用不同容器", subtitle: "卡片不是唯一答案", paragraphs: [
                    "选择容器时，应先问这段内容是否独立、是否需要被单独比较。一个判断可以独立成卡，一篇长文则需要连续的阅读节奏。"
                ], comparison: true),
                DesignChapter(id: "risks", title: "需要保留的边界与风险", subtitle: "漂亮之外，还要可信", paragraphs: [
                    "没有返回的摘要不能由界面自行编造，没有原文时间锚点也不能显示假的跳转。正在分析、分析失败和无需自动分析，应当是三个不同的状态。",
                    "如果设备同步中断，用户应看到已经保存的进度和下一步恢复方式。界面变简洁，不代表隐藏失败，更不意味着后台能够无限运行。",
                    "这一轮先验证展示结构。正式接入时仍需以真实长文、弱网、大字号和真机后台行为逐项验收。"
                ])
            ]),
        DesignRecord(
            id: "walking-notes", title: "散步时，关于专注的几个想法", group: "今天", time: "08:12", duration: "7 分钟",
            excerpt: "录音已经保存，正在整理分析。完成后会出现在这里。", status: .processing,
            summary: "", insights: [], actions: [], chapters: []),
        DesignRecord(
            id: "weekly-review", title: "一周复盘：留出真正重要的时间", group: "昨天", time: "18:40", duration: "24 分钟",
            excerpt: "减少被动切换，把最清醒的时段留给需要思考的工作。", status: .ready,
            summary: "这一周忙碌的主要原因不是任务多，而是注意力不断切换。下一周尝试保留连续时间，并让临时事务进入固定处理窗口。",
            insights: [DesignInsight(id: "focus-time", title: "时间完整，比时间长更重要", body: "把需要推理的工作安排在连续时段，避免在消息和任务之间来回切换。", quote: "“一小时没有被打断，比断断续续忙三个小时更有进展。”")],
            actions: [DesignAction(id: "calendar", title: "安排一段不被打扰的时间", context: "下周选一个早晨，先做小范围尝试")],
            chapters: [DesignChapter(id: "reflection", title: "重新认识这一周的忙碌", subtitle: "从填满日程到保护注意力", paragraphs: ["复盘不只是统计完成了多少任务，也要观察工作的节奏。过多的临时切换会让思考总停留在开始阶段。", "尝试给重要工作留一段完整时间，再集中处理消息。这是一次小范围试验，而不是要求每天都保持理想状态。"])])
    ]

    static let failed = DesignRecord(id: "failed-example", title: "客户访谈：第一次使用的感受", group: "今天", time: "10:20", duration: "18 分钟", excerpt: "录音已保存在手机。网络恢复后可重新上传，无需再次同步设备。", status: .failed, summary: "", insights: [], actions: [], chapters: [])
}

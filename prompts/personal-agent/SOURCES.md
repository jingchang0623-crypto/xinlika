# Personal Agent 行为与运行循环参考

这些是本项目中文提示词和运行逻辑的设计参考；没有安装或替换为另一套 Agent 框架，也没有逐字搬运上游系统提示词。运行时复用已有 OpenAI SDK、LangGraph 检查点与 SQLite 任务账本。2026-10-21 查询，固定到以下提交，避免把主分支后续变化当成已核对版本。

| 项目／来源 | 借鉴的处理逻辑 | 心力卡落地与边界 |
| --- | --- | --- |
| [Omi proactive_notification.py](https://github.com/BasedHardware/omi/blob/f162bdb341d73b7f2bbbc35603e620406bcec98c/backend/utils/llm/proactive_notification.py)（MIT） | `evaluate_relevance`、`generate_notification`、`validate_notification` 三个阶段的提示词；默认不介入，具体变化优先，检查最近通知与用户目标，独立复核拦截低价值提醒 | observe → respond → review → publish 四个可恢复节点；“当前记录”和历史依据分开；不复制设备佩戴者就是说话人的假设。该文件 `evaluate_proactive_notification` 明确标记为兼容评估用的旧单次调用，不把它误称当前三步生产循环。 |
| [OpenClaw heartbeat](https://github.com/openclaw/openclaw/blob/e0a0bbcf2d01909552419ccfe865eb753fc4c9e8/docs/gateway/heartbeat.md)、[system-prompt.ts](https://github.com/openclaw/openclaw/blob/e0a0bbcf2d01909552419ccfe865eb753fc4c9e8/src/agents/system-prompt.ts) | 事件唤醒／定期 Agent 轮次；持久调度、冷却、静默、monitor scratch；运行能力与身份／上下文分层 | 新记录、语义整理和纠正触发持久 `personal_analysis` 作业；五分钟合并观察，十五分钟反馈冷却，每滚动 24 小时至多六条；无变化不调用模型。不是照搬旧 HEARTBEAT.md：核对版本的运行时不再读取该文件，使用数据库 monitor scratch。 |
| [Hermes system_prompt.py](https://github.com/NousResearch/hermes-agent/blob/5b147ab036d6d19131bff8d20701b5001eab844a/agent/system_prompt.py)、[prompt_builder.py](https://github.com/NousResearch/hermes-agent/blob/5b147ab036d6d19131bff8d20701b5001eab844a/agent/prompt_builder.py)（MIT） | 稳定角色、会话上下文、动态用户资料三层组织；行为规格而非形容词人设；完成工作要有真实工具结果，失败不可伪造成功 | 稳定中文 contract 与 observe/respond/review 分文件，当前证据／更正／待观察线索分字段。版本及 SHA-256 写入分析上下文。未来对接工具时必须明确权限；本轮只有 App 内建议，不赋予终端、群发或外部动作权限。 |

核心不是“多记一些事实”，而是有状态的理解、介入判断和反馈修正。既有全文检索只为 Agent 找到旧依据服务，不构成 Personal Agent 本身。Mem0、Graphiti 不作为本轮角色设定与 Agent 循环的参考主体。

## 本地文件

- `contract.zh-CN.md`：角色、用户目标、来源、时间和权限边界。
- `observe.zh-CN.md`：理解变化，判断是否值得介入，留下可失效的观察线索。
- `respond.zh-CN.md`：基于证据给一条具体反馈。
- `review.zh-CN.md`：独立拒绝复述、重复、误归属、过期及无证据的建议。

## 不照搬的部分

不把录音中的第一人称等同用户，不让 Agent 凭线索扩张权限，不把模型工作笔记升级成人格或事实。来源未辨的记录可以自动分析其中事项；只能以“录音中的讨论”反馈，不能归给用户。背景播放／测试排除出主动个人分析。上游的外部通知通道、工具执行与无限自我修改不随这些提示词引入。

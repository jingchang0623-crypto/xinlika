# 最小 API 导览

除 `/health` 外，接口需 `Authorization: Bearer <device token>`。凭据用本地CLI建立，不由公共HTTP注册；单用户、多设备。POST还需要编辑权限和JSON Content-Type。

| 方法/路径 | 用途 |
|---|---|
| GET `/health` | 进程健康；不证明模型、音频或队列质量 |
| GET `/v1/shared/capabilities` | 空间身份、设备权限及协议版本 |
| GET `/v1/shared/sync?day=2026-10-23&time_zone=Asia%2FShanghai` | 持久修订和权威快照；可带cursor/view |
| GET `/v1/agent?day=2026-10-23` | 当日投影、主题、文档、任务、回答与建议 |
| POST `/v1/dialogues/text` | 明确提交文字；字段id、session_id、text、occurred_at |
| POST `/v1/memory/ask` | 提交异步问答；字段id、question；稍后读取answers |
| POST `/v1/feedback` | 带expected_version的纠正/完成/驳回；同反馈id重试幂等 |
| POST `/v1/mobile/ingest` | 已授权采集批次、重点、缺口、卡上参考与续段消息 |
| GET `/v1/mobile/segments?session_id=UUID` | 已关联物理分段及恢复状态 |
| POST `/v1/jobs/retry` | 显式重试符合条件的失败任务 |
| GET `/v1/voice`、`/v1/acoustics` | 可选声音功能状态；未配置权重不代表已经推理 |

输入的UUID保持稳定。相同身份但更换内容会发生409冲突，不应通过换新id掩盖一次失败。用户纠正以原文档id和版本为目标，旧版本失效后重建派生结果，不直接改写原声。

文字纠正示例：

```json
{
  "id": "33333333-3333-4333-8333-333333333333",
  "target_id": "22222222-2222-4222-8222-222222222222",
  "expected_version": 1,
  "action": "correct_document",
  "values": {"text": "更正：演示版改为下周三交付。"}
}
```

`target_id`应替换为该空间真实返回的文档身份。异步处理应观察任务状态；HTTP接收成功不等于ASR或模型质量通过。接收契约的完整边界以 `heartball_mobile.py` 和协议回归测试为准。

服务端拒绝控制录音卡。它也不是MCP server；只读MCP是路线图中的适配工作。

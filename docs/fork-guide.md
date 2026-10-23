# Fork 后做一个能交付的扩展

先[运行合成演示](quickstart.md)，再按[完整指南](full-app.md)连接自己的服务。选择一个你能说明输入、输出和失败条件的范围；不需要先接所有硬件或重写整个 App。

## Android 跨品牌客户端

目标是支持各种 Android 手机；当前尚未提供公开实现。第一份成果可以是连接共享空间、同步和补记文字，随后补纠正/问答，再做麦克风及 BLE。文件入口、格式边界、跨品牌验收见 [Android 分阶段任务](android-plan.md)。不要提交只含设计稿但宣称兼容完成的 PR。

## 只读 MCP

状态：未实现。第一份成果是独立只读适配器，提供搜索记录、取原文/版本、取主题时间线三个小工具；具体名称可在实现中确定。

入口：`scripts/heartball_shared.py` 的鉴权与修订快照、`scripts/heartball_recall.py` 的召回、`scripts/test_heartball_shared.py` 与 `scripts/test_heartball_recall.py`。客户端协议参考 `clients/Sources/LuyinbiCore/HeartballClient.swift`；不能让 MCP 直接暴露整份 SQLite 或绕过设备权限。

验收：只读凭据可查询，撤权后失败；每条结果含来源 ID、版本、录制时间与最小必要片段；来源纠正后不继续返回旧的有效答案；控制最大返回量、超时和错误。不提供发送消息、写入或执行操作。先用合成账本接一个实际 MCP 客户端验证，记录兼容版本。

## 更少打扰的个人 Agent

入口：`prompts/personal-agent/`、`scripts/heartball_personal_agent.py`、`scripts/test_heartball_personal_agent.py`。

第一份成果是一组角色提示词与输入/期望/失败对照。至少覆盖：没有新变化保持安静、引用具体来源、播放内容不算本人经历、纠正使旧建议失效。报告实际模型、提示词版本及有用/无用反馈；不要只展示一句好建议。

## 设备或 ASR 适配器

入口：`scripts/heartball_asr.py`、`scripts/test_heartball_asr.py`、`scripts/heartball_mobile.py`、`scripts/test_heartball_mobile.py`；BLE 参考位于 GPL 的 `clients/Sources/LuyinbiCore/`。

第一份成果只支持一种明确音频格式或一种设备。验收：稳定身份、真实采集时间、SHA-256、丢响应后重试不重复、同 ID 改内容被拒绝、空转写不造句、失败保留原声。新格式不能绕过 CB08 容器严格检查；同时提交授权/许可证依据和可公开样本。

## 中文事件、跨天主题与纠正

入口：`scripts/heartball_organization.py`、`scripts/heartball_topics.py`、`scripts/heartball_recall.py` 及对应回归。

第一份成果是合成或明确授权的小对照集与一项修复。至少包含同名不同事项、跨天改期、撤回决定、旧录音后上传、纠正来源。分别展示正确关联、误合并和漏关联；卡片更少不等于质量更好。模型固定夹具验证控制逻辑，真实模型另报质量。

## 把第一次运行的阻碍修掉

没有硬件也能贡献：按文档做一次全新安装，记录 Python/macOS/Xcode 版本、失败命令和脱敏错误。修复文档路径、配置诊断或一个清楚的错误提示。通过[体验反馈模板](https://github.com/jingchang0623-crypto/xinlika/issues/new?template=first-run.yml)报告成功或失败都有效；无需上传个人记录。

PR 请写：具体触发、前后行为、验证、仍未覆盖的设备/条件。后端 MIT，客户端 GPL-3.0-only；复制或移植前先确认授权。[贡献规范](../CONTRIBUTING.md)

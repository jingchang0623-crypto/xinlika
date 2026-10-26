# 心力卡原生客户端公开交付

2026-10-23。承接前次后端v0.1.0，用户明确确认有旧代码再授权权利，但不采用MIT；客户端改为GPL-3.0-only，后端维持MIT。没有把用户确认原文或私有会话发布到GitHub。

公开代码位于 `<LOCAL_HOME>/Documents/Codex/2026-10-23/xinlika`，已推送主分支。原项目源码、用户安装的App、云端与录音卡保持原状态，本轮没有连接/停止真实采集。

逐项授权核查、排除范围、完整运行指南、替换与验证已经随仓库公开：

- [授权核查](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/client-licensing.md)
- [完整应用指南](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/full-app.md)
- [原生验证](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/native-validation.md)

主要变化：纳入现有原生采集/恢复/界面，移除旧账号、私有服务、原开发团队与阅读器依赖；厂商静态库/AAR/HAR/固件不打包。旧协议研究仓库不复制；校时编码按已核对字段重新表达。新增通用兼容ASR，服务密钥只由用户在服务端配置。

干净clone无`.build`/`.venv`/私有连接配置仍可安装构建。iPhone原生UI跑通记录→事件原句→纠正→问答，Mac原生API读回同一条更正。新公开包未做实体蓝牙/锁屏，Mac窗口自动化超时；未将API验证冒充窗口操作。首选多端流程为iPhone采集、Mac查看/纠正；Mac本机采集作为独立部署模式，不会自动送入共享账本。

本轮未发社交内容或外联消息。

已发布 [v0.2.0 预发布版](https://github.com/jingchang0623-crypto/xinlika/releases/tag/v0.2.0)，目标提交 `c40ebcb90ff8b1a0dded0132883ec225feba65e4`。

远端验证成功：

- [后端 Python 3.11 / 3.12](https://github.com/jingchang0623-crypto/xinlika/actions/runs/39890793488)：193 项回归及演示检查通过。
- [原生 Mac 构建及 iPhone 集成](https://github.com/jingchang0623-crypto/xinlika/actions/runs/39890793491)：90 项 Core/探针、10 项会话时间检查、23 项 iPhone 采集测试和 1 项完整 UI 流程通过；Mac API 读回同一更正及引用答案。

用于集成测试的本机合成 loopback 服务已结束，浏览器 CI 检查任务已清理。公开仓库使用完整克隆后自行构建的方式，iPhone 实机签名、真实模型/ASR 服务与 CB08 硬件由运行者准备。

# Android：从共享工作台到跨品牌采集

**状态：规划与贡献入口。当前没有公开 Android 客户端，也没有“所有 Android 已兼容”的测试结论。** 目标是让不同品牌手机使用同一套个人上下文后端，分阶段交付与验证。

## 第一阶段：先把完整文字闭环跑通

新建自己有权贡献的 Android 工程，优先实现服务地址/设备凭据配置、能力查询、事件/主题同步、文字补记、打开原句、纠正及问答。无需 CB08 或 ASR；使用自己的文字模型，或显式合成测试服务。旧 Android 工程未纳入本次公开范围；后续复用应沿用权利确认、来源与 GPL 标注流程。

参考：

- API 路由与鉴权：`scripts/heartball-shared-service.py`、`scripts/heartball_http.py`。
- 原生 HTTP 数据结构：`clients/Sources/LuyinbiCore/HeartballClient.swift`；纠正与工作台交互：`clients/iOS/XinlikaRootView.swift`。
- 快照和设备撤权：`scripts/heartball_shared.py`、`scripts/test_heartball_shared.py`。
- 可复现流程：`clients/UITests/WorkspaceFlowTests.swift`、`examples/native-test-server.py`。

第一份 PR 可以只做连接、同步和文字补记；完成标准是全新安装可连接自己的空间，输入时间与提交时间明确，重复提交不会悄悄制造第二条记录，凭据不写进日志或仓库。接着补上纠正后引用新版本、撤权后不能再读的跨端验收。

## 第二阶段：手机麦克风采集

先给 Android 麦克风输出定义独立的音频格式/时钟契约，再接入后端；不能把 PCM/AAC 直接标成 CB08 的 40 字节 Opus 帧。现有严格 ASR 容器适配主要服务 CB08，新音频格式需明确转换与回归。

最小验收：显式开始/结束、可见录音状态、本地不可变消息与 outbox、进程重启恢复、断网补传、哈希及幂等。区分“已保存 / 已上传 / 已转写 / 已整理”。实际系统后台限制需参考目标 SDK 官方文档并实机验证。

## 第三阶段：CB08 BLE

参考 `clients/Sources/LuyinbiCore/` 的协议、帧解析、目录、续段及采集控制；GPL 参考代码的移植必须保留相应授权与来源。设备选择、订阅状态、断连缺口、保存后卡上参考、物理续段不能省略。不要引入未获再分发许可的厂商二进制。

接收端入口是 `POST /v1/mobile/ingest`；稳定 ID、设备/会话绑定、真实 stream 起始时间、序号、字节范围、SHA-256 与不可变重试见 `scripts/test_heartball_mobile.py`。测试里的生成字节只验证协议，不是可播放音频样本。

## 第四阶段：跨品牌测试矩阵

每一行实测报告至少提供：品牌/型号、Android/系统版本、App 提交、硬件/固件、前后台和锁屏时长、音频增长/缺口、进程或网络中断条件、补传与来源一致性、耗电测量方法。逐台报告通过、失败和未知；一个系统通过不能推出所有 Android 支持。

首轮可选择贡献者手边的 Pixel、三星、小米、OPPO/一加/Realme 等不同系统；这是候选测试范围，不是兼容声明。先用合成/明确授权样本，不附私人录音、标识或凭据。

## 开始前约定

在 [Issue](https://github.com/jingchang0623-crypto/xinlika/issues/new/choose) 说明你要实现的阶段、手边设备和可验收范围，避免多个人重复写同一模块。后端为 MIT；`clients/` 按 GPL-3.0-only 贡献，复用或移植源码须保留来源。[Fork 指南](fork-guide.md)列出其他无需 Android 设备也能参与的方向。

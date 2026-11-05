# 心力卡（Xinlika）

基于 CB08 录音卡的开源 Personal Agent：iPhone 持续采集并上传分段，云端转写与自动整理，Mac 同步查看事件、主题和 Agent 内容。真实录音与运行凭据保留在私有环境，详见 [公开仓库说明](docs/public-repository-policy.md)。

截至 2026-10-26 的近期更新：

- [事项重要程度与关注偏好反馈](docs/xinlika-interest-feedback-2026-10-26.md)：iPhone 0.3.10（29），支持重要／不重要、撤销、筛选与持久重试；Agent 参考显式反馈，不冒充模型训练或真实偏好效果已通过。
- [内部片段归属修复与新增实录验证](docs/xinlika-v6-followup-2026-10-24.md)：修复重复归属，自动取回卡上原声，新增跨录音正例及双端纠正同步；仍保留首页准入偏松和非还原纠正关联稳定性未通过的限制。
- [共享云端实际启用](docs/xinlika-v6-cloud-2026-10-24.md)：v6 已进入新增来源处理链路，复用既有上传与 ASR 缓存，采用有处理锁的平滑交接。
- [录音入口与恢复边界](docs/xinlika-capture-entry-2026-10-25.md)：采集操作和恢复状态的后续修复。

下列记录保留各阶段当时的状态与验收边界，不能把旧阶段的开关描述当成最新部署状态。

新增 [事件边界、跨对话关联与证据成本修复](docs/xinlika-event-links-2026-10-24.md)：开发已知正负例 3/3、新增独立参照 5/5；同份优化证据的输入 tokens 减少 62.4%。验收版本注册为 `xinlika-events-v6`，后续实际启用见上方云端报告。

新增 [Harness² 版本化 Skill 与冻结实录优化](docs/xinlika-harness2-integration-2026-10-24.md)：官方框架隔离运行完成，独立八项检查由 7/8 到 8/8，留出回放 tokens 增加 14.3%。开发集仍有误归并及跨对话漏关联，候选未启用；没有重复 ASR 或改动录音服务。

新增 [AI Passport 开发环境与可行性评估](docs/ai-passport-feasibility-2026-10-23.md)：开放固件可用于验证离线重点标记，全天独立录音仍受存储与续航约束；独立硬件仓库、构建入口和验证边界见报告。

新增 [iPhone 本人声纹与全天新封批声音标签](docs/xinlika-allday-voice-2026-10-21.md)：云端独立 sherpa-onnx worker 已上线，三段真实登记及独立口述／视频播放对照已完成。声纹仅作归属线索，播放可靠分类、本人声音回放及通勤场景仍待实测。

基于 CB08 录音卡、Mac 原生应用与可替换服务的开源 Personal Agent。仓库保留既有深脑客户端与导入工具。

当前新产品名为 **心力卡（Xinlika）**：基于 CB08 录音卡的开源 Personal Agent 应用。独立 `HeartballLab` 原型已接上持续录音、重点单独整理、voxgate 转写，以及基于 LangGraph 的记忆／主动反馈／用户纠正链路，不切换既有深脑生产路由。产品以 AI 自动整理、按需纠正为方向，自动语义事件、跨对话主题与无需逐条确认的 Agent 问答已接入 0.4.0。事件按录制证据展示时间，未知录制时间不使用处理时间代替。先读 [心力球真实反馈与产品取舍](docs/heartball-user-evidence-and-product-reset-2026-10-21.md)、[Mac 界面与验证边界](docs/design/xinlika-today-taste-2026-10-21.md)及[运行方式](docs/heartball-processing-loop-2026-10-21.md)；启动入口为 `python3 scripts/run-heartball-lab.py`。

最新交付：[iPhone 0.3.4 同文件实时恢复与自动补齐](docs/xinlika-bluetooth-recovery-2026-10-21.md)。复查厂商 SDK 后，CB08／V1.0.0 用 `01 01` 接回已有录音，两轮真实范围往返（含 App 后台）观察到恢复，未停止或重建卡文件。保存后自动核对并上传原声，长缺口自动补转写，不再需要手点核对。实时仍有断连缺口，极短尾边界的语义修复仍未完成。140 项 iOS 测试与 60 项 Core 自测通过；云端 r3 同时修复短录音正常空文字被误报 500。此前直连云端、两端纠正和 Mac 0.4.4 验收见 [上一轮记录](docs/xinlika-iphone-cloud-2026-10-21.md)，共享部署基础见 [服务端](docs/xinlika-shared-server-2026-10-21.md)。

[0.4.3 完整的今天与可展开会议](docs/xinlika-today-2026-10-21.md)：今天按录制日期完整取数，会议／对话默认折叠，展开全部事项与重点；历史记录不再混入，也不受最近 100 条预览上限影响。[0.4.2 事项归并与集中聊天](docs/xinlika-event-density-2026-10-21.md)及 [0.4.1 真实闭环报告](docs/xinlika-real-loop-2026-10-21.md)证据保留；全天连续录音的自动会议边界识别尚未实现，同一议题跨录音关联的漏报仍未解决。前版实现见 [0.4.0](docs/xinlika-semantic-workspace-2026-10-21.md)。
新增 [voxgate 分钟级转写验证](docs/voxgate-minute-batches-2026-10-20.md)：独立本机 API，测试 1/5 分钟 Ogg 文件，包含长会话丢文的分段补丁、复现脚本及当前 Swift/Ogg 接入边界。个人 Agent 按分钟更新上下文，不要求逐字实时转写。

[真实录音卡验证](docs/voxgate-real-audio-2026-10-21.md)：早期两段试听是背景视频／游戏解说；历史候选 `142643` 原文件 120–420 秒已由用户确认为多人场景，补测发现转写对切段位置敏感，噪声及漏字验收尚未通过。分钟上传可运行，正式上传链路保持原配置。

新增独立的 [CB08 实时采集验证原型](docs/cb08-realtime-prototype-2026-10-20.md)：`swift build --product cb08-probe`，显式选择设备后验证断连恢复与三小时切段，音频只落本机，保留卡上文件。硬件资料优先交叉核对 [声云公开 SDK](https://github.com/SonicloudTech/sonicloud_opensdk)。

## 目录

新增 [声音来源与活动归集](docs/xinlika-sources-and-activities-2026-10-21.md)：一天按活动容纳多个事项，会议与重点可展开，跨对话项目关联继续独立；真实会议账本已进行模型验证。sherpa-onnx 的 VAD、声音标签和匿名声纹做了本机实测，尚未启用本人归属或自动丢弃。服务端 r8 已支持绑定原声哈希的辅助声音观察，标签接入不重复转写；全天自动打标签及本人声纹仍待验证。客户端改动已构建，手机未安装。

新增 [Personal Agent 处理循环与服务端 r4](docs/xinlika-personal-agent-2026-10-21.md)：参考 Omi、OpenClaw、Hermes 的处理逻辑，接入观察、生成、独立复核与纠正回流，普通记录不需要逐条确认。115 项测试通过，真实会议文字的本地及云端模型验证均选择静默；有价值主动反馈质量仍待日常验收。新增一致备份与隔离恢复实测。

- `Sources/LuyinbiCore/` — 引擎层：蓝牙协议、同步、音频、深脑客户端
- `Sources/LuyinbiApp/` — 界面层：内容库 / 设备 / 录音 三块
- `iOS/` — iPhone MVP：登录、可恢复 BLE 下载、后台文件上传、本地记账与分析结果
- `project.yml` — iOS Xcode 工程的单一真源，用 XcodeGen 生成 `Shennao.xcodeproj`
- `Sources/luyinbi-cli/` — 命令行，用来单独验链路的某一环
- `Sources/*SelfTest/` — 自检，不依赖蓝牙硬件（真机蓝牙在开发机上受 TCC 限制跑不起来）
- `python-importer/` — 最早的 Python 版，仍可用，与 Swift 版共用清单与幂等键
- `icon/make-icon.swift` — App 图标，矢量绘制后导出整套尺寸，不依赖设计工具
- `scripts/build-local-app.sh` — 打成能双击打开的 `.app`（ad-hoc 签名，仅本机/内部分发用）

## 链路

设备广播 → 连接 → 列文件 → 分片下载裸 opus（40 B = 20 ms）→ 封 ogg → 落盘记账
→ 六步上传深脑（建会话 / 票据 / PUT COS / 分片完成 / stop / finalize）
→ 服务端 ffmpeg 归一化 + 腾讯 ASR → 转写 → 自动排分析

## 几条踩过的硬规矩

- **下载完成 ≠ 设备说完成。** 收到的字节必须与设备报的大小一字不差、且能被 40 整除。
  曾经只认 `endCode == 0`，结果一条三小时会议只收到三分之一就被当成完整录音推走。
- **录制期间不压缩。** 实测 SIGKILL：裸 PCM 救回 638 秒，AAC 读出 0.00 秒。
- **三小时是既有导入策略的分段阈值，不能当作本台设备已证实的硬上限。** 本台 CB08 在充电 Mac 长测中同一文件录制约 3 小时 20 分钟，未发生物理切段，详见实时采集报告。跨文件合并仍需文件、时间和音频证据，不凭时长自动推定连续。
- **深脑是国内服务器，不走系统代理。** 跟随代理 2320ms，绕开 123ms，大文件分片直接断。
- **真实录音时刻在文件名里。** 不传 startedAt 的话深脑记的是上传时刻。

## 跑测试

```bash
swift build
for t in CoreSelfTest CleanupSelfTest AuditSelfTest VoiceSelfTest; do swift run -q $t; done
```

## iPhone / TestFlight

1. 将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填写生产的公共客户端配置。该文件不进 Git，严禁使用 Supabase service-role key。
2. 运行 `xcodegen generate`，用 Xcode 打开 `Shennao.xcodeproj`。
3. 连接并解锁 iPhone，选择 `Shennao` scheme 后直接 Run。
4. 发 TestFlight 时先运行 Release Archive，再用 `Config/ExportOptions-TestFlight.plist` 上传 App Store Connect。

iOS 与 Mac 共用 `Sources/LuyinbiCore` 中的协议、BLE、Ogg 和深脑上传实现；iOS 的下载检查点、后台传输、任务调度和界面独立维护。

已在共用 BLE 核心加入连接后自动校时：服务就绪后发送手机/电脑当地公历时间，断线重连时再次发送。硬件不返回校时应答，实际屏幕效果待安装新版后真机验收。见 [自动校时说明](docs/device-time-sync.md)。

0.2.0 (11) 合并深脑云端历史与录音卡本地记录：直接上传及其他设备上传的分析会出现在「记录」，按会话/转写 ID 去重，云端目录只读同步，不触发重新上传或分析。见 [云端历史与验证](docs/ios-0.2.0.md)。

0.1.9 (10) 修复保存后找不到短录音：状态刷新不再打断文件列表同步，暂停同步时仍登记保存文件，提供“查看录音”直达入口，保留短录音确认和额度保护。已在卡上找到用户的 22 秒录音。见 [修复与验证](docs/ios-0.1.9.md)。

0.1.8 (9) 修复 CB08 / V1.0.0 的 App 开始录音与结束保存：改用真机验证可用的 `1-0 / 1-2`，独立查询状态确认结果，断连后同一录音文件继续保留。界面提供开始、结束保存和状态；该固件暂停状态回报不可靠，暂不开放继续按钮。见 [修复与验证](docs/ios-0.1.8.md) 和 [原始诊断](docs/ios-0.1.7.md)。

0.1.5 (6) 增加长录音、批量录音与旧队列的导入确认，支持持久批量忽略和统一暂停下载、上传。首页以结果为主，设备信息按需展开。这些保护继续保留，见 [导入保护与验证](docs/ios-0.1.5.md)。此前的自动连接与恢复实现见 [0.1.4 MVP](docs/ios-0.1.4.md)；真实硬件耗电和额度收益仍需用户验收。

0.1.3 (4) 已接入原生记录列表、概览卡片与 Markdown 长文阅读器，支持目录、阅读位置与辅助字号；已覆盖安装到用户 iPhone 16 Pro 并启动，待用户体验验收。构建使用 Xcode 26.5，Markdown 依赖固定为 0.8.0。见 [实施与验证](docs/ios-0.1.3.md)。

0.1.2 已安装开发签名测试包，完成一轮锁屏下载与完整性真机验证；新增录音的后台上传、弱网和系统终止场景仍待验收。见 [0.1.2 实现与验收记录](docs/ios-0.1.2-validation.md) 和 [后续规划](docs/ios-0.1.2-plan.md)。开发签名安装不等于 TestFlight 已发布。

0.1.1 历史修复与测试命令见 [iPhone 稳定性计划](docs/ios-0.1.1.md)。

## 云端 iPhone／Watch 构建

本机无需安装完整 Xcode。GitHub Actions 执行核心测试、iPhone／Watch 构建和模拟器验收；TestFlight 单独手动触发，需配置 Apple 签名材料。步骤与真机验收清单见 [云端构建](docs/cloud-apple-builds.md)。

本地统一检查：`scripts/setup-dev.sh` 后运行 `scripts/check-project.sh`。

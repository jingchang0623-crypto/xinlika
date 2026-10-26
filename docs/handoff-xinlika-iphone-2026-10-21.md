# 新会话交接：直接实现心力卡 iPhone 版

> 状态更新（2026-10-21 17:04 后）：用户已在 iPhone 新会话明确授权“现在保存并交给 iPhone 测试”。Mac 本轮已正常保存，参考核对与 36 批处理完成，旧 `cb08` heartbeat 收尾后暂停。见 `docs/xinlika-continuous-2026-10-21.md` 与其最终 result.json。以下“正在运行”是交接启动时约束的历史记录；后续录音卡测试由 iPhone 会话负责，勿按旧状态重新连接或开始 Mac 录音。

用户在 2026-10-21 明确要求：在新会话直接开始开发，复用现有工程，先跑通持续采集、锁屏后台、断连补传和自动整理闭环。当前 Mac 持续录音继续运行，不能干扰；需要连接手机或操作录音卡时再告诉用户。不要停在调研或只给方案。

## 工作目录与执行边界

- 实际目录：`<PROJECT_ROOT>`。项目保存路径 `<LOCAL_HOME>/Documents/ChatGPT/深脑 app` 已核对指向同一目录。
- 当前分支 `codex/iphone-testflight-mvp`，存在大量未提交的用户与本聊天改动。就地复用、保留所有改动；用户未请求 worktree，不复制一份遗漏未跟踪文件的工程，不自动提交/推送或发布。
- 遵守用户 AGENTS 与 `<LOCAL_HOME>/.codex/RTK.md`。浏览器一律先读并使用 ego-browser skill；SwiftUI 修改先读 swiftui-expert-skill。设计沿用已有简洁原生样式及用户提供的心力球截图，不增加冗长说明和逐条确认。
- 原声、转写、模型正文、密钥和检查点只放忽略的 `.build`；配置只读取本地私有文件，不打印或在交接中复制密钥。普通记录允许自动整理，用户纠正用于修正结果，不是所有记录必须确认的门槛。

## 最高优先级：不要干扰正在运行的 Mac 录音

- 运行信息：`.build/xinlika-continuous-20261021/run.json`，session `b999cd96-bd44-43ac-beeb-2417e1c39663`。
- 约 2026-10-21 16:29 Asia/Shanghai 开始，本轮上限 86400 秒，60 秒封批；卡文件 `note20261021-162911.opus`。采集证据 `.build/heartball-lab/captures/<session>/probe/`。
- 心力卡本机服务 `127.0.0.1:18766`；连接描述及 token 在 `.build/heartball-lab/runtime.json`。处理配置 `.build/heartball-lab/processing.json`，ASR 桥接 `127.0.0.1:18765`，服务端模型当前为 `intern-s2`，私有配置已有可调用接口。
- 本聊天 heartbeat `cb08` 正以 5 分钟间隔巡检本轮。新会话不要停用、修改或另建重复录音巡检，不接管它的收尾职责。原聊天负责这轮观察。
- **不得连接/扫描/列目录/控制当前录音卡，不重启 Mac 服务、ASR、采集进程，不重发 start/resume，不停止或删除卡文件。不得用本轮活跃数据库实例化新的 Engine——初始化会将活跃会话标为 interrupted。**
- 只读状态可运行 `python3 scripts/cb08-probe-status.py .build/heartball-lab/captures/<session>/probe`，也可私读 token 查询 `/v1/state`、`/v1/agent`，但不要输出正文/凭据。
- 编译 iOS 使用独立 DerivedData。不要运行会重建、替换 Mac 正在执行的 `.build/debug/cb08-probe` 或重打包 Mac App 的全量构建/启动脚本。新服务验证使用隔离临时目录和新端口，保持 Mac API 与其账本不变。
- 可先做代码、模拟器、协议/持久化测试和独立服务集成。USB 连接手机本身不要求切走录音卡；需要手机安装或蓝牙真机试验时告诉用户。**录音卡从 Mac 交给 iPhone 必须等用户明确同意该交接时机，不能为测试擅自打断当前录音。**

## 现有可复用工程

### iPhone 基础

`project.yml` 是 XcodeGen 单一真源；现有 `Shennao` target、iOS 17+，bundle `com.zaowuyun.shennao`，旧版本 0.2.0。基于它演进产品“心力卡”，不是只给旧深脑换名字。不要擅自更换 bundle 或卸载用户 App 丢失容器。

- `iOS/AppModel.swift`、`ShennaoiOSApp.swift`、`RootView.swift`：旧 App 生命周期与界面；当前录音监控循环主要挂在前台 scene task，不能据此宣称锁屏持续采集已做好。
- `Sources/LuyinbiCore/BLEClient.swift`：CoreBluetooth 封装，AE22/AE23 分离解析、状态恢复、`onFrameObservation`、通知订阅状态。普通旧 App 默认丢弃实时音频；必须显式接收并持久化，不能以现有“控制录音”冒充持续实时采集。
- `Protocol.swift`、`FrameParser.swift`、`Commands.swift`、`RecordingControl.swift`、`RecorderButtonHandshake.swift`、`OggWrap.swift`：共享协议、命令、握手和封装。`project.yml` 目前显式列共享文件，要补必要依赖而不是假设全包已引入。
- `iOS/DeviceSyncCoordinator.swift`、`Ledger.swift`、`DownloadCheckpoint.swift`：恢复意图、账本与分片下载。
- `iOS/BackgroundUploader.swift`：后台文件传输。现有 DeepBrain 六步上传协议与心力卡处理服务不同，不能只换 apiBase。
- `iOS/Info.plist` 已声明 `bluetooth-central`，**声明不是锁屏、被系统挂起/终止后的实测证据**。
- `iOS/Tests`、`UITests`、`RecorderHardwareProbe.swift` 可复用。以前 iPhone 16 Pro 的安装报告是历史证据，不代表现在已连接，也不代表新链路通过。

### Mac 与处理端

本机心力卡 0.4.3 已贯通采集、独立重点、voxgate 转写、LangGraph 处理、自动事件、记忆问答与纠正。源代码可复用，但 Mac 控制与手机控制必须解耦。

- `Sources/CB08ProbeSupport/` 与 `Sources/cb08-probe/main.swift`：落盘、身份、前后台握手及恢复证据；提取可复用逻辑，不在手机上依赖 CLI 子进程。
- `Sources/LuyinbiCore/HeartballClient.swift`：API 模型/客户端；当前硬限制 `http://127.0.0.1`，且 `/v1/capture/start` 控制的是 **Mac 设备**。iPhone 不能调用这个接口来表示自己开始收音，更不能简单把绑定地址公开到公网。
- `scripts/heartball_store.py`：逻辑会话、流、60 秒批次、重点、哈希、幂等账本；`heartball_agent_store.py`：策略、任务、文档/记忆、纠正；`heartball_processing.py`：ASR/模型适配与持久工作流。
- `heartball_organization.py`、`heartball_event_merge.py`、`heartball_topics.py`、`heartball_day.py`：事件、跨批归并、主题回查、当天完整投影。
- 固定复用依赖见 `requirements-heartball.txt` 和 `docs/heartball-third-party-components.md`：voxgate、LangGraph 1.2.16、SQLite Checkpointer 3.1.2、OpenAI SDK 2.54.0、Pydantic、HTTPX。Omi/OpenMuse 是架构参考，不是整套已移植。用户要求复用开源及另一调研会话 （私有调研会话） 的成果，优先已有代码/文档，不重写 ASR 或再堆一套记忆框架。

## 直接推进的第一条 iPhone 闭环

1. 在现有工程落实可持久恢复的手机采集协调器。订阅实时音频后握手、空闲时校时并新建录音，保留卡上录音。后台接收、队列有界、原始包及时落盘；音频时刻来自实际采集证据，不能用服务收到请求/处理完成时刻代替。
2. 手机持久账本区分逻辑会话、物理卡文件、连接流、批次、内容哈希、接收区间与断连缺口。默认 60 秒封批、最大 300 秒、结束提交尾段。独立重点使用逻辑范围，结束重点不停止硬件。
3. 设计并实现手机上传入口/适配，复用现有 ASR 与 Agent 工作流；上传重试幂等，提取失败不重复转写。**断网待传**与**蓝牙断连漏采**是两种恢复：卡上补录仅在文件身份、大小、结束码确定且设备可安全读取后对齐补齐，不能简单把重连后的声音接上就声称补回了中间内容。
4. iPhone 今天页接当天已有全部事项，会议/对话折叠，普通事项自动整理，重点独立；主题及“记忆和聊天”复用同一服务结果与纠正规则。不要一分钟造一个主题，不为普通记录增加逐条确认。
5. 先跑隔离服务 + 模拟器/协议测试，再按需请用户接手机。真机覆盖亮屏、锁屏、切后台、无网/恢复、出蓝牙范围/返回、App 重启、重点与尾段。以真实录音及卡上参考做身份、时刻、内容范围与重复检查；模拟器、合成文本或任务成功不算后台采集/语音准确率验收。

手机外出需要可访问的服务。目前没有已指定的云服务器/公网部署授权或地址。先实现服务适配与可配置的认证连接、独立本机/局域网集成和离线队列，不因未指定云机器停下开发；不要伪称已上云或擅自开公网端口/传密钥。确实需要云资源时，再提出具体缺少的地址/部署信息。

## 硬件与产品已知事实

- 本台 CB08 已在 Mac 同文件记录约 3 小时 20 分钟，未观察到物理切段；三小时不是已证实的硬上限。跨切段、丢样及尾包仍需证据，不能自动拼接或称零丢样。
- 正常厂商握手试次接到了卡上起始编码；历史停止时实时流相对卡文件少 20–40 毫秒，保留了参考证据，不能保证词级精确边界。
- 机身黑屏第一次短按可能仅唤醒；亮屏短按会停止/保存。不同回应值、拒绝/不回应没有变成可靠无中断书签；一次 continue 试次虽显示仍录音，不能当作已验收标记手势。普通/电话拨动计时仍增加，但未建立可靠重点事件。第一版采用 App 重点按钮，不伪造硬件重点键能力。
- 设备校时只在确认空闲、准备新录音时进行；协议没有可依赖的 RTC 读回 ACK，以新文件名验证新起点，不影响已有录音。
- Mac 的 peripheral UUID 不能直接假设为 iPhone 上同一 UUID；在手机核对设备身份。
- 会议里有远端与其他发言者，不能把所有句子归为用户本人承诺；保留背景播放/来源纠正边界。
- 跨录音同主题正向关联仍漏报；同录音跨分钟归并已有真实结果。会议容器用明确共同来源，全天持续流中的自动会议起止识别尚未实现。界面折叠不等于语义归并或这个问题已解决。

## 先读这些证据

- `docs/xinlika-continuous-2026-10-21.md` 与 `docs/validation/xinlika-continuous-2026-10-21/startup.json`：正在运行的本轮。
- `docs/xinlika-today-2026-10-21.md`、`docs/xinlika-event-density-2026-10-21.md`：0.4.3/0.4.2 最新行为及 74 项 Python 测试（不等于 iOS 后台通过）。
- `docs/xinlika-real-loop-2026-10-21.md`、`docs/cb08-dual-mode-recording-2026-10-21.md`、`docs/cb08-realtime-prototype-2026-10-20.md`、`docs/device-time-sync.md`：真机结果与未通过项。
- `docs/heartball-third-party-components.md`、`docs/heartball-processing-loop-2026-10-21.md`、`docs/ios-0.2.0.md`：复用、处理协议与原 iPhone 基础。

用户已授权开始实现和必要的本机验证，不反复询问例行实现选项。需要手机连接、录音卡交接/按键或其他真实外部输入时，给出具体单步操作；在等待时继续独立开发。不要为了保持进度把未知项写成通过。

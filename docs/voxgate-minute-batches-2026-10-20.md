# voxgate 分钟级转写验证与接入方案

> 2026-10-21 更新：[真实录音卡验证](voxgate-real-audio-2026-10-21.md) 发现识别切段敏感性，当前没有通过正式切换验收。下方合成样本成绩不能代表真实多人/噪声效果。

本轮按用户修正后的方向验证：个人 Agent 使用分钟级上下文，优先每 60 秒上传一个音频片段，可延长到 300 秒；不要求逐字实时出字。这里的时长是初始建议，不是已经修改了正式 App 的录音策略。

## 已运行的服务

- 上游：[WEIFENG2333/voxgate](https://github.com/WEIFENG2333/voxgate)，固定提交 `da98bb5ff9ce913b4317081a00e9e0c51f080edf`。
- 当前部署：本机 Mac，`http://127.0.0.1:18765/v1`，启用随机 Bearer Token，单请求并发；尚未部署到远端云服务器。
- 接口：`POST /v1/audio/transcriptions`，multipart，`model=voxgate`，`response_format=json`，不传 `stream=true`。
- 默认 Go/PCM 上游构建，解码依赖系统 FFmpeg；手机到自有服务仍传压缩的 Ogg/Opus。
- 源码、二进制、配置、凭据及合成音频全部在被 Git 忽略的 `.build/voxgate-evaluation/` 中。
- 研究服务通过豆包输入法的非公开云端接口识别，不是本地离线模型。上游项目将用途限制为学习研究。

## 分钟文件发现的丢文问题

未经修改的服务按 30 秒进行内部识别。16.36 秒合成短音频可返回完整文本，耗时 3.484 秒；但更长的文件出现 HTTP 200 却丢失大量内容。

针对单个 30 秒 WAV 的本地协议记录显示：前半段返回文本从开头逐步增长，随后一条结果的起点移到约 22.8 秒，文本重新从该位置开始。voxgate 的 `transcriptState` 假定每个返回值始终是全量文本，只保留最后快照，因此前文被覆盖。这是本轮样本直接观察到的行为，不推断为所有输入、所有上游版本的固定时长限制。

未用猜测拼接 partial 的办法修复。新增本地小补丁，让 HTTP 服务透传已有的识别分段长度，并让分段阈值跟随该长度。本轮使用 **15 秒内部识别段**，规避已观察到的长会话重置；60/300 秒上传文件的产品节奏不受影响。

补丁：[voxgate-file-chunks.patch](../scripts/patches/voxgate-file-chunks.patch)。包含 HTTP JSON/SSE 分段回归：一份 2.5 秒音频配置 1 秒识别段，必须返回三个片段的完整拼接，防止低于原 30 秒阈值时配置不生效。上游原有 97 项测试加本轮回归共 98 项通过。

## 实测结果

素材为 macOS `say` 的 Tingting 合成语音：十段不同中文内容，每段归一为 30 秒。包含人物、项目、同步、记忆归属及末尾校验短句；不是循环拼接同一句，也未使用个人真实录音。

| 输入文件 | 内部识别段 | 两次处理耗时 | 参考/返回字符 | 归一化字符错误率 |
|---|---:|---|---|---:|
| 60 秒 Ogg | 原版 30 秒 | 9.805 / 9.455 秒 | 239 / 36 | 86.19% |
| 300 秒 Ogg | 原版 30 秒 | 45.012 / 47.321 秒 | 1160 / 150 | 87.59% |
| 60 秒 Ogg | 补丁后 15 秒 | 9.819 / 9.893 秒 | 239 / 238 | 0.84% |
| 300 秒 Ogg | 补丁后 15 秒 | 48.191 / 48.016 秒 | 1160 / 1160 | 0.43% |

错误率按 Unicode 归一化、忽略标点/空白、统一大小写后的字符编辑距离计算。它不能评价标点、说话人归属或真实会议质量。`云杉计划` 被识别为 `云山计划`，因此精确短句校验只有 3/4 和 19/20 命中；所有主题正文与末尾均已保留，但仍有同音错误、个别分段边界漏字和不自然断句。

60 秒 WAV 为 1,920,044B，16kbps CBR Ogg 为 124,824B；300 秒分别为 9,600,044B 和 623,304B。设备基线裸 Opus 是 40B/20ms，对应约 120KB/分钟、600KB/五分钟，不应为了调用 API 在手机上扩大成 PCM 再上传。分段减少单批等待和失败重传范围，不减少相同总音频量的 BLE 字节；实际蓝牙吞吐和后台耗电仍需真机量测。

上述耗时包括本机 HTTP 调用、解码和上游识别，不包含录音攒批等待、BLE 下载或手机到云端的网络上传。单请求串行测试不能证明多人吞吐或全天稳定性。

结构化证据：[results.json](validation/voxgate-minute-batches-2026-10-20/results.json)。完整请求结果及临时诊断留在 `.build/voxgate-evaluation/results/`；原始协议诊断含凭据，只留在权限受限的 runtime 目录，不提交。

## 复现

以下命令从本项目根目录运行。需要 Go、Git、FFmpeg；生成合成音频另需 macOS `say` 的 Tingting 声音。没有自动下载或发送任何真实个人录音。

```bash
python3 scripts/voxgate-local.py setup
python3 scripts/voxgate-local.py serve
```

`serve` 前台运行，按 Ctrl-C 停止。在另一个终端检查和测试：

```bash
python3 scripts/voxgate-local.py check
python3 scripts/evaluate-voxgate.py fixtures
python3 scripts/evaluate-voxgate.py benchmark --seconds 60 300 --formats ogg --runs 2
```

setup 固定上游提交、检查并应用本地补丁、构建服务，重复运行不轮换已有本地密钥。服务配置位于 `.build/voxgate-evaluation/runtime/config.json`，权限 0600；认证缺失或错误均已验证返回 401。基准默认在 HTTP 失败、空转写或合成样本字符错误率超过 15% 时退出失败，并保留每个请求的耗时、全文和漏句诊断。这个阈值只是实验闸门，不是产品验收标准。

## 当前 Swift/Ogg 路径验证

新增独立的 Swift 验证工具，直接编译当前项目的 `OggWrap.swift`。它可将合成的 40B/20ms 裸 Opus 封成 Ogg，经原生 URLSession 上传给 voxgate，不替换 App 的深脑配置。

```bash
swiftc Sources/LuyinbiCore/OggWrap.swift scripts/voxgate-smoke.swift -o .build/voxgate-evaluation/bin/voxgate-smoke
.build/voxgate-evaluation/bin/voxgate-smoke .build/voxgate-evaluation/runtime/config.json .build/voxgate-evaluation/fixtures/batch-60s-cb08-raw.bin .build/voxgate-evaluation/results/swift-cb08-60s.json --cb08-raw
```

输入来自 FFmpeg 合成编码后提取的定长包，只验证容器与 HTTP 兼容，不等同于真实 CB08 音频或 iOS 锁屏验收。残缺包会在上传前失败，不调用当前 `OggWrap.wrap` 的尾包裁剪行为。

实测 60 秒/120,000B 合成裸包，经共享封装变成 124,715B Ogg，HTTP 200，耗时 10.060 秒；归一化返回 238 字，字符错误率 0.84%。41B 残缺输入已验证在上传前拒绝。这证明当前 Swift 封装路径和 API 可以连接，不代表正式 App 已切换或真实硬件已通过。

## 如何接入当前项目

建议流程：CB08 → Swift 采集与持久化 → 60–300 秒音频批次 → 后台文件上传 → 自有持久任务队列 → voxgate 15 秒内部识别 → 稳定转写 → 事件/记忆/Agent。

### 采集节奏与上传节奏分开

1. **设备到手机**：可以接收持续到达的 Opus，并在本地封成分钟文件。这不要求实时 ASR，也不要求设备每分钟停止录音。`BLEClient` 已有观察入口，独立 `CaptureJournal` 原型验证了落盘；正式 App 尚未切到这条持续接收路径。
2. **手机到服务端**：建议先按 60 秒封批，网络/电量策略允许合并到最多 300 秒；在采集会话结束时提交不足一分钟的尾段。原始数据先保存，上传失败不影响后续采集。
3. **如果希望每隔几分钟才连接设备下载**：必须先验证当前固件能否安全导出正在录制文件的已完成部分。不能把“每分钟停止/重开录音”当作默认实现，也不能仅凭 ASR 成功认定这个硬件能力已解决。

已有断连实验观察到设备不会自动补发断连期间的音频。重连后的第一批应保留缺口，之后用卡上归档修复；不能把两端直接拼接成一段连续时间。Ogg 切段还需核对 Opus 起始解码状态、预跳过和时间偏移。

### API 与任务边界

voxgate 当前是同步识别接口，没有本项目所需的持久任务、组织权限和幂等入库。建议将它作为后端 worker 的 ASR 适配器，外层提供：

- `POST /api/audio-batches`：确认音频与元数据已持久化后返回 202 和 `batchId`。
- `GET /api/audio-batches/{batchId}`：区分 queued、transcribing、ready、failed，返回稳定文字、来源范围和错误；任务状态在服务重启后保留。
- 批次携带 `captureSessionId`、`chunkIndex`、采集起止时间、样本范围/缺口、内容哈希及用户/组织身份。幂等键绑定用户、逻辑会话和批次序号，重试复用任务；同批次更换内容应报冲突或显式生成修订。
- ASR 成功后再排事件抽取任务，抽取失败不重新上传或转写。保持已采集、已上传、已转写、已理解的进度分离。

已有 `BackgroundUploader` 的文件落盘、系统后台上传与回执机制值得复用，但服务器需要新的任务接收契约。现有 `DeepBrain.upload()` 是建会话、COS 票据、stop/finalize 的六步协议；voxgate 不实现它，不能只改 `apiBase`。

Mac 与 iOS 后续可以共用一个音频批次/处理服务抽象。短期保留现有深脑路由，同时在独立实验入口提交批次；验证完整链路后再决定正式切换。语义事件可以跨音频批次合并，不把五分钟文件硬当成一个完整话题，也不把每段临时文本直接写成长期记忆。

本轮没有修改正式 App 的自动上传目标、设备录制状态、卡上文件、深脑额度或生产数据。尚待验证：真实 CB08/多人/噪声、跨片段句子边界、iOS 锁屏采集与分钟封批、断网补传，以及远端 Linux 部署。正式使用前还需解决非公开服务的使用授权和可替换识别后端。

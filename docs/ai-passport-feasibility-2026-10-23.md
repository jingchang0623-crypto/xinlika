# AI Passport：心力卡硬件可行性与开发环境

日期：2026-10-23。范围：读取教程、准备本机开发环境、构建官方硬件测试基线、评估接入方案。本轮没有实现心力卡专用固件，也没有向设备写入固件、擦除 Flash 或改变心力卡现有服务。

## 判断

**可以作为心力卡的可编程采集与交互原型，值得验证持续录音中的离线重点标记；目前不足以认定能替代 CB08 承担全天独立录音。**

优势是固件、按键、屏幕和音频管线均可控制。CB08 当前受限于闭源固件的“短按保存并停止”，在 AI Passport 上可以设计成“重点开始／重点结束，总录音继续”。这仍需实现持久标记和音频存储后实机验收；有开放源码不等于已经具备该功能。

建议以 **AI Passport 采集与标记 → BLE → 心力卡 iPhone/Mac → 原声存储、转写、主题、记忆与 Agent** 为目标。不要把 ASR、大模型或现有完整 Agent 搬进 ESP32-C3。

## 阅读的资料与证据等级

- [用户指定的教程](https://ai-passport.folotoy.cn/guides/create-a-play-with-agent/)：完整项目开发、复用 BSP、验证合并镜像、最后才做实机测试。
- [官方产品页](https://ai-passport.folotoy.cn/)：60 × 95 × 8.5 mm、50 g、500 mAh。网页正文快照保存在本项目 `research/ai-passport-2026-10-23/`，仅保存公开 `main` 内容。
- [官方源代码](https://gitee.com/FoloToy/ai-passport)：本机检出提交 `a06235e4c94361e3f8a2d498930254101718acae`。核对了 `AGENTS.md`、工程／硬件指南、`bsp_pins.h`、音频／按键 BSP、音频／BLE demo、分区表和依赖锁。
- [社区 BLE 语音上行经验](https://github.com/folotoy/ai-passport/blob/main/docs/reference/shinku-chen/ble-voice-uplink-and-pairing.zh_CN.md)：作者报告一台设备＋安卓手机上完成 Opus 上行和一轮 AI 对话；约 3 KB/s、16 kHz 单声道、60 ms 帧、complexity 0、DTX。**这是社区实测记录，本轮未复现**，未覆盖 iPhone、长时会话、距离或续航。
- [社区持续 BLE 连接功耗经验](https://github.com/folotoy/ai-passport/blob/main/docs/reference/shinku-chen/ble-active-idle-power.zh_CN.md)：提示自动浅睡可能破坏该项目的 BLE 链路；挂起 codec 的空闲策略不能用于持续采集中的麦克风。没有可直接用于全天续航承诺的电流实测。
- [Pocket Intercom 源码入口](https://github.com/Shinku-Chen/ai-passport/tree/feature/openclaw-intercom)及[安卓 App](https://github.com/Shinku-Chen/ai-passport-openclaw-android)：后续可提取协议与编码模式，不能把安卓配套应用当作现有 iPhone 支持。

## 硬件与现有代码能支持什么

| 能力 | 已核对事实 | 对心力卡的影响 |
| --- | --- | --- |
| 主控和内存 | ESP32-C3，8 MB Flash，无 PSRAM | 需限制缓冲、任务栈和字体，不能整段录音常驻 RAM |
| 收音与播放 | ES8311，I2S；BSP 提供阻塞式 PCM 读写 | 可以做流式采集；现有 demo 只录三秒，约分配 96 KB，不能直接扩成全天 |
| 按键 | UP/DOWN/OK；有 PRESS、CLICK、DOUBLE、LONG、RELEASE 事件 | 可以自定义开始／结束重点；回调仅入队，不执行音频、Flash 或网络工作 |
| 屏幕 | 240 × 320 ST7789，支持背光控制 | 可显示录音状态、重点中、电量、断连和空间；中文需要独立字库覆盖检查 |
| BLE | 基线仅作不可连接广播 | 音频 GATT 服务、配对、分帧、确认、恢复、客户端均要新增或移植 |
| Wi-Fi | 基线是扫描示例 | 不能据此声称已有 Wi-Fi 上传；首版优先单独 BLE，减少 RAM 和配网复杂度 |
| 本地存储 | 默认只有 NVS、PHY 和 factory app，无音频文件系统分区 | 离线录音需另设数据分区和存储实现；不是开箱即用的录音卡 |
| 电池 | 500 mAh；CW2017 提供 SOC 和电压 | 电量读数不等于电流测量，持续收音＋编码＋BLE 的续航必须测 |
| NFC | 被动 NTAG213，无 MCU BSP 接口 | 可作静态入口，不能假设能动态写入录音或重点 |

硬件引脚与接口以 `components/bsp/include/bsp_pins.h` 和 BSP 实现为准。本轮未假设额外 SD 卡、外接存储或空闲引脚。

## 全天录音的两个硬约束

以下是容量／能量预算，**不是实测续航或实测编码质量**：

- 16 kHz、16 bit、单声道 PCM：32,000 B/s，24 小时约 **2.765 GB**。
- 按社区参考约 24 kbps（3,000 B/s）：24 小时约 **259.2 MB**，未加协议／容器开销。
- 即使把整个 8 MiB Flash 都假设为音频空间，24 kbps 也仅约 **46.6 分钟**；8 kbps 理论上限约 **2.33 小时**。实际还要占固件、NVS 和文件系统，远小于这个上限；低码率录音编码质量也未验证。
- 默认 app 分区跨度覆盖剩余 Flash，不代表已经存了 8 MB 固件，也不代表固件末尾未用区域可直接当文件系统使用。
- 500 mAh 想录满 24 小时，整机平均电流的理想上限约 **20.8 mA**，还未考虑电池有效容量和损耗。当前没有持续采集＋编码＋蓝牙组合下的仪器证据。

因此，“离线重点按键”与“离线原声永久保存”要分开。小容量日志可以离线保存标记，但若对应音频在断连期间丢失，重连后不能恢复重点原声。短缓存应有明确上限、满盘提示和缺口记录，不能静默覆盖后声称记录完整。Flash 写入还需评估磨损、断电提交和同芯片执行／采集并发时的停顿。

## 适配现有心力卡的工作

现有 iPhone、Core BLE 和部分服务端入口绑定 **CB08 的每帧 40 B／20 ms（2,000 B/s）**：例如 `scripts/heartball_mobile.py` 的字节对齐、批次时长、原声范围与 `.cb08` 存档。

AI Passport 社区参考使用可变长的 60 ms Opus 包，**不能把其数据直接塞入 CB08 接口，也不能直接套用字节偏移÷2,000 推算时间**。

后续实现应新增明确的 Passport 采集适配器，携带 codec、采样率、声道、packet length、帧序号、累计采样位置、设备／启动／会话身份；客户端封成可解码的容器或规范 PCM，再进入可识别来源的摄取接口。可复用转写后的活动、主题、记忆、问答与纠正链路，音频入口和原声核对需要单独适配。

重点协议应绑定会话和采样位置，按键起止都本地持久提交；时间校准只增加墙上时间映射，不改变已有采样区间。明确断连、丢包、开着重点时停止录音、重启后未闭合重点、重试去重和数据完整性。手机收到 BLE 通知的时间不能替代设备录音位置。

## 建议首个可验收版本

1. 设备显示“录音中／重点中／断连／存储已满”等真实状态。OK 短按切换重点，连续录音不停止；用单独、明确的长按手势结束总录音。息屏首按也处理重点，不能只唤醒。
2. 音频 worker 按块读取 I2S，先验证短时 PCM 完整性，再加入低复杂度 Opus；手机接收、保留原声并按采样时基每分钟封批。
3. 独立实现可查询的标记日志与短断连缓存，设计分区、校验、恢复、满盘行为及回传确认；不能用 NVS 高频逐音频帧写入充当全天存储。
4. 加入 Passport 专用 iPhone/Mac 适配器，先接入隔离测试数据，再复用现有服务端整理和 Agent；保留 CB08 正常路由。
5. 测试 30 分钟持续采集、重点切换、息屏、掉线／重连、App 锁屏、设备重启和断电恢复；用最终原声检查样本数／包序列与可听缺口。之后再做 8／12／24 小时电流和音频稳定性测试。

本轮仅构建硬件测试基线，没有交付上述心力卡专用版本。派生应用需要重新设计设备界面，不能以官方硬件测试菜单改名作为产品。

## 本机环境与复用入口

- 系统：本地 macOS arm64、zsh；已有 Xcode Command Line Tools 和 Homebrew Python 3.12.13。
- 独立硬件仓库：`<LOCAL_HOME>/Developer/ai-passport`，分支 `codex/xinlika-feasibility`。原心力卡仓库的既有修改保留。
- ESP-IDF 源码：`<LOCAL_HOME>/esp/esp-idf-v5.5.3`，官方 GitHub `v5.5.3` tag。tag 对象为 `b31fcc7a314a44ad992b58f589f7d1d8a4fadff6`，解析后的 commit 为 `2c211b236707889e8400c4dc5644dd5c4ee071e0`；子模块全部检出后源码状态干净。
- 工具与独立 Python 环境：使用 IDF 安装器管理的 `<LOCAL_HOME>/.espressif`，仅安装 ESP32-C3 所需工具。
- 新装主机工具：CMake、Ninja、ccache、dfu-util；libusb 和 Python 3.12 已存在。
- 实际激活版本：ESP-IDF `v5.5.3`、GCC `14.2.0 / esp-14.2.0_20251107`、CMake `3.30.2`、Ninja `1.13.2`、Python `3.12.13`。Homebrew 的 CMake 4.4.4 仍保留，IDF 子进程使用另装的推荐版本 3.30.2。
- GitHub 的 CMake 归档下载失败后，使用 `IDF_GITHUB_ASSETS=dl.espressif.cn/github_assets` 从乐鑫官方镜像安装，校验保持开启。完整构建首次在默认组件存储 `components-file.espressif.com` 失败，随后只对构建子进程设置 `IDF_COMPONENT_STORAGE_URL=https://components-file.espressif.cn`；入口脚本保留这个默认值，也允许显式覆盖。未改变锁定依赖。
- 五个必需 Skill 已链接到硬件仓库 `.agents/skills/`，`install_passport_skills.py --check` 验证五个发现路径均可读。当前聊天按对应源码执行 setup/build 流程；新开硬件仓库聊天时可从项目发现这些 Skill。
- 本机入口：`scripts/with-passport-idf.sh`，作用域仅限当前子进程，检查 IDF 版本；不编辑 shell 启动文件或全局 Git／代理配置。
- 只在新下载的硬件仓库修改了两个 macOS 兼容点：校验 actionlint 时优先用 `shasum`，以及 Apple ld 使用 `-dead_strip` 而非 GNU `--gc-sections`。未修改 BSP、音频固件行为或依赖锁。

从心力卡仓库运行：

```bash
./scripts/with-passport-idf.sh
./scripts/with-passport-idf.sh ./tools/validate.sh
./scripts/with-passport-idf.sh ./tools/validate.sh --firmware
```

脚本会自动进入独立硬件仓库。跨目录使用时传入脚本的绝对路径，也可用 `AI_PASSPORT_REPO`／`AI_PASSPORT_IDF_ROOT` 覆盖默认位置。

## 本轮验证

- **Host tests: PASS**：官方静态检查、workflow 校验、C 逻辑／故障注入与 Python 校验测试已通过，包含音频失败恢复、按键、BLE 与 Wi-Fi 生命周期。上述 macOS 修正保持了实际测试。
- **Build: PASS**：`IDF_COMPONENT_API_TIMEOUT=15 ./scripts/with-passport-idf.sh ./tools/validate.sh` 完整门禁退出码 0。官方基线编译、合并镜像、Flash 边界／分区／镜像内容校验通过。随后单独运行 `tools/archive_firmware.py verify`，验证匹配的 ELF 和归档成功。依赖锁无差异。
- **Device tests: NOT RUN**：只读枚举看到 Espressif VID `0x303A`／PID `0x1001`，串口 `/dev/cu.usbmodem13301`；用户已确认是 AI Passport。未打开／复位串口、烧录或擦除。
- **Unverified**：设备启动、屏幕、实际收音、持续录音、重点日志、BLE 音频、iPhone 锁屏传输、断电恢复和续航。本轮没有申请刷写与心力卡无关的基线固件。

本轮产物（均为官方硬件测试基线）：

- 合并镜像：`<LOCAL_HOME>/Developer/ai-passport/build/FoloToy-AI-Passport-full.bin`，1,592,992 B；布局面向从 `0x0` 刷写。
- 镜像 SHA-256：`64bfaf09cbc33dc65db30a8d993bf961d12e4af680e498213c5ab840d5e7e7c2`。
- 调试归档：`<LOCAL_HOME>/Developer/ai-passport/build/firmware/64bfaf09cbc33dc65db30a8d993bf961d12e4af680e498213c5ab840d5e7e7c2/`，包含匹配的 ELF、MAP、镜像和 `manifest.json`。
- ELF SHA-256：`b9817a76707abe6c6bbb7f8008fd2a9ab7ee7ddeb88633366ee2a3c32c0f5ab8`；应用版本 `a06235e-dirty`，`dirty` 来自本轮两个主机脚本修正，未提交。
- 应用镜像：1,527,456 B；默认 factory 分区 8,323,072 B，剩余分区空间不等于已实现的音频存储。
- 完整日志：本心力卡仓库 `.build/ai-passport-validation/full-gate-mirror-20261023.log`。脱敏结果摘要见 `research/ai-passport-2026-10-23/validation.json`。

后续如实现并决定测试专用固件，应核对确切镜像和目标端口，再确认刷写。合并镜像从 `0x0` 写入会替换固件，可能重置 NVS／用户数据；完整擦除并不是默认步骤。

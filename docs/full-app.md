# 从 clone 到完整心力卡

v0.2.0 提供原生 iPhone 与 Mac 客户端。推荐闭环：**CB08 → iPhone 本地保存/补传 → 自托管后端 ASR 与整理 → iPhone/Mac 查看、问答与纠正**。不使用原开发者的账号、服务、签名或 API Key。

需要：Mac、Xcode、Python 3.11+、XcodeGen（`brew install xcodegen`）；录音卡场景需要兼容 CB08，真机安装需要自己的 Apple 签名团队/可用设备。没有录音卡也可先用两端“补充记录”贯通真实模型处理。模型与 ASR 需要你自己的授权服务；代码开源不包含免费服务额度。

维护者提供的项目录音卡硬件价格参考为不到 200 元（2026-10-23）；非固定售价或整套成本，未在此核验商家报价。购买前核对 CB08 型号/固件，不能按外观或价格推断兼容。ASR、模型、存储、服务器及现有手机/电脑另计。[价格与对比依据](oppo-context.md)

当前可构建平台为 iPhone（iOS 17+）和 Mac（macOS 14+）；Android 属于[后续扩展计划](android-plan.md)，不是现有安装选项。

## 1. 安装和私有配置

```bash
git clone https://github.com/jingchang0623-crypto/xinlika.git
cd xinlika
PYTHON=python3.12 ./scripts/bootstrap.sh
```

选定你自己的 Chat Completions 兼容文字服务与 Audio Transcriptions 兼容 ASR。文字服务需支持 JSON 对象输出和系统消息；语音服务需接收 Ogg/Opus，返回包含 `text` 的 JSON。根据服务实际名称填写模型：

```bash
.venv/bin/python scripts/configure-workspace.py \
  --base-url http://192.168.1.20:18778 \
  --model-url https://your-model-provider.example/v1 \
  --model your-text-model \
  --asr-url https://your-asr-provider.example/v1 \
  --asr-model your-transcription-model
```

`192.168.1.20` **只是示例**，换成运行后端的电脑实际私有地址；iPhone 不能使用 Mac 的 `127.0.0.1`。仅在同一电脑和模拟器体验可用 `http://127.0.0.1:18778`。公网部署需要自己的 HTTPS；本脚本不自动打开路由器或公开服务。

生成的 `private-config/processing.json` 只引用环境变量名，不包含模型密钥。Mac/iPhone 各有一份独立、可撤销的连接凭据；连接文件权限为 0600。脚本拒绝覆盖已有配置；请显式编辑或新建目录，不删除已有空间来重配。

## 2. 启动你的处理服务

在本机终端设置 `XINLIKA_MODEL_API_KEY` 和 `XINLIKA_ASR_API_KEY` 为你自己的服务密钥，随后：

```bash
./scripts/start-server.sh --host 192.168.1.20 --port 18778
```

配置中的服务端地址和启动绑定地址必须相符。密钥仅保留在你自己的环境或明确指定的私有 key 文件中，不填写到原生客户端。仅验证文字时可不配 `--asr-*`；此时客户端明确显示语音未配置，自动整理模式不会启动录音。

本机状态位于 `.build/workspace`；首次配置不要指向旧项目的活动数据目录。关闭电脑会中断服务端处理，手机保留原声和待传；恢复后继续。若要离开家使用，需自己部署持续在线的 HTTPS 后端。

## 3. 构建和打开 Mac App

```bash
.venv/bin/python clients/tools/build-mac.py
open .build/XinlikaOpenSource.app
```

脚本构建并本地签名专用包标识 `org.xinlika.mac`，不覆盖旧深脑/心力卡。应用读取刚生成的 Mac 连接文件。也可在“录音卡 → 连接共享服务”手填自己的服务地址和 Mac 设备凭据。

从“补充对话”输入一句真实内容，等待整理，打开事件原句，再向 Agent 提问。该路径使用你的实际文字模型；无需录音卡。

## 4. 构建和安装 iPhone App

```bash
xcodegen generate --spec clients/project.yml
open clients/Xinlika.xcodeproj
```

选择 Xinlika scheme、你的签名团队、连接的 iPhone。必要时把 `org.xinlika.app` 换成自己可签名的唯一包标识。仓库不含原团队ID、证书、provisioning profile 或预签名 IPA。模拟器无需团队：

```bash
xcodebuild -project clients/Xinlika.xcodeproj -scheme Xinlika \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

打开 App 的“设置”，填入 `connection-iphone.json` 中的地址和该设备凭据。录音卡页显示文字/语音配置状态。允许系统在你连接自有录音卡和局域网服务时提出的对应权限。

模拟器不能验收 BLE 录音。先用“今天 → ＋补充记录”验证记录、主题、原句、问答和纠正。该补记使用提交时间作为明确输入时间，不把后端处理完成时间当录制时间。

## 5. 真实录音闭环

1. 确认录音卡没有被别的 App 或 Mac 占用，按需要唤醒；本产品不能保证远程唤醒待机设备。
2. iPhone 录音卡页选择设备与声音来源，开启自动转写整理，开始持续记录；必须先配好文字与 ASR。
3. 确认已收原声在增加，再锁屏。重点在 App 中开始/结束，**机身保存键会结束全局录音**。
4. 结束时点“结束并保存”，卡与手机靠近；等待原声自动核对、网络待传清空和服务器任务完成。
5. 两端查看同一日期的事件与原句；在一端纠正内容后，另一端刷新。重问应采用新依据；旧答案可标为已过期。

录音场景的告知与授权由使用者按实际环境处理。不要为了演示上传整卡历史。ASR 失败保留原声；“收到/已上传/已转写/已整理”是不同状态。兼容固件、断连期间实时缺口、短尾边界和活动质量限制见 [evidence](evidence.md)。

## 6. 可选：Mac 本机录音卡采集

Mac 默认作为共享空间的阅读和纠正端。另保留独立本机模式，供只用 Mac 的开发者：

```bash
swift build --package-path clients --scratch-path .build/swift --product cb08-probe
.build/swift/debug/cb08-probe scan --seconds 5
.venv/bin/python clients/tools/local-service.py \
  --device YOUR_SCANNED_UUID --root .build/local-capture \
  --processing-config private-config/processing.json --max-seconds 3600
```

扫描是显式用户操作，启动服务本身不开始录音。App 的本机控制连接该 runtime；使用本机工作区后可以明确开始采集。本机账本与共享空间是**两种部署模式**，本机采集不会自动转送共享服务。不要把它和 iPhone 同时连到同一张卡，也不要把两个模式误当同一数据空间。默认推荐上面的 iPhone 采集、多端共享路径。

## 7. 复现公开测试

```bash
.venv/bin/python -m unittest discover -s scripts -p 'test_*.py'
swift run --package-path clients --scratch-path .build/swift CB08ProbeSelfTest
swift run --package-path clients --scratch-path .build/swift XinlikaWorkspaceCheck
```

iPhone UI 集成测试用 `examples/native-test-server.py` 启动独立 loopback 合成服务，随后运行 `XinlikaUITests`；它不调用真实 ASR/模型或录音卡。CI 的原生任务执行相同入口。详细证据见 [native-validation](native-validation.md)。

源码授权：后端 MIT；`clients/` GPL-3.0-only。厂商二进制 SDK、固件、模型权重均不包含。

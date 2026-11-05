# 云端 iPhone／Watch 构建与真机验收

2026-11-05。使用 GitHub 托管的 macOS／Xcode 构建，本机无需安装完整 Xcode。应用仍需 Apple 签名，手机和手表通过 TestFlight 安装。

## 自动检查

工作流 `Xinlika iPhone and Watch checks` 对 push、PR 和手动触发执行：

1. 选择 `macos-26` 上的 Xcode 26.5，安装经 SHA-256 校验的 XcodeGen 2.46.0、ffmpeg、Python 3.12 和 uv。
2. 同步 `requirements-dev.lock`，执行五组 Swift 可执行自测、Python 全量测试、公开内容扫描和 Swift XCTest。
3. 生成 `Shennao.xcodeproj`，构建 Release iPhone 应用及嵌入的 `XinlikaWatch`，不使用签名凭据。
4. 选择可用 iPhone 模拟器，运行 `ShennaoTests` 与 `ShennaoUITests`。失败返回非零，日志和 xcresult 保留七天。

工作流没有 Watch 模拟器交互测试；Watch 的编译和共享归档／中转逻辑测试不代表手表实机录音通过。模拟器也不能验证真实蓝牙、锁屏录音和后台系统限制。

手动启动已推送分支的检查：

```bash
gh workflow run xinlika-apple.yml --repo jingchang0623-crypto/xinlika --ref <branch>
gh run list --repo jingchang0623-crypto/xinlika --branch <branch>
```

尚未进入默认分支的工作流可能无法通过 `workflow_dispatch` 发现；首次 push 也会自动运行。以 Actions 实际结论为准，本文档本身不是通过记录。

## 配置 TestFlight

在 Apple Developer 创建两个明确的 App ID 和对应 App Store Connect 分发描述文件：

| Target | Bundle ID |
| --- | --- |
| Shennao | `com.zaowuyun.shennao` |
| XinlikaWatch | `com.zaowuyun.shennao.watchkitapp` |

App Store Connect 中的 iOS 应用需使用同一个手机 Bundle ID。证书需要包含私钥的 Apple Distribution `.p12`；只有公开证书不能完成签名。API 密钥需要有上传该应用的权限。

在 GitHub 仓库的 `testflight` Environment Secrets 配置下列值。不要提交文件或把私钥、密码粘贴到聊天里。

| Secret | 内容 |
| --- | --- |
| `APPLE_TEAM_ID` | 10 位开发团队 ID |
| `APPLE_DISTRIBUTION_P12_BASE64` | 含私钥的分发证书 `.p12`，单行 Base64 |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | `.p12` 导出密码，使用非空密码 |
| `IOS_APPSTORE_PROFILE_BASE64` | 手机 App Store 分发描述文件，单行 Base64 |
| `WATCH_APPSTORE_PROFILE_BASE64` | 手表 App Store 分发描述文件，单行 Base64 |
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | API Key 的 Issuer ID |
| `ASC_PRIVATE_KEY_BASE64` | 对应 `.p8` 私钥，单行 Base64 |

CLI 可以通过标准输入写入 Secrets，例如在可信本机执行：

```bash
base64 < /absolute/path/distribution.p12 | tr -d '\n' | gh secret set APPLE_DISTRIBUTION_P12_BASE64 --env testflight --repo jingchang0623-crypto/xinlika
```

其余文件同理；密码使用 `gh secret set APPLE_DISTRIBUTION_P12_PASSWORD --env testflight --repo jingchang0623-crypto/xinlika` 的隐藏交互输入。不要使用命令行 `--body` 携带私钥或密码。

`Xinlika TestFlight` 仅手动触发，先运行完整自动检查，再安装临时钥匙串和两个分发描述文件。签名脚本校验团队、精确 Bundle ID、有效期及分发类型；按 target 指定 Manual 签名，使用同一构建号归档手机和手表，再通过 App Store Connect API 上传。

云端构建号为 `((run_number + 10000) / 100).((run_number + 10000) % 100).run_attempt`，第一批形如 `100.1.1`，高于本机已记录的 `34`，重试也有独立编号。若 App Store Connect 已存在更高构建号，应先提高偏移量。营销版本仍来自 `project.yml`。

钥匙串、签名文件和归档均位于临时目录，退出时清理；产物只保留上传状态。签名失败的末尾错误会进入 Actions 日志，仓库访问者可看到日志，不应给构建过程加入私人录音或业务配置。

上传成功仍要等待 App Store Connect 处理、解决出口合规问答并把版本分配给测试组。外部测试可能需要 Beta 审核。缺少 Apple 账户配置或签名材料时，只能完成不签名检查。

## 真机验收记录

安装前结束当前录音，确认现有记录已保存且可回放；记录原版本和服务配置，不卸载应用来清空数据。每一项记录版本／构建号、设备与系统版本、时间、实际结果和证据位置；凭据、完整设备标识和私人录音留在本机。

| 场景 | 通过条件 |
| --- | --- |
| TestFlight 安装 | 手机可打开，配对 Watch 能安装同一构建；现有记录与服务配置保留 |
| 手机录音与重启 | 开始／保存正常，重开应用后记录仍在；上传状态能区分等待、失败和已确认 |
| 蓝牙断开与恢复 | 用合成短录音验证断连提示及恢复，不把缺失音频标成完整录音 |
| 锁屏／后台 | 真实录音期间锁屏并切后台，核对音频时长、实际内容和中断提示 |
| Watch 离线录音 | 断开手机／网络后开始、保存、重开 Watch，待传记录仍可恢复 |
| Watch 手机中转 | 恢复连接后只导入一次；手机确认文件哈希与落盘后，Watch 才可按策略释放本地副本 |
| 上传失败恢复 | 断网后保存，联网后恢复；认证失败明确提示，不假报上传成功 |
| 展示与可访问性 | 采集状态、记录详情、兴趣反馈在大字号和深色模式下可操作 |

回退以保留数据为前提：先停止采集，保留现有归档和队列，再选择仍有效的先前 TestFlight 构建；不得把卸载重装当作无损回退。自动构建通过、上传完成和真机验收完成分别记录。

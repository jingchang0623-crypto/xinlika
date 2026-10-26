# iOS 0.1.4 (5)：打开 App 自动带回录音

日期：2026-09-06。依据 [硬件 MVP 决策](hardware-mvp-priorities.md) 开发，核心目标是减少每次选择设备、点同步和守着设备页的操作。已完成开发、自动化测试、构建及模拟器独立启动验证；不将模拟设备测试计作真实蓝牙验收。

## 使用路径

首次登录后，在「设备」寻找并选择自己的灵魂卡，点击「记住设备并开启自动同步」。页面明确显示同步账号。

此后设备开机且在附近时，打开或回到 App 会自动尝试连接、校时、检查录音，优先处理未完成下载，再带回新文件。默认「记录」页显示任务状态与最近检查时间，可以直接阅读已有结果。

用户主动暂停后，暂停状态跨切页、前后台和进程重启保留。点击「恢复自动同步」才重新开启；「同步一次」只执行这一轮，不改变暂停偏好。

完整保存到手机的文件按原队列上传，下载结束释放蓝牙。尚未完整下载的内容仍依赖设备可连接，离开范围时保留已落盘的断点；不承诺 App 永远后台运行或无需打开 App。

## 实现与边界

| 部分 | 实现 |
|---|---|
| 持久偏好 | 按服务环境、账号、组织隔离一台首选设备，保存 CoreBluetooth UUID、名称、自动同步偏好、暂停状态、最近完整列表检查时间 |
| 任务意图 | 与设备偏好分开保存；成功清除本轮意图，保留设备供下次查新；失败、列表不完整或仍在录制时保留恢复意图 |
| 合并触发 | 同一时刻只有一个请求令牌；前台自动触发间隔至少 60 秒，手动操作可主动再试；没有持续扫描或定时无限重连 |
| 设备匹配 | 优先使用系统已知 UUID；前台必要时最多扫描 4 秒；不以同名或信号最强设备代替用户选定设备 |
| 恢复顺序 | 当前账号、设备、文件名及大小匹配的未完成文件优先；同组保持固件顺序，不依赖错误的硬件日期判断新旧 |
| 系统恢复 | 只允许匹配本账号既有意图的恢复设备继续后台任务；恢复事件早于账号验证时保留标识，账号恢复后再判断；后台不启动新的发现扫描 |
| 旧版本迁移 | 旧 owner-only 意图必须有匹配账号、组织、设备且未完成的本地任务才迁移；不会自动替用户开启今后的查新偏好 |
| 减少等待 | 登录完成后，蓝牙同步与旧云端结果刷新独立调度；连接/服务发现有超时，显式断开唤醒挂起等待，文件列表与共享下载循环响应取消 |
| 既有正确性 | 复用下载检查点、完整长度/格式/哈希校验、原子落盘、后台 PUT、上传收据与幂等键、账号过滤及结果对账 |
| 状态 | 区分下载、已保存到手机、上传和云端处理；最近检查仅在完整收到列表后更新，校时没有设备回执，不显示未经确认的校准成功 |

60 秒冷却在本次 App 进程内生效，重新启动会重新尝试；暂停偏好和任务意图跨进程保存。硬件正在录制的文件保留待下一次检查。首批历史录音也会沿用现有导入规则，不按日期擅自排除文件。

核心改动在 `iOS/DeviceSyncCoordinator.swift`、`iOS/AppModel.swift`、`iOS/DeviceSyncStatusView.swift`、`DeviceView`、`RecordsView`；共享核心仅做连接后校时及相关取消处理。没有加入遥控录音、增益设置、自动删除或新的收费分析触发。

## 验证记录

最终全量验证：**83 项通过、0 失败、0 跳过**，Xcode 26.5 / iPhone 17 Pro / iOS 26.5 模拟器。结果包 `/tmp/shennao-ios-014-verified.xcresult`，摘要已保存到 [test-summary.json](design/hardware-mvp/test-summary.json)。

- 68 项单元/契约测试：包括新增的 16 项设备调度与恢复排序测试，以及既有校时协议、下载检查点、完整性、上传幂等和结果状态测试。
- 15 项原生 UI 测试：新增 7 项覆盖首次设置后重启自动检查、前台/切页去重、主动暂停取消并跨重启保留、暂停后手动同步一次、离线不误报成功且已有结果可读、退出账号隐藏偏好、最大辅助字号及深色模式；原有 8 项阅读回归全部通过。
- Mac 构建及自检通过：Core 60、Cleanup 24、Audit 55、Voice 10，共 149 条断言。3 组依赖原始录音或归档样本的检查因本机缺少文件而跳过，不能算真实音频验收。
- Release arm64 真机架构无签名构建通过；确认版本 0.1.4 (5)，未发现 `UIReadingFixtures` / `configureSyncSimulation` 符号。这是编译验证，不是安装或发布。
- `git diff --check` 通过。构建仅有未接入 AppIntents 的元数据提取提示，没有编译错误。

中间首轮 65 项单元及随后 82 项全量测试也通过；补充续传排序、账号恢复后的独立调度及后台恢复条件后，以上 83 项在最终代码上重新完整执行。

构建产物与日志：

- 模拟器包：`/tmp/shennao-ios-014-build/Build/Products/Debug-iphonesimulator/Shennao.app`
- Release 包：`/tmp/shennao-ios-014-release/Build/Products/Release-iphoneos/Shennao.app`
- 全量测试：`/tmp/shennao-ios-014-verified.log`；Release：`/tmp/shennao-ios-014-release.log`
- Mac：`/tmp/shennao-ios-014-mac-build.log` 与 `core` / `cleanup` / `audit` / `voice` 同前缀日志。

独立启动验证：测试结束后重新启动指定 iPhone 模拟器，安装上述 Debug 包，先以普通模式启动（PID 14727），确认显示未登录的正常记录页面；再以显式模拟设备模式启动（PID 14827），确认自动调用一次、最近检查时间出现、已有样例可见。模拟器保持打开，当前显示带橙色标注的演示页面。没有操作另一台已运行的 iPad 模拟器。

已导出并目视检查 [界面与启动截图](design/hardware-mvp/gallery.md)，包括普通启动、演示启动、设备记忆、暂停、离线和大字号深色状态。

测试入口 `SHENNAO_SYNC_FIXTURE=1` 仅在 Debug 生效，使用隔离的 UserDefaults suite 和真实 AppModel/调度器，在蓝牙执行边界替换为模拟任务；不会扫描硬件、登录真实账号、上传录音或调用分析接口。页面明确显示「模拟器演示 · 不连接硬件或云端」。模拟任务只验证调度及界面流程，检查点和上传契约另由单元测试验证，不能据此证明完整真实传输。

可重复命令：

```sh
xcodegen generate
xcodebuild -project Shennao.xcodeproj -scheme Shennao \
  -destination 'id=65F68B44-C13E-4864-AE11-83D5C6C1B950' \
  -derivedDataPath /tmp/shennao-ios-014-build \
  -clonedSourcePackagesDirPath /tmp/shennao-ios-packages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test

swift build
swift run CoreSelfTest
swift run CleanupSelfTest
swift run AuditSelfTest
swift run VoiceSelfTest
```

已启动模拟器后，可不使用测试模式启动普通 App：

```sh
xcrun simctl launch --terminate-running-process \
  65F68B44-C13E-4864-AE11-83D5C6C1B950 com.zaowuyun.shennao
```

重现本次演示（仅限 Debug 包）：

```sh
SIMCTL_CHILD_SHENNAO_SYNC_FIXTURE=1 \
SIMCTL_CHILD_SHENNAO_SYNC_SUITE=codex-mvp-014-20260906-preview \
SIMCTL_CHILD_SHENNAO_SYNC_SCENARIO=ready \
xcrun simctl launch --terminate-running-process \
  65F68B44-C13E-4864-AE11-83D5C6C1B950 com.zaowuyun.shennao
```

演示套件也会保留主动暂停偏好；若之前已点暂停，重新打开仍保持暂停，可直接点「恢复自动同步」。

## 真机与用户行为仍待验证

1. 新版安装到 iPhone 后，录音保存、待机或休眠后的硬件是否无需按键即可连接；首次连接、断线重连及设备重启后的时钟显示与新文件名。
2. 真实掉线后以非零 offset 续传、最终音频与源文件一致；弱网和新录音后台上传收尾、云端会话不重复。
3. 切 App、锁屏、系统回收与用户强退分开验证；模拟器不能替代这些蓝牙与后台系统行为。
4. 先记录 3–5 次旧流程基线，再记录 10 次日常机会的额外点击、主动盯守时间及结果可达时间；「至少 9 次打开后无需额外同步操作」是待验证门槛，不是本次测试成绩。

截至 2026-09-06 的开发轮未安装用户 iPhone；后续安装状态见下文。未发布 TestFlight、未提交或推送代码，保留工作区原有修改。

## 真机安装更新 · 2026-09-07 09:31

用户连接手机并要求安装测试后，已将 **0.1.4 (5)** 原位覆盖安装到此前的 iPhone 16 Pro。安装前设备查询为 0.1.3 (4)，安装后再次查询确认版本为 0.1.4 (5)，随后通过 CoreDevice 启动成功（PID 15620，前台激活，无演示参数）。

使用同一 bundle `com.zaowuyun.shennao` 与 Team `<APPLE_TEAM_ID>` 的 Release 配置、Apple Development 签名。构建及 `codesign --verify --deep --strict` 校验通过。产物：`/tmp/shennao-ios-014-device/Build/Products/Release-iphoneos/Shennao.app`，构建日志：`/tmp/shennao-ios-014-device-build.log`。

此次是覆盖安装，未卸载 App、清理数据容器或手动操作录音。未安装到 iPad，也未发布 TestFlight。仅确认安装版本和进程启动；账号/既有录音展示、真实自动校时、连接与同步效果交由用户本轮测试，不将启动成功记作硬件链路验收。

首次测试请在「设备」页寻找并选择自己的灵魂卡，点击「记住设备并开启自动同步」。之后以短测试录音检查：录音保存后打开 App 是否无需再点同步、硬件时钟显示是否正确、暂停后再次打开是否保持暂停。

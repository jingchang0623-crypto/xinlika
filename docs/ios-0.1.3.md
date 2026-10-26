# iOS 0.1.3 (4)：原生阅读体验首版

日期：2026-09-05。用户确认设计方案后，已将阅读链路接入正式 `Shennao` target，不再只是独立设计预览。真机安装与验收状态见本文末尾。

## 用户能看到的变化

- 默认进入「记录」；按录音日期分组，显示标题、时间/时长、摘要片段与处理状态。搜索范围是标题和摘要，不冒充全文检索。
- 概览将已有摘要、关键判断、原话引用与对话中的行动分层展示。没有后端内容就明确显示缺失，不额外请求 AI 生成摘要。
- 完整分析采用原生连续文档：多级标题、嵌套列表、引用、代码、GFM 表格及安全的网页链接。正文可选择复制，更多菜单保留 Markdown 原文。
- 目录可直接跳到章节；退出详情、切到后台时保存最后可见正文块。按账号/记录及报告版本隔离，只保存哈希和块标识，不把报告正文写入偏好设置。
- 大字号下阅读模式改为原生菜单，表格改为逐字段纵向阅读；常规字号仅在表格内部横滑。支持系统、浅色、深色外观。
- 设备页保留真实扫描、连接同步、暂停与恢复提示；技术信息折叠。设置使用原生 Form，保留账号、连接参数（Debug）与开源许可。

## 保持不变的业务边界

- BLE、下载检查点、Ledger 格式、后台上传、结果对账、账号归属和手动分析的额度确认不重构。
- AppModel 仅增加可等待的 `refreshAllResults()` 展示层入口，调用原有 `reconcile(force: true)`；测试样例扩充仅在 Debug 的既有测试入口生效。
- 转写与回听仍通过现有 web-ticket 入口，以临时 WebKit 数据存储和同源导航限制打开。没有伪造本地播放器或时间戳定位。
- `.ready` 不被解释为分析完成；仅服务端分析状态 `done` 才显示分析完成。缓存仍可读时，更新失败单独提示。
- 行动卡片为只读原文，不表示已经建立跨端待办。Markdown 中的勾选标记只复现原始文档。
- 不自动加载 Markdown 图片，不执行原始 HTML；链接只允许用户点击打开 http/https，排除凭据 URL。原始文本仍可查看。
- 本次未删除、重新上传用户录音，也未发起新的真实分析。

## 维护结构

| 层 | 文件/责任 |
|---|---|
| 平台导航与主题 | `RootView`、`ReadingTheme`：每个 tab 独立 NavigationStack；语义颜色及系统字体 |
| 记录展示投影 | `RecordPresentation`：只读状态、摘要片段、录音日期；不用缓存更新时间代替录音时间 |
| 原生列表/设备/设置 | `RecordsView`、`DeviceView`、`AccountView`：调用既有业务入口 |
| 阅读状态 | `MeetingView`、`MeetingReadingScreen`：按记录隔离，局部弹层、模式和阅读位置 |
| 结构化概览 | `MeetingOverview`：保留已有字段和原话，不推断缺失内容 |
| 文档解析 | `ReadingDocument`：Markdown AST 转不可变 Sendable 块，actor 内解析，版本稳定 ID |
| 文档排版 | `ReadingDocumentView`：SwiftUI 文本/列表/表格、目录、Dynamic Type |
| 次级入口 | `RecordInformationSheet`、`SecureTranscriptWebView`：技术信息、原文和转写 |

SwiftUI UI Patterns 指导了原生控件选择和按 tab 保留导航；SwiftUI Expert 指导了局部状态、取消过期解析、稳定 ID、辅助字号和解析与主线程隔离。没有把网页 CSS/DOM 方案移植进 App。

Mac 与 iOS 继续共用既有协议核心，Android 的核心功能以同一后端字段语义对齐；这次没有改动 Mac/Android UI。新增阅读器先在 iOS 验证，暂不为了代码复用扩大跨端框架改造。

## 依赖与构建

- 官方 [Swift Markdown](https://github.com/swiftlang/swift-markdown) **0.8.0**，revision `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`。
- 传递解析器 [Swift cmark](https://github.com/swiftlang/swift-cmark) 同时固定 **0.8.0**，revision `924936d0427cb25a61169739a7660230bffa6ea6`。
- 两个版本均在 `project.yml` 固定，防止重生成工程时解析器静默升级。许可证与上游 NOTICE 在 `iOS/Resources/ThirdPartyNotices.txt` 随包分发，可从设置阅读。
- 此依赖版本要求 Swift 6.2 工具链；本次使用 Xcode 26.5。App deployment target 仍为 iOS 17，不代表已经验证 iOS 17 运行时。
- 已构建并校验签名的真机包：`/tmp/shennao-ios-013-device/Build/Products/Release-iphoneos/Shennao.app`，bundle `com.zaowuyun.shennao`，版本 **0.1.3 (4)**。
- 此包为 Release 配置、开发签名（`get-task-allow=true`），**不是 TestFlight 或 App Store 发布**。Release 不包含 Debug 界面样例入口。

```sh
xcodegen generate
xcodebuild -project Shennao.xcodeproj -scheme Shennao \
  -destination 'id=65F68B44-C13E-4864-AE11-83D5C6C1B950' \
  -derivedDataPath /tmp/shennao-ios-013-build \
  -clonedSourcePackagesDirPath /tmp/shennao-ios-packages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

## 验证范围与下一步

第一轮生产 scheme 测试：52 通过、0 失败、0 跳过。覆盖两万字符以上合成长文、目录跳转及重启后阅读位置、标题/摘要搜索、概览原话、表格、最大辅助字号、深色、缓存错误、空记录与未自动分析。样例明确标记为界面测试内容，未使用用户报告截图。

Mac 既有断言回归：Core 52、Cleanup 24、Voice 10、Audit 55，共 141 通过、0 失败。三组依赖本机原始录音/归档的检查因缺少样本跳过；不能当作真机音频验收。

最终全量复测：**54 通过、0 失败、0 跳过**（46 项单元/契约测试、8 项 UI 测试），结果包 `/tmp/shennao-ios-013-tests-verified.xcresult`。另覆盖原文/信息页入口与随包许可文件。中间一轮新增测试因原生 LabeledContent 的组合可访问性元素定位方式报错（53 通过、1 失败），修正测试选择器后全量复测通过，未为通过测试削弱产品功能。

已导出并检查正式界面的截图：[查看原生图库](<<LOCAL_HOME>/Documents/ChatGPT/深脑 app/docs/design/production-v1/gallery.md>)。最终截图为测试样例，不包含用户私人录音。模拟器系统外观保持 light、字号保持 large；辅助字号/深色只通过测试 App 启动配置应用。浏览器研究任务空间已关闭。

Xcode 测试日志含 `DebuggerLLDB.DebuggerVersionStore.StoreError` 环境提示，但最终 xcodebuild 退出码为 0，xcresult 汇总为 Passed；没有据该提示跳过测试。Release 签名与资源校验成功，未发现 UIReadingFixtures/DesignPreview 二进制符号；`git diff --check` 通过。

### 真机安装更新 · 2026-09-05 17:54

用户要求同步到手机体验后，确认之前的 iPhone 16 Pro 已连接。使用相同 bundle `com.zaowuyun.shennao` 原位覆盖安装，设备应用查询确认从 0.1.2 (3) 更新为 **0.1.3 (4)**，随后启动成功。没有卸载应用、清理数据容器、操作录音删除或手动重传；没有安装到 iPad。此次仅验证安装与启动，账号/录音保留的实际展示及阅读体验由用户继续验收。仍是开发签名安装，不是 TestFlight 发布。

仍待完成：

1. 用户在已安装的 iPhone 新版中，用原有长报告验证实际阅读、选择复制与转写/回听。
2. 真实锁屏/切 App、强制断连后的恢复及新录音后台上传回归。这次合成 UI 测试不覆盖蓝牙或服务端端到端行为。
3. iOS 17 实际运行、小屏真机、VoiceOver 人工朗读和实际性能采样；当前截图/自动化只覆盖 iPhone 17 Pro / iOS 26.5 模拟器。
4. 真机反馈稳定后再评估本机全文检索、分享导出、音频时间戳定位；跨端待办须先有服务端状态契约，不在样式改造中顺带实现。

没有提交或推送代码，保留了工作区先前已有修改。

# 深脑原生设计预览

方案见 [iOS 设计方案](../docs/ios-design-proposal.md)，官方规范研究见 [设计研究](../docs/ios-design-research.md)。

这是可运行的 SwiftUI 样机，不是生产 App 的替换版本。

- 独立 target / scheme：`ShennaoDesignPreview`
- 独立 bundle：`com.zaowuyun.shennao.design-preview`
- 最低部署 iOS 17；本轮运行环境 iOS 26.5 iPhone 17 Pro 模拟器。
- 只依赖 `Design/Preview` 的示例数据和视图，不包含 BLE、网络、账号、Keychain、上传或生产 Ledger。
- 搜索、导航、目录、引用展开、外观切换可以操作；设备暂停是明确标注的本地状态演示。
- 长文为确定性的结构化示例，不是 Markdown 解析器，也不代表 2 万字真实内容的性能验收。
- `Design/UITests` 检查预览的主路径，不能替代生产目标的测试。

## 运行

```sh
xcodegen generate
open Shennao.xcodeproj
```

在 Xcode 选择 `ShennaoDesignPreview` 和 iPhone 模拟器后运行。不要选择用户手机进行自动安装。

启动参数支持 `--screen=records`、`overview`、`analysis`、`device`、`settings`、`empty`、`error`。例如 `--screen=analysis` 直接显示完整分析。

## 生产移植边界

先移植语义主题和只读展示组件，再将生产缓存映射到展示模型。不能复制示例的录音、电量、进度和固定数量进入生产版本；也不能为了让界面完整而补造后端不存在的摘要、原文引用或行动状态。

现有 `iOS/`、共享核心和真实录音在本轮没有被本预览修改。生成的 Xcode 工程不入库；新增 target 配置保存在 `project.yml`。

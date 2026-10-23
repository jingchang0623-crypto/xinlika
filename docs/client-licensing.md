# 客户端授权核查与替换结果

核查日期：2026-10-23。本页记录找到的许可证、用户的权利确认及实际纳入范围，不将“仓库能访问”当成再发布许可。

| 来源 | 核查证据 | 本次处理 |
|---|---|---|
| [shennao-mac](https://github.com/qiuyiwu1989-star/shennao-mac) | GitHub 未声明根许可证；本地基线 `9587788`。用户已明确确认有再授权权利并同意客户端 GPL-3.0 | 仅所需 Swift 基础、采集与新工作台，放入 `clients/` 并明确 GPL-3.0-only；保留来源与哈希 |
| [shennao-app](https://github.com/qiuyiwu1989-star/shennao-app) | 未声明根许可证；实际为 Android 项目 | 不复制 Android 代码。iPhone 来自当前工作区独立开发的 Swift 工程 |
| [SoniCloud SDK](https://github.com/SonicloudTech/sonicloud_opensdk/tree/f10cd9bf2a2341566d923818602ac93fb9246091) | 根 MIT；[README 许可边界](https://github.com/SonicloudTech/sonicloud_opensdk/blob/f10cd9bf2a2341566d923818602ac93fb9246091/README.zh-CN.md#许可与使用边界) 区分示例代码与可能专有的静态库/AAR/HAR/固件等 | 不纳入、下载或链接厂商二进制。使用原生 CoreBluetooth 源码；保留协议来源说明，不复制完整厂商文档 |
| [lomehong/record](https://github.com/lomehong/record) | 未找到根许可证；旧注释引用其协议研究 | 不纳入该仓库源码/素材；校时编码按厂商可核对的字段事实重新表达。未声称 clean-room |
| Swift Markdown / cmark | 旧阅读路径存在这组包依赖 | 心力卡原生路径不依赖旧阅读器，因此移除这组依赖，不打包旧云端阅读流程 |
| voxgate 研究服务 | 源码 MIT，非公开语音上游的使用条件独立 | 新增可配置、明确授权的兼容 ASR 适配器，完整运行无需 voxgate；旧研究接口仅保留为可选 |
| 旧云端/签名/图标 | 私有域名、账户、开发团队与素材不适合默认公开运行 | 移除旧登录路由和平台接口，使用自己的服务、设备凭据、签名团队与包标识；无旧图标素材 |

用户的确认是本次客户端的再授权依据；它不替上游仓库修改许可证，也不对厂商专有代码作授权。相关确认原文留在私人会话中，未把私人会话上传仓库。

## 路径授权

- `clients/**`：GPL-3.0-only，包括原生 App、Swift 核心、探针及桌面本机采集服务。见 [客户端许可证](../clients/LICENSE) 与 [来源说明](../clients/PROVENANCE.md)。
- 后端 `scripts/**`、`prompts/**`、独立演示及根文档：MIT，除明确标注的第三方文件外。
- GPL 不是禁止商业使用；分发修改后的 GPL 客户端时需要满足相应源码、许可证和声明要求。后端 MIT 不把客户端改成 MIT。

## 为什么没有照搬整个旧工程

旧代码有不少本产品已不需要的路径：旧平台登录、旧云端 API、历史录音管理、阅读器和设计预览。精简后原生客户端只通过当前心力卡 API 工作，降低账号/服务依赖和第三方授权范围。

保留持续采集、保存后卡上参考、断点与哈希、后台不可变消息、来源纠正和语义工作台。保留代码不等于对所有设备/固件重新验收；公开构建验证和此前硬件记录分别报告。

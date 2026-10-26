# 同事分发与 App Store 发布评估

评估日期：2026-09-07。范围：本地代码、发布配置、CLI 文档、Apple 官方规则及 App Store Connect 只读查询。本轮没有改动产品代码、上传构建、邀请测试者或提交审核。

## 建议

先邀请 3–5 位同事通过 TestFlight 验证完整使用流程，再决定面向公众上架或面向特定组织长期分发。人数为本项目的 MVP 建议，不是平台限制。TestFlight 用于阶段性测试，每个构建最多可测试 90 天，不适合作为永久内部安装渠道。

普通同事使用按邮箱邀请的外部测试组，默认关闭公开邀请链接。“内部测试者”是 App Store Connect 中有相应角色的成员，并不等于公司员工。已有发布团队成员可以使用内部组；不为测试 App 而给普通同事增加发布后台权限。外部组首个构建需要 TestFlight 审核，后续构建仍可能需要审核。[Apple TestFlight](https://developer.apple.com/testflight/)、[测试流程和有效期](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

| 目标 | 分发方式 | 决策 |
| --- | --- | --- |
| 近期同事试用、持续收集反馈 | TestFlight | 当前首选；同事安装 TestFlight，接受邀请，再安装和更新深脑 |
| 长期仅供特定组织使用 | Custom Apps | 通过 Apple 企业分发体系指定组织，需组织接入和 Apple 审核；在首次获批前确定分发方式 |
| 面向更多用户使用 | 公开 App Store | 完成商店资料、隐私、业务模式、地区要求及正式审核后上线 |

Custom Apps 也支持分发前邀请测试者。[Apple Custom Apps](https://developer.apple.com/custom-apps/)

## 已核实的项目状态

| 项目 | 只读检查结果 |
| --- | --- |
| 本机 CLI | `/opt/homebrew/bin/asc`，版本 `4.10.0` |
| API 访问 | 当前默认凭据成功查询到目标应用；只证明这些读取接口可用，不证明全部写入权限及合同状态已就绪 |
| App Store Connect 应用 | `Shennao`，App ID `6808874247`，Bundle ID `com.zaowuyun.shennao` |
| 商店版本 | `1.0`，`PREPARE_FOR_SUBMISSION` |
| 上传的构建 | 0；包含全部处理状态的查询无结果 |
| TestFlight 测试组 | 0；分页查询无结果 |
| 当前本地版本 | `0.2.0 (11)`，iOS 17 起、仅 iPhone |
| 导出准备 | 已有 `Config/ExportOptions-AppStore.plist` 和 `Config/ExportOptions-TestFlight.plist`；均使用 `app-store-connect` 导出方法和自动签名 |
| 真机包与发行包 | 已有 Apple Development 签名的真机测试包；本轮未验证 App Store distribution archive/export/upload |

本地 `0.2.0` 可以先做 TestFlight 测试。提交商店 `1.0` 时，需要生成营销版本与商店版本一致、构建号合适的发行包，不能直接将版本不匹配的测试包关联到正式版本。

执行 `asc validate --app 6808874247 --version 1.0 --output json` 返回 34 个 error、2 个 warning、1 个 info，退出码 1。主要事项是：

- 简体中文描述、关键词、支持 URL 缺失。
- 审核信息、主分类、内容权利声明、版权、销售地区配置缺失。
- 未关联构建，未上传截图。
- 年龄分级有 24 个字段待填写。应按实际产品回答，不照搬工具建议或批量填“否”。
- 副标题、隐私政策 URL 为空。
- App Privacy 的发布状态无法通过此次公共 API 检查确认。

这些是当前 CLI 对正式商店版本的预检结果，不是 Apple 审核结论，也不等于每项都阻止 TestFlight 上传。特别是 CLI 将隐私政策 URL 归为 warning，但 Apple 明确要求 App 内和商店元数据提供隐私政策入口；工具严重程度不能代替 Apple 规则。[审核指南 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy)

## CLI 与技能如何使用

用户提供的仓库是独立、非 Apple 官方的命令行工具；另有配套的 Agent Skills 仓库。它支持本地 Xcode 构建、归档和导出、签名资源管理、上传构建、TestFlight 组管理、商店文案与截图同步、发布预检、提审及状态查询。[CLI 文档](https://github.com/rorkai/App-Store-Connect-CLI)、[配套技能](https://github.com/rorkai/app-store-connect-cli-skills)

本轮看到的远端最新版是 `5.0.0`，本机是 `4.10.0`。落地时应固定并核对工具与技能版本，以已安装 CLI 的 `--help` 为命令依据；本轮没有升级 CLI 或安装技能。

建议将现有 Xcode 构建流程与 CLI 发布操作连接起来，优先使用公开 API。部分深度校验依赖实验性、登录后的 Apple 网页接口，不应把此类校验成功当作审核保证。技能包中也有需要浏览器创建应用记录的流程；本项目已存在应用记录，可以复用。

该工具不能代替 Apple Developer Program 资格、有效签名私钥、匹配的权限、协议接受或 Apple 审核。普通开发者计划标价每年 99 美元，按地区以当地货币结算；本轮未单独验证会员有效期或未接受协议。[Apple 入会说明](https://developer.apple.com/programs/enroll/)

## 同事试用前优先解决的产品事项

1. **每人独立账号，验证服务端权限。** 当前登录需要已有账号及组织成员关系；组织选择取最早的 membership。云端历史查询限定 `org_id`，通过用户 token 和 RLS 控制访问。本地缓存按账号隔离不等于服务端个人记录已经隔离。至少用两个独立账号验证个人记录、明确授权的共享记录、换账号后的缓存可见范围；多组织用户还需确认选中的组织正确。不得复用开发者本人账号或私人录音作为同事样例。
2. **明确录音和 AI 数据处理。** `AccountView` 没有隐私政策入口，商店该 URL 也为空。补充可访问的政策、数据保存与删除方式；核对音频、账号标识、转写及分析结果的真实数据流，填写 App Privacy。`PrivacyInfo.xcprivacy` 中空的 collected-data 数组不能作为“没有数据收集”的依据，也不单凭该数组判定违规。若录音或个人数据会发给第三方 AI，应披露接收方与用途并在分享前取得明确许可。[App Privacy](https://developer.apple.com/app-store/app-privacy-details/)、[审核指南 5.1.1 / 5.1.2](https://developer.apple.com/app-store/review/guidelines/#privacy)
3. **保持必要、简洁的提示。** 隐私政策和数据管理入口放设置；首次上传时呈现必要的告知和选择；保留录音中的清晰状态、停止控制、异常录音确认及额度确认。记录页继续以分析结果为中心。Apple 对录音要求用户同意及清晰的视觉或声音指示。[审核指南 2.5.14](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
4. **准备可审查的体验。** 提供专用审核账号与非敏感样例，让无录音卡时也可查看云端分析。录音卡部分提供准确的操作说明、演示资料，并按审核要求提供必需硬件或资源；演示视频不保证能代替硬件。当前 Release 未提供注册入口；若后续加入注册或引导注册，需要同时落实适用的 App 内删除账号能力。[审核指南 2.1 / 5.1.1](https://developer.apple.com/app-store/review/guidelines/)

## MVP 发布顺序与验收

1. 完成账号权限验证、必要的隐私入口与授权流程，准备测试账号、反馈联系信息及 TestFlight 测试说明。
2. 归档、发行签名、导出，检查版本号和构建号，上传至现有 App ID，确认 Apple 处理成功。
3. 建立按邮箱邀请的同事外部组，提交所需 TestFlight 审核，获批后邀请测试者。
4. 首批 3–5 人完成一周测试：独立安装和登录、蓝牙状态和开始/结束录音、短录音可找回、长录音/批量导入保护、其他来源云端分析可见、账号隔离、弱网恢复。无需硬件的同事可先测云端记录与阅读体验。
5. 验收重点：同事能够自行完成首次使用；待确认录音在同意前不下载或提交分析；普通刷新不新建分析任务；私人记录不被未授权账号看到；录音状态明确或明确标为未知，不能把失联当成已停止。

以上为后续实施顺序，本次没有开始执行上传或邀请。TestFlight 每个构建有 90 天期限；长期分发方式应在测试结束后确定。

## 正式上架的额外决策

- 准备真实截图、支持页面、商店描述、分类、年龄分级、版权、内容权利声明与审核资料。
- 明确收费模式。当前 App 没有购买入口，可以评估作为既有深脑网页服务的免费配套 App；Apple 3.1.3(f) 对符合条件、App 内没有购买或外部购买引导的免费配套 App 有例外。若加入分析额度购买或订阅，需重新评估 IAP 与上架地区规则，不能默认现有网页支付可直接移植。[审核指南 3.1.3(f)](https://developer.apple.com/app-store/review/guidelines/#other-purchase-methods)
- 如果选择中国大陆 App Store，需要核实适用的 App ICP 备案及其他地区材料，备案内容与商店信息保持一致。现有网站域名或网站备案本身不能证明该 App 已满足相关要求。本轮未查询该 App 的备案状态。[Apple 中国大陆可用性说明](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- 最终提交和公开发布前，确认面向公众还是特定组织；检查发布主体、地区与发布时间。Apple 审核所需时间与是否通过均不能由 CLI 保证。

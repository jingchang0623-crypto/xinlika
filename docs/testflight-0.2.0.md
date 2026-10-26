# 深脑 0.2.0 (11) TestFlight 发布记录

更新日期：2026-09-07。

## 当前状态

**0.2.0 (11) 已上传 TestFlight，并于 2026-09-07 21:51（北京时间）提交外部测试审核，审核状态为 `WAITING_FOR_REVIEW`。** Apple 构建处理状态为 `VALID`。 Release 归档、发行签名和 IPA 校验成功，当前代码 119 项单元测试全部通过。

Build ID：`b3a00e51-0de6-47ed-b759-40e17840e35f`。内部状态 `IN_BETA_TESTING`，外部状态 `WAITING_FOR_BETA_REVIEW`。账号所有者和审核联系人账号均已加入内部自测组，构建已直接关联到两位测试员，邀请状态均为 `INVITED`。外部审核已通过，尚未邀请同事。

旧 `factory-build` 钥匙串的密码不可用。已使用现有开发者 API 凭据创建新发行证书和描述文件，在独立临时钥匙串中完成签名，保留旧证书及旧钥匙串。导出结束后恢复了原钥匙串搜索列表，并删除临时签名钥匙串。

## 已完成

- 使用本机 `asc 4.10.0`；通过 `asc install-skills` 安装其固定版本配套技能，来源提交 `e30039abddbe388179324d0f9cdccb66c3843115`。
- 确认现有应用 `6808874247`，Bundle ID `com.zaowuyun.shennao`，团队 `<APPLE_TEAM_ID>`。
- 从当前工作区生成 Xcode 工程，使用自动签名和现有 API 凭据完成 Release 归档。
- 检查归档中的版本、图标、生产 API 配置和 Supabase 公共客户端 key；key 的角色为 `anon`。
- 单元测试 119 项通过；结果位于 `build/testflight-0.2.0-11/UnitTests.xcresult`。
- 按用户要求创建外部组「同事测试」，ID `d62c323d-0e11-4901-8990-d66520bf526b`，公开链接关闭，反馈开启。尚未添加测试者。
- 创建内部组「开发者自测」，ID `dd476167-19e4-4c79-9d24-42260240d5d5`，添加账号所有者，已确认 `INVITED`。上述构建已关联这两个组。
- 写入中文 TestFlight 应用简介，localization ID `fda6d4a2-d748-4c1a-80c2-422c2eceb1fb`。
- 写入中文 What to Test 和英文审核说明。
- 按用户最新更正填写审核联系人陈京昌；专用审核账号已经验证登录、组织访问及移动端云库接口。
- 创建仅含虚构内容的英文审核样例，记录 ID `26431db3-91bc-478d-ad56-f399472385e7`；移动端接口可读取。样例分析仍在服务器排队，已在 Apple 审核说明中明确标注，未重复触发分析。
- 严格 TestFlight 预检通过：0 错误、0 警告。已提交外部审核并通过独立查询确认 `WAITING_FOR_REVIEW`。
- 从官网核实并填写既有隐私政策 `https://shennao.zaowuyun.com/zh/privacy` 和公开反馈邮箱 `hi@zaowuyun.com`。本次没有改写政策，也未对政策与 iOS 功能的全部一致性作法律审查。
- 新发行证书 `8MBJPFK4DR`，SHA-1 `82E99AE5BDBDD64BC8A539E1DEDA96BA698689F0`；新描述文件 `YXB5D8KDYM`，UUID `f86b3fd7-48f1-4d12-8420-7cf7244f9b2a`。

## 本地产物

目录 `build/testflight-0.2.0-11/` 已由现有 `.gitignore` 排除：

- `Shennao.xcarchive`：成功归档。
- `Shennao-0.2.0-11.ipa`：已上传的发行签名包，2,370,443 字节。
- `ExportOptions-Isolated.plist`：本次使用的新证书和描述文件映射。
- `archive-auto.log`、`export-isolated.log`、`unit-tests.log`、`upload.log`：成功构建、测试及上传日志；`export.log` 留存旧钥匙串失败记录。
- `release-verification.json`：不含凭据的核对结果。
- `build-info.json`、`build-groups.json`、`testflight-readiness.json`、`tester-access.json`：Apple 状态和分组读回结果。测试者邮箱仅保留在已忽略的本地目录中。
- `what-to-test-zh-Hans.txt`、`beta-description-zh-Hans.txt`、`review-notes-draft.txt`：测试资料。
- `external-review-inputs.json`：仅本地保存、权限 `0600` 的已填写审核资料与专用审核凭据，不复制到 Git。

## 继续步骤

1. 两个内部测试员会收到新的 TestFlight 邮件邀请；在 iPhone 上打开邮件接受邀请后，刷新 TestFlight 并安装 0.2.0 (11)。
2. 外部测试审核已通过，构建外部状态为 `IN_BETA_TESTING`。
3. 用户提供同事邮箱后，待构建获准外部测试再分发安装邀请。「同事测试」组已关联构建，公开链接保持关闭。
4. 审核样例的云端分析仍为 `queued`；仅确认记录和登录可用，尚未确认生成的分析正文可读。相关状态保存在 `demo-sample-verification.json`，英文审核说明已注明这一限制。

审核联系人及专用账号已按用户更正保存到 App Store Connect；密码不写入本文件。提交结果保存在 `beta-review-submission.json`，提交 ID 为 `b3a00e51-0de6-47ed-b759-40e17840e35f`。

新签名材料保存在用户目录 `.appstoreconnect/signing/shennao-20260907/`，私钥、加密 PKCS#12 及其密码文件均使用受限本地权限，不进仓库。后续打包可重用这些材料和临时钥匙串流程，无需旧 `factory-build` 密码。

App Store Connect：https://appstoreconnect.apple.com/apps/6808874247/testflight/ios

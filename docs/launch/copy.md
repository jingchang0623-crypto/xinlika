# 可编辑传播文案

以下是草稿。配图中的原生界面真实运行，输入和模型响应是合成夹具。发布时保留这条说明与 Android 状态；价格注明硬件范围。兼容性与成本依据见 [oppo-context](../oppo-context.md)。

## 主标题

**看过 OPPO 心力球，用 iPhone 的我做了一个开源心力卡**

其他可选标题：

- 不到 200 元的录音卡，能给 iPhone 上的个人 Agent 补上什么？
- 心力卡开源：iPhone + Mac，把日常记录变成可纠正的上下文
- 一句原文纠正，怎样让个人 Agent 不再沿用旧答案？
- 欢迎 Fork 心力卡：一起把随身上下文带到更多 Android 手机

首个标题如果不是维护者本人发布，改为“用 iPhone 也能探索开源心力卡”，避免冒称作者经历。

## 短帖

看过 OPPO 心力球，但用 iPhone？我们把心力卡 Xinlika 开源了。

原生 iPhone + Mac，录音/补记 → 事件与跨记录主题 → 带出处问答。原文可以纠正，重新问答采用新依据。后端自己部署，ASR 和模型自己选。

项目所用录音卡硬件不到 200 元（维护者价格参考；ASR、模型、服务器另计）。没硬件和密钥也能先跑合成演示。

Android 跨品牌适配是下一步，欢迎 Fork 做客户端、只读 MCP 或采集适配器。

https://github.com/jingchang0623-crypto/xinlika

开发者预览，需自行构建；演示采用合成输入与模型响应。独立项目，与 OPPO 无关联，不兼容心力球硬件。

## X 系列帖

**1/4 · 为什么做**

看过 OPPO 心力球，用 iPhone 的我更想试一件事：让自己的 Agent 用上现实生活里的上下文。心力卡 Xinlika 已开源，包含原生 iPhone/Mac 和自托管后端。

**2/4 · 看什么**

演示重点不是多一份摘要，而是“记录 → 找原句 → 纠正 → 再问”。原生截图来自实际模拟器流程；输入和模型响应是合成夹具，HTTP/存储/处理链路真实运行，不是识别质量测评。

**3/4 · 需要什么**

项目所用录音卡硬件不到 200 元（维护者参考价，非整套成本）。完整使用需自己的模型/ASR、服务和原生构建环境；没卡可先补记文字，没密钥可跑合成报告。当前不是下载即用的商店 App。

**4/4 · 一起做什么**

Android 跨品牌客户端是下一步；MCP/Watch 尚未实现。欢迎 Fork 认领一个小闭环，或告诉我们第一次运行卡在哪一步。后端 MIT，客户端 GPL-3.0-only。独立项目，与 OPPO 无关联。

https://github.com/jingchang0623-crypto/xinlika

## 开发者社区 / 公众号正文

OPPO 心力球让“随身上下文”这个方向更容易被理解：个人 Agent 要知道的，不只有电脑里的文件，也包括我们平时讨论过什么、改变了什么决定。

我用 iPhone，也希望能自己运行和改造这条链路，于是把心力卡 Xinlika 整理成了公开仓库。目前包含原生 iPhone/Mac 客户端、Python 后端、事件/主题整理、带出处问答与中文个人 Agent 提示词。Android 跨品牌适配是接下来的方向。

值得先看的，是纠正链路。一次记录生成事件，事件保留原句；当日期或来源被纠正，相关旧答案失效，重新问答使用新依据。它仍会有识别和关联错误，所以我们把原声/原文、版本和恢复状态也作为产品的一部分。

项目所用录音卡硬件不到 200 元，价格由维护者提供作参考；不是整套成本，也不是所有同价卡都兼容。真实使用还需要 ASR、文字模型和持续运行的服务。可以先不买硬件：无密钥合成演示会生成纠正前后报告，有自己的文字模型后再用两端补记跑完整路径。

我们把完整 clone、配置、构建、签名与录音步骤写进了文档。仓库没有原开发者私有账号/签名依赖；后端 MIT，客户端 GPL-3.0-only。它是开发者预览，需要 Mac/Xcode 构建，不是免配置消费品。

如果你想贡献，不必先做整个 Android App。可以从连接共享空间、同步和补记文字开始，再补纠正、问答、麦克风与 BLE。其他方向包括只读 MCP、更多 ASR/设备适配、中文跨天主题，以及更少打扰的个人助理提示词。每个方向都写了文件入口和验收方式。

当前公开构建已有干净 clone、后端回归和原生合成 UI 验证；新包的实体 BLE/锁屏、全天连续性、电量和长期建议质量仍待实测。配图展示合成输入与模型响应，不用它冒充真实识别准确率。

心力球手机兼容范围也需要准确表达：10 月 16 日极客公园实机报道说当时支持 OPPO、一加和 Realme，暂不支持其他品牌。心力卡的现有 iPhone 路径提供另一种选择，但不连接心力球硬件，也不声称功能等价。

仓库：https://github.com/jingchang0623-crypto/xinlika

欢迎先跑一次，留一个具体失败、使用场景或 Fork 目标。独立项目，与 OPPO 无关联。

## English short post

Everyday context for a personal agent, on iPhone too.

Xinlika is open source: native iPhone/Mac clients, a self-hosted backend, source-linked events/topics and answers you can correct. Choose your own ASR and model. Cross-brand Android is next; MCP and Watch are not implemented yet.

The maintainer reports sub-CNY 200 recorder hardware; services and total setup cost are separate. Try the synthetic demo before buying anything.

https://github.com/jingchang0623-crypto/xinlika

Developer preview, build from source. Demo inputs/model replies are synthetic. Independent from OPPO; not compatible with Xinliqiu hardware. Backend MIT, clients GPL-3.0-only.

## 评论区常见问题的短答

| 问题 | 回答 |
|---|---|
| iPhone 能用吗？ | 有原生 iOS 17+ 源码和完整构建指南，需要 Mac/Xcode 和自己的签名/服务；当前没有商店安装包。 |
| Android 呢？ | 规划中，当前没有公开客户端。欢迎从共享空间同步和文字闭环开始贡献，不能宣称所有品牌已兼容。 |
| 是心力球的第三方 App 吗？ | 不是。使用 CB08 和自己的后端，不连接 OPPO 硬件或服务。 |
| 200 元能全部跑起来？ | 不到 200 元仅指维护者所用录音卡硬件参考价，模型、ASR、服务器及手机/电脑另计。 |
| 没录音卡能试吗？ | 可以。无密钥跑合成 HTML 演示；有自己的文字模型后用原生 App 补记跑完整文字路径。 |
| 能直接连 Codex/Claude 吗？ | 目前没有 MCP server；只读适配器是明确的 Fork 方向。 |

# 心力卡首页与传播素材交付

2026-10-23。公开仓库主分支提交 `cebae25961fca573f1791a140e83f819b1ff4d84`。已更新中英文 README、仓库简介/完整运行链接/topics，以及 GitHub Social preview（自制 1280×640）。

核心信息：iPhone/Mac 已有原生源码；项目所用录音卡硬件不到 200 元（用户本轮提供的维护者价格参考，非商家核验或整套成本）；Android 跨品牌适配为下一步，未实现不写成已支持。

OPPO 品牌限制按 10 月 16 日极客公园实机报道准确表述为 OPPO/一加/Realme，其他品牌当时暂不支持；不作永久限制或官方完整清单断言。没有采购卡、引导未核验店铺或宣称心力球硬件兼容。

公开成果：

- [首页](https://github.com/jingchang0623-crypto/xinlika)
- [素材总入口](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/launch/README.md)
- [中英文传播文案](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/launch/copy.md)
- [演示与 75 秒拍摄脚本](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/launch/demo.md)
- [Fork 指南](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/fork-guide.md)
- [Android 分阶段计划](https://github.com/jingchang0623-crypto/xinlika/blob/main/docs/android-plan.md)

重新运行完整原生 UI 测试 1 项通过，导出三个原始截图及 SHA-256，使用真实 UI/HTTP/SQLite/LangGraph、合成输入和固定模型。封面、三帧排版、12 秒 GIF/MP4 均内嵌合成标注；轮播不称连续录像。原生派生素材按 GPL-3.0-only，文档按 MIT。固定模型回显原文与更正的局限原样保留，没有重绘成更好的回答。

验证：合成演示 5/5，演示回归 1/1，Markdown 文件链接、Fork 文件入口、YAML、原图哈希、媒体尺寸/时长、diff whitespace 均通过。GitHub 在线页面的封面/GIF 载入成功，移动 390px 视口图宽 324px，无图片越界；OG image 已是新上传预览。新提交自动触发后端和原生 CI，结果见 Actions；不把执行中写成通过。

本轮未发社交帖、评论、私信或预约传播。仅在已授权公开仓库中更新代码/文档与简介/预览；本机合成服务和预览服务已结束。实际卡、旧安装 App 和生产服务没有操作。

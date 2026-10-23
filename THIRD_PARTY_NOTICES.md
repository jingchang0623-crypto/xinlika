# 第三方组件与授权范围

MIT 只适用于本仓库发布且有权许可的代码与文档，不为外部服务、模型权重或未发布客户端授予权限。

| 项目 | 用途 | 已记录许可证 |
|---|---|---|
| [LangGraph](https://github.com/langchain-ai/langgraph) / SQLite Checkpointer | 可恢复处理图 | MIT |
| [OpenAI Python SDK](https://github.com/openai/openai-python) | 兼容模型与语音 API 客户端 | Apache-2.0 |
| [Pydantic](https://github.com/pydantic/pydantic) | 结构与引用校验 | MIT |
| [HTTPX](https://github.com/encode/httpx) | SDK 传输 | BSD-3-Clause |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 可选 VAD、声音标签、说话人向量 | Apache-2.0；模型单独核对 |
| [voxgate](https://github.com/WEIFENG2333/voxgate) | 现有研究语音适配器 | MIT；非公开上游服务使用条件另计 |

上述是开发记录中的版本与许可信息，依赖版本固定于 requirements 文件；未将依赖源码、模型文件、voxgate 二进制或厂商 SDK 打包进本仓库。声学引擎是可选模块，基础安装不包含 numpy/sherpa-onnx 和权重。

Omi、OpenClaw、Hermes、OpenMuse 是行为或架构参考。中文提示词为本项目编写，固定参考版本见 [SOURCES](prompts/personal-agent/SOURCES.md)。没有复制其完整系统提示词或声称已运行整套应用。

旧 Swift 客户端基于 `qiuyiwu1989-star/shennao-mac` 等既有工程。2026-10-23 GitHub 元数据未声明许可证，故未将这些客户端及厂商 SDK 纳入 MIT 发布。独立后端不需要这些文件即可运行。用户或贡献者提供未来客户端代码时，须说明其权利来源。

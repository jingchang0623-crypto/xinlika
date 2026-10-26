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

Omi、OpenClaw、OpenMuse 是行为或架构参考。Hermes 与 DeepSeek Harness 通过可选子进程适配使用；不包含它们的源码或安装环境。中文提示词为本项目编写，固定参考版本见 [SOURCES](prompts/personal-agent/SOURCES.md)。没有复制其完整系统提示词或声称已运行整套应用。

原生客户端现位于 `clients/`，经权利人明确确认按 GPL-3.0-only 再发布，根 MIT 不适用于该路径。其 Swift 原生实现不链接厂商静态库/AAR/HAR/固件，也不包含旧账户接口或 Swift Markdown 阅读路径。逐项来源和授权边界见 [客户端授权核查](docs/client-licensing.md) 与 [客户端来源](clients/PROVENANCE.md)。

## 发布视觉素材

`assets/launch/` 使用本项目 GPL 原生客户端实际 UI 截图并制作排版，按 GPL-3.0-only 提供，保留原生上游归属。原图由合成测试生成，不包含厂商图片或商标图形。见 [素材来源](assets/launch/README.md)。

## 可选 Agent 与优化依赖

`requirements-agent-runtime.txt` 固定 MCP Python SDK 1.30.0（MIT）和 DeepSeek Harness SDK 0.2.1rc2（MIT）；安装时获取其上游分发，不把二进制或依赖源码复制进本仓库。Hermes 使用操作者另建的环境；Harness² 优化器固定上游提交于 `requirements-harness2.txt`，独立安装，不在录音服务中自动运行。参考与版本记录见 `prompts/` 及相关技术说明；实际调用模型/外部 MCP 需要操作者配置权限与费用。

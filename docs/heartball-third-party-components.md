# 心力卡处理链路的开源组件

以下版本在 2026-10-21 本机实际安装或构建，不代表上游最新版本。Python 直接依赖固定在 `requirements-heartball.txt`；运行环境和私有服务位于 `.build`，未将依赖源码或模型凭据复制进业务代码。

| 组件 | 本次实际复用 | 固定版本／来源 | 根许可证 |
|---|---|---|---|
| voxgate | 音频转写 API、FFmpeg 解码及现有 15 秒内部分段补丁；不重写输入法协议 | `WEIFENG2333/voxgate`，`da98bb5ff9ce913b4317081a00e9e0c51f080edf` | MIT |
| LangGraph | 抽取→保存→评估及记忆查询的状态图，失败节点恢复 | 1.2.16 | MIT |
| LangGraph SQLite Checkpointer | 持久化节点输出，保存失败后复用已经完成的模型抽取 | 3.1.2 | MIT |
| OpenAI Python SDK | 调用兼容的转写和文本模型接口，超时及错误分类 | 2.54.0 | Apache-2.0 |
| Pydantic | 抽取、记忆引用及回答的结构校验 | 2.14.1 | MIT |
| HTTPX | SDK 的 HTTP 传输 | 0.28.1 | BSD-3-Clause |
| 现有 Swift CB08 / Ogg 模块 | BLE 接收、完整卡上参考、封装与身份保护 | 当前工程 | 保留现有代码与第三方 SDK 的授权边界 |

项目和源代码：[voxgate](https://github.com/WEIFENG2333/voxgate)、[LangGraph](https://github.com/langchain-ai/langgraph)、[OpenAI Python](https://github.com/openai/openai-python)、[Pydantic](https://github.com/pydantic/pydantic)、[HTTPX](https://github.com/encode/httpx)。许可证信息核对安装包 metadata 与本机 voxgate 固定源码。voxgate 的非公开语音后端仍作为研究适配器，代码许可不代表第三方服务授权或生产可用性。

Omi 与 OpenMuse 在本轮是架构参考，没有声称部署整套产品或直接运行其云服务：沿用既有固定源码研究中的证据版本、到期复核、反馈失效、任务租约与恢复思路。具体业务规则留在小型适配层：录音权限、原声范围、用户确认、来源过滤和纠正。这些规则不由通用 Agent 框架自动保证。

外部参考的版本与能力边界见 [既有深入核查](personal-agent-oss-and-hardware-deep-dive-2026-10-20.md)。语音方案也复用了用户指定的 调研会话（私有会话，不随公开仓库分发） 中已经跑通的 voxgate 服务端路径。

LangGraph 的外部 tracing 显式关闭；模型结果、检查点、音频和凭据均保存在私有 `.build`。本轮没有引入第二套记忆权威数据库，也没有同时安装 Omi、OpenMuse、Mem0、Graphiti 等完整应用。

## 0.4.0 语义整理

新事件/主题流程继续使用已有 LangGraph 和 SQLite Checkpointer，以及 OpenAI SDK / Pydantic，没有新增一套 Agent 框架。新文档在一次模型抽取中同时产出事件；旧转写单独补整理，不重跑 ASR。业务账本、CB08 录制时间来源和纠正失效逻辑属于本项目适配代码。Omi/OpenMuse 仍是已固定源码的架构参考，未声称整套部署或直接移植。普通记录可自动整理与查询，不再以逐条用户确认为前置条件。详见 [交付](xinlika-semantic-workspace-2026-10-21.md)。

## 2026-10-23 原生 Agent 适配实验

| 新组件 | 实际复用 | 固定版本／来源 | 框架根许可证 |
|---|---|---|---|
| Hermes Agent | 原生 `AIAgent` 模型／工具循环、MCP、会话与压缩；独立虚拟环境 | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)，`3ba2b0787ed3a73ec3b08085ed0137f235209cf4` | MIT |
| DeepSeek Harness | 官方 Python SDK 所启动的原生执行进程、MCP 与插件配置；非自建仿制循环 | [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)，`687f282e8625c6b8d11ff58211a90524be2e4317`；SDK `0.2.1rc2` | MIT |
| MCP Python SDK | 领域工具服务、外部只读 stdio 服务、外部 MCP 客户端 | [modelcontextprotocol/python-sdk](https://github.com/modelcontextprotocol/python-sdk)，`1.30.0` | MIT |

直接依赖另列于 `requirements-agent-runtime.txt`。这些框架的根许可不替代附加依赖自己的许可。当前为私有隔离回放与可选处理分支，没有把第三方运行环境、模型凭据或真实转写放进发布包。事实、纠正、授权、音频和时间戳仍由既有业务账本管理。原生框架负责推理执行，未引入另一个会与纠正状态冲突的记忆权威库。详细方法与实测边界见 [统一适配说明](xinlika-agent-adapter-2026-10-23.md)。

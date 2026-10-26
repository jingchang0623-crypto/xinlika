# v6、MCP 与文件导入

main 的公开布局沿用 `clients/` 原生端与 `scripts/` 后端；开发日志中的根 `iOS/`、`Sources/` 对应公开版 `clients/iOS/`、`clients/Sources/`。日志是特定开发环境的记录，不是本次公开包重新通过真机验收。

先按 [完整运行](full-app.md) 启动默认后端。新版客户端仍可连接未启用 v6 的服务；启用关注反馈需要服务返回 `eventInterestProtocol=1`。

## 明确启用 v6

在独立 Python 3.12 环境安装：

```sh
.venv/bin/python -m pip install -r requirements-agent-runtime.txt
.venv/bin/python scripts/configure-workspace.py \
  --base-url https://YOUR_SERVICE_HOST \
  --model-url https://YOUR_MODEL_HOST/v1 --model YOUR_MODEL \
  --asr-url https://YOUR_ASR_HOST/v1 --asr-model YOUR_ASR_MODEL \
  --processing-profile xinlika-events-v6
```

将示例主机/模型换成你有权使用的接口。密钥通过 `XINLIKA_MODEL_API_KEY`、`XINLIKA_ASR_API_KEY` 环境变量提供；不在命令里写密钥。配置只写到被忽略的 `private-config/`，已存在时拒绝覆盖。无 ASR 的文字模式可省略两项 `--asr-*`。相应依赖需安装在生成配置所用的同一 Python 环境。

`agent_runtime` 使用 DeepSeek Harness 子进程处理问答等任务，v6 事项路径使用增量编辑器与滚动/跨对话复核；模型接口可以单独选择。Hermes 适配器另需其支持的独立环境，不随基础安装自动下载。两者是同一业务契约的可选运行时，不代表任意模型都通过本项目语义验收。

公共配置保留通用兼容 ASR，也保留显式的 voxgate 适配选项，二者不可同时设置。不要只改 API 地址冒充更换完整处理协议。已有部署升级应备份账本，按维护窗口或经过验证的 handoff 机制执行；本文命令不会自动迁移运行中的服务。

## 外部 Agent 读取

```sh
.venv/bin/python scripts/xinlika-mcp.py --connection private-config/connection-mac.json
```

将这条 stdio 命令填入支持 MCP 的 Agent 配置，并使用绝对路径。连接文件含设备凭据，不应提交。默认只暴露查上下文与读取精确来源，不开放修改记忆或操作硬件；来源修订/失效和权限仍由服务端校验。内部分析工具只允许专用隔离账本及明确的 analysis task。

外部 MCP 入口另用操作者持有的配置指定 `tool_allowlist`、显式环境变量白名单或 HTTPS `headers_env`；不从聊天正文执行命令，也不把微信导出内容当系统指令。

## 导入已有导出文件

```sh
.venv/bin/python scripts/xinlika-import-context.py --help
```

支持显式选择的 JSON/TXT/HTML 聊天导出；记录来源、原始时间、说话人、文件哈希和去重身份。导入是第三方观察，不直接成为本人承诺。原文件与正文留在私有运行目录；导入、是否分析和外部 MCP 调用均需操作者明确选择。此版本不包含微信解密或自动读本机微信数据库。

## 验证边界

v6 的冻结 Skill 与既有脱敏指标保留；公开版改用不含硬件控制的 HTTP 组件并更新相应代码哈希，未借发布重复使用留出集调提示词。测试不重复 ASR，也不联系真实模型、录音卡或现有服务。首页准入、误归并、跨对话漏关联与不恢复原文的纠正关系稳定性仍需持续实录评估。Harness² 保持离线、可选和显式预算，不在日常采集中自动优化。

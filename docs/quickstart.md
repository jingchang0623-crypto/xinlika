# 运行心力卡后端

完整 iPhone/Mac 录音与多端闭环见 [完整应用指南](full-app.md)。客户端 GPL-3.0-only，后端 MIT。

## 1. 无凭据演示

使用 Python 3.11+，新建虚拟环境，安装 `requirements-heartball.txt` 后运行：

```bash
python examples/demo.py
```

演示创建独立 `.build/demo-*` 目录，写入合成文字和确定性模型夹具，走实际 LangGraph、SQLite、引用和纠正链路。它不会连接硬件或远端模型，不覆盖已有目录。HTML 和 JSON 是可复查的快照报告，切换纠正前后只是切换报告视图。

## 2. 启动单用户、多设备共享服务

macOS / Linux 上运行，服务不控制录音卡。先建立一份空处理配置；即便未配置模型，认证、接收和同步协议也能启动。

```bash
mkdir -p private-config
cp examples/processing.example.json private-config/processing.json
python scripts/heartball-shared-service.py device add \
  --root .build/my-workspace --name local-editor \
  --base-url http://127.0.0.1:18778 \
  --output private-config/connection.json
python scripts/heartball-shared-service.py serve \
  --root .build/my-workspace --port 18778 \
  --processing-config private-config/processing.json
```

示例配置为 `{}`，所以此时不会转写或调用模型。设备凭据只保存到输出文件，不打印。运行另一台设备时单独生成凭据；只读设备使用 `--access reader`。撤销命令：`device revoke --root .build/my-workspace --id DEVICE_ID`。

服务默认 `127.0.0.1`。手机无法访问电脑的 loopback；局域网需显式私有 IP，公网需 HTTPS/TLS 与自己的域名。当前空间只服务一个用户，多设备不能当作多用户隔离。

## 3. 接入真实文字模型

创建你自己的私有配置，使用明确授权的兼容模型接口。以下是配置形状；将地址与模型名称替换成你实际拥有的服务。密钥从环境变量读取：

```json
{
  "model": {
    "base_url": "https://your-provider.example/v1",
    "api_key_env": "XINLIKA_MODEL_API_KEY",
    "model": "your-model-name"
  }
}
```

设置环境变量后重启你新建的开发服务。`model` 配置仅开启文字理解；不会自动获得语音识别。客户端调用示例：

```bash
python examples/client.py text "云杉项目演示版计划下周三交付。" \
  --occurred-at 2026-10-23T10:00:00+08:00
python examples/client.py state --day 2026-10-23
python examples/client.py ask "云杉项目什么时候交付？"
```

问答和整理是异步任务，稍后 `state` 查看 `processingJobs` 与 `answers`。普通文字记录无需逐条确认即可整理和检索。正式个人声明与观察记录区分保存，录音里的“我”不默认是设备主人。

客户端默认读取 `private-config/connection.json`；输出内容来自你的私有空间，不要粘贴进公开 Issue。

## 4. 接入语音与采集

公开后端保留开发阶段 `VoxgateAdapter`，通过私有配置的 `voxgate_config` 路径连接 loopback 研究服务。该服务未随首发安装或启动，且其非公开上游有独立使用条件。它不是生产服务授权，也不作为“免费语音 API”卖点。现可使用 `asr` 配置连接自己的授权兼容语音服务，见 [完整应用指南](full-app.md)。

`heartball_mobile.py` 定义手机接收消息：批次、重点、缺口、完成、卡上参考与跨文件续段。消息包含逻辑会话、物理文件、录制时间、流身份、序号、字节范围与哈希，服务拒绝同身份不同内容。默认 60 秒、最大 300 秒；当前原声格式针对已验证的 CB08 40B/20ms 参数，不接受把任意音频冒充该格式。

v0.2.0 包含原生 BLE 客户端，不包含固件，也不提供给心力球刷机或接入 OPPO 服务的方式。声音模型旁路需要 numpy、sherpa-onnx 与各自授权权重，基础安装不含这些大文件。

## 5. 测试与恢复

```bash
python -m unittest discover -s scripts -p 'test_*.py'
python -m unittest discover -s examples -p 'test_*.py'
python scripts/heartball_backup.py --help
```

备份使用 SQLite 一致快照和封存音频对象；恢复到新目录，不覆盖在线数据。没有自动异机备份或容量告警的完成承诺。CI 测试不使用模型密钥，不上传实际音频。

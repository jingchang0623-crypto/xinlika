# 独立声音模型进程

在共享服务源码导出目录中构建：

```sh
docker build -f Dockerfile.acoustics --build-arg APPLICATION_IMAGE=xinlika-shared:local -t xinlika-acoustics:local .
```

锁文件针对 Python 3.12 / Linux AMD64，完整校验三个官方 PyPI wheel 的 SHA256。离线构建可预先下载锁文件对应 wheel，使用 `--no-index --find-links`；不把模型、音频、声纹或凭据打入镜像。

模型目录需包含 `silero_vad.onnx`、`wespeaker_zh_cnceleb_resnet34.onnx`，以及 `sherpa-onnx-zipformer-small-audio-tagging-2024-04-15/` 下的 `model.int8.onnx` 和 `class_labels_indices.csv`。使用与验证记录一致的模型哈希。模型由 sherpa-onnx 官方发布；首次部署前核对模型来源、许可证及文件哈希。标签分数和声纹相似度尚未做现场校准。

设置 `XINLIKA_ACOUSTIC_MODELS` 为服务器上模型的绝对目录，`XINLIKA_DATA_VOLUME` 为既有 API 数据卷名。可使用 `compose.acoustics.yaml` 单独启动 worker；该文件只引用外部既有数据卷。也可与 API compose 合并，但首次接管已有生产容器前需核对容器名称和卷映射，避免另建空白服务。运行时无网络、无 API 密钥、不连接录音卡；只共享持久账本和只读模型目录，CPU 0.5、内存 768 MiB。

首次启动从当前批次末尾建立游标，后续只自动分析新封批、已授权整理的音频。声纹登记另需显式登记、独自说话确认、原上传设备归属及三个独立会话。不会默认回扫整卡或历史档案。`--backfill-batch-id` 仅用于有明确授权的单个已选批次。

队列将模型版本和音频哈希作为幂等身份，运行中租约到期可恢复，失败最多尝试四次。健康检查读持久心跳；业务失败需同时检查 `/v1/acoustics` 的任务状态。声音推理不重调 ASR，模型证据到达后触发现有整理链路更新。

声纹相近仅是候选：本人录音回放也可能匹配。它不会把 `personal_attribution_allowed` 改为 true，不会把会议他人发言直接写成用户承诺。停用声纹会清除当前样本向量、配置向量和匹配结果；原声及既有备份仍遵循原保留策略，不代表所有副本已擦除。

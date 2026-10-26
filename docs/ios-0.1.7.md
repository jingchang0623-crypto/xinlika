# 0.1.7：录音控制真机诊断

> 后续：0.1.8 已通过另一组命令实现 CB08 / V1.0.0 的真实开始与保存，见 [修复与硬件验证](ios-0.1.8.md)。下方保留定位过程中各阶段的原始结论。

## 已确认的问题

2026-09-07，用户在 iPhone 16 Pro 上测试 0.1.6 (7)，开始和结束均提示“操作结果未确认”，硬件没有变化。0.1.7 (8) 增加诊断后，用户再次复现。

两轮真实开始操作（北京时间 12:06:39、12:06:57）结果一致：操作前 `3-19 → 3-20 body=02`；App 向 AE21 发出一次空参数 `TYPE=3 CMD=1`，3 秒内没有 `3-2` 应答；随后连续只读查询均返回 `3-20 body=02`，硬件没有开始录音。硬件响应 SEQ 独立递增，实现按 TYPE/CMD 匹配，没有错误要求回显请求 SEQ。

开始失败不能归因于界面刷新或仅仅等待不足。当前证据是这张卡未执行这组命令，不能据此推断所有固件或所有远程录音命令均不支持。结束失败有用户反馈，尚没有同等级别的命令回包证据。

原始日志：`/tmp/shennao-017-recording-diagnostics-1.json`。设备内路径：`Library/Application Support/Shennao/recording-diagnostics.json`。最多保留 300 条控制事件，不记录音频、文件名、设备 UUID 或凭据。

## 协议依据

对照 [协议](https://github.com/lomehong/record/blob/master/docs/协议.md)、[设备封装](https://github.com/lomehong/record/blob/master/recorder/device.py) 和 [传输实现](https://github.com/lomehong/record/blob/master/recorder/ble.py)，上游 master 为 `ac762fea4cb3372fa87d0739310796f216902a23`，帧格式、AE21 写入方式一致。

上游列出的实测覆盖连接、电量、文件列表、下载和 CRC 等，没有将远程开始、保存列为已经验证的能力。0.1.6 模拟测试可以验证状态机，不能证明固件支持录音控制。

另有 `1-0` 开始实时转写、`1-2` 停止实时转写、`1-3` 暂停或继续。用于独立录音前必须实测状态变化、断开蓝牙后继续录音、停止后卡上文件存在，不能仅凭命令名称认定等价。

## 改动与验证

- 增加受限的发送、接收、超时诊断和操作标识。
- 控制只发送一次，随后只读轮询确认延迟状态；区分拒绝、无应答、状态未变和无法读回。
- 仅 Debug 提供 `--probe-recorder-id <UUID>` 独立入口。只连接指定设备，先确认空闲；不创建云端客户端、不进入同步流程、不下载或持久化音频、不删除文件。Release 不包含入口。
- 104 项单元测试通过（20 项录音控制），0 失败：`/tmp/shennao-ios-017-unit.xcresult`。
- 9 项录音控制 UI 测试通过，0 失败：`/tmp/shennao-ios-017-ui.xcresult`。
- `swift build`、Release 构建及签名检查通过。
- Release 0.1.7 (8) 覆盖安装后于 12:06 成功启动，随后取得上述失败证据。

替代命令诊断包已构建并安装；首次启动被 iOS 因手机锁屏拒绝（CoreDevice 10002 / FBSOpenApplicationErrorDomain 7），随后设备清单显示 iPhone unavailable，尚未执行任何替代录音命令。安装和启动证据为 `/tmp/shennao-017-probe-install.json`、`/tmp/shennao-017-probe-launch.json`，连接状态为 `/tmp/shennao-017-current-devices.json`。需重新连接、解锁后继续，当前不标记问题已修复。

诊断入口通过显式启动参数开启；普通点击 App 图标不会自动运行硬件探测。新增诊断入口已通过 Debug 真机构建；上述 104 项单元与 9 项 UI 测试在加入独立入口之前完成。共享核心另通过 60 项自检，缺少本地音频样本的一组对照跳过，日志 `/tmp/shennao-017-core-selftest.log`。

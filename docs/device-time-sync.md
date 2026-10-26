# 蓝牙连接后自动校时

日期：2026-09-06。

2026-10-21 心力卡更新：产品采集现在仅在确认空闲、创建专用新文件前自动校时，重连和参考下载不改钟。三次新文件名已与主机开始命令核对成功，容差为 2 秒；有写入日志也有独立文件名验证，不能等同于 RTC 读回或采样级对时。当前路径与实测限制见[真实会议闭环验证](xinlika-real-loop-2026-10-21.md)。以下保留旧客户端实现的历史说明，不代表心力卡采集探针的连接策略。

当前 Swift App 原本没有发送校时命令。参考项目已提供同型号 QS668/CB08 的校时协议，因此可以通过 App 在蓝牙连接成功后设置硬件时间，无需新增手机端权限或网络请求。用户这台硬件的实际执行效果仍需真机确认。

## 协议依据

参考 [lomehong/record](https://github.com/lomehong/record/tree/ac762fea4cb3372fa87d0739310796f216902a23)，检查的是提交 `ac762fea4cb3372fa87d0739310796f216902a23`。

- [protocol.py](https://github.com/lomehong/record/blob/ac762fea4cb3372fa87d0739310796f216902a23/recorder/protocol.py#L125)：`TYPE=0 / CMD=0`，参数是年份 2 字节小端，加月、日、时、分、秒各 1 字节，共 7 字节。完整帧 15 字节，使用现有 CRC-16/XMODEM。
- [device.py](https://github.com/lomehong/record/blob/ac762fea4cb3372fa87d0739310796f216902a23/recorder/device.py#L234)：取 `time.localtime()`，明确标注无应答。
- [cli.py](https://github.com/lomehong/record/blob/ac762fea4cb3372fa87d0739310796f216902a23/recorder/cli.py#L175)：连接后自动调用校时。

## 实现

`BLEClient.connect` 等 AE21 写入特征和 AE22 通知订阅就绪后调用 `syncTime()`，随后才向上层返回。因此首次同步、下载中断后的重新连接，以及系统恢复后重新走连接流程，都会发送当时的系统时间。iOS、Mac App 和 Swift CLI 共用这一入口。系统只恢复了外设引用、尚未重新完成连接流程时，不会提前发送。

`Proto.buildTimeSync` 固定使用公历，并按每次调用时的系统时区计算年月日时分秒；不依赖用户选择的佛历等日历，也不把 UTC 或固定 UTC+8 当作当地时间。字段用普通整数，非 BCD。不能用协议表示的日期会抛出错误。

校时命令不等待应答、不读取通知队列，不增加等待超时，也不会消费电量、文件列表或下载应答。每次连接发送一次，不在持续下载期间定时插入校时。连接保持期间若系统时间或时区变化，将在下一次连接时更新硬件。

这项变更设置设备当前时钟，不重命名既有录音，也不回写历史录音日期。过去以错误时钟创建的文件名不会自动修复；正在录制文件的行为和后续新文件命名需要在该固件上验收。

## 验证

协议校验采用独立 Python `struct.pack('<H5B', ...)` 和 `binascii.crc_hqx` 生成的完整帧向量，并覆盖时区跨日跨年、夏令时、闰日和无效日期。

本轮结果：

- `swift build` 成功，涵盖 Mac App、Swift CLI 与共用核心。
- `swift run -q CoreSelfTest`：60 项断言通过、0 失败，其中新增 8 项校时断言；既有本机音频样本对照因无样本跳过。
- iOS `ShennaoTests`：52 项通过、0 失败，其中新增 6 项协议测试。使用 iPhone 17 Pro / iOS 26.5 模拟器，实际构建正式 `Shennao` target；本轮未运行 UI 测试。结果包 `/tmp/shennao-clock-unit-tests.xcresult`，日志 `/tmp/shennao-clock-ios-tests.log`。
- 检查调用顺序：校时位于服务发现/通知订阅完成之后、`connect` 返回之前，无 `await expect`，因此不会抢读后续业务通知。此项为代码检查，不替代真机蓝牙验证。

复现 iOS 验证：

```sh
xcodebuild -project Shennao.xcodeproj -scheme Shennao \
  -destination 'id=65F68B44-C13E-4864-AE11-83D5C6C1B950' \
  -derivedDataPath /tmp/shennao-ios-013-build \
  -clonedSourcePackagesDirPath /tmp/shennao-ios-packages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -only-testing:ShennaoTests CODE_SIGNING_ALLOWED=NO test
```

真机验收步骤：

1. 安装包含此修改的新版 App，让录音笔处于待机，执行连接同步，对照手机与设备屏幕的日期和时间。
2. 断开后再次连接，确认再次校时，且电量/列表查询、下载正常。
3. 校时后新录一段短录音，检查新文件名的日期时间；已有文件保持原名。
4. 下载中断并重连，检查断点恢复；录音中连接则另外检查显示时间和录制连续性。

协议没有校时 ACK 或当前时钟读回命令，代码写入完成不能证明硬件时钟已更新；不能把模拟器单元测试描述成真机校时通过。本次尚未安装到用户手机，也未发布 TestFlight。

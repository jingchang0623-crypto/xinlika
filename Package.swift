// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Luyinbi",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WatchCaptureCore", path: "SharedCapture"),
        .testTarget(name: "WatchCaptureCoreTests", dependencies: ["WatchCaptureCore"], path: "Tests/WatchCaptureCoreTests"),
        // 纯逻辑层：帧编解码、字段解析、Ogg 封装、删除判据。不依赖任何 UI 或蓝牙，
        // 因此可以在命令行下完整自测。
        .target(name: "LuyinbiCore"),
        // 自测跑成可执行目标：纯命令行工具链没有 XCTest（那要完整 Xcode）。
        .executableTarget(name: "CoreSelfTest", dependencies: ["LuyinbiCore"]),
        // 删除判据的自测（纯 CLT 没有 XCTest，所以每套测试都是可执行目标）
        .executableTarget(name: "CleanupSelfTest", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "VoiceSelfTest", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "AuditSelfTest", dependencies: ["LuyinbiCore"]),
        .target(name: "CB08ProbeSupport", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "CB08ProbeSelfTest", dependencies: ["CB08ProbeSupport", "LuyinbiCore"]),
        .executableTarget(name: "HeartballLab", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "HeartballClientCheck", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "XinlikaWorkspaceCheck", dependencies: ["LuyinbiCore"]),
        // Separate local experiment: no cloud, file deletion, or production UI changes.
        .executableTarget(
            name: "cb08-probe", dependencies: ["CB08ProbeSupport", "LuyinbiCore"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/cb08-probe/Info.plist",
            ])]),
        // 菜单栏 + 主窗口。
        // 这里**不**用 -sectcreate 嵌 Info.plist：
        //   1. 正常 .app 读的是 Contents/Info.plist，嵌一份等于留两个真相；
        //   2. 更要命的是源码放在 iCloud 里，同步时文件会被短暂锁住/驱逐，
        //      链接器读不到就报 "link command failed"——表现为改完源码第一次构建必失败、
        //      重试又好，极难定位。裸 CLI（luyinbi-cli）没有 bundle 才必须保留这招。
        .executableTarget(
            name: "LuyinbiApp",
            dependencies: ["LuyinbiCore"],
            exclude: ["Info.plist"]),
        // 命令行工具：真机验证蓝牙层，UI 出来之前就能用。
        // 关键：把 Info.plist 嵌进二进制的 __TEXT,__info_plist 段。
        // CoreBluetooth 要读得到 NSBluetoothAlwaysUsageDescription，否则进程直接 SIGABRT
        // 且日志全空。裸二进制没有 bundle，只能靠这个链接器技巧——
        // 这也让我们彻底摆脱了「把 python 塞进 .app 壳里」那套绕法。
        .executableTarget(
            name: "luyinbi-cli",
            dependencies: ["LuyinbiCore"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/luyinbi-cli/Info.plist",
            ])]),
    ]
)

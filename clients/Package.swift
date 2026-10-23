// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "XinlikaClients",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "XinlikaMac", targets: ["HeartballLab"]),
               .executable(name: "cb08-probe", targets: ["cb08-probe"])],
    targets: [
        .target(name: "LuyinbiCore"),
        .target(name: "CB08ProbeSupport", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "HeartballLab", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "cb08-probe", dependencies: ["CB08ProbeSupport", "LuyinbiCore"],
                          exclude: ["Info.plist"], linkerSettings: [.unsafeFlags([
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                            "-Xlinker", root + "/Sources/cb08-probe/Info.plist"])]),
        .executableTarget(name: "CB08ProbeSelfTest", dependencies: ["CB08ProbeSupport", "LuyinbiCore"]),
        .executableTarget(name: "XinlikaWorkspaceCheck", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "HeartballClientCheck", dependencies: ["LuyinbiCore"]),
        .executableTarget(name: "NativeWorkspaceCheck", dependencies: ["LuyinbiCore"])
    ])

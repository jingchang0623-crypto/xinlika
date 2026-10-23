# Native client source and licensing

`clients/` is licensed under **GPL-3.0-only**, including the Swift native apps, the BLE/protocol module, capture tools and the local desktop daemon. The repository's root MIT license does not relicense these files. See [LICENSE](LICENSE).

The native foundation originated in [qiuyiwu1989-star/shennao-mac](https://github.com/qiuyiwu1989-star/shennao-mac), local baseline commit `9587788`, attributed to qiuyiwu1989-star. Xinlika's iPhone capture/store/upload UI and Mac workspace were subsequently developed in this project. The rights holder explicitly confirmed authority to republish the relevant client code under GPL-3.0 on 2026-10-23. This is a grant for this release; it does not imply that the upstream repositories' default branches now have a license.

[shennao-app](https://github.com/qiuyiwu1989-star/shennao-app) is an Android project; no Android source is included in this native release. The iPhone client is the Swift implementation from this workspace, not an Android port.

The original native foundation's protocol comments refer to Python research and public protocol descriptions, including `lomehong/record`, whose root license was not found. No Python code or assets from that repository are copied into this release. The native protocol format and clock payload were also cross-checked against the device vendor's published protocol facts; the clock builder is independently re-expressed in this release. This is not a claim of clean-room development.

The vendor [SonicloudTech/sonicloud_opensdk](https://github.com/SonicloudTech/sonicloud_opensdk/tree/f10cd9bf2a2341566d923818602ac93fb9246091) has an MIT license for example code, but its README's “许可与使用边界” separately reserves possible proprietary terms for AAR/static libraries/HAR/firmware and some documents. **No vendor binary SDK, firmware, model weights, commercial cloud credentials or copied vendor documentation is included or required to build these clients.** BLE uses Apple's CoreBluetooth; containers/audio use project source and system APIs. No copied Swift Markdown dependency is needed by the Xinlika-only path.

Source hashes and file origins are recorded in [source-manifest.json](source-manifest.json). New packaging removes the old account flow, private service addresses, development team, signing identity and old app assets. Use your own signing team and a unique bundle identifier on a physical iPhone.

Apple SDKs and Xcode are platform prerequisites, not redistributed by this repository. Backend Python files outside `clients/` remain MIT. The GPL desktop daemon invokes the GPL capture executable and imports the MIT backend; distribute that combined desktop component under GPL with corresponding source and notices.

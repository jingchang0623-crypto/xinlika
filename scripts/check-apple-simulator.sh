#!/bin/bash
set -euo pipefail
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
mkdir -p .build/checks
xcodegen generate
simulator_id=$(xcrun simctl list devices available --json | python3 -c '
import json,sys
devices=json.load(sys.stdin)["devices"]
phones=[d for runtime,rows in devices.items() if ".iOS-" in runtime for d in rows if d["name"].startswith("iPhone")]
if not phones: raise SystemExit("No available iPhone simulator runtime")
print(sorted(phones,key=lambda d: (d["name"]!="iPhone 17",d["name"]))[0]["udid"])
')
# Keep previous result bundles intact; use a new path for each local invocation.
result_path="$project_root/.build/ci-simulator.xcresult"
if [ -e "$result_path" ]; then
    result_path="$project_root/.build/ci-simulator-$(date +%Y%m%d%H%M%S).xcresult"
fi
if ! xcodebuild -project Shennao.xcodeproj -scheme Shennao \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -configuration Debug -derivedDataPath .build/ci-simulator-derived-data \
    -resultBundlePath "$result_path" -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO test > .build/checks/ios-simulator.log 2>&1; then
    tail -100 .build/checks/ios-simulator.log >&2
    exit 1
fi
echo "Simulator unit and UI tests passed: $result_path"

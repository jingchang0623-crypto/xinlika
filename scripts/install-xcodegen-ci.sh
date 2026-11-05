#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?Run from GitHub Actions}"
: "${GITHUB_PATH:?Run from GitHub Actions}"
tools_dir="$RUNNER_TEMP/xinlika-xcodegen"
mkdir -p "$tools_dir"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip \
    --output "$tools_dir/xcodegen.zip"
printf '%s  %s\n' 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 "$tools_dir/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$tools_dir/xcodegen.zip" -d "$tools_dir"
"$tools_dir/xcodegen/bin/xcodegen" --version
echo "$tools_dir/xcodegen/bin" >> "$GITHUB_PATH"

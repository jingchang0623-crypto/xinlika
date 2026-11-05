#!/bin/bash
# Intended for an ephemeral GitHub-hosted macOS runner, after the quality gate.
set -euo pipefail
umask 077
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
python3 scripts/prepare-apple-signing.py --check-inputs
: "${RUNNER_TEMP:?Run from GitHub Actions}"
: "${GITHUB_RUN_NUMBER:?Run from GitHub Actions}"
: "${GITHUB_RUN_ATTEMPT:?Run from GitHub Actions}"
signing_dir=$(mktemp -d "$RUNNER_TEMP/xinlika-signing.XXXXXX")
spec_path=$(mktemp "$project_root/.ci-signing-XXXXXX.json")
keychain_path="$signing_dir/signing.keychain-db"
profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles_dir" .build
cleanup() {
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    for target in Shennao XinlikaWatch; do
        rm -f "$profiles_dir/xinlika-ci-$GITHUB_RUN_ID-$target.mobileprovision"
    done
    rm -f "$spec_path"
    rm -rf "$signing_dir"
}
trap cleanup EXIT
export XINLIKA_SIGNING_DIR="$signing_dir"
python3 - <<'PY'
import base64,os
from pathlib import Path
root=Path(os.environ['XINLIKA_SIGNING_DIR'])
for key,name in [('APPLE_DISTRIBUTION_P12_BASE64','distribution.p12'),
                 ('IOS_APPSTORE_PROFILE_BASE64','Shennao.mobileprovision'),
                 ('WATCH_APPSTORE_PROFILE_BASE64','XinlikaWatch.mobileprovision'),
                 ('ASC_PRIVATE_KEY_BASE64','AuthKey.p8')]:
    (root/name).write_bytes(base64.b64decode(os.environ[key],validate=True))
PY
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$signing_dir/distribution.p12" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" \
    -k "$keychain_path" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain_path" >/dev/null
# The hosted runner is discarded after the job; don't change a developer's keychain list.
security list-keychains -d user -s "$keychain_path" "$HOME/Library/Keychains/login.keychain-db"
for target in Shennao XinlikaWatch; do
    security cms -D -i "$signing_dir/$target.mobileprovision" > "$signing_dir/$target.plist"
    cp "$signing_dir/$target.mobileprovision" "$profiles_dir/xinlika-ci-$GITHUB_RUN_ID-$target.mobileprovision"
done
# Keep both app targets identical and retries distinct. Offset avoids existing local build 34.
sequence=$((GITHUB_RUN_NUMBER + 10000))
build_number="$((sequence / 100)).$((sequence % 100)).$GITHUB_RUN_ATTEMPT"
python3 scripts/prepare-apple-signing.py --directory "$signing_dir" --spec "$spec_path" --build-number "$build_number"
xcodegen generate --spec "$spec_path" --project "$project_root"
archive_path="$signing_dir/Xinlika.xcarchive"
xcodebuild -project Shennao.xcodeproj -scheme Shennao -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive_path" \
    -derivedDataPath "$signing_dir/DerivedData" archive > "$signing_dir/archive.log" 2>&1 || {
    tail -80 "$signing_dir/archive.log" >&2; exit 1;
}
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$signing_dir/export" \
    -exportOptionsPlist "$signing_dir/ExportOptions.plist" \
    -authenticationKeyPath "$signing_dir/AuthKey.p8" -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" > "$signing_dir/upload.log" 2>&1 || {
    tail -80 "$signing_dir/upload.log" >&2; exit 1;
}
printf 'Uploaded commit %s, build %s. App Store Connect processing and physical device acceptance remain pending.\n' \
    "$GITHUB_SHA" "$build_number" | tee .build/testflight-status.txt

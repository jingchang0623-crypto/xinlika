#!/bin/sh
# Local checks use synthetic fixtures; Apple builds are a separate explicit gate.
set -u
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root" || exit 2
apple=false
case ${1:-} in
    '') ;;
    --apple) apple=true ;;
    *) echo 'Usage: scripts/check-project.sh [--apple]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo 'Usage: scripts/check-project.sh [--apple]' >&2
    exit 2
fi
python_path="$project_root/.build/heartball-agent-env/bin/python"
if [ ! -x "$python_path" ] || ! "$python_path" -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
    echo 'Run scripts/setup-dev.sh first (requires Python 3.12+ and uv).' >&2
    exit 2
fi
if "$apple" && { ! xcodebuild -version >/dev/null 2>&1 || ! command -v xcodegen >/dev/null 2>&1; }; then
    echo '--apple requires a selected full Xcode installation and XcodeGen.' >&2
    exit 2
fi
log_dir="$project_root/.build/checks"
mkdir -p "$log_dir" || exit 2
failures=0
run_check() {
    check_name=$1
    shift
    if "$@" > "$log_dir/$check_name.log" 2>&1; then
        echo "PASS $check_name"
    else
        check_status=$?
        echo "FAIL $check_name (exit $check_status)" >&2
        tail -30 "$log_dir/$check_name.log" >&2
        failures=$((failures + 1))
        return 1
    fi
}
if run_check swift-build swift build --disable-sandbox; then
    for product in CoreSelfTest CleanupSelfTest AuditSelfTest VoiceSelfTest CB08ProbeSelfTest; do
        run_check "$product" ".build/debug/$product" || :
    done
fi
run_check python-tests env PYTHONPATH="$project_root/scripts" "$python_path" -m unittest discover -s scripts -p 'test_*.py' || :
run_check public-content "$python_path" scripts/check-public-content.py --include-untracked || :
run_check diff-format git diff --check || :
if "$apple"; then
    run_check swift-xctest swift test --disable-sandbox || :
    if run_check xcodegen xcodegen generate; then
        run_check ios-build xcodebuild -project Shennao.xcodeproj -scheme Shennao \
            -destination 'generic/platform=iOS' -configuration Release \
            -derivedDataPath "$project_root/.build/checks-derived-data" CODE_SIGNING_ALLOWED=NO build || :
    fi
else
    echo 'SKIP Apple gate: run with --apple for Swift XCTest and iPhone/Watch build; requires Xcode and XcodeGen.'
fi
echo "Logs: $log_dir (test logs include fixture skips and assertion counts)"
if [ "$failures" -ne 0 ]; then
    echo "Checks failed: $failures" >&2
    exit 1
fi
echo 'Local core checks passed. Device, UI and live cloud validation are separate.'

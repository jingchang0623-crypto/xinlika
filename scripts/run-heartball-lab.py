#!/usr/bin/env python3
"""Build/open the native 心力卡 workspace. Opening never starts recording."""
import argparse
import hashlib
import os
import tempfile
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error

PROJECT = Path(__file__).resolve().parents[1]


def healthy(config):
    try:
        data = json.loads(config.read_text())
        if not data["baseURL"].startswith("http://127.0.0.1:"):
            return False
        request = urllib.request.Request(data["baseURL"] + "/v1/state", headers={"Authorization": "Bearer " + data["token"]})
        with urllib.request.urlopen(request, timeout=1) as response:
            return response.status == 200
    except (OSError, ValueError, KeyError):
        return False


def ensure_local_asr(processing):
    """Restart only this project's configured loopback bridge, never a remote service."""
    if not processing:
        return
    selectors = json.loads(processing.read_text())
    path = selectors.get('voxgate_config')
    expected = PROJECT / '.build/voxgate-evaluation/runtime/config.json'
    if not path or Path(path).resolve() != expected.resolve():
        return
    config = json.loads(expected.read_text())
    server = config['server']
    if server['host'] != '127.0.0.1':
        return
    request = urllib.request.Request(f"http://127.0.0.1:{server['port']}/health",
                                    headers={'Authorization': 'Bearer ' + server['auth_token']})
    def ready():
        try:
            with urllib.request.urlopen(request, timeout=1) as response:
                return response.status == 200
        except urllib.error.HTTPError:
            raise RuntimeError('Configured local ASR rejected its health request; existing listener preserved')
        except OSError:
            return False
    if ready():
        return
    with (expected.parent / 'service-console.txt').open('ab') as log:
        process = subprocess.Popen([sys.executable, str(PROJECT / 'scripts/voxgate-local.py'), 'serve'],
                                   cwd=PROJECT, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 10
    while not ready():
        if process.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError('Local ASR did not start; original audio and pending jobs are preserved')
        time.sleep(.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device")
    parser.add_argument("--root", type=Path, default=PROJECT / ".build/heartball-lab")
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--processing-config", type=Path, help="Private ASR/model selectors; credentials never go in source")
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime = root / "runtime.json"
    processing = args.processing_config or (root / "processing.json" if (root / "processing.json").exists() else None)
    ensure_local_asr(processing)
    service_python = sys.executable
    if processing:
        candidate = PROJECT / ".build/heartball-agent-env/bin/python"
        if not candidate.exists():
            parser.error("Install requirements-heartball.txt in .build/heartball-agent-env before enabling processing")
        service_python = str(candidate)
    if not args.skip_build:
        for product in ("cb08-probe", "HeartballLab", "HeartballClientCheck"):
            subprocess.run(["swift", "build", "--product", product], cwd=PROJECT, check=True)
    if not healthy(runtime):
        device = args.device
        if device is None and runtime.exists():
            device = json.loads(runtime.read_text()).get("device")
        if not device:
            parser.error("A stopped service needs an explicit --device UUID")
        with (root / "service-console.txt").open("ab") as log:
            command = [service_python, str(PROJECT / "scripts/heartball-local.py"), "--device", device, "--root", str(root)]
            if processing:
                command += ["--processing-config", str(processing.resolve())]
            subprocess.Popen(command, cwd=PROJECT,
                             stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 10
        while not healthy(runtime):
            if time.monotonic() >= deadline:
                raise RuntimeError("Local service did not become ready; see private service log")
            time.sleep(0.1)
    # Native apps can block in open(2) when a runtime file lives on a removable
    # volume. Keep only the loopback connection descriptor in Application Support;
    # recordings, model credentials and the database remain in the private root.
    runtime_id = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    native_dir = Path.home() / "Library/Application Support/OpenHeartball/LocalRuntime" / runtime_id
    native_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    native_dir.chmod(0o700)
    native_runtime = native_dir / "runtime.json"
    connection = json.loads(runtime.read_text())
    descriptor = {"baseURL": connection["baseURL"], "token": connection["token"]}
    fd, temporary = tempfile.mkstemp(dir=native_dir, prefix=".runtime-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(descriptor, output)
        os.replace(temporary, native_runtime)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    app = PROJECT / ".build/心力卡.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PROJECT / ".build/debug/HeartballLab", macos / "HeartballLab")
    info = {"CFBundleExecutable": "HeartballLab", "CFBundleIdentifier": "org.openheartball.lab",
            "CFBundleName": "心力卡", "CFBundleDisplayName": "心力卡",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "8", "CFBundleShortVersionString": "0.4.4",
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
            "HeartballRuntimePath": str(native_runtime), "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    if not args.no_open:
        subprocess.run(["open", str(app)], check=True)
    print(f"心力卡 ready: {app}. Recording starts only through an explicit action.")


if __name__ == "__main__":
    main()

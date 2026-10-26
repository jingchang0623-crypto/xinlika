#!/usr/bin/env python3
"""Build and run the isolated, pinned ASR evaluation service."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".build/voxgate-evaluation"
SOURCE = STATE / "source"
CONFIG = STATE / "runtime/config.json"
REVISION = "da98bb5ff9ce913b4317081a00e9e0c51f080edf"
PATCH = ROOT / "scripts/patches/voxgate-file-chunks.patch"
PATCHES = [PATCH, ROOT / "scripts/patches/voxgate-empty-final.patch"]


def setup():
    for tool in ("git", "go", "ffmpeg"):
        if not shutil.which(tool):
            raise RuntimeError(f"Missing dependency: {tool}")
    STATE.mkdir(parents=True, exist_ok=True)
    if not SOURCE.exists():
        subprocess.run(["git", "clone", "https://github.com/WEIFENG2333/voxgate.git", str(SOURCE)], check=True)
        subprocess.run(["git", "checkout", "--detach", REVISION], cwd=SOURCE, check=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=SOURCE, text=True).strip()
    if revision != REVISION:
        raise RuntimeError(f"Unexpected checkout {revision}; expected {REVISION}. Existing source was preserved.")
    # Independent patches also upgrade a checkout that already has the
    # earlier 15-second chunk patch, without resetting local source changes.
    for patch in PATCHES:
        applied = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=SOURCE, capture_output=True)
        if applied.returncode != 0:
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=SOURCE, check=True)
            subprocess.run(["git", "apply", str(patch)], cwd=SOURCE, check=True)
    (STATE / "bin").mkdir(exist_ok=True)
    subprocess.run(["go", "build", "-o", str(STATE / "bin/voxgate"), "./cmd/voxgate"], cwd=SOURCE, check=True)
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.parent.chmod(0o700)
    if not CONFIG.exists():
        config = {
            "credential_path": str(CONFIG.parent / "credentials.json"),
            "server": {"host": "127.0.0.1", "port": 18765,
                       "auth_token": secrets.token_urlsafe(32),
                       "max_concurrency": 1, "request_timeout": "5m"},
        }
        with CONFIG.open("x", opener=lambda p, f: os.open(p, f, 0o600)) as output:
            json.dump(config, output, indent=2)
    config = json.loads(CONFIG.read_text())
    config["evaluation"] = {"asr_chunk_seconds": 15, "patch_sha256": hashlib.sha256(b"".join(patch.read_bytes() for patch in PATCHES)).hexdigest()}
    CONFIG.write_text(json.dumps(config, indent=2))
    CONFIG.chmod(0o600)
    print(f"Built voxgate at {REVISION}; local configuration: {CONFIG}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["setup", "serve", "check"])
    args = parser.parse_args()
    if args.action == "setup":
        setup()
        return
    config = json.loads(CONFIG.read_text())
    host = config["server"]["host"]
    if host != "127.0.0.1":
        raise RuntimeError("This evaluation launcher only binds to 127.0.0.1")
    if args.action == "serve":
        executable = STATE / "bin/voxgate"
        chunks = config["evaluation"]["asr_chunk_seconds"]
        if not isinstance(chunks, int) or chunks < 1:
            raise RuntimeError("Expected a positive integer ASR chunk duration")
        # Avoid unrelated global voxgate settings altering this experiment.
        env = {k: v for k, v in os.environ.items() if not k.startswith("VOXGATE_")}
        os.execve(executable, [str(executable), "--config", str(CONFIG), "serve", "--chunk-duration", f"{chunks}s"], env)
    base = f"http://{host}:{config['server']['port']}"
    for route in ("/health", "/v1/models"):
        request = urllib.request.Request(base + route, headers={
            "Authorization": "Bearer " + config["server"]["auth_token"]})
        with urllib.request.urlopen(request, timeout=5) as response:
            print(route, response.status, response.read().decode().strip())


if __name__ == "__main__":
    main()

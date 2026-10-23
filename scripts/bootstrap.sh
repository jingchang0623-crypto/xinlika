#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_python=${PYTHON:-python3}
"$task_python" -c 'import sys; assert sys.version_info >= (3,11), "Python 3.11+ required; set PYTHON=python3.12"'
if [ ! -x "$task_root/.venv/bin/python" ]; then
  "$task_python" -m venv "$task_root/.venv"
fi
"$task_root/.venv/bin/python" -m pip install -r "$task_root/requirements-heartball.lock"
printf '%s\n' 'Installed. Next: .venv/bin/python scripts/configure-workspace.py --help'

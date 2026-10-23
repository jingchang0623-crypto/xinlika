#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -f "$task_root/private-config/processing.json" ]; then
  printf '%s\n' 'Run configure-workspace.py first; see docs/full-app.md.' >&2
  exit 1
fi
exec "$task_root/.venv/bin/python" "$task_root/scripts/heartball-shared-service.py" serve \
  --root "$task_root/.build/workspace" --processing-config "$task_root/private-config/processing.json" "$@"

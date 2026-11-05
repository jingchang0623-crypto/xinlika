#!/bin/sh
# Install project-local verification dependencies without changing system Python.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
python_bin=${PYTHON_BIN:-python3.12}
if ! command -v "$python_bin" >/dev/null 2>&1 || ! "$python_bin" -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
    echo 'Python 3.12+ is required. Set PYTHON_BIN to its executable.' >&2
    exit 2
fi
if ! command -v uv >/dev/null 2>&1; then
    echo 'uv is required to sync the pinned development environment.' >&2
    exit 2
fi
venv_path="$project_root/.build/heartball-agent-env"
if [ ! -x "$venv_path/bin/python" ]; then
    uv venv --python "$python_bin" "$venv_path"
fi
if ! "$venv_path/bin/python" -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
    echo 'The existing .build/heartball-agent-env needs Python 3.12+. Preserve it and recreate it before setup.' >&2
    exit 2
fi
uv pip sync --python "$venv_path/bin/python" requirements-dev.lock
echo 'Development environment ready: .build/heartball-agent-env'

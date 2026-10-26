#!/usr/bin/env bash
# Activate the separately installed Passport toolchain without changing shell startup files.
set -euo pipefail

AI_PASSPORT_REPO="${AI_PASSPORT_REPO:-${HOME}/Developer/ai-passport}"
AI_PASSPORT_IDF_ROOT="${AI_PASSPORT_IDF_ROOT:-${HOME}/esp/esp-idf-v5.5.3}"

if [[ ! -f "${AI_PASSPORT_IDF_ROOT}/export.sh" || ! -d "${AI_PASSPORT_REPO}/.git" ]]; then
    echo "Passport checkout or ESP-IDF installation is missing. See docs/ai-passport-feasibility-2026-10-23.md." >&2
    exit 1
fi

# Prefer the existing Homebrew Python 3.12 for the dedicated IDF virtual environment.
if [[ -d /opt/homebrew/opt/python@3.12/libexec/bin ]]; then
    export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:${PATH}"
fi
source "${AI_PASSPORT_IDF_ROOT}/export.sh" >&2
AI_PASSPORT_IDF_VERSION="$(idf.py --version)"
if [[ "${AI_PASSPORT_IDF_VERSION}" != "ESP-IDF v5.5.3" ]]; then
    echo "Expected ESP-IDF v5.5.3; found ${AI_PASSPORT_IDF_VERSION}" >&2
    exit 1
fi
export IDF_CCACHE_ENABLE=1
# The default component storage failed on this host. Use Espressif's official
# mainland-China storage for this child process, preserving explicit overrides.
export IDF_COMPONENT_STORAGE_URL="${IDF_COMPONENT_STORAGE_URL:-https://components-file.espressif.cn}"
cd "${AI_PASSPORT_REPO}"
if [[ $# -eq 0 ]]; then
    printf '%s\n' "${AI_PASSPORT_IDF_VERSION}"
    exit 0
fi
exec "$@"

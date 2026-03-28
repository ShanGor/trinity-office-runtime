#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if rg -n '< <\(' "${PROJECT_ROOT}/install.sh" "${PROJECT_ROOT}/wrapper/trinity-pptx" >/dev/null; then
    echo "Expected install.sh and wrapper/trinity-pptx to avoid process substitution" >&2
    exit 1
fi

echo "PASS: installer and wrapper avoid process substitution dependencies"

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/runtime/build.sh"

# shellcheck source=/dev/null
source "${BUILD_SCRIPT}"

mapfile -t python_packages <<< "$(runtime_python_packages)"

for expected in \
    "markitdown-no-magika[pptx]==0.1.2" \
    "Pillow"
do
    if ! printf '%s\n' "${python_packages[@]}" | grep -Fx "$expected" >/dev/null; then
        echo "Expected runtime build to include Python package: $expected" >&2
        exit 1
    fi
done

echo "PASS: runtime/build.sh pins Python package specs for the bundled runtime"

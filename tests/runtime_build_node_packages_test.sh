#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/runtime/build.sh"

# shellcheck source=/dev/null
source "${BUILD_SCRIPT}"

mapfile -t node_packages < <(runtime_node_packages)

if ! printf '%s\n' "${node_packages[@]}" | grep -Fx "pptxgenjs@3.12.0" >/dev/null; then
    echo "Expected runtime build to pin pptxgenjs to a Node 12 compatible version" >&2
    exit 1
fi

echo "PASS: runtime/build.sh pins Node package specs for the bundled runtime"

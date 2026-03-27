#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/runtime/build.sh"

# shellcheck source=/dev/null
source "${BUILD_SCRIPT}"

mapfile -t runtime_packages < <(runtime_apt_packages)

for expected in \
    "fonts-noto-cjk" \
    "fonts-wqy-zenhei"
do
    if ! printf '%s\n' "${runtime_packages[@]}" | grep -Fx "$expected" >/dev/null; then
        echo "Expected runtime build to include CJK font package: $expected" >&2
        exit 1
    fi
done

echo "PASS: runtime/build.sh includes bundled CJK font packages"

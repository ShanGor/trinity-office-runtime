#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/runtime/build.sh"

# shellcheck source=/dev/null
source "${BUILD_SCRIPT}"

findmnt() {
    if [ "$1" != "-T" ]; then
        return 1
    fi

    case "$4" in
        FSTYPE)
            printf '9p\n'
            ;;
        OPTIONS)
            printf 'ro,nosuid\n'
            ;;
        *)
            return 1
            ;;
    esac
}

mktemp() {
    printf '/tmp/trinity-office-runtime-build.mock\n'
}

if build_dir_supports_rootfs "/mnt/d/sources/ai/trinity-office-runtime/build"; then
    echo "Expected 9p/drvfs-backed build directory to be rejected for rootfs creation" >&2
    exit 1
fi

if [ "$(choose_build_dir "/mnt/d/sources/ai/trinity-office-runtime/build")" != "/tmp/trinity-office-runtime-build.mock" ]; then
    echo "Expected build directory selection to fall back to a temporary location on 9p/drvfs mounts" >&2
    exit 1
fi

if [ "$(choose_build_dir "/mnt/d/sources/ai/trinity-office-runtime/dist")" != "/tmp/trinity-office-runtime-build.mock" ]; then
    echo "Expected output directory selection to fall back to a temporary location on 9p/drvfs mounts" >&2
    exit 1
fi

echo "PASS: runtime/build.sh avoids 9p/drvfs build directories for rootfs creation"

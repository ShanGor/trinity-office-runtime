#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

# shellcheck source=/dev/null
source "${INSTALL_SCRIPT}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
capture_file="${tmpdir}/capture.txt"
mkdir -p "${runtime_dir}"

cat > "${runtime_dir}/trinity-pptx" << 'INNER'
#!/bin/sh
printf '%s\n' "$*" > "${CAPTURE_FILE}"

if [ "${1:-}" != "exec" ] || [ "${2:-}" != "python3" ] || [ "${3:-}" != "-c" ]; then
    exit 1
fi

case "${4:-}" in
    *markitdown_no_magika*)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
INNER
chmod +x "${runtime_dir}/trinity-pptx"

export CAPTURE_FILE="${capture_file}"
verify_markitdown_runtime "${runtime_dir}" >/dev/null

if ! grep -F "markitdown_no_magika" "${capture_file}" >/dev/null; then
    echo "Expected install.sh to verify the markitdown_no_magika module name" >&2
    cat "${capture_file}" >&2
    exit 1
fi

echo "PASS: install.sh verifies the bundled MarkItDown module name"

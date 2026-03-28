#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/wrapper/trinity-office"

if ! command -v bwrap >/dev/null 2>&1; then
    echo "SKIP: bwrap not available"
    exit 0
fi

if ! bwrap --ro-bind / / --dev /dev --proc /proc /bin/true >/dev/null 2>&1; then
    echo "SKIP: bwrap not available"
    exit 0
fi

copy_binary_with_deps() {
    local binary="$1"
    local rootfs="$2"
    local dep=""
    local deps=""

    mkdir -p "${rootfs}$(dirname "$binary")"
    cp "$binary" "${rootfs}${binary}"

    deps="$(ldd "$binary" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}')"
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        mkdir -p "${rootfs}$(dirname "$dep")"
        cp "$dep" "${rootfs}${dep}"
    done <<< "$deps"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
mkdir -p \
    "${runtime_dir}/rootfs/usr/bin" \
    "${runtime_dir}/rootfs/usr/lib"

copy_binary_with_deps /bin/sh "${runtime_dir}/rootfs"

cat > "${runtime_dir}/rootfs/usr/bin/python3" << 'INNER'
#!/bin/sh
printf '%s\n' "$0"
INNER
chmod +x "${runtime_dir}/rootfs/usr/bin/python3"

ln -s rootfs/usr/bin "${runtime_dir}/bin"
ln -s rootfs/usr/lib "${runtime_dir}/lib"

output="$(
    TRINITY_OFFICE_RUNTIME="${runtime_dir}" \
    "${WRAPPER}" exec python3 -c "import sys; print(sys.executable)"
)"

if [[ "$output" != *"/usr/bin/python3"* ]]; then
    echo "Expected wrapper to execute python3 from the bundled rootfs /usr/bin path" >&2
    echo "Actual: ${output}" >&2
    exit 1
fi

if [[ "$output" == *"/runtime/bin/python3"* ]]; then
    echo "Expected wrapper to avoid the compatibility /runtime/bin path when a bundled rootfs is present" >&2
    echo "Actual: ${output}" >&2
    exit 1
fi

echo "PASS: wrapper runs python3 inside the bundled rootfs layout"

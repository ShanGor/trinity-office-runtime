#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/wrapper/trinity-office"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
work_dir="${tmpdir}/work"
fake_bin="${tmpdir}/fake-bin"
capture_file="${tmpdir}/bwrap-args.txt"
mkdir -p "${runtime_dir}/bin" "${runtime_dir}/rootfs/usr/bin" "${runtime_dir}/rootfs/usr/lib" "${work_dir}" "${fake_bin}"

printf 'const x = 1;\n' > "${work_dir}/test.js"

cat > "${runtime_dir}/rootfs/usr/bin/node" << 'INNER'
#!/bin/bash
set -euo pipefail

if [ "$PWD" != "${EXPECTED_WORK_DIR}" ]; then
    echo "expected sandbox command to run from ${EXPECTED_WORK_DIR}, got ${PWD}" >&2
    exit 1
fi

if [ "${1:-}" != "--check" ]; then
    echo "expected --check as first argument, got ${1:-}" >&2
    exit 1
fi

if [ ! -f "${2:-}" ]; then
    echo "expected script argument to resolve to an existing workspace file, got ${2:-}" >&2
    exit 1
fi
INNER
chmod +x "${runtime_dir}/rootfs/usr/bin/node"

cat > "${fake_bin}/bwrap" << 'INNER'
#!/bin/bash
set -euo pipefail

usr_bin=""
work_dir=""
chdir_path=""
capture_file="${BWRAP_CAPTURE_FILE:?}"

printf '%q\n' "$@" > "$capture_file"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bind|--ro-bind)
            src="$2"
            dst="$3"
            case "$dst" in
                /usr/bin)
                    usr_bin="$src"
                    ;;
                /work)
                    work_dir="$src"
                    ;;
            esac
            shift 3
            ;;
        --chdir)
            chdir_path="$2"
            shift 2
            ;;
        --tmpfs|--proc|--dev)
            shift 2
            ;;
        --setenv)
            shift 3
            ;;
        --unshare-all|--share-net|--die-with-parent)
            shift
            ;;
        *)
            break
            ;;
    esac
done

cmd="$1"
shift

case "$cmd" in
    /usr/bin/*)
        cmd="${usr_bin}${cmd#/usr/bin}"
        ;;
esac

rewritten_args=()
for arg in "$@"; do
    case "$arg" in
        /work)
            rewritten_args+=("${work_dir}")
            ;;
        /work/*)
            rewritten_args+=("${work_dir}/${arg#/work/}")
            ;;
        *)
            rewritten_args+=("$arg")
            ;;
    esac
done

case "$chdir_path" in
    /work)
        cd "$work_dir"
        ;;
esac

EXPECTED_WORK_DIR="$work_dir" "$cmd" "${rewritten_args[@]}"
INNER
chmod +x "${fake_bin}/bwrap"

(
    cd "$work_dir"
    PATH="${fake_bin}:$PATH" \
    TRINITY_OFFICE_RUNTIME="${runtime_dir}" \
    BWRAP_CAPTURE_FILE="${capture_file}" \
    "${WRAPPER}" exec node --check test.js
)

if ! grep -Fx -- '--chdir' "$capture_file" >/dev/null || ! grep -Fx -- '/work' "$capture_file" >/dev/null; then
    echo "expected exec to run sandboxed commands with --chdir /work" >&2
    cat "$capture_file" >&2
    exit 1
fi

(
    cd "$work_dir"
    PATH="${fake_bin}:$PATH" \
    TRINITY_OFFICE_RUNTIME="${runtime_dir}" \
    BWRAP_CAPTURE_FILE="${capture_file}" \
    "${WRAPPER}" exec node --check "${work_dir}/test.js"
)

if ! grep -Fx -- '/work/test.js' "$capture_file" >/dev/null; then
    echo "expected absolute workspace arguments to be rewritten to /work paths" >&2
    cat "$capture_file" >&2
    exit 1
fi

echo "PASS: exec binds caller workspace and rewrites workspace paths in sandbox"

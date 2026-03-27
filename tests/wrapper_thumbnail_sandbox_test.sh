#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/wrapper/trinity-pptx"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
work_dir="${tmpdir}/work"
fake_bin="${tmpdir}/fake-bin"
mkdir -p "${runtime_dir}/bin" "${runtime_dir}/lib" "${work_dir}" "${fake_bin}"

cat > "${runtime_dir}/bin/soffice" << 'INNER'
#!/bin/bash
set -euo pipefail

outdir=""
input=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --outdir)
            outdir="$2"
            shift 2
            ;;
        *)
            input="$1"
            shift
            ;;
    esac
done

if [ -z "$outdir" ] || [ -z "$input" ]; then
    echo "missing outdir or input" >&2
    exit 1
fi

name="$(basename "$input")"
stem="${name%.*}"
printf '%s\n' '%PDF-1.4' > "${outdir}/${stem}.pdf"
INNER
chmod +x "${runtime_dir}/bin/soffice"

cat > "${runtime_dir}/bin/pdftoppm" << 'INNER'
#!/bin/bash
set -euo pipefail

singlefile=false
input=""
output_prefix=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -singlefile)
            singlefile=true
            shift
            ;;
        -jpeg|-r|-f|-l)
            if [ "$1" = "-jpeg" ]; then
                shift
            else
                shift 2
            fi
            ;;
        *)
            if [ -z "$input" ]; then
                input="$1"
            else
                output_prefix="$1"
            fi
            shift
            ;;
    esac
done

if [ ! -f "$input" ]; then
    echo "missing input pdf: $input" >&2
    exit 1
fi

if [ "$singlefile" = true ]; then
    printf '%s\n' 'fake jpeg' > "${output_prefix}.jpg"
else
    printf '%s\n' 'fake jpeg' > "${output_prefix}-1.jpg"
fi
INNER
chmod +x "${runtime_dir}/bin/pdftoppm"

cat > "${fake_bin}/bwrap" << 'INNER'
#!/bin/bash
set -euo pipefail

runtime_dir=""
input_dir=""
work_dir=""
sandbox_tmp=""

cleanup() {
    if [ -n "$sandbox_tmp" ] && [ -d "$sandbox_tmp" ]; then
        rm -rf "$sandbox_tmp"
    fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bind|--ro-bind)
            src="$2"
            dst="$3"
            case "$dst" in
                /runtime)
                    runtime_dir="$src"
                    ;;
                /input)
                    input_dir="$src"
                    ;;
                /work)
                    work_dir="$src"
                    ;;
            esac
            shift 3
            ;;
        --tmpfs)
            if [ "$2" = "/tmp" ]; then
                sandbox_tmp="$(mktemp -d)"
            fi
            shift 2
            ;;
        --proc|--dev|--chdir)
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
    /runtime/*)
        cmd="${runtime_dir}${cmd#/runtime}"
        ;;
esac

rewritten_args=()
for arg in "$@"; do
    case "$arg" in
        /runtime/*)
            rewritten_args+=("${runtime_dir}${arg#/runtime}")
            ;;
        /input)
            rewritten_args+=("${input_dir}")
            ;;
        /input/*)
            rewritten_args+=("${input_dir}/${arg#/input/}")
            ;;
        /work)
            rewritten_args+=("${work_dir}")
            ;;
        /work/*)
            rewritten_args+=("${work_dir}/${arg#/work/}")
            ;;
        /tmp)
            rewritten_args+=("${sandbox_tmp}")
            ;;
        /tmp/*)
            rewritten_args+=("${sandbox_tmp}/${arg#/tmp/}")
            ;;
        *)
            rewritten_args+=("$arg")
            ;;
    esac
done

"$cmd" "${rewritten_args[@]}"
INNER
chmod +x "${fake_bin}/bwrap"

printf 'fake pptx' > "${work_dir}/demo.pptx"

(
    cd "${work_dir}"
    PATH="${fake_bin}:${PATH}" \
    TRINITY_PPTX_RUNTIME="${runtime_dir}" \
    "${WRAPPER}" thumbnail demo.pptx preview.jpg
)

if [ ! -f "${work_dir}/preview.jpg" ]; then
    echo "Expected sandboxed thumbnail generation to create preview.jpg" >&2
    ls -la "${work_dir}" >&2
    exit 1
fi

if [ -f "${work_dir}/demo.pdf" ]; then
    echo "Expected wrapper to clean up intermediate PDF after thumbnail generation" >&2
    ls -la "${work_dir}" >&2
    exit 1
fi

if [ -f "${work_dir}/preview-1.jpg" ]; then
    echo "Expected wrapper to produce requested JPG filename instead of pdftoppm default suffix" >&2
    ls -la "${work_dir}" >&2
    exit 1
fi

echo "PASS: sandboxed thumbnail generation creates requested output filename"

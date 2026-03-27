#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/wrapper/trinity-pptx"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
work_dir="${tmpdir}/work"
mkdir -p \
    "${runtime_dir}/bin" \
    "${runtime_dir}/lib/libreoffice/program" \
    "${work_dir}"

cat > "${runtime_dir}/bin/soffice" << 'INNER'
#!/bin/sh
set -eu

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

printf 'fake pptx' > "${work_dir}/demo.pptx"

(
    cd "${work_dir}"
    TRINITY_NO_SANDBOX=1 \
    TRINITY_PPTX_RUNTIME="${runtime_dir}" \
    "${WRAPPER}" convert demo.pptx renamed.pdf
)

if [ ! -f "${work_dir}/renamed.pdf" ]; then
    echo "Expected convert subcommand to honor requested output filename" >&2
    ls -la "${work_dir}" >&2
    exit 1
fi

if [ -f "${work_dir}/demo.pdf" ]; then
    echo "Expected wrapper to rename demo.pdf to renamed.pdf" >&2
    ls -la "${work_dir}" >&2
    exit 1
fi

echo "PASS: convert subcommand honors requested output filename"

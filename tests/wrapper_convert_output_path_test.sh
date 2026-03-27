#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER="${PROJECT_ROOT}/wrapper/trinity-pptx"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
input_dir="${tmpdir}/input"
output_dir="${tmpdir}/output"
mkdir -p \
    "${runtime_dir}/bin" \
    "${runtime_dir}/lib/libreoffice/program" \
    "${input_dir}" \
    "${output_dir}"

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

printf 'fake pptx' > "${input_dir}/demo.pptx"

TRINITY_NO_SANDBOX=1 \
TRINITY_PPTX_RUNTIME="${runtime_dir}" \
"${WRAPPER}" convert "${input_dir}/demo.pptx" "${output_dir}/renamed.pdf"

if [ ! -f "${output_dir}/renamed.pdf" ]; then
    echo "Expected convert to honor requested output path" >&2
    find "${tmpdir}" -maxdepth 2 -type f | sort >&2
    exit 1
fi

if [ -f "${input_dir}/renamed.pdf" ] || [ -f "${input_dir}/demo.pdf" ]; then
    echo "Expected convert output to stay out of the input directory" >&2
    find "${tmpdir}" -maxdepth 2 -type f | sort >&2
    exit 1
fi

echo "PASS: convert honors requested output path without sandbox"

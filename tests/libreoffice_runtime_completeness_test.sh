#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
output_file="${tmpdir}/completeness.out"
mkdir -p \
    "${runtime_dir}/bin" \
    "${runtime_dir}/lib/libreoffice/program" \
    "${runtime_dir}/lib/libreoffice/share/config/soffice.cfg/modules/simpress/ui" \
    "${runtime_dir}/share/java"

# shellcheck source=/dev/null
source "${INSTALL_SCRIPT}"

if check_libreoffice_bundle_completeness "${runtime_dir}" >"${output_file}" 2>&1; then
    echo "Expected completeness check to fail when required LibreOffice files are missing" >&2
    exit 1
fi

missing_output="$(cat "${output_file}")"
for expected in \
    bin/soffice \
    lib/libreoffice/program/javaldx \
    lib/libreoffice/share/config/soffice.cfg/modules/simpress/ui/tabviewbar.ui \
    "share/java/hsqldb1.8.0.jar or lib/libreoffice/program/classes/hsqldb.jar"
do
    if [[ "${missing_output}" != *"${expected}"* ]]; then
        echo "Expected completeness output to mention missing ${expected}" >&2
        exit 1
    fi
done

touch "${runtime_dir}/lib/libreoffice/share/config/soffice.cfg/modules/simpress/ui/tabviewbar.ui"
mkdir -p "${runtime_dir}/lib/libreoffice/program/classes"
touch "${runtime_dir}/lib/libreoffice/program/classes/hsqldb.jar"
cat > "${runtime_dir}/bin/soffice" << 'INNER'
#!/bin/sh
exit 0
INNER
cat > "${runtime_dir}/lib/libreoffice/program/javaldx" << 'INNER'
#!/bin/sh
exit 0
INNER
chmod +x "${runtime_dir}/bin/soffice" "${runtime_dir}/lib/libreoffice/program/javaldx"

if ! check_libreoffice_bundle_completeness "${runtime_dir}" >/dev/null 2>&1; then
    echo "Expected completeness check to pass once required LibreOffice files exist" >&2
    exit 1
fi

echo "PASS: install.sh detects incomplete LibreOffice runtime bundles"

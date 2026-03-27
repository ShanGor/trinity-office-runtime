#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
program_dir="${runtime_dir}/lib/libreoffice/program"
mkdir -p "${program_dir}"

cat > "${program_dir}/fundamentalrc" << 'INNER'
[Bootstrap]
BRAND_BASE_DIR=file:///usr/lib/libreoffice
CONFIGURATION_LAYERS=xcsxcu:file:///etc/libreoffice/registry
URE_MORE_JAVA_CLASSPATH_URLS=file:///usr/share/java/hsqldb1.8.0.jar
INNER

cat > "${program_dir}/sofficerc" << 'INNER'
FHS_CONFIG_FILE=file:///etc/libreoffice/sofficerc
INNER

cat > "${program_dir}/bootstraprc" << 'INNER'
[Bootstrap]
InstallMode=invalid
UserInstallation=${ORIGIN}/../../..
INNER

# shellcheck source=/dev/null
source "${INSTALL_SCRIPT}"
repair_libreoffice_bundle_paths "${runtime_dir}"

if ! grep -F 'BRAND_BASE_DIR=${ORIGIN}/..' "${program_dir}/fundamentalrc" >/dev/null; then
    echo "Expected BRAND_BASE_DIR to be rewritten to the bundled LibreOffice root" >&2
    exit 1
fi

if ! grep -F 'file://${ORIGIN}/../../../etc/libreoffice/registry' "${program_dir}/fundamentalrc" >/dev/null; then
    echo "Expected registry path to be rewritten to the bundled etc directory" >&2
    exit 1
fi

if ! grep -F 'file://${ORIGIN}/../../../share/java/hsqldb1.8.0.jar' "${program_dir}/fundamentalrc" >/dev/null; then
    echo "Expected hsqldb jar path to be rewritten to the bundled share directory" >&2
    exit 1
fi

if ! grep -F 'file://${ORIGIN}/../../../etc/libreoffice/sofficerc' "${program_dir}/sofficerc" >/dev/null; then
    echo "Expected sofficerc path to be rewritten to the bundled etc directory" >&2
    exit 1
fi

if ! grep -F 'InstallMode=install' "${program_dir}/bootstraprc" >/dev/null; then
    echo "Expected InstallMode to be forced to install" >&2
    exit 1
fi

if ! grep -F 'UserInstallation=$SYSUSERCONFIG/libreoffice/4' "${program_dir}/bootstraprc" >/dev/null; then
    echo 'Expected UserInstallation to point to $SYSUSERCONFIG/libreoffice/4' >&2
    exit 1
fi

echo "PASS: install.sh repairs LibreOffice bundle metadata for portable runtime use"

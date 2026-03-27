#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
program_dir="${runtime_dir}/lib/libreoffice/program"
arch_dir="${runtime_dir}/lib/x86_64-linux-gnu"

mkdir -p "${program_dir}/services" "${arch_dir}"
touch \
    "${program_dir}/bootstraprc" \
    "${program_dir}/redirectrc" \
    "${program_dir}/fundamentalrc" \
    "${program_dir}/sofficerc" \
    "${program_dir}/setuprc" \
    "${program_dir}/unorc" \
    "${program_dir}/lounorc" \
    "${program_dir}/types.rdb" \
    "${program_dir}/services.rdb" \
    "${program_dir}/libgcc3_uno.so" \
    "${program_dir}/services/services.rdb"
touch "${arch_dir}/libexisting.so"

# shellcheck source=/dev/null
source "${INSTALL_SCRIPT}"
repair_libreoffice_program_compat_symlinks "${runtime_dir}"

for expected in unorc lounorc types.rdb services.rdb libgcc3_uno.so services; do
    if [ ! -L "${arch_dir}/${expected}" ]; then
        echo "Expected compatibility symlink for ${expected}" >&2
        exit 1
    fi
done

if [ "$(readlink "${arch_dir}/unorc")" != "../libreoffice/program/unorc" ]; then
    echo "Unexpected unorc symlink target: $(readlink "${arch_dir}/unorc")" >&2
    exit 1
fi

if [ ! -f "${arch_dir}/libexisting.so" ]; then
    echo "Existing architecture-local files should be preserved" >&2
    exit 1
fi

if [ -L "${arch_dir}/fundamentalrc" ] || [ ! -f "${arch_dir}/fundamentalrc" ]; then
    echo "Expected fundamentalrc to be copied into the multi-arch directory" >&2
    exit 1
fi

if [ -L "${arch_dir}/sofficerc" ] || [ ! -f "${arch_dir}/sofficerc" ]; then
    echo "Expected sofficerc to be copied into the multi-arch directory" >&2
    exit 1
fi

echo "BRAND_BASE_DIR=file:///usr/lib/libreoffice" > "${program_dir}/fundamentalrc"
echo 'FHS_CONFIG_FILE=file://${ORIGIN}/../../../etc/libreoffice/sofficerc' > "${program_dir}/sofficerc"
repair_libreoffice_program_compat_symlinks "${runtime_dir}"

if ! grep -F 'BRAND_BASE_DIR=${ORIGIN}/../libreoffice' "${arch_dir}/fundamentalrc" >/dev/null; then
    echo "Expected multi-arch fundamentalrc to use the bundled libreoffice root" >&2
    exit 1
fi

if ! grep -F 'file://${ORIGIN}/../../etc/libreoffice/sofficerc' "${arch_dir}/sofficerc" >/dev/null; then
    echo "Expected multi-arch sofficerc to use the bundled etc directory" >&2
    exit 1
fi

echo "PASS: install.sh repairs LibreOffice multi-arch compatibility entries"

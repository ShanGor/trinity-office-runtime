#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${PROJECT_ROOT}/install.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runtime_dir="${tmpdir}/runtime"
share_dir="${runtime_dir}/lib/libreoffice/share"
mkdir -p "${share_dir}/psprint" "${share_dir}/prereg" "${share_dir}/uno_packages"

ln -s /etc/libreoffice/registry "${share_dir}/registry"
ln -s /etc/libreoffice/psprint.conf "${share_dir}/psprint/psprint.conf"
ln -s /var/lib/libreoffice/share/prereg/bundled "${share_dir}/prereg/bundled"
ln -s /var/spool/libreoffice/uno_packages/cache "${share_dir}/uno_packages/cache"

# shellcheck source=/dev/null
source "${INSTALL_SCRIPT}"
repair_libreoffice_share_symlinks "${runtime_dir}"

if [ "$(readlink "${share_dir}/registry")" != "../../../etc/libreoffice/registry" ]; then
    echo "Expected registry symlink to point at the bundled etc directory" >&2
    exit 1
fi

if [ "$(readlink "${share_dir}/psprint/psprint.conf")" != "../../../../etc/libreoffice/psprint.conf" ]; then
    echo "Expected psprint.conf symlink to point at the bundled etc directory" >&2
    exit 1
fi

if [ "$(readlink "${share_dir}/prereg/bundled")" != "../../../../var/lib/libreoffice/share/prereg/bundled" ]; then
    echo "Expected prereg symlink to point at the bundled var directory" >&2
    exit 1
fi

if [ "$(readlink "${share_dir}/uno_packages/cache")" != "../../../../var/spool/libreoffice/uno_packages/cache" ]; then
    echo "Expected uno_packages cache symlink to point at the bundled var directory" >&2
    exit 1
fi

if [ ! -d "${runtime_dir}/var/lib/libreoffice/share/prereg/bundled" ]; then
    echo "Expected prereg cache directory to be created inside the bundle" >&2
    exit 1
fi

if [ ! -d "${runtime_dir}/var/spool/libreoffice/uno_packages/cache" ]; then
    echo "Expected uno_packages cache directory to be created inside the bundle" >&2
    exit 1
fi

echo "PASS: install.sh repairs LibreOffice share symlinks for portable runtime use"

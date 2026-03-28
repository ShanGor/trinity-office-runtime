#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/runtime/build.sh"

# shellcheck source=/dev/null
source "${BUILD_SCRIPT}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

rootfs="${tmpdir}/rootfs"
install_root="${rootfs}/opt/libreoffice26.2"
mkdir -p \
    "${install_root}/program/classes" \
    "${install_root}/share/registry" \
    "${install_root}/share/psprint" \
    "${install_root}/share/uno_packages/cache"

touch \
    "${install_root}/program/soffice" \
    "${install_root}/program/sofficerc" \
    "${install_root}/program/classes/hsqldb.jar" \
    "${install_root}/program/classes/sdbc_hsqldb.jar" \
    "${install_root}/share/psprint/psprint.conf"

configure_official_libreoffice_rootfs_layout "${rootfs}" "26.2.2"

if [ "$(readlink "${rootfs}/usr/bin/soffice")" != "../../opt/libreoffice26.2/program/soffice" ]; then
    echo "Expected /usr/bin/soffice to point at the official LibreOffice install root" >&2
    exit 1
fi

if [ "$(readlink "${rootfs}/usr/lib/libreoffice")" != "../../opt/libreoffice26.2" ]; then
    echo "Expected /usr/lib/libreoffice to point at the official LibreOffice install root" >&2
    exit 1
fi

if [ "$(readlink "${rootfs}/etc/libreoffice/registry")" != "../../opt/libreoffice26.2/share/registry" ]; then
    echo "Expected /etc/libreoffice/registry to point at the bundled registry tree" >&2
    exit 1
fi

if [ "$(readlink "${rootfs}/etc/libreoffice/psprint.conf")" != "../../opt/libreoffice26.2/share/psprint/psprint.conf" ]; then
    echo "Expected /etc/libreoffice/psprint.conf to point at the bundled psprint config" >&2
    exit 1
fi

if [ "$(readlink "${rootfs}/usr/share/java/hsqldb1.8.0.jar")" != "../../../opt/libreoffice26.2/program/classes/hsqldb.jar" ]; then
    echo "Expected legacy HSQLDB compatibility symlink to point at the bundled LibreOffice jar" >&2
    exit 1
fi

if [ "$(readlink "${rootfs}/var/spool/libreoffice/uno_packages/cache")" != "../../../../opt/libreoffice26.2/share/uno_packages/cache" ]; then
    echo "Expected UNO package cache compatibility symlink to point at the bundled LibreOffice cache" >&2
    exit 1
fi

echo "PASS: runtime/build.sh creates LibreOffice compatibility links for the official tarball layout"

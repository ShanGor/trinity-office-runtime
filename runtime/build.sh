#!/bin/bash
set -euo pipefail

# Build script for Trinity Office Runtime
# Creates a minimal rootfs with LibreOffice, Python, Node.js, and Poppler

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_DIST_DIR="$PROJECT_ROOT/dist"
DEFAULT_BUILD_DIR="$PROJECT_ROOT/build"
DIST_DIR="$DEFAULT_DIST_DIR"
BUILD_DIR="$DEFAULT_BUILD_DIR"
ROOTFS="$BUILD_DIR/rootfs"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"
LIBREOFFICE_VERSION="${LIBREOFFICE_VERSION:-26.2.2}"
LIBREOFFICE_DOWNLOAD_BASE="${LIBREOFFICE_DOWNLOAD_BASE:-https://download.documentfoundation.org/libreoffice/stable}"
BUILD_CACHE_DIR="${TRINITY_BUILD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/trinity-office-runtime}"

copy_tree_contents() {
    local src="$1"
    local dst="$2"

    if [ -d "$src" ]; then
        mkdir -p "$dst"
        cp -a "$src"/. "$dst"/
    fi
}

copy_path_into_dir() {
    local src="$1"
    local dst_dir="$2"

    if [ -e "$src" ] || [ -L "$src" ]; then
        mkdir -p "$dst_dir"
        cp -a "$src" "$dst_dir"/
    fi
}

path_mount_options() {
    local path="$1"
    local probe="$path"
    local mount_point=""

    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        probe="$(dirname "$probe")"
    done

    if command -v findmnt >/dev/null 2>&1; then
        findmnt -T "$probe" -no OPTIONS 2>/dev/null || true
        return 0
    fi

    mount_point="$(df -P "$probe" 2>/dev/null | awk 'NR==2 {print $6}')"
    if [ -n "$mount_point" ]; then
        awk -v mount_point="$mount_point" '$2 == mount_point {print $4; exit}' /proc/mounts
    fi
}

path_filesystem_type() {
    local path="$1"
    local probe="$path"

    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        probe="$(dirname "$probe")"
    done

    if command -v findmnt >/dev/null 2>&1; then
        findmnt -T "$probe" -no FSTYPE 2>/dev/null || true
        return 0
    fi

    df -PT "$probe" 2>/dev/null | awk 'NR==2 {print $2}'
}

build_dir_supports_rootfs() {
    local options
    local filesystem_type

    options="$(path_mount_options "$1")"
    filesystem_type="$(path_filesystem_type "$1")"
    case ",${options}," in
        *,nodev,*|*,noexec,*)
            return 1
            ;;
    esac

    case "$filesystem_type" in
        9p|drvfs)
            return 1
            ;;
    esac

    case ",${options}," in
        *,aname=drvfs,*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

choose_build_dir() {
    local preferred_dir="$1"

    if build_dir_supports_rootfs "$preferred_dir"; then
        echo "$preferred_dir"
        return 0
    fi

    mktemp -d "${TMPDIR:-/tmp}/trinity-office-runtime-build.XXXXXX"
}

resolve_ubuntu_repo() {
    local deb_arch="$1"

    if [ -n "${UBUNTU_REPO:-}" ]; then
        echo "$UBUNTU_REPO"
        return 0
    fi

    if [ "$deb_arch" = "arm64" ]; then
        echo "http://ports.ubuntu.com/ubuntu-ports"
    else
        echo "http://archive.ubuntu.com/ubuntu"
    fi
}

runtime_apt_packages() {
    cat <<'EOF'
libegl1
libdbus-1-3
libgbm1
libglib2.0-0
libgl1
libgl1-mesa-dri
libglx-mesa0
libcups2t64
libopengl0
libxinerama1
poppler-utils
python3
python3-pip
python3-venv
nodejs
npm
fonts-liberation
fonts-dejavu-core
fonts-freefont-ttf
fonts-noto-cjk
fonts-wqy-zenhei
EOF
}

runtime_python_packages() {
    cat <<'EOF'
markitdown-no-magika[pptx]==0.1.2
Pillow
EOF
}

runtime_node_packages() {
    cat <<'EOF'
pptxgenjs@3.12.0
EOF
}

libreoffice_series() {
    local version="${1:-$LIBREOFFICE_VERSION}"
    echo "${version%.*}"
}

libreoffice_install_dirname() {
    local version="${1:-$LIBREOFFICE_VERSION}"
    echo "libreoffice$(libreoffice_series "$version")"
}

libreoffice_download_dir_arch() {
    case "$1" in
        amd64)
            echo "x86_64"
            ;;
        arm64)
            echo "aarch64"
            ;;
        *)
            echo "Unsupported LibreOffice architecture: $1" >&2
            exit 1
            ;;
    esac
}

libreoffice_download_file_arch() {
    case "$1" in
        amd64)
            echo "x86-64"
            ;;
        arm64)
            echo "aarch64"
            ;;
        *)
            echo "Unsupported LibreOffice architecture: $1" >&2
            exit 1
            ;;
    esac
}

libreoffice_download_url() {
    local version="${1:-$LIBREOFFICE_VERSION}"
    local deb_arch="$2"
    local dir_arch
    local file_arch

    if [ -n "${LIBREOFFICE_TARBALL_URL:-}" ]; then
        echo "$LIBREOFFICE_TARBALL_URL"
        return 0
    fi

    dir_arch="$(libreoffice_download_dir_arch "$deb_arch")"
    file_arch="$(libreoffice_download_file_arch "$deb_arch")"
    echo "${LIBREOFFICE_DOWNLOAD_BASE}/${version}/deb/${dir_arch}/LibreOffice_${version}_Linux_${file_arch}_deb.tar.gz"
}

replace_with_symlink() {
    local target="$1"
    local path="$2"

    rm -rf "$path"
    ln -s "$target" "$path"
}

build_cache_subdir() {
    local subdir="$1"

    mkdir -p "${BUILD_CACHE_DIR}/${subdir}"
    echo "${BUILD_CACHE_DIR}/${subdir}"
}

ensure_chroot_char_device() {
    local path="$1"
    local mode="$2"
    local major="$3"
    local minor="$4"

    rm -f "$path"
    mknod -m "$mode" "$path" c "$major" "$minor"
}

prepare_chroot_devfs() {
    local rootfs="$1"

    mount -t tmpfs -o mode=755,nosuid tmpfs "$rootfs/dev"
    mkdir -p "$rootfs/dev/pts" "$rootfs/dev/shm"

    ensure_chroot_char_device "$rootfs/dev/null" 666 1 3
    ensure_chroot_char_device "$rootfs/dev/zero" 666 1 5
    ensure_chroot_char_device "$rootfs/dev/full" 666 1 7
    ensure_chroot_char_device "$rootfs/dev/random" 666 1 8
    ensure_chroot_char_device "$rootfs/dev/urandom" 666 1 9
    ensure_chroot_char_device "$rootfs/dev/tty" 666 5 0
    ensure_chroot_char_device "$rootfs/dev/console" 600 5 1
    ensure_chroot_char_device "$rootfs/dev/ptmx" 666 5 2

    mount -t devpts -o mode=620,ptmxmode=666,nosuid,noexec devpts "$rootfs/dev/pts"
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$rootfs/dev/shm"

    ln -snf /proc/self/fd "$rootfs/dev/fd"
    ln -snf /proc/self/fd/0 "$rootfs/dev/stdin"
    ln -snf /proc/self/fd/1 "$rootfs/dev/stdout"
    ln -snf /proc/self/fd/2 "$rootfs/dev/stderr"
}

run_in_chroot() {
    local rootfs="$1"
    local passthrough_var=""
    local npm_registry=""
    local -a env_vars=(
        HOME=/root
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        LANG=C.UTF-8
        LC_ALL=C.UTF-8
        DEBIAN_FRONTEND=noninteractive
        PIP_DISABLE_PIP_VERSION_CHECK=1
    )

    shift

    for passthrough_var in \
        HTTP_PROXY \
        HTTPS_PROXY \
        NO_PROXY \
        NPM_CONFIG_REGISTRY \
        PIP_EXTRA_INDEX_URL \
        PIP_FIND_LINKS \
        PIP_INDEX_URL \
        PIP_NO_INDEX \
        PIP_TRUSTED_HOST \
        http_proxy \
        https_proxy \
        no_proxy \
        npm_config_registry
    do
        if [ -n "${!passthrough_var:-}" ]; then
            env_vars+=("${passthrough_var}=${!passthrough_var}")
        fi
    done

    npm_registry="${NPM_CONFIG_REGISTRY:-${npm_config_registry:-${NPM_REPO:-}}}"
    if [ -n "$npm_registry" ]; then
        env_vars+=(
            "NPM_CONFIG_REGISTRY=${npm_registry}"
            "npm_config_registry=${npm_registry}"
        )
    fi

    chroot "$rootfs" /usr/bin/env "${env_vars[@]}" "$@"
}

configure_official_libreoffice_rootfs_layout() {
    local rootfs="$1"
    local version="${2:-$LIBREOFFICE_VERSION}"
    local install_dirname
    local install_root=""

    install_dirname="$(libreoffice_install_dirname "$version")"
    install_root="/opt/${install_dirname}"

    if [ ! -d "${rootfs}${install_root}/program" ]; then
        echo "Missing extracted LibreOffice program directory: ${install_root}/program" >&2
        exit 1
    fi

    mkdir -p \
        "${rootfs}/usr/bin" \
        "${rootfs}/usr/lib" \
        "${rootfs}/usr/share/java" \
        "${rootfs}/etc/libreoffice" \
        "${rootfs}/var/lib/libreoffice/share/prereg/bundled" \
        "${rootfs}/var/spool/libreoffice/uno_packages"

    replace_with_symlink "../../${install_root#/}" "${rootfs}/usr/lib/libreoffice"
    replace_with_symlink "../../${install_root#/}/program/soffice" "${rootfs}/usr/bin/soffice"
    replace_with_symlink "../../${install_root#/}/share/registry" "${rootfs}/etc/libreoffice/registry"
    replace_with_symlink "../../${install_root#/}/share/psprint/psprint.conf" "${rootfs}/etc/libreoffice/psprint.conf"
    replace_with_symlink "../../${install_root#/}/program/sofficerc" "${rootfs}/etc/libreoffice/sofficerc"
    replace_with_symlink "../../../${install_root#/}/program/classes/hsqldb.jar" "${rootfs}/usr/share/java/hsqldb1.8.0.jar"
    replace_with_symlink "../../../${install_root#/}/program/classes/sdbc_hsqldb.jar" "${rootfs}/usr/share/java/sdbc_hsqldb.jar"
    replace_with_symlink "../../../../${install_root#/}/share/uno_packages/cache" "${rootfs}/var/spool/libreoffice/uno_packages/cache"
}

install_official_libreoffice() {
    local rootfs="$1"
    local deb_arch="$2"
    local build_dir="$3"
    local version="${4:-$LIBREOFFICE_VERSION}"
    local cache_dir="${5:-}"
    local work_dir="${build_dir}/libreoffice"
    local extract_dir="${work_dir}/extract"
    local tarball="${work_dir}/libreoffice-${version}-${deb_arch}.tar.gz"
    local cached_tarball=""
    local deb_dir=""
    local url=""

    mkdir -p "$work_dir" "$extract_dir" "${rootfs}/tmp/libreoffice-debs"
    url="$(libreoffice_download_url "$version" "$deb_arch")"

    if [ -n "$cache_dir" ]; then
        cached_tarball="${cache_dir}/LibreOffice_${version}_${deb_arch}.tar.gz"
        if [ -s "$cached_tarball" ]; then
            echo "Using cached LibreOffice ${version} tarball: ${cached_tarball}"
            cp -f "$cached_tarball" "$tarball"
        fi
    fi

    if [ ! -s "$tarball" ]; then
        echo "Downloading LibreOffice ${version} from ${url}"
        curl -L --retry "${CURL_RETRIES:-5}" --retry-delay "${CURL_RETRY_DELAY:-5}" -o "$tarball" "$url"
        if [ -n "$cached_tarball" ]; then
            cp -f "$tarball" "$cached_tarball"
        fi
    fi

    echo "Installing LibreOffice ${version}..."
    tar -xzf "$tarball" -C "$extract_dir"
    deb_dir="$(find "$extract_dir" -type d -name DEBS -print -quit)"
    if [ -z "$deb_dir" ]; then
        echo "Unable to locate LibreOffice DEBS directory in ${tarball}" >&2
        exit 1
    fi

    cp -a "$deb_dir"/. "${rootfs}/tmp/libreoffice-debs"/
    if ! run_in_chroot "$rootfs" /bin/sh -c 'dpkg -i /tmp/libreoffice-debs/*.deb'; then
        run_in_chroot "$rootfs" apt-get install -f -y --no-install-recommends
    fi
    run_in_chroot "$rootfs" apt-get install -f -y --no-install-recommends
    run_in_chroot "$rootfs" rm -rf /tmp/libreoffice-debs

    configure_official_libreoffice_rootfs_layout "$rootfs" "$version"
}

cleanup_chroot_environment() {
    local rootfs="$1"

    umount -R "$rootfs/dev" >/dev/null 2>&1 || true
    umount -R "$rootfs/sys" >/dev/null 2>&1 || true
    umount "$rootfs/proc" >/dev/null 2>&1 || true
}

prepare_chroot_environment() {
    local rootfs="$1"

    mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev"
    cleanup_chroot_environment "$rootfs"

    mount -t proc proc "$rootfs/proc"
    mount --rbind /sys "$rootfs/sys"
    mount --make-rslave "$rootfs/sys"
    prepare_chroot_devfs "$rootfs"
}

repair_libreoffice_bundle_paths() {
    local dist_root="$1"
    local program_dir="$dist_root/lib/libreoffice/program"
    local fundamental_rc="$program_dir/fundamentalrc"
    local soffice_rc="$program_dir/sofficerc"
    local bootstrap_rc="$program_dir/bootstraprc"

    if [ -f "$fundamental_rc" ]; then
        sed -i \
            -e 's|^BRAND_BASE_DIR=file:///usr/lib/libreoffice$|BRAND_BASE_DIR=${ORIGIN}/..|' \
            -e 's|^BRAND_BASE_DIR=file://\${ORIGIN}|BRAND_BASE_DIR=${ORIGIN}|' \
            -e 's|file:///etc/libreoffice/registry|file://${ORIGIN}/../../../etc/libreoffice/registry|g' \
            -e 's|file:///usr/share/java/hsqldb1.8.0.jar|file://${ORIGIN}/../../../share/java/hsqldb1.8.0.jar|g' \
            "$fundamental_rc"
    fi

    if [ -f "$soffice_rc" ]; then
        sed -i \
            -e 's|file:///etc/libreoffice/sofficerc|file://${ORIGIN}/../../../etc/libreoffice/sofficerc|g' \
            "$soffice_rc"
    fi

    if [ -f "$bootstrap_rc" ]; then
        sed -i \
            -e 's|^InstallMode=.*|InstallMode=install|' \
            -e 's|^UserInstallation=.*|UserInstallation=$SYSUSERCONFIG/libreoffice/4|' \
            "$bootstrap_rc"
    fi
}

repair_libreoffice_program_compat_symlinks() {
    local dist_root="$1"
    local program_dir="$dist_root/lib/libreoffice/program"
    local arch_dir
    local -a arch_dirs=()
    local dst
    local src
    local entry
    local -a symlink_entries=(
        "unorc"
        "lounorc"
        "types.rdb"
        "services.rdb"
        "libgcc3_uno.so"
    )
    local -a copy_entries=(
        "bootstraprc"
        "redirectrc"
        "fundamentalrc"
        "sofficerc"
        "setuprc"
        "versionrc"
    )

    if [ ! -d "$program_dir" ]; then
        return 0
    fi

    mapfile -t arch_dirs <<< "$(find "$dist_root/lib" -mindepth 1 -maxdepth 1 -type d -name '*-linux-gnu' | sort)"
    for arch_dir in "${arch_dirs[@]}"; do
        [ -n "$arch_dir" ] || continue
        for entry in "${symlink_entries[@]}"; do
            src="${program_dir}/${entry}"
            dst="${arch_dir}/${entry}"
            if [ ! -e "$src" ]; then
                continue
            fi
            if [ -L "$dst" ] && [ ! -e "$dst" ]; then
                rm -f "$dst"
            fi
            if [ -e "$dst" ] || [ -L "$dst" ]; then
                continue
            fi
            ln -s "../libreoffice/program/${entry}" "$dst"
        done

        for subdir in services types; do
            if [ -d "${program_dir}/${subdir}" ]; then
                dst="${arch_dir}/${subdir}"
                if [ -L "$dst" ] && [ ! -e "$dst" ]; then
                    rm -f "$dst"
                fi
                if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
                    ln -s "../libreoffice/program/${subdir}" "$dst"
                fi
            fi
        done

        for entry in "${copy_entries[@]}"; do
            src="${program_dir}/${entry}"
            dst="${arch_dir}/${entry}"
            if [ ! -f "$src" ]; then
                continue
            fi
            if [ -L "$dst" ] || [ -f "$dst" ]; then
                rm -f "$dst"
            fi
            cp "$src" "$dst"
            case "$entry" in
                fundamentalrc)
                    sed -i \
                        -e 's|^BRAND_BASE_DIR=.*|BRAND_BASE_DIR=${ORIGIN}/../libreoffice|' \
                        -e 's|^BRAND_INI_DIR=.*|BRAND_INI_DIR=${ORIGIN}/../libreoffice/program|' \
                        -e 's|file://${ORIGIN}/../../../etc/libreoffice/registry|file://${ORIGIN}/../../etc/libreoffice/registry|g' \
                        -e 's|file://${ORIGIN}/../../../share/java/hsqldb1.8.0.jar|file://${ORIGIN}/../../share/java/hsqldb1.8.0.jar|g' \
                        "$dst"
                    ;;
                sofficerc)
                    sed -i \
                        -e 's|file://${ORIGIN}/../../../etc/libreoffice/sofficerc|file://${ORIGIN}/../../etc/libreoffice/sofficerc|g' \
                        "$dst"
                    ;;
            esac
        done
    done
}

repair_libreoffice_share_symlinks() {
    local dist_root="$1"
    local share_dir="$dist_root/lib/libreoffice/share"

    if [ ! -d "$share_dir" ]; then
        return 0
    fi

    mkdir -p \
        "$dist_root/var/lib/libreoffice/share/prereg/bundled" \
        "$dist_root/var/spool/libreoffice/uno_packages/cache"

    rm -f "$share_dir/registry"
    ln -s "../../../etc/libreoffice/registry" "$share_dir/registry"

    mkdir -p "$share_dir/psprint" "$share_dir/prereg" "$share_dir/uno_packages"
    rm -f "$share_dir/psprint/psprint.conf" "$share_dir/prereg/bundled" "$share_dir/uno_packages/cache"
    ln -s "../../../../etc/libreoffice/psprint.conf" "$share_dir/psprint/psprint.conf"
    ln -s "../../../../var/lib/libreoffice/share/prereg/bundled" "$share_dir/prereg/bundled"
    ln -s "../../../../var/spool/libreoffice/uno_packages/cache" "$share_dir/uno_packages/cache"
}

verify_markitdown_runtime() {
    local script='
import importlib
import PIL

last_error = None
for module_name in ("markitdown", "markitdown_no_magika"):
    try:
        importlib.import_module(module_name)
        break
    except Exception as exc:
        last_error = exc
else:
    raise last_error or ModuleNotFoundError("No MarkItDown module is available")
'

    TRINITY_NO_SANDBOX=1 "$DIST_DIR/trinity-office" exec python3 -c "$script" >/dev/null
}

verify_markitdown_rootfs_runtime() {
    local script='
import importlib
import PIL

last_error = None
for module_name in ("markitdown", "markitdown_no_magika"):
    try:
        importlib.import_module(module_name)
        break
    except Exception as exc:
        last_error = exc
else:
    raise last_error or ModuleNotFoundError("No MarkItDown module is available")
'

    run_in_chroot "$DIST_DIR/rootfs" python3 -c "$script" >/dev/null
}

bundled_libreoffice_has_hsqldb_jar() {
    [ -f "$DIST_DIR/share/java/hsqldb1.8.0.jar" ] || \
        [ -f "$DIST_DIR/lib/libreoffice/program/classes/hsqldb.jar" ]
}

bundled_runtime_has_libreoffice_rootfs() {
    [ -d "$DIST_DIR/rootfs/usr/bin" ] || return 1

    if [ ! -d "$DIST_DIR/rootfs/usr/lib/libreoffice" ] && \
        ! compgen -G "$DIST_DIR/rootfs/opt/libreoffice*/program" >/dev/null; then
        return 1
    fi

    return 0
}

verify_runtime_bundle() {
    echo "Verifying bundled runtime..."

    if [ ! -x "$DIST_DIR/bin/python3" ]; then
        echo "Missing bundled python3 binary"
        exit 1
    fi

    if [ ! -x "$DIST_DIR/bin/node" ]; then
        echo "Missing bundled node binary"
        exit 1
    fi

    if [ ! -x "$DIST_DIR/bin/soffice" ]; then
        echo "Missing bundled soffice binary"
        exit 1
    fi

    if [ ! -x "$DIST_DIR/lib/libreoffice/program/javaldx" ]; then
        echo "Missing bundled LibreOffice javaldx helper"
        exit 1
    fi

    if [ ! -f "$DIST_DIR/lib/libreoffice/share/config/soffice.cfg/modules/simpress/ui/tabviewbar.ui" ]; then
        echo "Missing bundled LibreOffice Impress UI config: lib/libreoffice/share/config/soffice.cfg/modules/simpress/ui/tabviewbar.ui"
        exit 1
    fi

    if ! bundled_libreoffice_has_hsqldb_jar; then
        echo "Missing bundled LibreOffice Java dependency: share/java/hsqldb1.8.0.jar or lib/libreoffice/program/classes/hsqldb.jar"
        exit 1
    fi

    if bundled_runtime_has_libreoffice_rootfs; then
        prepare_chroot_environment "$DIST_DIR/rootfs"
        if ! verify_markitdown_rootfs_runtime; then
            cleanup_chroot_environment "$DIST_DIR/rootfs"
            echo "Bundled rootfs python runtime failed to import MarkItDown"
            exit 1
        fi
        if ! run_in_chroot "$DIST_DIR/rootfs" /usr/bin/env \
            NODE_PATH=/usr/local/lib/node_modules:/usr/lib/node_modules:/usr/share/nodejs \
            node -e "require('pptxgenjs')" >/dev/null
        then
            cleanup_chroot_environment "$DIST_DIR/rootfs"
            echo "Bundled rootfs node runtime failed to import pptxgenjs"
            exit 1
        fi
        if ! run_in_chroot "$DIST_DIR/rootfs" /usr/bin/env \
            -u DISPLAY \
            -u WAYLAND_DISPLAY \
            -u XDG_RUNTIME_DIR \
            -u DBUS_SESSION_BUS_ADDRESS \
            /usr/bin/soffice --headless --version >/dev/null
        then
            cleanup_chroot_environment "$DIST_DIR/rootfs"
            echo "Bundled rootfs soffice failed to start"
            exit 1
        fi
        cleanup_chroot_environment "$DIST_DIR/rootfs"
    else
        verify_markitdown_runtime

        TRINITY_NO_SANDBOX=1 "$DIST_DIR/trinity-office" exec \
            node -e "require('pptxgenjs')"

        env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
            TRINITY_NO_SANDBOX=1 "$DIST_DIR/trinity-office" exec \
            soffice --headless --version >/dev/null
    fi

    if bwrap_is_usable; then
        env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
            "$DIST_DIR/trinity-office" exec soffice --headless --version >/dev/null
    elif command -v bwrap >/dev/null 2>&1; then
        echo "Skipping sandboxed soffice verification because bubblewrap is installed but unusable in this environment"
    fi
}

bwrap_is_usable() {
    command -v bwrap >/dev/null 2>&1 || return 1
    bwrap --ro-bind / / --dev /dev --proc /proc /bin/true >/dev/null 2>&1
}

main() {
    local preferred_build_dir="${TRINITY_BUILD_DIR:-$DEFAULT_BUILD_DIR}"
    local preferred_dist_dir="${TRINITY_DIST_DIR:-$DEFAULT_DIST_DIR}"
    local -a runtime_packages=()
    local -a python_packages=()
    local -a node_packages=()
    local cache_root=""
    local debootstrap_cache_dir=""
    local download_cache_dir=""
    local apt_archives_cache_dir=""
    local pip_cache_dir=""
    local npm_cache_dir=""
    local ubuntu_base_tarball=""

    DIST_DIR="$(choose_build_dir "$preferred_dist_dir")"
    BUILD_DIR="$(choose_build_dir "$preferred_build_dir")"
    ROOTFS="$BUILD_DIR/rootfs"

    echo "=== Trinity Office Runtime Builder ==="
    echo "Build directory: $BUILD_DIR"
    echo "Output directory: $DIST_DIR"
    if [ "$BUILD_DIR" != "$preferred_build_dir" ]; then
        echo "Using a temporary build directory because ${preferred_build_dir} is mounted with nodev/noexec"
    fi
    if [ "$DIST_DIR" != "$preferred_dist_dir" ]; then
        echo "Using a temporary output directory because ${preferred_dist_dir} is mounted with nodev/noexec or uses a case-insensitive 9p/drvfs filesystem"
    fi

    # Clean previous builds
    cleanup_chroot_environment "$ROOTFS"
    cleanup_chroot_environment "$DIST_DIR/rootfs"
    rm -rf "$DIST_DIR" "$BUILD_DIR"
    mkdir -p "$DIST_DIR" "$BUILD_DIR"

    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ARCH_NAME="x64"
        DEB_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        ARCH_NAME="arm64"
        DEB_ARCH="arm64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi

    echo "Building for architecture: $ARCH ($DEB_ARCH)"

    cache_root="$(build_cache_subdir "")"
    debootstrap_cache_dir="$(build_cache_subdir "debootstrap/${UBUNTU_CODENAME}-${DEB_ARCH}")"
    download_cache_dir="$(build_cache_subdir "downloads")"
    apt_archives_cache_dir="$(build_cache_subdir "apt-archives/${UBUNTU_CODENAME}-${DEB_ARCH}")"
    pip_cache_dir="$(build_cache_subdir "pip")"
    npm_cache_dir="$(build_cache_subdir "npm")"
    echo "Using build cache: ${cache_root}"

    # Allow callers to override the Ubuntu mirror while preserving
    # architecture-specific defaults for normal builds.
    UBUNTU_REPO="$(resolve_ubuntu_repo "$DEB_ARCH")"
    echo "Using repository: $UBUNTU_REPO"

    # Create minimal Ubuntu rootfs
    echo "Creating minimal rootfs..."
    mkdir -p "$ROOTFS"

    # Use debootstrap if available, otherwise download minimal rootfs
    if command -v debootstrap &> /dev/null; then
        echo "Using debootstrap..."
        debootstrap --cache-dir="$debootstrap_cache_dir" \
            --variant=minbase --include=ca-certificates \
            "$UBUNTU_CODENAME" "$ROOTFS" "$UBUNTU_REPO"
    else
        echo "Downloading minimal Ubuntu rootfs..."
        ubuntu_base_tarball="${download_cache_dir}/ubuntu-base-${UBUNTU_VERSION}-${DEB_ARCH}.tar.gz"
        if [ ! -s "$ubuntu_base_tarball" ]; then
            curl -L -o "$ubuntu_base_tarball" "https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_VERSION}/release/ubuntu-base-${UBUNTU_VERSION}-base-${DEB_ARCH}.tar.gz"
        fi
        tar xzf "$ubuntu_base_tarball" -C "$ROOTFS"
    fi

    # Configure apt sources with universe repository
    echo "Configuring apt sources..."
    cat > "$ROOTFS/etc/apt/sources.list" << EOF
deb $UBUNTU_REPO $UBUNTU_CODENAME main universe
deb $UBUNTU_REPO $UBUNTU_CODENAME-updates main universe
deb $UBUNTU_REPO $UBUNTU_CODENAME-security main universe
EOF

    # Package post-install hooks need a normal chroot view of /proc and /dev.
    prepare_chroot_environment "$ROOTFS"
    trap 'cleanup_chroot_environment "$ROOTFS"' EXIT
    copy_tree_contents "$apt_archives_cache_dir" "$ROOTFS/var/cache/apt/archives"
    copy_tree_contents "$pip_cache_dir" "$ROOTFS/var/cache/trinity-pip"
    copy_tree_contents "$npm_cache_dir" "$ROOTFS/var/cache/trinity-npm"

    # Install required packages in chroot
    echo "Installing packages..."
    run_in_chroot "$ROOTFS" apt-get update

    # Install basic packages first
    run_in_chroot "$ROOTFS" apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg

    # Install Ubuntu-packaged runtime dependencies.
    # Keep Node.js self-contained from the Ubuntu archive and bundle CJK-capable
    # fonts so LibreOffice can substitute missing Windows Chinese fonts instead
    # of rendering tofu boxes in exported PDFs.
    mapfile -t runtime_packages <<< "$(runtime_apt_packages)"
    run_in_chroot "$ROOTFS" apt-get install -y --no-install-recommends \
        "${runtime_packages[@]}"

    install_official_libreoffice "$ROOTFS" "$DEB_ARCH" "$BUILD_DIR" "$LIBREOFFICE_VERSION" "$download_cache_dir"

    # Clean up apt cache
    copy_tree_contents "$ROOTFS/var/cache/apt/archives" "$apt_archives_cache_dir"
    run_in_chroot "$ROOTFS" apt-get clean
    run_in_chroot "$ROOTFS" rm -rf /var/lib/apt/lists/*

    # Install Python packages into the bundled runtime path.
    # Using --target ensures the package lands inside the runtime bundle. We also
    # keep packaging logic tolerant of dependencies that still install into
    # /usr/local on future distro or toolchain changes.
    # Use the no-magika MarkItDown distribution here because the upstream
    # magika/onnxruntime stack has started crashing during bundled runtime
    # verification on GitHub Actions, while presentation extraction only needs the
    # core MarkItDown CLI/API.
    echo "Installing Python packages..."
    run_in_chroot "$ROOTFS" mkdir -p /usr/lib/python3/dist-packages
    mapfile -t python_packages <<< "$(runtime_python_packages)"
    run_in_chroot "$ROOTFS" /usr/bin/env PIP_CACHE_DIR=/var/cache/trinity-pip \
        pip3 install --upgrade \
        --retries "${PIP_RETRIES:-10}" \
        --timeout "${PIP_TIMEOUT:-300}" \
        --target /usr/lib/python3/dist-packages \
        "${python_packages[@]}"
    copy_tree_contents "$ROOTFS/var/cache/trinity-pip" "$pip_cache_dir"

    # Install Node.js packages globally.
    # Keep a known-good pptxgenjs version pinned to reduce bundle regressions
    # across distro/runtime upgrades.
    echo "Installing Node.js packages..."
    mapfile -t node_packages <<< "$(runtime_node_packages)"
    run_in_chroot "$ROOTFS" /usr/bin/env NPM_CONFIG_CACHE=/var/cache/trinity-npm \
        npm install -g "${node_packages[@]}"
    copy_tree_contents "$ROOTFS/var/cache/trinity-npm" "$npm_cache_dir"

    cleanup_chroot_environment "$ROOTFS"
    trap - EXIT

    # Remove unnecessary files to reduce size
    echo "Optimizing rootfs size..."
    rm -rf "$ROOTFS/usr/share/doc"/*
    rm -rf "$ROOTFS/usr/share/man"/*
    rm -rf "$ROOTFS/usr/share/info"/*
    rm -rf "$ROOTFS/var/cache"/*
    rm -rf "$ROOTFS/var/log"/*
    rm -rf "$ROOTFS/tmp"/*
    find "$ROOTFS/usr/lib/python3" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$ROOTFS/usr/lib/python3" -name "*.pyc" -delete 2>/dev/null || true

    # Copy to dist with a preserved rootfs for LibreOffice and top-level
    # compatibility symlinks for the existing wrapper/runtime contract.
    echo "Creating distribution package..."
    mkdir -p "$DIST_DIR/rootfs" "$DIST_DIR/rootfs/var/lib" "$DIST_DIR/rootfs/var/spool"

    copy_path_into_dir "$ROOTFS/bin" "$DIST_DIR/rootfs"
    copy_path_into_dir "$ROOTFS/lib" "$DIST_DIR/rootfs"
    copy_path_into_dir "$ROOTFS/lib64" "$DIST_DIR/rootfs"
    copy_path_into_dir "$ROOTFS/opt" "$DIST_DIR/rootfs"
    copy_path_into_dir "$ROOTFS/usr" "$DIST_DIR/rootfs"
    copy_path_into_dir "$ROOTFS/etc" "$DIST_DIR/rootfs"
    copy_path_into_dir "$ROOTFS/var/lib/libreoffice" "$DIST_DIR/rootfs/var/lib"
    copy_path_into_dir "$ROOTFS/var/spool/libreoffice" "$DIST_DIR/rootfs/var/spool"

    ln -s "rootfs/usr/bin" "$DIST_DIR/bin"
    ln -s "rootfs/usr/lib" "$DIST_DIR/lib"
    ln -s "rootfs/usr/share" "$DIST_DIR/share"
    ln -s "rootfs/etc" "$DIST_DIR/etc"
    ln -s "rootfs/var" "$DIST_DIR/var"

    # Copy wrapper script
    cp "$PROJECT_ROOT/wrapper/trinity-office" "$DIST_DIR/"
    chmod +x "$DIST_DIR/trinity-office"

    # Create version file
    echo "1.0.0" > "$DIST_DIR/VERSION"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DIST_DIR/VERSION"

    verify_runtime_bundle

    # Create tarball
    echo "Creating tarball..."
    cd "$PROJECT_ROOT"
    tar --hard-dereference -czf "trinity-office-runtime-linux-${ARCH_NAME}.tar.gz" -C "$DIST_DIR" .

    echo ""
    echo "=== Build Complete ==="
    echo "Output: trinity-office-runtime-linux-${ARCH_NAME}.tar.gz"
    echo "Size: $(du -h "trinity-office-runtime-linux-${ARCH_NAME}.tar.gz" | cut -f1)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

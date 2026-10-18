#!/bin/bash
# YggMesh Docker Image Builder
# Uses OpenWrt Image Builder (x86_64) to create a rootfs and package it as a Docker image.
# The resulting image is used for Mininet-WiFi emulation.
#
# Usage: ./scripts/build_docker.sh
#
# Required build-time inputs (env vars):
#   YGGDRASIL_DNS          Space-separated DNS resolver addresses reachable over Yggdrasil (can be empty)
#   DEFAULT_ROOT_PASSWORD  Initial root password set on first boot
#   PRIVATE_SSID           Client AP SSID for end-user devices
#   YGGPEERS_INSTANCES     Space-separated yggpeers base URLs for global peer auto-discovery (can be empty to disable)
#   YGGPEERS_COUNT         Target number of global peers per node with internet on WAN (1-10)
#   YGGPEERS_CHECK_INTERVAL Minutes between peer checks: 1-59 or a multiple of 60 up to 1380
#   YGGPEERS_RERANK_INTERVAL Days between forced refreshes of the peers list (1-90)
#   CLEARNET_EXITS         Space-separated public keys of clearnet exits (can be empty)
#   CLEARNET_MODE          Clients' IPv4: off, wan, wan_exit or exit
#
# These are the defaults of the user settings on a fresh install; flashing
# with kept settings keeps the node's own ones.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

OPENWRT_TARGET="x86/64"
DOCKER_IMAGE="yggmesh-openwrt"

# ============================================================================
# Functions
# ============================================================================

usage() {
    echo "Usage: $0"
    echo ""
    echo "Build a Docker image containing the YggMesh rootfs (x86_64)."
    echo ""
    echo "OpenWrt version: ${OPENWRT_VERSION} (override with OPENWRT_VERSION env var)"
    echo ""
    echo "Environment variables (REQUIRED, unless specified otherwise):"
    echo "  BUILD_ROOT            Image Builder workdir (optional, default: /tmp/yggmesh-build)"
    echo "  OPENWRT_VERSION        OpenWrt release (optional, default: ${OPENWRT_VERSION})"
    echo "  PACKAGES_EXTRA         Additional packages (optional, space-separated)"
    echo "  YGGDRASIL_DNS          Space-separated DNS resolver addresses reachable over Yggdrasil (can be empty)"
    echo "  DEFAULT_ROOT_PASSWORD  Initial root password"
    echo "  PRIVATE_SSID           Client AP SSID"
    echo "  YGGPEERS_INSTANCES     Space-separated yggpeers base URLs for peer auto-discovery (can be empty to disable)"
    echo "  YGGPEERS_COUNT         Target number of global peers per node (1-10)"
    echo "  YGGPEERS_CHECK_INTERVAL Minutes between peer checks: 1-59 or a multiple of 60 up to 1380"
    echo "  YGGPEERS_RERANK_INTERVAL Days between forced refreshes of the peers list (1-90)"
    echo "  CLEARNET_EXITS         Space-separated public keys of clearnet exits (can be empty)"
    echo "  CLEARNET_MODE          Clients' IPv4: off, wan, wan_exit or exit"
    exit 1
}

build_rootfs() {
    local dir
    dir="$(get_builder_dir "$OPENWRT_TARGET")"

    local tmpfiles
    tmpfiles=$(prepare_files_dir "docker_x86_64" "eth0:wan")
    add_yggdrasil "$OPENWRT_TARGET" "$tmpfiles"

    local packages="${COMMON_PACKAGES[*]} ${PACKAGES_EXTRA:-}"

    echo "Building rootfs for profile: generic"
    echo "Packages: ${packages}"

    make -C "$dir" image \
        PROFILE="generic" \
        PACKAGES="$packages" \
        FILES="$tmpfiles" \
        type="rootfs"

    rm -rf "$tmpfiles"
}

build_docker_image() {
    if ! command -v docker &> /dev/null; then
        echo "Error: docker command not found." >&2
        echo "Please rebuild the Dev Container ('Dev Containers: Rebuild Container' in VS Code)," >&2
        echo "since we added the docker-in-docker feature to the configuration." >&2
        exit 1
    fi

    local builder_dir docker_build_dir rootfs_file
    builder_dir="$(get_builder_dir "$OPENWRT_TARGET")"
    docker_build_dir="${BUILD_ROOT}/docker_build"

    mkdir -p "$docker_build_dir"

    rootfs_file=$(ls "$builder_dir"/bin/targets/x86/64/*-rootfs.tar.gz | head -n 1)
    cp "$rootfs_file" "$docker_build_dir/rootfs.tar.gz"

    cat <<EOF > "$docker_build_dir/Dockerfile"
FROM scratch
ADD rootfs.tar.gz /
CMD ["/sbin/init"]
EOF

    docker build -t "$DOCKER_IMAGE" "$docker_build_dir"
}

# ============================================================================
# Main
# ============================================================================

if [ $# -gt 0 ]; then
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
    else
        echo "Error: Unknown argument '$1'"
        echo ""
        usage
    fi
fi

echo "=== YggMesh Docker Image Builder ==="
echo "OpenWrt: ${OPENWRT_VERSION}"
echo "Target:  ${OPENWRT_TARGET}"
echo "Image:   ${DOCKER_IMAGE}"
mkdir -p "$BUILD_ROOT"
echo "Build root: ${BUILD_ROOT}"
echo ""

validate_inputs
download_builder "$OPENWRT_TARGET"
build_rootfs
build_docker_image

echo ""
echo "Build complete! Docker image '${DOCKER_IMAGE}' is ready."


#!/bin/bash
# YggMesh Firmware Builder
# Uses OpenWrt Image Builder to create custom firmware with mesh packages.
#
# Usage: ./scripts/build.sh <device_keyname>
# Example: ./scripts/build.sh axt1800
#
# Required build-time inputs (env vars).
#   YGGDRASIL_DNS          Space-separated DNS resolver addresses reachable over Yggdrasil (can be empty)
#   DEFAULT_ROOT_PASSWORD  Initial root password set on first boot
#   YGGDRASIL_PEERS        Space-separated list of Yggdrasil peer URIs (can be empty)
#   PRIVATE_SSID           Client AP SSID for end-user devices
#   MESH_ID                802.11s mesh identifier
#   MESH_KEY               SAE key for mesh peering
#   YGG_PORT               Yggdrasil fixed peering port

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_DIR}"

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.0}"
YGGMESH_BUILD="23"
FIRMWARE_VERSION="${OPENWRT_VERSION}-ym${YGGMESH_BUILD}"

# ============================================================================
# Device Database (device → target/subtarget + Image Builder profile)
# ============================================================================

device_config() {
    local device="$1"
    case "$device" in
        axt1800)
            OPENWRT_TARGET="qualcommax/ipq60xx"
            PROFILE="glinet_gl-axt1800"
            PORT_MAP="dsa"
            ;;
        mt3000)
            OPENWRT_TARGET="mediatek/filogic"
            PROFILE="glinet_gl-mt3000"
            PORT_MAP="eth0:wan eth1:lan"
            ;;
        mt6000)
            OPENWRT_TARGET="mediatek/filogic"
            PROFILE="glinet_gl-mt6000"
            PORT_MAP="eth0:wan eth1:lan"
            ;;
        ax53u)
            OPENWRT_TARGET="ramips/mt7621"
            PROFILE="asus_rt-ax53u"
            PORT_MAP="dsa"
            ;;
        ar300m16)
            OPENWRT_TARGET="ath79/generic"
            PROFILE="glinet_gl-ar300m16"
            PORT_MAP="eth0:lan eth1:wan"
            ;;
        cpe710)
            OPENWRT_TARGET="ath79/generic"
            PROFILE="tplink_cpe710-v1"
            PORT_MAP="eth0:lan eth1:wan"
            ;;
        ap3000outdoor)
            OPENWRT_TARGET="mediatek/filogic"
            PROFILE="cudy_ap3000outdoor-v1"
            PORT_MAP="eth0:wan"
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# Packages
# ============================================================================

PACKAGES=(
    yggdrasil
    luci
    luci-proto-yggdrasil
    tcpdump
    iperf3
    iwinfo
    curl
)

# ============================================================================
# Functions
# ============================================================================

usage() {
    echo "Usage: $0 <device>"
    echo ""
    echo "Devices:"
    echo "  axt1800        GL.iNet GL-AXT1800 (Slate AX)       qualcommax/ipq60xx"
    echo "  mt3000         GL.iNet GL-MT3000 (Beryl AX)        mediatek/filogic"
    echo "  mt6000         GL.iNet GL-MT6000 (Flint 2)         mediatek/filogic"
    echo "  ax53u          Asus RT-AX53U                       ramips/mt7621"
    echo "  ar300m16       GL.iNet GL-AR300M16-EXT (16MB)      ath79/generic"
    echo "  cpe710         TP-Link CPE710 v1 (5GHz outdoor)    ath79/generic"
    echo "  ap3000outdoor  Cudy AP3000 Outdoor V1              mediatek/filogic"
    echo ""
    echo "OpenWrt version: ${OPENWRT_VERSION} (override with OPENWRT_VERSION env var)"
    echo ""
    echo "Environment variables (REQUIRED, unless specified otherwise):"
    echo "  OPENWRT_VERSION        OpenWrt release (optional, default: ${OPENWRT_VERSION})"
    echo "  PACKAGES_EXTRA         Additional packages (optional, space-separated)"
    echo "  YGGDRASIL_DNS          Space-separated DNS resolver addresses reachable over Yggdrasil (can be empty)"
    echo "  DEFAULT_ROOT_PASSWORD  Initial root password"
    echo "  YGGDRASIL_PEERS        Space-separated Yggdrasil peer URIs (can be empty)"
    echo "  PRIVATE_SSID           Client AP SSID"
    echo "  MESH_ID                802.11s mesh identifier"
    echo "  MESH_KEY               SAE key for mesh peering"
    echo "  YGG_PORT               Yggdrasil fixed peering port"
    exit 1
}

builder_dir() {
    echo "${BUILD_ROOT}/imagebuilder-${OPENWRT_VERSION}-${OPENWRT_TARGET//\//-}"
}

is_case_sensitive_dir() {
    local dir="$1"
    local lower upper
    lower="${dir}/.yggmesh_case_test"
    upper="${dir}/.YGGMESH_CASE_TEST"

    rm -f "$lower" "$upper"
    : > "$lower"

    # If creating lower-case path also creates upper-case alias, FS is case-insensitive.
    if [ -e "$upper" ]; then
        rm -f "$lower" "$upper"
        return 1
    fi

    rm -f "$lower" "$upper"
    return 0
}

validate_inputs() {
    # Fail early before downloading anything if required inputs are missing.
    # :? fails if unset or empty; ? fails only if unset (empty string is allowed).
    : "${DEFAULT_ROOT_PASSWORD:?DEFAULT_ROOT_PASSWORD must not be empty}"
    : "${PRIVATE_SSID:?PRIVATE_SSID must not be empty}"
    : "${MESH_ID:?MESH_ID must not be empty}"
    : "${MESH_KEY:?MESH_KEY must not be empty}"
    : "${YGG_PORT:?YGG_PORT must not be empty}"
    : "${YGGDRASIL_DNS?YGGDRASIL_DNS must be set (can be empty)}"
    : "${YGGDRASIL_PEERS?YGGDRASIL_PEERS must be set (can be empty)}"
}

download_builder() {
    local dir
    dir="$(builder_dir)"

    if [ -d "$dir" ]; then
        echo "Image Builder already downloaded at ${dir##*/}, skipping..."
        return
    fi

    # OpenWrt 25.x uses .tar.zst, older uses .tar.xz
    local base_url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${OPENWRT_TARGET//\//-}.Linux-x86_64"
    echo "Downloading OpenWrt Image Builder ${OPENWRT_VERSION} for ${OPENWRT_TARGET}..."
    mkdir -p "$dir"

    if wget -q --spider "${base_url}.tar.zst" 2>/dev/null; then
        wget -q --show-progress -O- "${base_url}.tar.zst" | zstd -d | tar -x --strip-components=1 -C "$dir"
    else
        wget -q --show-progress -O- "${base_url}.tar.xz" | tar -xJ --strip-components=1 -C "$dir"
    fi
}

build_firmware() {
    local dir
    dir="$(builder_dir)"

    local packages
    packages="${PACKAGES[*]} ${PACKAGES_EXTRA:-}"

    # Create temp FILES dir with version/profile
    local tmpfiles
    tmpfiles=$(mktemp -d)
    cp -a "${PROJECT_DIR}/files/"* "$tmpfiles/"
    mkdir -p "$tmpfiles/etc/yggmesh/inputs"
    echo "$FIRMWARE_VERSION" > "$tmpfiles/etc/yggmesh/version"
    echo "$PROFILE" > "$tmpfiles/etc/yggmesh/profile"
    echo "$PORT_MAP" > "$tmpfiles/etc/yggmesh/port_map"

    # Bake build-time inputs into the firmware.
    echo "$YGGDRASIL_DNS" > "$tmpfiles/etc/yggmesh/inputs/yggdrasil_dns"
    echo "$DEFAULT_ROOT_PASSWORD" > "$tmpfiles/etc/yggmesh/inputs/root_password"
    echo "$YGGDRASIL_PEERS" > "$tmpfiles/etc/yggmesh/inputs/yggdrasil_peers"
    echo "$PRIVATE_SSID" > "$tmpfiles/etc/yggmesh/inputs/private_ssid"
    echo "$MESH_ID" > "$tmpfiles/etc/yggmesh/inputs/mesh_id"
    echo "$MESH_KEY" > "$tmpfiles/etc/yggmesh/inputs/mesh_key"
    echo "$YGG_PORT" > "$tmpfiles/etc/yggmesh/inputs/ygg_port"

    echo "Building firmware for profile: ${PROFILE}"
    echo "Packages: ${packages}"
    echo "Custom files: ${tmpfiles}"

    make -C "$dir" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$tmpfiles" \
        BIN_DIR="${PROJECT_DIR}/output"

    rm -rf "$tmpfiles"

    # Ensure output files are world-readable (served by nginx)
    chmod 644 "${PROJECT_DIR}/output/"* 2>/dev/null || true

    echo ""
    echo "Build complete! Firmware images:"
    ls -lh "${PROJECT_DIR}/output/"*.bin 2>/dev/null || true
    ls -lh "${PROJECT_DIR}/output/"*.img* 2>/dev/null || true
    ls -lh "${PROJECT_DIR}/output/"*.itb 2>/dev/null || true

    # Update manifest.json with this device's sysupgrade info
    update_manifest
}

update_manifest() {
    local manifest="${PROJECT_DIR}/output/manifest.json"
    local sysupgrade_file sha256

    # Find the sysupgrade.bin for this profile
    sysupgrade_file=$(ls -t "${PROJECT_DIR}/output/"*"${PROFILE}"*-sysupgrade.bin 2>/dev/null | head -1)

    if [ -z "$sysupgrade_file" ]; then
        echo "Warning: No sysupgrade.bin found for ${PROFILE}, skipping manifest update"
        return
    fi

    sha256=$(sha256sum "$sysupgrade_file" | cut -d' ' -f1)
    local filename
    filename=$(basename "$sysupgrade_file")

    # Create or update manifest.json
    if [ -f "$manifest" ]; then
        # Update existing manifest — replace version + add/update device entry
        local tmp
        tmp=$(mktemp)
        python3 -c "
import json, sys
with open('$manifest') as f:
    m = json.load(f)
m['version'] = '$FIRMWARE_VERSION'
m.setdefault('devices', {})['$PROFILE'] = {
    'sysupgrade': '$filename',
    'sha256': '$sha256'
}
json.dump(m, sys.stdout, indent=2)
" > "$tmp" && mv "$tmp" "$manifest"
    else
        # Create new manifest
        python3 -c "
import json, sys
m = {
    'version': '$FIRMWARE_VERSION',
    'devices': {
        '$PROFILE': {
            'sysupgrade': '$filename',
            'sha256': '$sha256'
        }
    }
}
json.dump(m, sys.stdout, indent=2)
" > "$manifest"
    fi

    # Ensure manifest is world-readable (served by nginx)
    chmod 644 "$manifest"

    echo ""
    echo "Manifest updated: ${manifest}"
    echo "  Device: ${PROFILE}"
    echo "  File:   ${filename}"
    echo "  SHA256: ${sha256}"
}

# ============================================================================
# Main
# ============================================================================

if [ $# -lt 1 ]; then
    usage
fi

INPUT="$1"

if ! device_config "$INPUT"; then
    echo "Error: Unknown device '${INPUT}'"
    echo ""
    usage
fi

echo "=== YggMesh Firmware Builder ==="
echo "Device:  ${INPUT}"
echo "OpenWrt: ${OPENWRT_VERSION}"
echo "Target:  ${OPENWRT_TARGET}"
echo "Profile: ${PROFILE}"

# OpenWrt build system requires case-sensitive filesystem.
# On macOS bind mounts in containers this can be case-insensitive,
# so move Image Builder workdir to Linux /tmp automatically.
if ! is_case_sensitive_dir "$BUILD_ROOT"; then
    BUILD_ROOT="/tmp/yggmesh-build"
    mkdir -p "$BUILD_ROOT"
    echo "Build root is case-insensitive; using case-sensitive workdir: ${BUILD_ROOT}"
fi

echo "Build root: ${BUILD_ROOT}"
echo ""

download_builder
validate_inputs
build_firmware

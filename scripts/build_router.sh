#!/bin/bash
# YggMesh Firmware Builder
# Uses OpenWrt Image Builder to create custom firmware with mesh packages.
#
# Usage: ./scripts/build_router.sh <device_keyname>
# Example: ./scripts/build_router.sh axt1800
#
# Required build-time inputs (env vars).
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

# ============================================================================
# Device Database (device → target/subtarget + Image Builder profile)
# ============================================================================

device_config() {
    local device="$1"
    case "$device" in
        axt1800)
            OPENWRT_TARGET="qualcommax/ipq60xx"
            PROFILE="glinet_gl-axt1800"
            PORT_MAP="wan:wan lan1:lan lan2:lan"
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
            PORT_MAP="wan:wan lan1:lan lan2:lan lan3:lan"
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
        wr3000)
            OPENWRT_TARGET="mediatek/filogic"
            PROFILE="cudy_wr3000-v1"
            PORT_MAP="wan:wan lan1:lan lan2:lan lan3:lan"
            # 16 MB SPI-NOR: the settings (JFFS2 rootfs_data) get what the image
            # leaves. PPPoE is never used by YggMesh (WAN is DHCP): drop it here.
            FIRMWARE_PARTITION_SIZE=$((0xf10000))
            DEVICE_PACKAGES="-ppp -ppp-mod-pppoe"
            ;;
        *)
            return 1
            ;;
    esac
}

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
    echo "  wr3000         Cudy WR3000 V1                      mediatek/filogic"
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

build_firmware() {
    local dir
    dir="$(get_builder_dir "$OPENWRT_TARGET")"

    local packages
    packages="${COMMON_PACKAGES[*]} ${DEVICE_PACKAGES:-} ${PACKAGES_EXTRA:-}"

    # Create temp FILES dir with version/profile and inputs
    local tmpfiles
    tmpfiles=$(prepare_files_dir "$PROFILE" "$PORT_MAP")
    add_yggdrasil "$OPENWRT_TARGET" "$tmpfiles"

    echo "Building firmware for profile: ${PROFILE}"
    echo "Packages: ${packages}"
    echo "Custom files: ${tmpfiles}"

    make -C "$dir" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$tmpfiles" \
        BIN_DIR="${PROJECT_DIR}/output"

    rm -rf "$tmpfiles"

    check_settings_space

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

# NOR devices keep the settings in a JFFS2 partition made of the firmware
# partition's space after the image. JFFS2 refuses to mount fewer than 5 erase
# blocks (64 KiB on NOR): the node then runs on a RAM overlay, loses its
# settings on reboot and hangs on the first boot after a flash with kept
# settings. Fail the build unless at least 512 KiB are left.
check_settings_space() {
    local img size free min=$((512 * 1024))

    [ -n "${FIRMWARE_PARTITION_SIZE:-}" ] || return 0
    img=$(ls -t "${PROJECT_DIR}/output/"*"${PROFILE}"*-sysupgrade.bin 2>/dev/null | head -1 || true)
    [ -n "$img" ] || return 0
    size=$(stat -c %s "$img")
    free=$((FIRMWARE_PARTITION_SIZE - size))
    echo "Settings space (rootfs_data): $((free / 1024)) KiB of ${FIRMWARE_PARTITION_SIZE} bytes"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::notice::${PROFILE}: $((free / 1024)) KiB left for the settings"
    if [ "$free" -lt "$min" ]; then
        fail "the image leaves only $((free / 1024)) KiB for the settings, at least $((min / 1024)) KiB are needed. Drop packages."
    fi
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
mkdir -p "$BUILD_ROOT"
echo "Build root: ${BUILD_ROOT}"
echo ""

validate_inputs
download_builder "$OPENWRT_TARGET"
build_firmware

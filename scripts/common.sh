#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_ROOT="${BUILD_ROOT:-/tmp/yggmesh-build}"
OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.0}"

get_builder_dir() {
    local target="$1"
    echo "${BUILD_ROOT}/imagebuilder-${OPENWRT_VERSION}-${target//\//-}"
}

download_builder() {
    local target="$1"
    local dir
    dir="$(get_builder_dir "$target")"

    if [ -d "$dir" ]; then
        echo "Image Builder already downloaded at ${dir##*/}, skipping..."
        return
    fi

    local base_url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${target}/openwrt-imagebuilder-${OPENWRT_VERSION}-${target//\//-}.Linux-x86_64"
    echo "Downloading OpenWrt Image Builder ${OPENWRT_VERSION} for ${target}..."
    mkdir -p "$dir"

    if wget -q --spider "${base_url}.tar.zst" 2>/dev/null; then
        wget -q --show-progress -O- "${base_url}.tar.zst" | zstd -d | tar -x --strip-components=1 -C "$dir"
    else
        wget -q --show-progress -O- "${base_url}.tar.xz" | tar -xJ --strip-components=1 -C "$dir"
    fi
}

# ============================================================================
# Shared Configuration & Packages
# ============================================================================

YGGMESH_BUILD="23"
FIRMWARE_VERSION="${OPENWRT_VERSION}-ym${YGGMESH_BUILD}"

COMMON_PACKAGES=(
    yggdrasil
    luci
    luci-proto-yggdrasil
    tcpdump
    iperf3
    iwinfo
    curl
)

# ============================================================================
# Shared Functions
# ============================================================================

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

    # Validate that YGG_PORT is a valid port number
    if ! [[ "$YGG_PORT" =~ ^[0-9]+$ ]] || [ "$YGG_PORT" -lt 1 ] || [ "$YGG_PORT" -gt 65535 ]; then
        echo "Error: Invalid port in YGG_PORT: '$YGG_PORT'. Must be 1-65535." >&2
        exit 1
    fi

    # Validate that MESH_KEY is at least 8 characters (SAE requirement)
    if [ "${#MESH_KEY}" -lt 8 ]; then
        echo "Error: MESH_KEY must be at least 8 characters long (WPA3-SAE requirement)." >&2
        exit 1
    fi

    # Validate that YGGDRASIL_DNS contains only valid IPv6 addresses
    if [ -n "$YGGDRASIL_DNS" ]; then
        for ip in $YGGDRASIL_DNS; do
            if ! python3 -c "import ipaddress, sys; ipaddress.IPv6Address(sys.argv[1])" "$ip" 2>/dev/null; then
                echo "Error: Invalid IPv6 address in YGGDRASIL_DNS: '$ip'" >&2
                echo "This will crash dnsmasq and break the router's IPv4 DHCP server." >&2
                exit 1
            fi
        done
    fi
}

prepare_files_dir() {
    local profile="$1"
    local port_map="$2"
    
    local tmpfiles
    tmpfiles=$(mktemp -d)
    cp -a "${PROJECT_DIR}/files/"* "$tmpfiles/"
    mkdir -p "$tmpfiles/etc/yggmesh/inputs"
    echo "$FIRMWARE_VERSION" > "$tmpfiles/etc/yggmesh/version"
    echo "$profile" > "$tmpfiles/etc/yggmesh/profile"
    echo "$port_map" > "$tmpfiles/etc/yggmesh/port_map"

    # Bake build-time inputs into the firmware.
    echo "$YGGDRASIL_DNS" > "$tmpfiles/etc/yggmesh/inputs/yggdrasil_dns"
    echo "$DEFAULT_ROOT_PASSWORD" > "$tmpfiles/etc/yggmesh/inputs/root_password"
    echo "$YGGDRASIL_PEERS" > "$tmpfiles/etc/yggmesh/inputs/yggdrasil_peers"
    echo "$PRIVATE_SSID" > "$tmpfiles/etc/yggmesh/inputs/private_ssid"
    echo "$MESH_ID" > "$tmpfiles/etc/yggmesh/inputs/mesh_id"
    echo "$MESH_KEY" > "$tmpfiles/etc/yggmesh/inputs/mesh_key"
    echo "$YGG_PORT" > "$tmpfiles/etc/yggmesh/inputs/ygg_port"

    echo "$tmpfiles"
}

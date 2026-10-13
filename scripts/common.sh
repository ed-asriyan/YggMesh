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

YGGMESH_BUILD="25"
FIRMWARE_VERSION="${OPENWRT_VERSION}-ym${YGGMESH_BUILD}"

COMMON_PACKAGES=(
    yggdrasil
    luci
    luci-proto-yggdrasil
    tcpdump
    iperf3
    iwinfo
    curl
    ca-bundle
    tayga
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
    : "${YGG_PORT:?YGG_PORT must not be empty}"
    : "${YGGDRASIL_DNS?YGGDRASIL_DNS must be set (can be empty)}"
    : "${YGGPEERS_INSTANCES?YGGPEERS_INSTANCES must be set (can be empty)}"
    : "${YGGPEERS_COUNT:?YGGPEERS_COUNT must not be empty}"
    : "${YGGPEERS_CHECK_INTERVAL:?YGGPEERS_CHECK_INTERVAL must not be empty}"
    : "${CLEARNET_EXITS?CLEARNET_EXITS must be set (can be empty)}"

    # Validate that YGG_PORT is a valid port number
    if ! [[ "$YGG_PORT" =~ ^[0-9]+$ ]] || [ "$YGG_PORT" -lt 1 ] || [ "$YGG_PORT" -gt 65535 ]; then
        echo "Error: Invalid port in YGG_PORT: '$YGG_PORT'. Must be 1-65535." >&2
        exit 1
    fi

    # Validate that YGGPEERS_COUNT is an integer from 1 to 10
    if ! [[ "$YGGPEERS_COUNT" =~ ^[0-9]+$ ]] || [ "$YGGPEERS_COUNT" -lt 1 ] || [ "$YGGPEERS_COUNT" -gt 10 ]; then
        echo "Error: Invalid YGGPEERS_COUNT: '$YGGPEERS_COUNT'. Must be 1-10." >&2
        exit 1
    fi

    # Validate YGGPEERS_CHECK_INTERVAL (minutes): 1-59, or a multiple of 60 up to 1380
    if ! [[ "$YGGPEERS_CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$YGGPEERS_CHECK_INTERVAL" -lt 1 ] \
        || [ "$YGGPEERS_CHECK_INTERVAL" -gt 1380 ] \
        || { [ "$YGGPEERS_CHECK_INTERVAL" -ge 60 ] && [ $((YGGPEERS_CHECK_INTERVAL % 60)) -ne 0 ]; }; then
        echo "Error: Invalid YGGPEERS_CHECK_INTERVAL: '$YGGPEERS_CHECK_INTERVAL'. Must be 1-59 or a multiple of 60 up to 1380 (minutes)." >&2
        exit 1
    fi

    # Validate YGGPEERS_INSTANCES (base URLs) and strip trailing slashes
    if [ -n "$YGGPEERS_INSTANCES" ]; then
        local url_re='^https?://[^ /]+(/.*)?$'
        local instance normalized=""
        for instance in $YGGPEERS_INSTANCES; do
            if ! [[ "$instance" =~ $url_re ]]; then
                echo "Error: Invalid URL in YGGPEERS_INSTANCES: '$instance'. Expected http(s)://host[/path]." >&2
                exit 1
            fi
            while [ "${instance%/}" != "$instance" ]; do
                instance="${instance%/}"
            done
            normalized="${normalized:+$normalized }$instance"
        done
        YGGPEERS_INSTANCES="$normalized"
    fi

    # Validate CLEARNET_EXITS: Yggdrasil node addresses (200::/8), not subnets
    # (300::/8) and not clearnet IPs. Normalized to the compressed form.
    if [ -n "$CLEARNET_EXITS" ]; then
        local exit_addr exit_norm normalized_exits=""
        for exit_addr in $CLEARNET_EXITS; do
            if ! exit_norm=$(python3 -c "
import ipaddress, sys
a = ipaddress.IPv6Address(sys.argv[1])
if a not in ipaddress.IPv6Network('200::/8'):
    sys.exit(1)
print(a.compressed)" "$exit_addr" 2>/dev/null); then
                echo "Error: Invalid address in CLEARNET_EXITS: '$exit_addr'. Expected a Yggdrasil node address in 200::/8." >&2
                exit 1
            fi
            normalized_exits="${normalized_exits:+$normalized_exits }$exit_norm"
        done
        CLEARNET_EXITS="$normalized_exits"
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
    echo "$PRIVATE_SSID" > "$tmpfiles/etc/yggmesh/inputs/private_ssid"
    echo "$MESH_ID" > "$tmpfiles/etc/yggmesh/inputs/mesh_id"
    echo "$YGG_PORT" > "$tmpfiles/etc/yggmesh/inputs/ygg_port"
    echo "$YGGPEERS_INSTANCES" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_instances"
    echo "$YGGPEERS_COUNT" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_count"
    echo "$YGGPEERS_CHECK_INTERVAL" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_check_interval"
    echo "$CLEARNET_EXITS" > "$tmpfiles/etc/yggmesh/inputs/clearnet_exits"

    # Build timestamp: the device uses it as a clock sanity check before HTTPS requests.
    date +%s > "$tmpfiles/etc/yggmesh/build_epoch"

    echo "$tmpfiles"
}

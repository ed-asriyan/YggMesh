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

YGGMESH_BUILD="27"
FIRMWARE_VERSION="${OPENWRT_VERSION}-ym${YGGMESH_BUILD}"

COMMON_PACKAGES=(
    # LuCI without the package manager page (apk still works from the shell)
    luci-light
    iwinfo
    # The TUN device of Yggdrasil-ng, which is not a package: see
    # add_yggdrasil. (uclient-fetch, libustream-mbedtls and ca-bundle are
    # defaults.)
    kmod-tun
)

# Yggdrasil-ng (https://github.com/Revertron/Yggdrasil-ng): the static binary
# of its release, one per OpenWrt package architecture family. To update it,
# change the version and the checksums of all four binaries.
YGGDRASIL_NG_VERSION="0.3.1"
declare -A YGGDRASIL_NG_SHA256=(
    [amd64]=d44847469b85ad3ede77041b0f73d1be428ba20d88c8b88d4999d594d788316b
    [arm64]=f62cd8fae45f19c735ce0a50789625239973327250716ee0dbb0f3ed95e25924
    [mips]=fb8731a1a16b75cc27d0a896d42ccdc55282a79f303fc638f44c830344456194
    [mipsel]=44fd2ca14d503b2aca5fd06e55da74420a5736ee55ea4a76599be0680f799464
)

# ============================================================================
# Shared Functions
# ============================================================================

# Prints error $* and exits. On GitHub Actions it is also an annotation of the
# run (newlines encoded), readable without the log.
fail() {
    echo "Error: $*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        local m="$*"
        m=${m//'%'/'%25'}
        m=${m//$'\n'/'%0A'}
        echo "::error::$m"
    fi
    exit 1
}

# Any other failed command of a build script becomes an annotation as well
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    set -E
    trap 'echo "::error::${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND} (exit $?)"' ERR
fi

# Runs $@; on failure fails with its output
run() {
    local out
    out=$("$@" 2>&1) || fail "$* failed:"$'\n'"$(printf '%s\n' "$out" | tail -n 30)"
    [ -z "$out" ] || printf '%s\n' "$out"
}

# Installs the Yggdrasil-ng binary for the Image Builder of target $1 as
# /usr/bin/yggdrasil into the FILES directory $2. The binary is downloaded
# once into BUILD_ROOT and checked against YGGDRASIL_NG_SHA256. The release
# binaries are static (musl) and soft-float on MIPS, so one fits every
# device of a package architecture family.
add_yggdrasil() {
    local ib arch bin file url sum
    ib="$(get_builder_dir "$1")"
    arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$ib/.config")
    case "$arch" in
        x86_64) bin=amd64 ;;
        aarch64_*) bin=arm64 ;;
        mips_*) bin=mips ;;
        mipsel_*) bin=mipsel ;;
        *) fail "no Yggdrasil-ng binary for the package architecture '$arch' of $1" ;;
    esac
    file="${BUILD_ROOT}/yggdrasil-ng-${YGGDRASIL_NG_VERSION}-${bin}"
    url="https://github.com/Revertron/Yggdrasil-ng/releases/download/v${YGGDRASIL_NG_VERSION}/yggdrasil-${bin}"
    if [ ! -f "$file" ]; then
        echo "Downloading Yggdrasil-ng ${YGGDRASIL_NG_VERSION} (${bin})..."
        run wget -q -O "${file}.part" "$url"
        mv "${file}.part" "$file"
    fi
    sum=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$sum" != "${YGGDRASIL_NG_SHA256[$bin]}" ]; then
        rm -f "$file"
        fail "$url has the checksum $sum, expected ${YGGDRASIL_NG_SHA256[$bin]}"
    fi
    install -D -m 0755 "$file" "$2/usr/bin/yggdrasil"
    echo "Yggdrasil-ng ${YGGDRASIL_NG_VERSION} (${bin}) added"
}

validate_inputs() {
    # Fail early before downloading anything if required inputs are missing.
    # :? fails if unset or empty; ? fails only if unset (empty string is allowed).
    : "${DEFAULT_ROOT_PASSWORD:?DEFAULT_ROOT_PASSWORD must not be empty}"
    : "${PRIVATE_SSID:?PRIVATE_SSID must not be empty}"
    : "${YGGDRASIL_DNS?YGGDRASIL_DNS must be set (can be empty)}"
    : "${YGGPEERS_INSTANCES?YGGPEERS_INSTANCES must be set (can be empty)}"
    : "${YGGPEERS_COUNT:?YGGPEERS_COUNT must not be empty}"
    : "${YGGPEERS_CHECK_INTERVAL:?YGGPEERS_CHECK_INTERVAL must not be empty}"
    : "${YGGPEERS_RERANK_INTERVAL:?YGGPEERS_RERANK_INTERVAL must not be empty}"
    : "${CLEARNET_EXITS?CLEARNET_EXITS must be set (can be empty)}"

    # CLEARNET_MODE: what clients' IPv4 uses
    : "${CLEARNET_MODE:?CLEARNET_MODE must not be empty}"
    case "$CLEARNET_MODE" in
        off|wan|wan_exit|exit) ;;
        *)
            echo "Error: Invalid CLEARNET_MODE: '$CLEARNET_MODE'. Must be off, wan, wan_exit or exit." >&2
            exit 1
            ;;
    esac

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

    # Validate that YGGPEERS_RERANK_INTERVAL (days) is an integer from 1 to 90
    if ! [[ "$YGGPEERS_RERANK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$YGGPEERS_RERANK_INTERVAL" -lt 1 ] || [ "$YGGPEERS_RERANK_INTERVAL" -gt 90 ]; then
        echo "Error: Invalid YGGPEERS_RERANK_INTERVAL: '$YGGPEERS_RERANK_INTERVAL'. Must be 1-90 (days)." >&2
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

    # Validate CLEARNET_EXITS: public keys of the exits (64 hex digits),
    # normalized to lower case
    if [ -n "$CLEARNET_EXITS" ]; then
        local exit_key normalized_exits=""
        for exit_key in $CLEARNET_EXITS; do
            if ! [[ "$exit_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
                echo "Error: Invalid exit in CLEARNET_EXITS: '$exit_key'. Expected the public key of an exit (64 hex digits)." >&2
                exit 1
            fi
            normalized_exits="${normalized_exits:+$normalized_exits }${exit_key,,}"
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

    # Bake build-time inputs into the firmware: the defaults of the user
    # settings on a fresh install (see files/usr/sbin/yggmesh-defaults).
    echo "$YGGDRASIL_DNS" > "$tmpfiles/etc/yggmesh/inputs/yggdrasil_dns"
    echo "$DEFAULT_ROOT_PASSWORD" > "$tmpfiles/etc/yggmesh/inputs/root_password"
    echo "$PRIVATE_SSID" > "$tmpfiles/etc/yggmesh/inputs/private_ssid"
    echo "$YGGPEERS_INSTANCES" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_instances"
    echo "$YGGPEERS_COUNT" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_count"
    echo "$YGGPEERS_CHECK_INTERVAL" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_check_interval"
    echo "$YGGPEERS_RERANK_INTERVAL" > "$tmpfiles/etc/yggmesh/inputs/yggpeers_rerank_interval"
    echo "$CLEARNET_EXITS" > "$tmpfiles/etc/yggmesh/inputs/clearnet_exits"
    echo "$CLEARNET_MODE" > "$tmpfiles/etc/yggmesh/inputs/clearnet_mode"

    # Build timestamp: the device uses it as a clock sanity check before HTTPS requests.
    date +%s > "$tmpfiles/etc/yggmesh/build_epoch"

    echo "$tmpfiles"
}

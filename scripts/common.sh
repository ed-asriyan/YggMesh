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

YGGMESH_BUILD="26"
FIRMWARE_VERSION="${OPENWRT_VERSION}-ym${YGGMESH_BUILD}"

COMMON_PACKAGES=(
    yggdrasil
    # LuCI without the package manager page (apk still works from the shell)
    luci-light
    luci-proto-yggdrasil
    iwinfo
    # The in-kernel CLAT, see yggmesh-clearnet. yggmesh-jool-siit: jool_siit
    # alone, see make_jool_siit_package. ip-tiny: busybox ip has no netns and
    # no veth. (uclient-fetch, libustream-mbedtls and ca-bundle are defaults.)
    yggmesh-jool-siit
    kmod-veth
    ip-tiny
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

# Puts yggmesh-jool-siit into the Image Builder's local packages/ directory:
# jool_siit and the GRO hotplug script of jool-tools-netfilter, depending on
# libnl-genl only. jool-tools-netfilter also brings jool and joold and, through
# the libnl meta package, libnl-route, libnl-nf and libnl-cli: ~700 KiB
# unpacked that the CLAT does not use, too much for 16 MB NOR devices.
make_jool_siit_package() {
    local ib arch work pkg ver lib
    ib="$(get_builder_dir "$1")"
    arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$ib/.config")
    [ -n "$arch" ] || fail "no CONFIG_TARGET_ARCH_PACKAGES in $ib/.config"
    work=$(mktemp -d)
    mkdir -p "$work/root/etc/apk" "$work/cache" "$work/pkg" "$work/x" "$work/files/usr/bin" "$ib/packages"

    ib_apk() {
        run env STAGING_DIR_HOST="$ib/staging_dir/host" \
            "$ib/staging_dir/host/bin/fakeroot" "$ib/staging_dir/host/bin/apk" \
            --root "$work/root" --keys-dir "$ib/keys" --no-logfile \
            --repositories-file "$ib/repositories" --cache-dir "$work/cache" "$@"
    }
    ib_apk add --arch "$arch" --initdb
    ib_apk fetch --arch "$arch" --output "$work/pkg" jool-tools-netfilter
    pkg=$(ls "$work"/pkg/jool-tools-netfilter-*.apk 2>/dev/null) \
        || fail "apk fetch left no jool-tools-netfilter package in $work/pkg"
    ver=${pkg##*/jool-tools-netfilter-}
    ver=${ver%.apk}
    # Packages are not signed one by one, the index is: fetch has checked the
    # file against the signed index already
    ib_apk --allow-untrusted extract --no-chown --destination "$work/x" "$pkg"
    [ -x "$work/x/usr/bin/jool_siit" ] || fail "no usr/bin/jool_siit in $pkg: $(cd "$work/x" && find . | head -20 | tr '\n' ' ')"

    cp -p "$work/x/usr/bin/jool_siit" "$work/files/usr/bin/"
    if [ -d "$work/x/etc/hotplug.d" ]; then
        mkdir -p "$work/files/etc"
        cp -rp "$work/x/etc/hotplug.d" "$work/files/etc/"
    fi
    # jool_siit must need nothing of libnl beyond libnl-genl (and libnl-core)
    for lib in $(grep -a -o 'libnl-[a-z-]*3\.so' "$work/files/usr/bin/jool_siit" | sort -u); do
        case "$lib" in
            libnl-3.so|libnl-genl-3.so) ;;
            *) fail "jool_siit $ver needs $lib, yggmesh-jool-siit must depend on it" ;;
        esac
    done

    rm -f "$ib"/packages/yggmesh-jool-siit-*.apk
    # OpenWrt's fakeroot finds its library through STAGING_DIR_HOST
    run env STAGING_DIR_HOST="$ib/staging_dir/host" \
        "$ib/staging_dir/host/bin/fakeroot" "$ib/staging_dir/host/bin/apk" mkpkg \
        --info "name:yggmesh-jool-siit" \
        --info "version:$ver" \
        --info "arch:$arch" \
        --info "description:jool_siit of jool-tools-netfilter $ver, without jool, joold and the full libnl" \
        --info "license:GPL-2.0-only" \
        --info "url:https://nicmx.github.io/Jool/" \
        --info "depends:libnl-genl kmod-jool-netfilter ethtool" \
        --files "$work/files" \
        --output "$ib/packages/yggmesh-jool-siit-$ver.apk"
    rm -rf "$work"
    echo "Repackaged jool_siit $ver as yggmesh-jool-siit"
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

    # Validate CLEARNET_EXITS: Yggdrasil node addresses (200::/8, not subnets
    # in 300::/8 and not clearnet IPs) or domain names, resolved by the node.
    # Addresses are normalized to the compressed form, names to lower case.
    if [ -n "$CLEARNET_EXITS" ]; then
        local exit_addr exit_norm normalized_exits=""
        for exit_addr in $CLEARNET_EXITS; do
            if ! exit_norm=$(python3 -c "
import ipaddress, re, sys
v = sys.argv[1]
if ':' in v:
    a = ipaddress.IPv6Address(v)
    if a not in ipaddress.IPv6Network('200::/8'):
        sys.exit(1)
    print(a.compressed)
elif re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}', v.lower()):
    print(v.lower())
else:
    sys.exit(1)" "$exit_addr" 2>/dev/null); then
                echo "Error: Invalid exit in CLEARNET_EXITS: '$exit_addr'. Expected a Yggdrasil node address in 200::/8 or a domain name." >&2
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

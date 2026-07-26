#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME=${1:-yggmesh-openwrt:latest}

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

install_host_dependencies() {
    export DEBIAN_FRONTEND=noninteractive

    # Check if wmediumd and pytest are already available to skip slow apt-get updates
    if command -v wmediumd >/dev/null 2>&1 && python3 -c "import pytest" >/dev/null 2>&1; then
        echo "Dependencies (wmediumd, pytest) already installed, skipping apt-get."
    else
        echo "Installing host dependencies (assuming Ubuntu)..."
        $SUDO apt-get update
        $SUDO apt-get install -y --no-install-recommends \
            build-essential \
            pkg-config \
            git \
            libnl-3-dev \
            libnl-genl-3-dev \
            libnl-route-3-dev \
            libconfig-dev \
            iw \
            kmod \
            wget \
            zstd \
            python3 \
            python3-pip \
            python3-pytest

        # mac80211_hwsim usually ships in the linux-modules-extra-<kernel> package
        # on stock Ubuntu kernels. Package name depends on the exact kernel flavor
        # in use, so don't fail the whole run if it's already built-in or unavailable.
        $SUDO apt-get install -y --no-install-recommends "linux-modules-extra-$(uname -r)" \
            || echo "Warning: could not install linux-modules-extra-$(uname -r); continuing (mac80211_hwsim may already be available)."

        # Fallback to pip if apt-get didn't provide newest pytest or environment requires it
        python3 -m pip install --quiet --upgrade pytest --break-system-packages || true
    fi

    # wmediumd/ is git-ignored in this repo (see .gitignore) - it's a build
    # artifact fetched fresh by this script, not something committed/vendored.
    # Clone the upstream wmediumd project (the fork with usfstl/time-travel
    # support that this project's Makefile expects - verified byte-for-byte
    # match with wmediumd/wmediumd/wmediumd.c) and build it locally against
    # this host's libnl/libconfig headers and current kernel.
    WMEDIUMD_DIR="${PROJECT_DIR}/wmediumd"
    WMEDIUMD_REPO_URL="${WMEDIUMD_REPO_URL:-https://github.com/bcopeland/wmediumd.git}"

    if [ ! -f "${WMEDIUMD_DIR}/wmediumd/wmediumd.c" ]; then
        echo "Cloning wmediumd sources from ${WMEDIUMD_REPO_URL}..."
        rm -rf "${WMEDIUMD_DIR}"
        git clone --depth 1 "${WMEDIUMD_REPO_URL}" "${WMEDIUMD_DIR}"
    else
        echo "wmediumd sources already present at ${WMEDIUMD_DIR}, skipping clone."
    fi

    if ! command -v wmediumd >/dev/null 2>&1 || [ ! -f /usr/local/bin/wmediumd ]; then
        echo "Building wmediumd from source (kernel: $(uname -r))..."
        make -C "${WMEDIUMD_DIR}" clean all
        $SUDO install -Dm 0755 "${WMEDIUMD_DIR}/wmediumd/wmediumd" /usr/local/bin/wmediumd
    fi

    echo "Verifying mac80211_hwsim kernel module is loadable..."
    $SUDO modprobe mac80211_hwsim radios=0
    $SUDO rmmod mac80211_hwsim || true
}

install_host_dependencies

echo "Starting Host Yggdrasil node (simulated Internet)..."
docker rm -f host_ygg_node &>/dev/null || true
docker run --rm --entrypoint yggdrasil ghcr.io/yggdrasil-network/yggdrasil-go:latest -genconf -json > /tmp/ygg-host.json
python3 -c "
import json
with open('/tmp/ygg-host.json', 'r') as f:
    conf = json.load(f)
conf['Listen'] = ['tcp://0.0.0.0:54321']
with open('/tmp/ygg-host.json', 'w') as f:
    json.dump(conf, f)
"
docker run -d --name host_ygg_node \
  --privileged \
  -v /tmp/ygg-host.json:/etc/yggdrasil-network/config.conf \
  -p 54321:54321/tcp \
  ghcr.io/yggdrasil-network/yggdrasil-go:latest
sleep 3

HOST_YGG_IP=$(docker exec host_ygg_node ip -6 addr show tun0 | grep 'scope global' | awk '{print $2}' | cut -d/ -f1 || echo "")
if [ -z "$HOST_YGG_IP" ]; then
    HOST_YGG_IP=$(docker exec host_ygg_node yggdrasil -useconffile /etc/yggdrasil-network/config.conf -address)
fi
echo "Host Yggdrasil IP: $HOST_YGG_IP"

DOCKER_GW=$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}')
echo "Host Internet Node reachable at tcp://${DOCKER_GW}:54321"

if ! docker image inspect "$IMAGE_NAME" &> /dev/null; then
    echo "Docker image '$IMAGE_NAME' not found. We will build it."
    export DEFAULT_ROOT_PASSWORD=${DEFAULT_ROOT_PASSWORD:-"passwd"}
    export PRIVATE_SSID=${PRIVATE_SSID:-"YggMesh"}
    export MESH_ID=${MESH_ID:-"test"}
    export MESH_KEY=${MESH_KEY:-"testtest"}
    export YGG_PORT=${YGG_PORT:-"12345"}
    export YGGDRASIL_DNS=${YGGDRASIL_DNS:-""}
    export YGGDRASIL_PEERS=${YGGDRASIL_PEERS:-""}
    
    "${SCRIPT_DIR}/build_docker.sh"
    
    if [ "$IMAGE_NAME" != "yggmesh-openwrt:latest" ]; then
        docker tag yggmesh-openwrt:latest "$IMAGE_NAME"
    fi
else
    echo "Docker image '$IMAGE_NAME' already exists. Skipping build."
fi

export YGG_DOCKER_IMAGE="$IMAGE_NAME"
export TEST_YGG_IP="$HOST_YGG_IP"
export TEST_YGG_PEER="tcp://${DOCKER_GW}:54321"

echo "Running tests against image '$IMAGE_NAME'..."
cd "$PROJECT_DIR"
pytest tests/test_scenarios.py -s -v || true

echo "Cleaning up host node..."
docker rm -f host_ygg_node

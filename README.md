# YggMesh
Custom OpenWrt firmware for self-organizing, **offline-first** mesh networks using **batman-adv** (L2) and **Yggdrasil** (IPv6 overlay). Designed for emergency and off-grid communication — no internet connection, cloud services, or pre-configuration required.

## Architecture

```
[Node A] ──── 802.11s (SAE) ──── [Node B] ──── 802.11s (SAE) ──── [Node C]
    │              batman-adv BATMAN_V (bat0)                           │
    └──────────── br-private (bat0 + LAN ports) ──────────────────────┘
                         │
              Yggdrasil multicast (br-private)
              IPv6 overlay — local peer discovery only
```

All nodes are identical. Every node provides:

- **Private WiFi** (`YggMesh`) — WPA3/SAE, 802.11r/k/v seamless roaming
- **Mesh backhaul** (802.11s on 2.4 GHz and 5 GHz where available) — SAE-encrypted, batman-adv BATMAN_V routing
- **Yggdrasil overlay** — end-to-end encrypted IPv6 management plane, peer discovery via local multicast on `br-private` (no TLS peers, no internet required)
- **Yggdrasil 300::/64 SLAAC** — clients on the private network receive a globally-routable Yggdrasil IPv6 address automatically

## Supported devices
| Device | Target | Notes |
|--------|--------|-------|
| GL.iNet GL-AXT1800 (Slate AX) | qualcommax/ipq60xx | WiFi 6, 512 MB RAM |
| GL.iNet GL-MT3000 (Beryl AX) | mediatek/filogic | WiFi 6, compact |
| GL.iNet GL-MT6000 (Flint 2) | mediatek/filogic | WiFi 6, 1 GB RAM |
| Asus RT-AX53U | ramips/mt7621 | WiFi 6, DSA switch |
| GL.iNet GL-AR300M16 (16 MB) | ath79/generic | 2.4 GHz only |
| TP-Link CPE710 v1 | ath79/generic | 5 GHz outdoor, 23 dBi directional |
| Cudy AP3000 Outdoor V1 | mediatek/filogic | WiFi 6, outdoor |

## Default credentials

> [!WARNING]
> **Change the default password immediately after first boot.**
> All nodes ship with the same default root password. Anyone on the network can log in via LuCI or SSH until you change it.

| | Value |
|---|---|
| Username | `root` |
| Password | `yggmesh` |

Change it: LuCI → System → Administration, or run `passwd` over SSH.

## Building

### Prerequisites

- Linux x86_64
- `wget`, `zstd`, `make`, `python3`

### Build firmware

```bash
./scripts/build.sh <device>
```

The script automatically downloads the OpenWrt Image Builder on first run (~1.5 GB per target).

**Examples:**

```bash
./scripts/build.sh axt1800        # GL-AXT1800
./scripts/build.sh cpe710         # CPE710 (5 GHz outdoor)
./scripts/build.sh ap3000outdoor  # Cudy AP3000 Outdoor

# Pin OpenWrt version
OPENWRT_VERSION=25.12.0 ./scripts/build.sh mt3000

# Extra packages
PACKAGES_EXTRA="nano htop" ./scripts/build.sh mt6000
```

Output firmware lands in `output/`.

### Flash

Standard OpenWrt sysupgrade:

```bash
sysupgrade -v /tmp/openwrt-*-sysupgrade.bin
```

Or via LuCI: System → Backup/Flash Firmware.

## How it works

### Zero-touch first boot

`files/etc/uci-defaults/99-yggmesh` runs once on first boot:

1. **Identity** — derives a unique hostname and private subnet from the hardware MAC (`YggMesh-XXXX`, `10.P1.P2.0/24`)
2. **Keys** — generates WPA3 private/mesh passwords and root password; saved to `/etc/yggmesh/keys`
3. **Network** — configures `bat0` (BATMAN_V), `br-private` bridge (bat0 + LAN ports), static private IP, WAN DHCP
4. **WiFi** — 802.11s mesh interfaces (SAE) + private AP (WPA3/SAE, 802.11r/k/v) on all available radios
5. **Firewall** — `lan` (ACCEPT), `wan` (REJECT + masquerade), `yggdrasil` (SSH/HTTP/ICMPv6 in, lan↔yggdrasil forwarding)
6. **DHCP** — private pool `10.P1.P2.100–249`, 12 h leases
7. **Yggdrasil** — generates node keys; sets `MulticastInterfaces` to `br-private` for offline local-only peer discovery; assigns `300::/64` to `br-private` for client SLAAC

Node identity (MAC-derived subnets, keys, Yggdrasil keys) is preserved across firmware upgrades via `sysupgrade.conf`.

### Mesh networking

batman-adv operates at Layer 2 over 802.11s interfaces on `bat0`. All nodes bridge `bat0` with their physical LAN ports into `br-private`, forming a single flat L2 network regardless of how nodes are connected. There is no internet gateway — `gw_mode` is set to `client` on all nodes.

### Yggdrasil overlay

Yggdrasil runs on every node and discovers peers via IPv6 multicast on `br-private`. No TLS peers or external infrastructure are needed. Each node gets a unique Yggdrasil address (`200::/7`) and advertises a `300::/64` subnet so connected clients receive globally-routable Yggdrasil IPv6 addresses via SLAAC.

## License

[MIT](LICENSE)

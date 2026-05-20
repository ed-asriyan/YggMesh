# YggMesh
Yggdrasil over WiFi Mesh

## The Idea
This project builds a mesh network for cases where normal network infrastructure is unavailable or unreliable.

- Routers connect to each other over [802.11s WiFi mesh](https://en.wikipedia.org/wiki/IEEE_802.11s).
- batman-adv runs on top of that WiFi mesh and provides Layer 2 routing across all nodes.
- Yggdrasil runs on top of batman-adv and provides end-to-end encrypted IPv6 mesh routing.
- Every node runs a WPA3 WiFi hotspot. Phones and laptops that connect to it are placed directly into the Yggdrasil network — they receive a globally-routable `200::/7` IPv6 address via SLAAC automatically.
- No internet connection, cloud service, or pre-configuration is required. Flash the firmware and the node is ready.
- Clearnet access is **not** provided by this project.

![Diagram](./diagram.drawio.svg)

Technically, it combines three layers:
- **[802.11s WiFi mesh](https://en.wikipedia.org/wiki/IEEE_802.11s)** — routers form a wireless backhaul using the 802.11s protocol with SAE encryption. batman-adv (BATMAN_V) routes L2 traffic across the mesh over a virtual `bat0` interface.
- **[Yggdrasil](https://yggdrasil-network.github.io)** — an end-to-end encrypted overlay network that runs on top of `bat0`. Every node gets a permanent `200::/7` IPv6 address derived from its public key. Nodes discover each other via multicast — no static configuration, no central registry, no internet required.
- **WiFi hotspot** — each node creates a private WPA3 access point (`YggMesh`) with 802.11r/k/v seamless roaming. Connected clients receive a `200::/7` Yggdrasil IPv6 address via SLAAC.

## How to Deploy
**Requirements:** A supported OpenWrt router (see table below).

**Supported devices:**
| Device | Target | Notes |
|--------|--------|-------|
| GL.iNet GL-AXT1800 (Slate AX) | qualcommax/ipq60xx | WiFi 6, 512 MB RAM |
| GL.iNet GL-MT3000 (Beryl AX) | mediatek/filogic | WiFi 6, compact |
| GL.iNet GL-MT6000 (Flint 2) | mediatek/filogic | WiFi 6, 1 GB RAM |
| Asus RT-AX53U | ramips/mt7621 | WiFi 6, DSA switch |
| GL.iNet GL-AR300M16 (16 MB) | ath79/generic | 2.4 GHz only |
| TP-Link CPE710 v1 | ath79/generic | 5 GHz outdoor, 23 dBi directional |
| Cudy AP3000 Outdoor V1 | mediatek/filogic | WiFi 6, outdoor |

> [!WARNING]
> This project is on extremely early stage. Something may break even if it's supposed ot work. Do it on your own risk. 

**What each node does after first boot:**
- Brings up 802.11s mesh interfaces on all available radios and joins the shared mesh with SAE encryption.
- Runs batman-adv (BATMAN_V) over those mesh interfaces, forming a single flat L2 network across all nodes.
- Runs Yggdrasil on top of `bat0`, discovering peers via multicast. No static peers or internet connection needed.
- Advertises a `300::/64` Yggdrasil subnet on `br-private` so clients receive a `200::/7` IPv6 address via SLAAC.
- Creates a private WPA3 WiFi hotspot (`YggMesh`) with seamless roaming across all nodes.

**Steps:**
1. Download the firmware for your device from the [Releases](https://github.com/ed-asriyan/YggMesh/releases) page, or [build it yourself](#building).
2. Flash it to your router via LuCI (System → Backup/Flash Firmware) or `sysupgrade`:
   ```
   sysupgrade -v /tmp/openwrt-*-sysupgrade.bin
   ```
3. Wait for the router to reboot. First boot takes about 30 seconds longer than usual while the node configures itself.
4. Repeat for every router you want in the mesh. No per-node configuration is needed — all nodes are identical.

> [!WARNING]
> **Change the default root password after first boot.**
> All nodes ship with the password `yggmesh`. Change it via LuCI → System → Administration or by running `passwd` over SSH.

### Building
To build firmware yourself you need Linux x86_64 with `wget`, `zstd`, `make`, and `python3`.

```bash
./scripts/build.sh <device>
```

The script downloads the OpenWrt Image Builder on first run (~1.5 GB per target). Output lands in `output/`.

```bash
./scripts/build.sh axt1800        # GL-AXT1800
./scripts/build.sh cpe710         # CPE710 (5 GHz outdoor)
./scripts/build.sh ap3000outdoor  # Cudy AP3000 Outdoor
```

## How It All Works
```
Phone / Laptop  (no special apps needed)
      │
      │  WiFi  (WPA3 — SSID: YggMesh)
      │  IPv6 SLAAC  200::/7  via  300::/64 route on br-private
      ▼
┌─────────────────────────────┐
│        YggMesh Node         │
│  wlan0  hostapd (YggMesh)   │
│  ygg0   Yggdrasil           │
│  bat0   batman-adv          │
│  wlan1  802.11s mesh (SAE)  │
└──────┬──────────────────────┘
       │  batman-adv L2 over 802.11s
       ▼
┌─────────────────────────────┐
│        YggMesh Node         │
│  wlan0  hostapd (YggMesh)   │
│  ygg0   Yggdrasil           │
│  bat0   batman-adv          │
│  wlan1  802.11s mesh (SAE)  │
└──────┬──────────────────────┘
       │  batman-adv L2 over 802.11s
       ▼
┌─────────────────────────────┐
│        YggMesh Node         │
│  wlan0  hostapd (YggMesh)   │
│  ygg0   Yggdrasil           │
│  bat0   batman-adv          │
│  wlan1  802.11s mesh (SAE)  │
└─────────────────────────────┘
```

## Verification
To verify the mesh is working correctly, set up a 3-node linear test (A → B → C).

### 1. Prepare three nodes
1. Flash the firmware to three devices.
2. Ensure none of them are plugged into your normal home network or internet router. They should only have power.

### 2. Arrange them in a line
1. Place **Node A** at one end of your house.
2. Place **Node B** somewhere in the middle.
3. Place **Node C** at the other end.
4. Power them all on and wait about 3 minutes for first-boot configuration and mesh forming.

*Note: Ensure the distance is large enough that a phone near Node A cannot see the Wi-Fi from Node C.*

### 3. Connect your phone
1. Turn off mobile data on your phone.
2. Stand physically near **Node A**.
3. Connect to the `YggMesh` WiFi hotspot using the default password.

### 4. Test the connection
1. Open a browser on your phone.
2. Try to load a public Yggdrasil website. You can find public websites  at https://yggdrasil-network.github.io/services.html.

If the site loads, your mesh is successfully formed and routing Yggdrasil traffic end-to-end across multiple hops.

## License

[MIT](LICENSE)

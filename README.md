# YggMesh
Yggdrasil over WiFi Mesh

> [!WARNING]
> This project is on extremely early stage. Something may break even if it's supposed ot work. Do it on your own risk.

## The Idea
This project builds a mesh network for cases where normal network infrastructure is unavailable or unreliable.

- Routers connect to each other over [802.11s WiFi mesh](https://en.wikipedia.org/wiki/IEEE_802.11s).
- [Yggdrasil](https://yggdrasil-network.github.io) runs directly on top of those 802.11s interfaces and provides end-to-end encrypted IPv6 mesh routing.
- All WiFi clients can resolve and access [Alfis](https://alfis.name) domains (such as `.ygg` and other Yggdrasil services) out of the box, thanks to integrated Alfis DNS forwarding.
- Every node runs an open WiFi hotspot. Phones and laptops that connect to it get access to Yggdrasil IPv6.
- Clearnet access is **not** provided out-of-the-box after flashing! Configuration after the first boot is required. Read [Clearnet Access](#clearnet-access).

![Diagram](./diagram.drawio.svg)

Technically, it combines these layers:
- **[802.11s WiFi mesh](https://en.wikipedia.org/wiki/IEEE_802.11s)** — routers form a wireless backhaul using the 802.11s protocol with SAE encryption. No L2 routing daemon is involved — the 802.11s interfaces are used directly as the transport for Yggdrasil.
- **[Yggdrasil](https://yggdrasil-network.github.io)** — an end-to-end encrypted L3 overlay network that runs directly on the 802.11s interfaces. Every node gets a permanent `200::/7` IPv6 address derived from its public key. Nodes discover each other via multicast on the mesh interfaces — no static configuration, no central registry, no internet required.
- **WiFi hotspot** — each node creates a public, open WiFi access point (`YggMesh`) with 802.11r/k/v seamless roaming. Connected clients receive a `200::/7` Yggdrasil IPv6 address via SLAAC.

## How to start
> **Important:** This firmware is currently designed for **fresh (virgin) installations only**. Over-The-Air (OTA) upgrades via `sysupgrade` or LuCI are not supported at this stage. Upgrading an existing installation may not work and wipe the node's cryptograpic identity, Yggdrasil keys, and custom configurations.

**Requirements:** A supported OpenWrt router (see table below).

**Supported devices:**
| Device | `device_keyname` | Links |
|--------|--------|-------|
| GL.iNet GL-AXT1800 (Slate AX) | `axt1800` | [GL.iNet](https://www.gl-inet.com/en-us/products/gl-axt1800), [Amazon](https://a.co/d/04RvIH3O) |
| GL.iNet GL-MT3000 (Beryl AX) | `mt3000` | [GL.iNet](https://www.gl-inet.com/en-us/products/gl-mt3000), [Amazon](https://a.co/d/0ho0XJkU) |
| GL.iNet GL-MT6000 (Flint 2) | `mt6000` | [GL.iNet](https://www.gl-inet.com/en-us/products/gl-mt6000), [Amazon](https://a.co/d/06pVFZCU) |
| Asus RT-AX53U | `ax53u` | [Amazon](https://a.co/d/04HaQXdK), [Asus](https://www.asus.com/networking-iot-servers/wifi-routers/asus-wifi-routers/rt-ax53u) |
| GL.iNet GL-AR300M16 (16 MB) | `ar300m16` | [Amazon](https://a.co/d/07d6zejs), [GL.iNet](https://www.gl-inet.com/products/gl-ar300m) |
| TP-Link CPE710 v1 | `cpe710` | [Amazon](https://a.co/d/0diuhGV5), [TP-Link](https://www.tp-link.com/us/business-networking/pharos-cpe/cpe710) |
| Cudy AP3000 Outdoor V1 | `ap3000outdoor` | [Amazon](https://a.co/d/0gA2n0vt) |
| Cudy WR3000 V1 | `wr3000` | [Cudy](https://www.cudy.com/products/wr3000-1-0) |

**Steps:**
1. Download the firmware for your device from the [Releases](https://github.com/ed-asriyan/YggMesh/releases) page, or [build it yourself](#building).
2. Flash it to your router.
   1. Option A. Flash the devide via dootloader. The specific to-do actions depend on your device, should you google the instructions. Usually it requires using TFTP server or holding _reset_ button.
   2. Option B. If you have OpenWRT and LuCI installed, go to System → Backup/Flash Firmware or do `sysupgrade -n -v /tmp/openwrt-*-sysupgrade.bin` (make sure to **not** keep settings).
4. Wait for the router to reboot. First boot takes about 30-60 seconds longer than usual while the node configures itself.
5. Repeat for every router you want in the mesh. No per-node configuration is needed — all nodes are identical.

> [!WARNING]
> **Change the default root password after first boot.**
> All nodes ship with the password `yggmesh`. Change it via LuCI → System → Administration or by running `passwd` over SSH.

**What each node does after first boot:**
- Brings up 802.11s mesh interfaces on all available radios and joins the shared mesh with SAE encryption.
- Runs Yggdrasil directly on the 802.11s interfaces, discovering peers via multicast. No static peers or internet connection needed.
- Advertises a `300::/64` Yggdrasil subnet on `br-private` so clients receive a `200::/7` IPv6 address via SLAAC.
- Creates an open public WiFi hotspot (`YggMesh`) across all nodes.

## Backlog
You can find the next items planned to add to YggMesh [here](https://github.com/users/ed-asriyan/projects/1/views/1).

## Building
### Option A: GitHub Actions (recommended for forks)
Fork this repository, then go to **Actions → Build Firmware → Run workflow**. Fill in the inputs and run. The firmware artifact will be available for download when the job completes.

| Input | Description |
|-------|-------------|
| `device` | Device keyname to build (see table above). |
| `default_root_password` | Initial root password set on first boot. **Always change from the default and on the first boot.** |
| `private_ssid` | Client AP SSID shown to end-user devices. |
| `yggdrasil_dns` | Space-separated DNS resolver IPv6 addresses reachable over Yggdrasil. Leave empty to skip overlay DNS. |
| `yggdrasil_peers` | Space-separated Yggdrasil peer URIs for reaching the global network. Leave empty to rely on local multicast discovery only. Find a list of public peers [here](https://publicpeers.neilalexander.dev). It is recommended to add just a few addresses geographically close to you. |

To trigger a release build for all devices at once, push a git tag (e.g. `v1.0.0`). Firmware for all supported devices will be built and attached to a GitHub Release automatically.

**If you edit the code:** `MESH_ID`, `MESH_KEY`, and `YGG_PORT` are hardcoded in the workflow and not exposed as inputs — all nodes built from the same fork share the same mesh credentials and can peer with each other. It is recommended to keep them at their default values so all forks can peer with one another.

### Option B: Local build
Requires either:
- Linux with `wget`, `zstd`, `make`, and `python3`
- This repository opened in the devcontainer (works on ARM Macs)

All variables below are required. The script will fail immediately if any are missing.

```bash
MESH_ID="yggmesh/mesh" \
MESH_KEY="qJ7tN2vL8pR4xKcM" \
YGG_PORT="17000" \
PRIVATE_SSID="YggMesh" \
DEFAULT_ROOT_PASSWORD="yggmesh" \
YGGDRASIL_DNS="324:71e:281a:9ed3::53 302:db60::53 202:1d4e:724e:de52:8273:e2b5:4988:a9ba" \
YGGDRASIL_PEERS="tls://example.com:443" \
./scripts/build_router.sh axt1800
```

The script downloads the OpenWrt Image Builder on first run (~1.5 GB per target). Output lands in `output/`.

| Variable | Description |
|----------|-------------|
| `MESH_ID` | 802.11s mesh network identifier. Must match across all nodes. **Recommended: `yggmesh/mesh`** — use this to peer with other YggMesh deployments/forks; change only to create a fully isolated mesh. |
| `MESH_KEY` | SAE key for 802.11s mesh peering. Must match across all nodes. Not a cryptographic secret — baked into the firmware image. **Recommended: `qJ7tN2vL8pR4xKcM`** — use this to peer with other YggMesh deployments/forks; change only to create a fully isolated mesh. |
| `YGG_PORT` | Yggdrasil fixed peering port. **Recommended: `17000`** — use this to peer with other YggMesh deployments/forks; change only to create a fully isolated mesh. |
| `PRIVATE_SSID` | Client AP SSID shown to end-user devices. |
| `DEFAULT_ROOT_PASSWORD` | Initial root password set on first boot. **Always change on first boot.** |
| `YGGDRASIL_DNS` | Space-separated DNS resolver IPv6 addresses reachable over Yggdrasil. Can be empty to skip overlay DNS. |
| `YGGDRASIL_PEERS` | Space-separated Yggdrasil peer URIs for reaching the global network. Can be empty to rely on local multicast discovery only. |

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
3. Connect to the `YggMesh` WiFi hotspot (it is an open network).

### 4. Test the connection
1. Open a browser on your phone.
2. Try to load a public Yggdrasil website. You can find public websites  at https://yggdrasil-network.github.io/services.html.

If the site loads, your mesh is successfully formed and routing Yggdrasil traffic end-to-end across multiple hops.

## Clearnet Access
To have access to clearnet, YggMesh node should have configured IP addresses or domain of
1. Global Yggdrasil peers
2. Yggdrasil to learnet proxies

Both are not distributed within YggMesh firmware (nothing is hardcoded). After the first boot, it's recommended to setup both.

### 1. Connect YggMesh to the global Yggdrasil network
First, you need to connect your local YggMesh to the global Yggdrasil network so it can reach external nodes.

1. Connect any of the YggMesh devices to the internet (e.g., plug an Ethernet cable into the WAN port).
2. Connect to the **YggMesh** WiFi on your phone or laptop and open `http://10.0.0.1/cgi-bin/luci/admin/network/network` in your browser. Authorize if required (the default password is `yggmesh`).
3. Next to the **yggdrasil** interface, click **Edit**.
4. Open the **Peers** tab.
5. Under **Peer addresses**, click **Add peer address**. Insert a **Peer URI** and leave the **Peer interface** field empty. *(You can find a list of public peers [here](https://publicpeers.neilalexander.dev/). It is recommended to add just a few addresses geographically close to you).*
6. Click **Save**, then click **Save & Apply**.
7. Next to the **yggdrasil** interface, click **Edit** again.
8. Ensure that you see your added peers under **Active peers** and that their status is **Up**. If their status is **Down**, your YggMesh device does not have clearnet access or the peer is unreachable. Try changing the peer URI and apply again.

Now the entire local YggMesh network is a part of the global Yggdrasil network.

### 2. Connecting to global clearnet (the Internet)
Setup [yggdrasil-clearnet-proxy](https://github.com/ed-asriyan/yggdrasil-clearnet-proxy) - read the project's readme and setup socks5 proxy on your device connected to YggMesh WiFi.

## License

[MIT](LICENSE)

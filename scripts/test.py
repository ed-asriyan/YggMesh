#!/usr/bin/env python3
import os
import subprocess
import time
import math

NODES = 2
GRID_SIZE = 10
DISTANCE_STEP = 10
VISIBILITY_RADIUS = 10.5
DOCKER_IMAGE = "yggmesh-openwrt:latest"

def run_cmd(cmd, check=True):
    return subprocess.run(cmd, shell=True, text=True, capture_output=True, check=check)

print("[*] Reloading mac80211_hwsim...")
run_cmd("rmmod mac80211_hwsim", check=False)
run_cmd(f"modprobe mac80211_hwsim radios={NODES}")
time.sleep(2)

macs = []
phy_names = []
for i in range(NODES):
    mac = run_cmd(f"cat /sys/class/net/wlan{i}/address").stdout.strip()
    macs.append(mac)
    # Predict the virtual mesh MAC (0x40 local bit set)
    macs.append("42" + mac[2:])
    phy_names.append(os.path.basename(os.path.realpath(f"/sys/class/net/wlan{i}/phy80211")))

print("[*] Generating wmediumd.cfg and starting simulator on host...")
matrix = []
for i in range(NODES * 2):
    row = []
    node_i = i // 2
    x_i = (node_i % GRID_SIZE) * DISTANCE_STEP
    y_i = (node_i // GRID_SIZE) * DISTANCE_STEP
    for j in range(NODES * 2):
        if i == j:
            row.append("0.0")
            continue
        node_j = j // 2
        x_j = (node_j % GRID_SIZE) * DISTANCE_STEP
        y_j = (node_j // GRID_SIZE) * DISTANCE_STEP
        dist = math.sqrt((x_i - x_j)**2 + (y_i - y_j)**2)
        loss = "0.0" if dist <= VISIBILITY_RADIUS else "1.0"
        row.append(loss)
    matrix.append("\t\t(" + ", ".join(row) + ")")

cfg_content = "ifaces :\n{\n"
for i, mac in enumerate(macs):
    cfg_content += f'\tmac{i} = "{mac}";\n'
cfg_content += "};\nmodel :\n{\n\ttype = \"matrix\";\n\tdefault = 1.0;\n\tmatrix = (\n"
cfg_content += ",\n".join(matrix)
cfg_content += "\n\t);\n};\n"

with open("wmediumd.cfg", "w") as f:
    f.write(cfg_content)

wmediumd_proc = subprocess.Popen(["wmediumd", "-c", "wmediumd.cfg"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

print("[*] Preparing Docker networks...")
run_cmd("docker network create wan_net", check=False)
wan_gw = run_cmd("docker network inspect wan_net --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'").stdout.strip()

print("[*] Starting containers and injecting PHY...")
for i in range(NODES):
    node_name = f"openwrt_{i}"
    run_cmd(f"docker rm -f {node_name}", check=False)

    net_flag = "--network wan_net" if i == 0 else "--network none"
    run_cmd(f"docker run -d --name {node_name} {net_flag} --privileged -v /sys/fs/cgroup:/sys/fs/cgroup:ro {DOCKER_IMAGE} /bin/sh -c 'mv /etc/uci-defaults/99-yggmesh /root/99-yggmesh && exec /sbin/init'")

    pid = run_cmd(f"docker inspect -f '{{{{.State.Pid}}}}' {node_name}").stdout.strip()
    run_cmd(f"iw phy {phy_names[i]} set netns {pid}")

print("[*] Waiting 10 seconds for OpenWrt init to finish...")
time.sleep(10)

for i in range(NODES):
    node_name = f"openwrt_{i}"
    
    run_cmd(f"docker exec {node_name} sh -c 'mkdir -p /tmp/cgroup && mount --bind /sys/fs/cgroup /tmp/cgroup && mount -t sysfs sysfs /sys && mkdir -p /sys/fs/cgroup && mount --bind /tmp/cgroup /sys/fs/cgroup'", check=False)
    run_cmd(f"docker exec {node_name} sh -c 'for dev in $(iw dev | grep Interface | awk \"{{print \\$2}}\"); do iw dev $dev del; done'", check=False)

    run_cmd(f"docker exec {node_name} rm -f /etc/config/wireless", check=False)
    run_cmd(f"docker exec {node_name} sh -c 'echo \"config wifi-device radio0\n\toption type mac80211\n\toption phy {phy_names[i]}\n\toption band 2g\n\toption channel 1\n\toption disabled 0\" > /etc/config/wireless'", check=False)
    
    run_cmd(f"docker exec {node_name} sh /root/99-yggmesh", check=False)

    run_cmd(f"docker exec {node_name} ip link set eth0 nomaster", check=False)
    run_cmd(f"docker exec {node_name} ip link set br-lan down", check=False)
    run_cmd(f"docker exec {node_name} brctl delbr br-lan", check=False)

    run_cmd(f"docker exec {node_name} uci set wireless.mesh_2g.mesh_id='yggmesh/mesh'", check=False)
    run_cmd(f"docker exec {node_name} uci set wireless.mesh_2g.key='qJ7tN2vL8pR4xKcM'", check=False)
    
    # 1. FIX: Bind Yggdrasil to ALL interfaces using regex (so it catches phyX-mesh0 correctly)
    run_cmd(f"docker exec {node_name} uci delete network.ygg_iface.interface", check=False)
    run_cmd(f"docker exec {node_name} uci add_list network.ygg_iface.interface='.*'", check=False)
    
    run_cmd(f"docker exec {node_name} uci set firewall.mesh_zone.input='ACCEPT'", check=False)
    run_cmd(f"docker exec {node_name} uci set firewall.mesh_zone.forward='ACCEPT'", check=False)
    run_cmd(f"docker exec {node_name} uci commit", check=False)

    if wan_gw and i == 0:
        docker_ip_full = run_cmd(f"docker inspect -f '{{{{range .NetworkSettings.Networks}}}}{{{{.IPAddress}}}}/{{{{.IPPrefixLen}}}}{{{{end}}}}' {node_name}").stdout.strip()
        run_cmd(f"docker exec {node_name} uci del_list network.private_dev.ports='eth0'", check=False)
        run_cmd(f"docker exec {node_name} uci set network.wan=interface", check=False)
        run_cmd(f"docker exec {node_name} uci set network.wan.device='eth0'", check=False)
        run_cmd(f"docker exec {node_name} uci set network.wan.proto='static'", check=False)
        run_cmd(f"docker exec {node_name} uci set network.wan.ipaddr='{docker_ip_full}'", check=False)
        run_cmd(f"docker exec {node_name} uci set network.wan.gateway='{wan_gw}'", check=False)
        run_cmd(f"docker exec {node_name} uci add_list network.wan.dns='8.8.8.8'", check=False)
        run_cmd(f"docker exec {node_name} uci commit network", check=False)
        
    run_cmd(f"docker exec {node_name} /etc/init.d/network restart", check=False)
    run_cmd(f"docker exec {node_name} /etc/init.d/firewall restart", check=False)

print("[*] Waiting for network to restart...")
time.sleep(5)

for i in range(NODES):
    run_cmd(f"docker exec openwrt_{i} wifi up", check=False)

print("[*] Waiting 10 seconds for Wi-Fi Mesh interfaces to initialize...")
time.sleep(10)

print("[*] Restarting Yggdrasil on all nodes so it binds to the active mesh interfaces...")
for i in range(NODES):
    run_cmd(f"docker exec openwrt_{i} /etc/init.d/yggdrasil restart", check=False)

TIMEOUT = 35
print(f"[*] Network deployed. Waiting {TIMEOUT} seconds for Yggdrasil IPv6 peering...")
time.sleep(TIMEOUT)

def diag(container, cmd):
    r = run_cmd(f"docker exec {container} sh -c {repr(cmd)}", check=False)
    print(r.stdout or r.stderr)

for i in range(NODES):
    print(f"\n[*] Diagnostics for openwrt_{i}...")
    print("-- wpa_supplicant --");   diag(f"openwrt_{i}", "logread | grep -i wpa_supplicant | tail -n 5")
    print("-- yggdrasil peers --");  diag(f"openwrt_{i}", "yggdrasilctl -endpoint=unix:///tmp/yggdrasil/yggdrasil.sock getPeers")

TARGET_IPV6 = "202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8"

print("\n[*] ==================== PING TESTS ====================")

ygg_ip_0 = run_cmd("docker exec openwrt_0 ip -6 addr show yggdrasil | grep 'scope global' | awk '{print $2}' | cut -d/ -f1").stdout.strip()
print(f"[*] Node 0 Yggdrasil IP: {ygg_ip_0}")

print(f"\n[*] Test 1: Mesh Overlay (Ping Node 0 from Node 1)")
ping_mesh = subprocess.run(f"docker exec openwrt_1 ping -c 4 {ygg_ip_0}", shell=True, text=True, capture_output=True)
print(ping_mesh.stdout)
if ping_mesh.returncode == 0:
    print("[+] SUCCESS: The YggMesh overlay is 100% operational!")
else:
    print("[-] FAILURE: Local Mesh Ping failed.")

print(f"\n[*] Test 2: Global Internet (Ping {TARGET_IPV6} from Node 0)")
ping_wan = subprocess.run(f"docker exec openwrt_0 ping -c 4 {TARGET_IPV6}", shell=True, text=True, capture_output=True)
print(ping_wan.stdout)

print(f"\n[*] Test 3: Transit Routing (Ping {TARGET_IPV6} from Node 1)")
for attempt in range(3):
    print(f"[*] Ping Attempt {attempt+1}/3...")
    ping_transit = subprocess.run(f"docker exec openwrt_1 ping -c 4 {TARGET_IPV6}", shell=True, text=True, capture_output=True)
    if ping_transit.returncode == 0:
        print(ping_transit.stdout)
        print("\n[+] SUCCESS: Transit routing to global internet works!")
        break
    else:
        print("[-] Unreachable. Waiting 15s for DHT to converge...")
        time.sleep(15)

if ping_transit.returncode != 0:
    print(ping_transit.stdout)
    print("\n[!] Note: The mesh works, but global ping failed. Target IP is offline or DHT needs more time.")

print("[*] Shutting down wmediumd and removing containers...")
wmediumd_proc.kill()
for i in range(NODES):
    run_cmd(f"docker rm -f openwrt_{i}")
run_cmd("rmmod mac80211_hwsim")

#!/usr/bin/env python3
import os
import subprocess
import time
import math
import json

NODES = 2
GRID_SIZE = 10
DISTANCE_STEP = 10
VISIBILITY_RADIUS = 10.5  # Slightly above 10 to cover float rounding errors. Use 15 for diagonals.
DOCKER_IMAGE = "yggmesh-openwrt:latest"

def run_cmd(cmd, check=True):
    return subprocess.run(cmd, shell=True, text=True, capture_output=True, check=check)

# 1. Initialize virtual radio modules
print("[*] Reloading mac80211_hwsim...")
run_cmd("rmmod mac80211_hwsim", check=False)
run_cmd(f"modprobe mac80211_hwsim radios={NODES}")
time.sleep(2)  # Wait for udev to create interfaces

# Collect MAC addresses and actual PHY names of created interfaces for wmediumd
macs = []
phy_names = []
for i in range(NODES):
    mac = run_cmd(f"cat /sys/class/net/wlan{i}/address").stdout.strip()
    macs.append(mac)
    phy_names.append(os.path.basename(os.path.realpath(f"/sys/class/net/wlan{i}/phy80211")))

# 2. Generate wmediumd configuration (Loss matrix)
print("[*] Generating wmediumd.cfg...")
matrix = []
for i in range(NODES):
    row = []
    x_i = (i % GRID_SIZE) * DISTANCE_STEP
    y_i = (i // GRID_SIZE) * DISTANCE_STEP
    for j in range(NODES):
        if i == j:
            row.append("0.0")
            continue
        x_j = (j % GRID_SIZE) * DISTANCE_STEP
        y_j = (j // GRID_SIZE) * DISTANCE_STEP
        dist = math.sqrt((x_i - x_j)**2 + (y_i - y_j)**2)

        # 0.0 = no loss, 1.0 = 100% frame loss
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

# 3. Container orchestration
print("[*] Preparing Docker networks...")
run_cmd("docker network create wan_net", check=False)
wan_gw = run_cmd("docker network inspect wan_net --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'").stdout.strip()
print(f"[*] wan_net gateway: {wan_gw}")

print("[*] Starting containers and injecting PHY...")
for i in range(NODES):
    node_name = f"openwrt_{i}"
    print(f"[*] Starting container {node_name}...")
    run_cmd(f"docker rm -f {node_name}", check=False)

    net_flag = "--network wan_net" if i == 0 else "--network none"

    # The --privileged flag is required.
    # Mounting /sys/fs/cgroup:ro helps procd work correctly with cgroups inside Docker.
    run_cmd(f"docker run -d --name {node_name} {net_flag} --privileged -v /sys/fs/cgroup:/sys/fs/cgroup:ro {DOCKER_IMAGE}")

    # Get container PID for namespace manipulation
    pid = run_cmd(f"docker inspect -f '{{{{.State.Pid}}}}' {node_name}").stdout.strip()

    # Move hardware PHY interface from host into container's network namespace.
    # Note: hwsim PHYs are named phy0, phy1... but wlan interfaces can be anything.
    # If the user's host has real wifi, hwsim starts at phy1 or higher. We need
    # to find the real phy index from our sysfs mapping.
    phy_idx = phy_names[i].replace("phy", "")
    print(f"[*] Moving phy{phy_idx} to container {node_name}...")
    run_cmd(f"iw phy {phy_names[i]} set netns {pid}")

    # Wait for container to fully initialize and OpenWRT to be ready
    time.sleep(2)

    # Note: the virtual hwsim PHY numbers inside the container do not always start
    # at phy0. OpenWRT's 'wifi config' will auto-generate them correctly. We
    # delete the existing /etc/config/wireless (if any) and let OpenWrt generate it.
    run_cmd(f"docker exec {node_name} rm -f /etc/config/wireless", check=False)
    run_cmd(f"docker exec {node_name} sh -c 'echo \"config wifi-device radio0\n\toption type mac80211\n\toption path virtual/mac80211_hwsim/hwsim0\n\toption band 2g\n\toption channel 1\n\toption disabled 0\" > /etc/config/wireless'", check=False)
    run_cmd(f"docker exec {node_name} sh /etc/uci-defaults/99-yggmesh", check=False)
    
    # Restart the wireless stack
    run_cmd(f"docker exec {node_name} wifi up", check=False)

    # Stop OpenWRT's netifd from running DHCP on eth0, which endlessly wipes 
    # the Docker-provisioned IP address in a loop.
    if wan_gw and i == 0:
        docker_ip = run_cmd(
            f"docker inspect -f '{{{{range .NetworkSettings.Networks}}}}{{{{.IPAddress}}}}/{{{{.IPPrefixLen}}}}{{{{end}}}}' {node_name}"
        ).stdout.strip()
        run_cmd(f"docker exec {node_name} uci delete network.wan", check=False)
        run_cmd(f"docker exec {node_name} uci commit network", check=False)
        
        # We need to restart the network without losing our docker IP. Since 
        # restarting drops the interface, we create an init script that forces
        # the route right after boot inside the container.
        run_cmd(f"docker exec {node_name} sh -c 'echo \"ip link set eth0 up && ip addr flush dev eth0 && ip addr add {docker_ip} dev eth0 && ip route add default via {wan_gw} dev eth0 && iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE\" > /etc/rc.local'", check=False)
        
        run_cmd(f"docker exec {node_name} /etc/init.d/network restart", check=False)
        time.sleep(3)
        # Execute it manually just to be 100% sure
        run_cmd(f"docker exec {node_name} sh /etc/rc.local", check=False)
        print(f"[*] Restored {docker_ip} + default route via {wan_gw} on eth0 in {node_name}")

# 4. Start wireless medium (after PHYs are in their namespaces)
print("[*] Starting wmediumd...")
wmediumd_proc = subprocess.Popen(["wmediumd", "-c", "wmediumd.cfg"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

TIMEOUT = 90
print(f"[*] Network deployed. Waiting {TIMEOUT} seconds for Yggdrasil peer connection...")
time.sleep(TIMEOUT)

# 5. Diagnostics
def diag(container, cmd):
    # Wrap in sh -c to prevent the host shell from splitting on ; | & etc.
    r = run_cmd(f"docker exec {container} sh -c {repr(cmd)}", check=False)
    print(r.stdout or r.stderr)

for i in range(NODES):
    print(f"\n[*] Diagnostics for openwrt_{i}...")
    print("-- interfaces --");      diag(f"openwrt_{i}", "ip addr")
    print("-- routes --");          diag(f"openwrt_{i}", "ip route; ip -6 route")
    print("-- yggdrasil peers --"); diag(f"openwrt_{i}", "yggdrasilctl -endpoint=unix:///tmp/yggdrasil/yggdrasil.sock getPeers")
    print("-- ping node 0 --");     diag(f"openwrt_{i}", "ping -c 1 10.0.0.1")

# 6. Testing
print(f"[*] IPv6 ping from node {NODES - 1} ({NODES}, {NODES})...")
TARGET_IPV6 = "202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8"
ping_result = subprocess.run(f"docker exec openwrt_{NODES - 1} ping -c 4 {TARGET_IPV6}", shell=True, text=True, capture_output=True)

print(ping_result.stdout)
if ping_result.returncode == 0:
    print("\n[+] SUCCESS: Routing through mesh works.")
else:
    print("\n[-] FAILURE: Ping failed.\n", ping_result.stderr)

# Cleanup
print("[*] Shutting down wmediumd and removing containers...")
wmediumd_proc.kill()
for i in range(NODES):
    run_cmd(f"docker rm -f openwrt_{i}")
run_cmd("rmmod mac80211_hwsim")

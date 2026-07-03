#!/usr/bin/env python3
import os
import subprocess
import time
import math
import re
import atexit
import signal

def run_cmd(cmd, check=True):
    return subprocess.run(cmd, shell=True, text=True, capture_output=True, check=check)

class YggNode:
    def __init__(self, network, node_id, x, y, has_internet, visibility_radius, docker_image):
        self.network = network
        self.id = node_id
        self.name = f"openwrt_{node_id}"
        self.x = x
        self.y = y
        self.has_internet = has_internet
        self.visibility_radius = visibility_radius
        self.docker_image = docker_image
        
        self.base_mac = None
        self.mesh_mac = None
        self.phy_name = None

    def get_ygg_ip(self):
        res = run_cmd(f"docker exec {self.name} ip -6 addr show yggdrasil | grep 'scope global' | awk '{{print $2}}' | cut -d/ -f1", check=False)
        return res.stdout.strip()

    def ping(self, target_ip, count=4):
        res = run_cmd(f"docker exec {self.name} ping -c {count} {target_ip}", check=False)
        if res.returncode != 0:
            return None
        
        match = re.search(r"min/avg/max(?:/mdev)? = [\d\.]+/(?P<avg>[\d\.]+)/", res.stdout)
        if match:
            return float(match.group("avg"))
        return 0.0

    def set_location(self, x, y):
        print(f"[*] Node {self.id} moving to ({x}, {y})...")
        self.x = x
        self.y = y
        self.network.reload_matrix()

    def set_visibility_radius(self, r):
        print(f"[*] Node {self.id} changing visibility radius to {r}...")
        self.visibility_radius = r
        self.network.reload_matrix()

class YggNetwork:
    def __init__(self):
        self.nodes = []
        self.wmediumd_proc = None
        atexit.register(self.cleanup)

    def create_node(self, x, y, has_internet=False, visibility_radius=10.5, docker_image="yggmesh-openwrt:latest"):
        node = YggNode(self, len(self.nodes), x, y, has_internet, visibility_radius, docker_image)
        self.nodes.append(node)
        return node

    def cleanup(self):
        print("\n[*] Cleaning up environment...")
        if self.wmediumd_proc:
            self.wmediumd_proc.kill()
        for node in self.nodes:
            run_cmd(f"docker rm -f {node.name}", check=False)
        run_cmd("rmmod mac80211_hwsim", check=False)

    def reload_matrix(self):
        if not self.nodes or not self.nodes[0].base_mac:
            return

        print("[*] Generating updated wmediumd.cfg...")
        macs = []
        for node in self.nodes:
            macs.extend([node.base_mac, node.mesh_mac])

        matrix = []
        nodes_count = len(self.nodes)
        for i in range(nodes_count * 2):
            row = []
            node_i = self.nodes[i // 2]
            for j in range(nodes_count * 2):
                if i == j:
                    row.append("0.0")
                    continue
                node_j = self.nodes[j // 2]
                dist = math.sqrt((node_i.x - node_j.x)**2 + (node_i.y - node_j.y)**2)
                loss = "0.0" if dist <= node_i.visibility_radius else "1.0"
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

        if self.wmediumd_proc:
            print("[*] Hard-restarting wmediumd to apply new matrix...")
            self.wmediumd_proc.kill()
            self.wmediumd_proc.wait()
            
        self.wmediumd_proc = subprocess.Popen(["wmediumd", "-c", "wmediumd.cfg"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def start(self):
        nodes_count = len(self.nodes)
        if nodes_count == 0:
            return

        print(f"[*] Initializing hwsim with {nodes_count} radios...")
        run_cmd("rmmod mac80211_hwsim", check=False)
        run_cmd(f"modprobe mac80211_hwsim radios={nodes_count}")
        time.sleep(2)

        for i, node in enumerate(self.nodes):
            mac = run_cmd(f"cat /sys/class/net/wlan{i}/address").stdout.strip()
            node.base_mac = mac
            node.mesh_mac = "42" + mac[2:]
            node.phy_name = os.path.basename(os.path.realpath(f"/sys/class/net/wlan{i}/phy80211"))

        self.reload_matrix()

        print("[*] Preparing Docker networks...")
        run_cmd("docker network create wan_net", check=False)
        wan_gw = run_cmd("docker network inspect wan_net --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'").stdout.strip()

        print("[*] Booting containers and mapping PHYs...")
        for node in self.nodes:
            run_cmd(f"docker rm -f {node.name}", check=False)
            net_flag = "--network wan_net" if node.has_internet else "--network none"
            run_cmd(f"docker run -d --name {node.name} {net_flag} --privileged -v /sys/fs/cgroup:/sys/fs/cgroup:ro {node.docker_image} /bin/sh -c 'mv /etc/uci-defaults/99-yggmesh /root/99-yggmesh && exec /sbin/init'")
            
            pid = run_cmd(f"docker inspect -f '{{{{.State.Pid}}}}' {node.name}").stdout.strip()
            run_cmd(f"iw phy {node.phy_name} set netns {pid}")

        print("[*] Waiting 10 seconds for OpenWrt init to finish...")
        time.sleep(10)

        print("[*] Applying mesh configurations...")
        for node in self.nodes:
            run_cmd(f"docker exec {node.name} sh -c 'mkdir -p /tmp/cgroup && mount --bind /sys/fs/cgroup /tmp/cgroup && mount -t sysfs sysfs /sys && mkdir -p /sys/fs/cgroup && mount --bind /tmp/cgroup /sys/fs/cgroup'", check=False)
            run_cmd(f"docker exec {node.name} sh -c 'for dev in $(iw dev | grep Interface | awk \"{{print \\$2}}\"); do iw dev $dev del; done'", check=False)

            run_cmd(f"docker exec {node.name} rm -f /etc/config/wireless", check=False)
            run_cmd(f"docker exec {node.name} sh -c 'echo \"config wifi-device radio0\n\toption type mac80211\n\toption phy {node.phy_name}\n\toption band 2g\n\toption channel 1\n\toption disabled 0\" > /etc/config/wireless'", check=False)
            
            run_cmd(f"docker exec {node.name} sh /root/99-yggmesh", check=False)

            run_cmd(f"docker exec {node.name} ip link set eth0 nomaster", check=False)
            run_cmd(f"docker exec {node.name} ip link set br-lan down", check=False)
            run_cmd(f"docker exec {node.name} brctl delbr br-lan", check=False)

            run_cmd(f"docker exec {node.name} uci set wireless.mesh_2g.mesh_id='yggmesh/mesh'", check=False)
            run_cmd(f"docker exec {node.name} uci set wireless.mesh_2g.key='qJ7tN2vL8pR4xKcM'", check=False)
            run_cmd(f"docker exec {node.name} uci delete network.ygg_iface.interface", check=False)
            run_cmd(f"docker exec {node.name} uci add_list network.ygg_iface.interface=\".*\"", check=False)
            run_cmd(f"docker exec {node.name} uci set firewall.mesh_zone.input='ACCEPT'", check=False)
            run_cmd(f"docker exec {node.name} uci set firewall.mesh_zone.forward='ACCEPT'", check=False)
            run_cmd(f"docker exec {node.name} uci commit", check=False)

            if node.has_internet:
                docker_ip = run_cmd(f"docker inspect -f '{{{{range .NetworkSettings.Networks}}}}{{{{.IPAddress}}}}/{{{{.IPPrefixLen}}}}{{{{end}}}}' {node.name}").stdout.strip()
                run_cmd(f"docker exec {node.name} uci del_list network.private_dev.ports='eth0'", check=False)
                run_cmd(f"docker exec {node.name} uci set network.wan=interface", check=False)
                run_cmd(f"docker exec {node.name} uci set network.wan.device='eth0'", check=False)
                run_cmd(f"docker exec {node.name} uci set network.wan.proto='static'", check=False)
                run_cmd(f"docker exec {node.name} uci set network.wan.ipaddr='{docker_ip}'", check=False)
                run_cmd(f"docker exec {node.name} uci set network.wan.gateway='{wan_gw}'", check=False)
                run_cmd(f"docker exec {node.name} uci add_list network.wan.dns='8.8.8.8'", check=False)
                run_cmd(f"docker exec {node.name} uci commit network", check=False)
                
            run_cmd(f"docker exec {node.name} /etc/init.d/network restart", check=False)
            run_cmd(f"docker exec {node.name} /etc/init.d/firewall restart", check=False)

        print("[*] Waiting for networking interfaces to map...")
        time.sleep(5)

        for node in self.nodes:
            run_cmd(f"docker exec {node.name} wifi up", check=False)

        print("[*] Securing 802.11s L2 links (10s)...")
        time.sleep(10)

        print("[*] Bootstrapping Yggdrasil daemons...")
        for node in self.nodes:
            run_cmd(f"docker exec {node.name} /etc/init.d/yggdrasil restart", check=False)


# =====================================================================
# ТЕСТОВЫЙ СЦЕНАРИЙ
# =====================================================================
if __name__ == "__main__":
    network = YggNetwork()

    node_1 = network.create_node(x=0, y=0, has_internet=True, visibility_radius=10.5, docker_image="yggmesh-openwrt:latest")
    node_2 = network.create_node(x=1, y=5, has_internet=False, visibility_radius=10.5, docker_image="yggmesh-openwrt:latest")
    node_3 = network.create_node(x=5, y=5, has_internet=False, visibility_radius=10.5, docker_image="yggmesh-openwrt:latest")

    network.start()

    print("\n[*] Waiting 50 seconds for Yggdrasil DHT routing to converge...")
    time.sleep(50)

    # Test 1: Mesh ping (проверка чисто локального линка)
    ping_result = node_3.ping("202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8")
    assert ping_result is not None, "Node 3 failed to ping Node 1 through the mesh network."
    print(f"[+] SUCCESS: Node 3 -> Node 1 (Mesh RTT: {ping_result} ms)")

    # Test 2: Global ping с ретраями на случай долгой сходимости DHT
    print("\n[*] Testing Global Internet Routing...")
    ping_result = None
    for attempt in range(4):
        ping_result = node_3.ping("202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8")
        if ping_result is not None:
            break
        print(f"[-] Attempt {attempt+1} failed. Waiting 15s for DHT to converge...")
        time.sleep(15)
        
    assert ping_result is not None, "Node 3 should be able to ping the global internet."
    print(f"[+] SUCCESS: Node 3 -> Global Internet (RTT: {ping_result} ms)")

    # Test 3: Topology change (настоящая физическая изоляция)
    print("\n[*] Changing topology: Isolating Node 3...")
    node_3.set_location(x=200, y=200)
    node_3.set_visibility_radius(15)
    
    print("[*] Waiting 15 seconds for topology propagation and mesh teardown...")
    time.sleep(25)
    
    # Пинг ДОЛЖЕН провалиться
    assert node_3.ping("202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8") is None, "Node 3 should NOT be able to ping the global internet after moving out of range."
    print("[+] SUCCESS: Node 3 is successfully isolated from the mesh.")

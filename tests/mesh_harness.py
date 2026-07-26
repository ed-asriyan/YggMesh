import os
import json
import subprocess
import time
import math
import re
import atexit
import signal
import sys

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

    def ping(self, target_ip, count=4*6):
        res = run_cmd(f"docker exec {self.name} ping -c {count} {target_ip}", check=False)
        if res.returncode != 0:
            return None
                
        match = re.search(r"min/avg/max(?:/mdev)? = [\d\.]+/(?P<avg>[\d\.]+)/", res.stdout)
        if match:
            return float(match.group("avg"))
        return 0.0

    def get_peers(self):
        res = run_cmd(f"docker exec {self.name} yggdrasilctl -endpoint unix:///tmp/yggdrasil/yggdrasil.sock -json getPeers", check=False)
        if res.returncode != 0:
            return []
        peers_info = json.loads(res.stdout)["peers"]
        return {peer['address'] for peer in peers_info if peer['up'] == True}

    def set_location(self, x, y):
        print(f"[*] Node {self.id} moving to ({x}, {y})...")
        self.x = x
        self.y = y
        self.network.reload_matrix(skip_bounce=False)

    def set_visibility_radius(self, r):
        print(f"[*] Node {self.id} changing visibility radius to {r}...")
        self.visibility_radius = r
        self.network.reload_matrix(skip_bounce=False)

class YggNetwork:
    def __init__(self):
        self.nodes = []
        self.wmediumd_proc = None
        atexit.register(self.cleanup)

    def create_node(self, x, y, has_internet=False, visibility_radius=10.5, docker_image="yggmesh-openwrt:latest"):
        docker_image = os.environ.get('YGG_DOCKER_IMAGE', docker_image)
        node = YggNode(self, len(self.nodes) + 1, x, y, has_internet, visibility_radius, docker_image)
        self.nodes.append(node)
        return node

    def cleanup(self):
        print("\n[*] Cleaning up environment...")
        if self.wmediumd_proc:
            self.wmediumd_proc.terminate()
            try:
                self.wmediumd_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.wmediumd_proc.kill()
        for node in self.nodes:
            run_cmd(f"docker rm -f {node.name}", check=False)
        run_cmd("rmmod mac80211_hwsim", check=False)

    def reload_matrix(self, skip_bounce=True):
        if not self.nodes or not self.nodes[0].base_mac:
            return
        print("[*] Generating updated wmediumd.cfg...")
        macs = []
        for node in self.nodes:
            macs.append(node.mesh_mac)
        matrix = []
        nodes_count = len(self.nodes)
        for i in range(nodes_count):
            row = []
            node_i = self.nodes[i]
            for j in range(nodes_count):
                if i == j:
                    row.append("40.0")
                    continue
                node_j = self.nodes[j]
                dist = ((node_i.x - node_j.x)**2 + (node_i.y - node_j.y)**2)**0.5
                loss = "40.0" if dist <= node_i.visibility_radius else "-50.0"
                row.append(loss)
            matrix.append(" (" + ", ".join(row) + ")")
        cfg_content = "ifaces :\n{\n"
        cfg_content += f'\tcount = {len(macs)};\n'
        cfg_content += '\tids = [\n'
        cfg_content += ",\n".join(f'\t\t"{mac}"' for mac in macs)
        cfg_content += "\n\t];\n};\nmodel :\n{\n\ttype = \"matrix\";\n\tdefault = -50.0;\n\tmatrix = (\n"
        cfg_content += ",\n".join(matrix)
        cfg_content += "\n\t);\n};\n"
        with open("wmediumd.cfg", "w") as f:
            f.write(cfg_content)
        if self.wmediumd_proc:
            print("[*] Hard-restarting wmediumd to apply new matrix...")
            self.wmediumd_proc.terminate()
            try:
                self.wmediumd_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.wmediumd_proc.kill()
                self.wmediumd_proc.wait()
            time.sleep(1)
                    
        print("[*] Starting wmediumd...")
        self.wmediumd_proc = subprocess.Popen(["wmediumd", "-c", "wmediumd.cfg"], stdout=open("/tmp/wmd.log", "w"), stderr=subprocess.STDOUT)
        if getattr(self, 'started', False) and not skip_bounce:
            for node in self.nodes:
                run_cmd(f'docker exec {node.name} wifi down', check=False)
            for node in self.nodes:
                run_cmd(f'docker exec {node.name} wifi up', check=False)
            time.sleep(15)
            for node in self.nodes:
                run_cmd(f'docker exec {node.name} /etc/init.d/yggdrasil restart', check=False)
            time.sleep(15)

    def start(self):
        import time
        self.started = True
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
            mac_parts = mac.split(":")
            mac_parts[0] = "42"
            node.mesh_mac = ":".join(mac_parts)
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
            run_cmd(f"docker exec {node.name} sh -c 'echo \"config wifi-device radio0\n\toption type mac80211\n\toption phy {node.phy_name}\n\toption band 2g\n\toption channel 1\n\toption disabled 0\n\nconfig wifi-iface mesh_2g\n\toption device radio0\n\toption mode mesh\n\toption mesh_id yggmesh/mesh\n\toption encryption sae\n\toption key qJ7tN2vL8pR4xKcM\n\toption macaddr {node.mesh_mac}\" > /etc/config/wireless'", check=False)
                        
            run_cmd(f"docker exec {node.name} sh /root/99-yggmesh", check=False)
            run_cmd(f"docker exec {node.name} ip link set eth0 nomaster", check=False)
            run_cmd(f"docker exec {node.name} ip link set br-lan down", check=False)
            run_cmd(f"docker exec {node.name} brctl delbr br-lan", check=False)
            run_cmd(f"docker exec {node.name} uci set wireless.mesh_2g.mesh_id='yggmesh/mesh'", check=False)
            run_cmd(f"docker exec {node.name} uci set wireless.mesh_2g.encryption='sae'", check=False)
            run_cmd(f"docker exec {node.name} uci set wireless.mesh_2g.key='qJ7tN2vL8pR4xKcM'", check=False)
            run_cmd(f"docker exec {node.name} uci set wireless.mesh_2g.macaddr='{node.mesh_mac}'", check=False)
            run_cmd(f"docker exec {node.name} uci set wireless.private_2g.macaddr='{node.base_mac}'", check=False)
            run_cmd(f"docker exec {node.name} uci delete network.ygg_iface.interface", check=False)
            run_cmd(f"docker exec {node.name} uci add_list network.ygg_iface.interface=\"phy.*-mesh0\"", check=False)
            run_cmd(f"docker exec {node.name} uci set firewall.mesh_zone.input='ACCEPT'", check=False)
            run_cmd(f"docker exec {node.name} uci set firewall.mesh_zone.forward='ACCEPT'", check=False)
            run_cmd(f"docker exec {node.name} uci commit", check=False)
            if node.has_internet:
                test_peer = os.environ.get('TEST_YGG_PEER')
                if test_peer:
                    run_cmd(f"docker exec {node.name} uci add network yggdrasil_yggdrasil_peer", check=False)
                    run_cmd(f"docker exec {node.name} uci rename network.@yggdrasil_yggdrasil_peer[-1]='ygg_test_peer'", check=False)
                    run_cmd(f"docker exec {node.name} uci set network.ygg_test_peer.address='{test_peer}'", check=False)
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

        print("[*] Syncing real mesh MAC addresses with wmediumd...")
        for node in self.nodes:
            res = run_cmd(f"docker exec {node.name} sh -c 'iw dev | awk \"/addr/ {{mac=\\$2}} /type mesh point/ {{print mac; exit}}\"'", check=False)
            real_mac = res.stdout.strip()
            if real_mac and len(real_mac.split(':')) == 6:
                node.mesh_mac = real_mac
        self.reload_matrix(skip_bounce=True)

        print("[*] Bootstrapping Yggdrasil daemons...")
        for node in self.nodes:
            run_cmd(f"docker exec {node.name} /etc/init.d/yggdrasil restart", check=False)

import pytest
import time
import os
from mesh_harness import YggNetwork

IMAGE_NAME = os.environ.get('YGG_DOCKER_IMAGE', 'yggmesh-openwrt:latest')
IP_TO_PING = os.environ.get("TEST_YGG_IP")  # Global Yggdrasil test IP
assert IP_TO_PING, "TEST_YGG_IP environment variable is required"

@pytest.fixture(scope="module")
def network():
    net = YggNetwork()
    
    # ---------------------------------------------
    # Topology:
    # ---------------------------------------------
    # Node 1: Edge node with internet gateway
    node_1 = net.create_node(x=0, y=0, has_internet=True, docker_image=IMAGE_NAME)
    
    # Node 2: Repeater node in the middle
    # Distance (0,0) to (5,5) = 7.07
    node_2 = net.create_node(x=5, y=5, has_internet=False, docker_image=IMAGE_NAME)
    
    # Node 3: Edge node on the other side
    # Distance (5,5) to (5,13) = 8.0
    # True distance (0,0) to (5,13) = 13.9 (greater than absolute visibility_radius 10.5)
    node_3 = net.create_node(x=5, y=13, has_internet=False, docker_image=IMAGE_NAME)
    
    net.start()
    
    # Initial routing convergence time
    print('\n[*] Waiting 60 seconds for Yggdrasil DHT routing to converge...')
    time.sleep(60)
    
    yield net, node_1, node_2, node_3
    
    net.cleanup()

def test_yggdrasil_ip_assignment(network):
    """Test that all nodes correctly derived and assigned their Yggdrasil IPv6 addresses."""
    net, node_1, node_2, node_3 = network
    assert node_1.get_ygg_ip(), "Node 1 failed to get Yggdrasil IP"
    assert node_2.get_ygg_ip(), "Node 2 failed to get Yggdrasil IP"
    assert node_3.get_ygg_ip(), "Node 3 failed to get Yggdrasil IP"

def test_global_internet_routing(network):
    """Test that Node 3 (no internet) can hit the global Yggdrasil internet via multihop."""
    net, node_1, node_2, node_3 = network
    ping_result = None
    
    for attempt in range(4):
        ping_result = node_3.ping(IP_TO_PING)
        if ping_result is not None:
            break
        time.sleep(15)
        
    assert ping_result is not None, "Node 3 failed to route to the global internet via multihop."

def test_multihop_repeater_behavior(network):
    """
    Pure black-box multi-hop test.
    We test if Node 1 and Node 3 can communicate. Then we remove the repeater (Node 2)
    and verify the connection breaks (since distance 13.9 > 10.5 limit). Finally,
    we bring Node 2 back and verify the connection restores.
    """
    net, node_1, node_2, node_3 = network
    node_1_ip = node_1.get_ygg_ip()
    
    # 1. Verify Node 3 can ping Node 1 initially
    ping_result = None
    for _ in range(4):
        ping_result = node_3.ping(node_1_ip)
        if ping_result is not None:
            break
        time.sleep(15)
    assert ping_result is not None, "Node 3 failed to ping Node 1 through the mesh repeater."
    
    # 2. Move Repeater (Node 2) completely out of range
    old_x, old_y = node_2.x, node_2.y
    node_2.set_location(x=200, y=200)
    time.sleep(25)  # Wait for Wi-Fi links to drop and DHT updates
    
    # 3. Verify Node 3 CANNOT ping Node 1 anymore
    # (Proves they were relying on Node 2 as a repeater, hiding internal details)
    assert node_3.ping(node_1_ip) is None, "Node 3 should NOT be able to ping Node 1 when the repeater is absent (out of range)."
    
    # 4. Move Repeater back into place
    node_2.set_location(x=old_x, y=old_y)
    time.sleep(40)  # Wait for Wi-Fi mesh re-forming and Yggdrasil rebuilding the tree
    
    # 5. Verify the connection recovers
    ping_result = None
    for _ in range(4):
        ping_result = node_3.ping(node_1_ip)
        if ping_result is not None:
            break
        time.sleep(15)
    assert ping_result is not None, "Node 3 failed to ping Node 1 after the repeater node returned."

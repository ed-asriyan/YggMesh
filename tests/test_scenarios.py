import pytest
import time
import os
from mesh_harness import YggNetwork

IMAGE_NAME = os.environ.get('YGG_DOCKER_IMAGE', 'yggmesh-openwrt:latest')
IP_TO_PING = os.environ.get("TEST_YGG_IP")
assert IP_TO_PING, "TEST_YGG_IP environment variable is required"


# ============================================================================
# ФИКСТУРА 1: ДИНАМИЧЕСКАЯ ТОПОЛОГИЯ (5 НОД)
# ============================================================================
@pytest.fixture(scope="module")
def dynamic_network():
    """
    Линейно-разветвленная сеть из 5 нод с шагом 7 метров (при радиусе 10.5м):
    Node 1 (0,0) [WAN] <-> Node 2 (7,0) <-> Node 3 (14,0) <-> Node 4 (21,0)
                                                          <-> Node 5 (21,7) [Мобильная нода / Роуминг]
    """
    net = YggNetwork()
    n1 = net.create_node(x=0, y=0, has_internet=True, docker_image=IMAGE_NAME)
    n2 = net.create_node(x=7, y=0, has_internet=False, docker_image=IMAGE_NAME)
    n3 = net.create_node(x=14, y=0, has_internet=False, docker_image=IMAGE_NAME)
    n4 = net.create_node(x=21, y=0, has_internet=False, docker_image=IMAGE_NAME)
    n5 = net.create_node(x=21, y=7, has_internet=False, docker_image=IMAGE_NAME)
    
    net.start()
    print('\n[*] Waiting 45s for 5-node dynamic topology convergence...')
    time.sleep(45)
    yield net, [n1, n2, n3, n4, n5]
    net.cleanup()


# ============================================================================
# ФИКСТУРА 2: ЖЕСТКИЙ GRID 5x5 (25 НОД)
# ============================================================================
@pytest.fixture(scope="module")
def grid_network():
    """
    Масштабный грид 5x5 (25 нод) с шагом 8 метров (при радиусе 10.5м).
    Связь строго по вертикали/горизонтали (Manhattan routing), по диагонали (11.31м) эфир не добивает.
    """
    net = YggNetwork()
    width, height = 5, 5
    spacing = 8.0
    
    nodes_matrix = {}
    for x in range(width):
        for y in range(height):
            # Два независимых выхода в интернет: в левом верхнем (0,0) и правем нижнем (4,4) углах
            has_net = (x == 0 and y == 0) or (x == width - 1 and y == height - 1)
            node = net.create_node(
                x=x * spacing, 
                y=y * spacing, 
                has_internet=has_net, 
                visibility_radius=10.5, 
                docker_image=IMAGE_NAME
            )
            nodes_matrix[(x, y)] = node
            
    net.start()
    print(f'\n[*] Grid 5x5 (25 nodes) started. Waiting 60s for full HWMP/DHT convergence...')
    time.sleep(60)
    yield net, nodes_matrix, width, height
    net.cleanup()


# ============================================================================
# БЛОК 1: ТЕСТЫ ДИНАМИКИ, РОУМИНГА, РЭБ И СПЛИТ-БРЕЙНА (5 НОД)
# ============================================================================

def test_01_ip_assignment(dynamic_network):
    """100% узлов обязаны получить валидные глобальные IPv6 Yggdrasil адреса"""
    _, nodes = dynamic_network
    for node in nodes:
        assert node.get_ygg_ip() is not None, f"Node {node.id} failed to get Yggdrasil IP"


def test_02_multihop_clearnet_routing(dynamic_network):
    """Пакет от Node 4 (3 хопа по воздуху) обязан дойти до глобального интернета через Node 1"""
    _, nodes = dynamic_network
    assert nodes[3].ping(IP_TO_PING, timeout_sec=45) is not None, "Node 4 failed multihop clearnet routing"


def test_03_physical_roaming_handover(dynamic_network):
    """
    Роуминг: Node 5 изначально подключена в хвосте (21,7). 
    Перемещаем её прямо вплотную к шлюзу Node 1 (0,1).
    L3-сессия Yggdrasil не должна умереть, трафик переключится с 4 хопов на 1 хоп.
    """
    _, nodes = dynamic_network
    n1, _, _, _, n5 = nodes
    
    assert n5.ping(IP_TO_PING, timeout_sec=30) is not None, "Node 5 initial connection failed"
    
    print("\n[*] Roaming: moving Node 5 from tail (21,7) directly to gateway (0,1)...")
    n5.set_location(0, 1)
    time.sleep(15)
    
    rtt_after = n5.ping(IP_TO_PING, count=5, timeout_sec=30)
    assert rtt_after is not None, "Node 5 dropped connection after roaming across physical space"
    print(f"[+] Roaming successful! New direct RTT: {rtt_after:.2f} ms")


def test_04_rf_jamming_degradation(dynamic_network):
    """
    Симуляция РЭБ / глушения радиоэфира (Signal-Jammed Zone).
    Глушим радиоканал между Node 2 и Node 3 (ставим SNR = -50 dB).
    Пинг от Node 4 до шлюза обязан упасть. После снятия помех — восстановиться.
    """
    _, nodes = dynamic_network
    n2, n3, n4 = nodes[1], nodes[2], nodes[3]
    
    # 1. Глушим линк в центре цепи
    n2.jam_link_to(n3, snr_db=-50.0)
    time.sleep(15)
    assert n4.ping(IP_TO_PING, count=3, timeout_sec=15) is None, "Traffic bypassed jammed RF link!"
    
    # 2. Снимаем глушение
    n2.restore_link_to(n3)
    time.sleep(25)
    assert n4.ping(IP_TO_PING, timeout_sec=45) is not None, "Mesh failed to recover after RF jamming stopped"


def test_05_split_brain_partition_and_merge(dynamic_network):
    """
    Сплит-брейн: разрываем сеть на 2 независимых острова: {Node 1, Node 2} и {Node 3, Node 4, Node 5}.
    Внутри изолированного острова {3,4,5} локальный Yggdrasil-пинг обязан продолжать работать!
    После слияния островов обратно — доступ в интернет восстанавливается у всех.
    """
    _, nodes = dynamic_network
    n1, n2, n3, n4, n5 = nodes
    n3_ip = n3.get_ygg_ip()
    
    print("\n[*] Creating Split-Brain partition: isolating {3,4,5} from {1,2}...")
    n3.set_location(50, 50)
    n4.set_location(57, 50)
    n5.set_location(57, 57)
    time.sleep(20)
    
    # Внешнего интернета на острове {3,4,5} быть не должно
    assert n4.ping(IP_TO_PING, count=3, timeout_sec=15) is None, "Split-brain isolation failed: reached clearnet!"
    # НО локальная сеть между Node 4 и Node 3 внутри острова обязана работать идеально
    assert n4.ping(n3_ip, timeout_sec=30) is not None, "Local Yggdrasil routing died inside isolated partition!"
    
    print("[*] Merging network islands back together...")
    n3.set_location(14, 0)
    n4.set_location(21, 0)
    n5.set_location(21, 7)
    time.sleep(30)
    assert n4.ping(IP_TO_PING, timeout_sec=45) is not None, "Mesh failed to merge split-brain islands"


def test_06_gateway_failover_to_redundant_isp(dynamic_network):
    """
    Динамический хендовер шлюза:
    Отключаем WAN на Node 1 -> интернет падает.
    Включаем WAN на Node 4 (в другом конце сети) -> вся сеть перенаправляет трафик через Node 4.
    """
    _, nodes = dynamic_network
    n1, n3, n4 = nodes[0], nodes[2], nodes[3]
    
    print("\n[*] Killing ISP on Node 1...")
    n1.disable_internet()
    time.sleep(10)
    assert n3.ping(IP_TO_PING, count=3, timeout_sec=15) is None, "Node 3 still has internet after sole gateway died"
    
    print("[*] Enabling redundant ISP on Node 4...")
    n4.enable_internet()
    assert n3.ping(IP_TO_PING, timeout_sec=60) is not None, "Mesh failed to failover to new gateway on Node 4"
    
    # Возвращаем в исходное состояние
    n4.disable_internet()
    n1.enable_internet()
    time.sleep(15)


def test_07_total_blackout_local_survival(dynamic_network):
    """При полном отключении всех WAN-шлюзов локальный L3-роутинг Yggdrasil не должен деградировать"""
    _, nodes = dynamic_network
    n1, n4 = nodes[0], nodes[3]
    n1_ip = n1.get_ygg_ip()
    
    n1.disable_internet()
    time.sleep(10)
    assert n4.ping(IP_TO_PING, count=3, timeout_sec=15) is None, "Clearnet reachable during blackout"
    print("[*] Verifying local mesh survival during total blackout...")
    assert n4.ping(n1_ip, timeout_sec=30) is not None, "Local Yggdrasil routing collapsed during ISP blackout"
    n1.enable_internet()


# ============================================================================
# БЛОК 2: МАСШТАБНЫЙ GRID 5x5 (25 НОД)
# ============================================================================

def test_08_grid_scale_edge_to_edge_latency(grid_network):
    """
    Пинг через всю сетку из угла (0,0) в противоположный угол (4,4).
    Минимум 8 беспроводных хопов (Manhattan distance).
    """
    _, nodes_matrix, width, height = grid_network
    src = nodes_matrix[(0, height - 1)]  # (0,4)
    dst = nodes_matrix[(width - 1, 0)]   # (4,0)
    dst_ip = dst.get_ygg_ip()
    
    print(f"\n[*] Stress testing 25-node grid: pinging from (0,4) to (4,0) across 8+ wireless hops...")
    avg_rtt = src.ping(dst_ip, count=10, timeout_sec=60)
    assert avg_rtt is not None, "Failed 8-hop routing across 5x5 grid"
    print(f"[+] 25-Node Grid Edge-to-Edge RTT: {avg_rtt:.2f} ms")


def test_09_grid_multi_gateway_load_redundancy(grid_network):
    """
    В сетке 5x5 работают ДВА независимых шлюза: в (0,0) и в (4,4).
    Убиваем шлюз (0,0). Нода из центра сетки (2,2) должна бесшовно продолжить ходить в интернет через (4,4).
    """
    _, nodes_matrix, width, height = grid_network
    gw1 = nodes_matrix[(0, 0)]
    gw2 = nodes_matrix[(width - 1, height - 1)]
    center_node = nodes_matrix[(2, 2)]
    
    assert center_node.ping(IP_TO_PING, timeout_sec=30) is not None, "Center node has no internet with dual gateways"
    
    print("\n[*] Killing Gateway 1 at (0,0)... Center node should route via Gateway 2 at (4,4)...")
    gw1.disable_internet()
    time.sleep(15)
    assert center_node.ping(IP_TO_PING, timeout_sec=45) is not None, "Center node lost internet after 1 of 2 gateways died"
    
    gw1.enable_internet()
    time.sleep(15)


def test_10_grid_blackhole_perimeter_rerouting(grid_network):
    """
    Стресс-тест «Черная дыра»:
    В сетке 5x5 выключаем (утаскиваем) весь внутренний квадрат 3x3 (9 нод в центре).
    Трафик из угла (0,0) в угол (4,4) больше не может идти напрямую по центру.
    802.11s и Yggdrasil обязаны перестроить маршрут и пустить пакеты строго по внешнему периметру сетки.
    """
    _, nodes_matrix, width, height = grid_network
    src = nodes_matrix[(0, 0)]
    dst = nodes_matrix[(4, 4)]
    dst_ip = dst.get_ygg_ip()
    
    # 1. Вырезаем ядро 3x3 (ноды с координатами от 1,1 до 3,3)
    core_nodes = []
    for x in range(1, 4):
        for y in range(1, 4):
            core_nodes.append(nodes_matrix[(x, y)])
            
    print(f"\n[*] Creating Black Hole: knocking out {len(core_nodes)} central nodes in the 5x5 grid...")
    saved_coords = []
    for n in core_nodes:
        saved_coords.append((n, n.x, n.y))
        n.set_location(999, 999)
        
    time.sleep(25) # Даем время на полный пересчет графа вокруг дыры
    
    print("[*] Testing perimeter routing around the 3x3 dead zone...")
    rtt_perimeter = src.ping(dst_ip, count=10, timeout_sec=60)
    assert rtt_perimeter is not None, "Mesh failed to reroute traffic around central 3x3 black hole!"
    print(f"[+] Perimeter routing successful! RTT via edge square: {rtt_perimeter:.2f} ms")
    
    # 2. Возвращаем ядро на место
    for n, x, y in saved_coords:
        n.set_location(x, y)
    time.sleep(25)
    assert src.ping(dst_ip, timeout_sec=45) is not None, "Mesh failed to restore direct paths after core healed"


def test_11_grid_diagonal_wall_isolation(grid_network):
    """
    Симуляция непроницаемой стены:
    Выстраиваем диагональный глухой барьер из отключенных нод от (0,4) до (4,0).
    Сетка разрезается на два абсолютно изолированных треугольника.
    Связь между углами (0,0) и (4,4) обязана прерваться.
    """
    _, nodes_matrix, width, height = grid_network
    src = nodes_matrix[(0, 0)]
    dst = nodes_matrix[(4, 4)]
    dst_ip = dst.get_ygg_ip()
    
    # Ноды на главной диагонали: (0,4), (1,3), (2,2), (3,1), (4,0)
    wall_nodes = [nodes_matrix[(i, 4 - i)] for i in range(5)]
    
    print(f"\n[*] Raising diagonal RF wall: removing {len(wall_nodes)} diagonal nodes...")
    saved_coords = []
    for n in wall_nodes:
        saved_coords.append((n, n.x, n.y))
        n.set_location(999, 999)
        
    time.sleep(20)
    assert src.ping(dst_ip, count=3, timeout_sec=15) is None, "Traffic penetrated diagonal RF wall!"
    
    for n, x, y in saved_coords:
        n.set_location(x, y)
    time.sleep(25)
    assert src.ping(dst_ip, timeout_sec=45) is not None, "Grid failed to recover after diagonal wall dropped"


def test_12_grid_self_healing_storm(grid_network):
    """
    Финальный стресс-тест штормом перестроений (Self-Healing Storm):
    В сетке 5x5 хаотично глушим 4 случайных линка, одновременно гасим шлюз в (0,0) и пингуем с края.
    Сеть должна выдержать шторм перестроений маршрутов и найти путь через шлюз (4,4).
    """
    _, nodes_matrix, width, height = grid_network
    src = nodes_matrix[(0, 4)]
    gw1 = nodes_matrix[(0, 0)]
    
    print("\n[*] Initiating Self-Healing Storm: jamming multiple random links + killing Gateway 1...")
    gw1.disable_internet()
    
    # Глушим линки: (0,3)-(1,3), (2,1)-(2,2), (3,3)-(3,4)
    nodes_matrix[(0, 3)].jam_link_to(nodes_matrix[(1, 3)])
    nodes_matrix[(2, 1)].jam_link_to(nodes_matrix[(2, 2)])
    nodes_matrix[(3, 3)].jam_link_to(nodes_matrix[(3, 4)])
    time.sleep(20)
    
    rtt_storm = src.ping(IP_TO_PING, count=10, timeout_sec=60)
    assert rtt_storm is not None, "Mesh collapsed under self-healing routing storm"
    print(f"[+] Mesh survived the storm! RTT to remaining Gateway 2: {rtt_storm:.2f} ms")
    
    # Откат изменений
    nodes_matrix[(0, 3)].restore_link_to(nodes_matrix[(1, 3)])
    nodes_matrix[(2, 1)].restore_link_to(nodes_matrix[(2, 2)])
    nodes_matrix[(3, 3)].restore_link_to(nodes_matrix[(3, 4)])
    gw1.enable_internet()

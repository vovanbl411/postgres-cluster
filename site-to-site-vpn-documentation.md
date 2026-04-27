# Документация: Site-to-Site VPN между локальным Kubernetes-кластером и PostgreSQL в Timeweb Cloud

## 1. Общая архитектура

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Timeweb Cloud                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Bastion Host (7706931-fd095296.twc1.net)                          │    │
│  │  ├─ eth0: 185.68.22.14 (публичный IP)                              │    │
│  │  ├─ eth1: 192.168.10.7 (приватная сеть PostgreSQL)                │    │
│  │  ├─ wg0: 10.200.0.1/24 (WireGuard туннель)                        │    │
│  │  └─ NAT: MASQUERADE на eth1 для трафика из WG                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              │ 192.168.10.0/24                               │
│         ┌────────────────────┼────────────────────┐                          │
│         ▼                    ▼                    ▼                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                      │
│  │ pg-node-1   │    │ pg-node-2   │    │ pg-node-3   │                      │
│  │ 192.168.10.4│    │ 192.168.10.5│    │ 192.168.10.6│                      │
│  │ :5432       │    │ :5432       │    │ :5432       │                      │
│  └─────────────┘    └─────────────┘    └─────────────┘                      │
└─────────────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ WireGuard UDP/51820
                              │
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Локальный кластер (k8s + Cilium)                    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  controller-0 (10.0.0.10)                                          │    │
│  │  ├─ ens3: 10.0.0.10/24 (локальная сеть кластера)                  │    │
│  │  ├─ wg0: 10.200.0.2/24 (WireGuard туннель)                        │    │
│  │  ├─ cilium_host: 10.244.1.91/32 (Cilium overlay)                  │    │
│  │  ├─ IP Forwarding: включен                                        │    │
│  │  └─ Маршрут: 192.168.10.0/24 dev wg0                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       ▲                                                                      │
│       │ Cilium VXLAN (10.244.0.0/16)                                       │
│       │                                                                      │
│  ┌────┴────┐    ┌─────────┐                                                │
│  │ worker-0│    │ worker-1│                                                │
│  │10.0.0.20│    │10.0.0.21│                                                │
│  │         │    │         │                                                │
│  │ip route │    │ip route │                                                │
│  │192.168..│    │192.168..│                                                │
│  │via 10.0.│    │via 10.0.│                                                │
│  └────┬────┘    └────┬────┘                                                │
│       │              │                                                       │
│  ┌────┴──────────────┴────┐                                                │
│  │      Pods (Cilium)      │                                                │
│  │   10.244.x.x/24         │                                                │
│  └─────────────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Таблица сетей

| Сеть | Назначение | Хосты / Диапазон |
|------|-----------|------------------|
| `185.68.22.14` | Публичный IP bastion | Точка входа для WireGuard |
| `192.168.10.0/24` | Сеть PostgreSQL в Timeweb | pg-node-1 (10.4), pg-node-2 (10.5), pg-node-3 (10.6), bastion eth1 (10.7) |
| `10.0.0.0/24` | Локальная сеть кластера | controller-0 (10.10), worker-0 (10.20), worker-1 (10.21) |
| `10.244.0.0/16` | Pod CIDR (Cilium overlay) | Все поды кластера |
| `10.200.0.0/24` | **WireGuard туннель** | bastion (10.200.0.1), controller-0 (10.200.0.2) |

---

## 3. Почему именно такие решения

### 3.1. WireGuard вместо IPSec/OpenVPN
- **Простота конфигурации** — один ключ, один порт UDP, никаких CA и сертификатов
- **Производительность** — работает на уровне ядра, минимальные накладные расходы
- **Стабильность** — при разрыве соединения восстанавливается за секунды (PersistentKeepalive)

### 3.2. Подсеть туннеля 10.200.0.0/24
Изначально использовалась подсеть `10.0.0.0/24`, которая **конфликтовала** с локальной сетью кластера (`10.0.0.10`, `10.0.0.20`, `10.0.0.21`).

**Проблема:** когда на controller-0 интерфейс `ens3` имел адрес `10.0.0.10/24`, а `wg0` — `10.0.0.2/24`, ядро не могло корректно определить исходящий интерфейс для ответов на пакеты из туннеля. Пакеты приходили на `wg0`, а ответы уходили через `ens3` и терялись.

**Решение:** выделить туннель в отдельную подсеть `10.200.0.0/24`, не пересекающуюся ни с одной из существующих сетей.

### 3.3. Почему НЕ Cilium Egress Gateway
Изначально планировалось использовать `CiliumEgressGatewayPolicy` для автоматического заворачивания трафика к PostgreSQL через controller-0.

**Проблема:** Cilium 1.15 с `kubeProxyReplacement=true` и `egressGateway.enabled=true` при перезагрузке BPF-программ (применение политики, обновление, перезапуск агента) **временно ломает hostNetwork** для static pods (etcd, kube-apiserver, kube-scheduler). Это вызывало `CrashLoopBackOff` control plane.

**Решение:** отключить Egress Gateway (`egressGateway.enabled: false`) и использовать **статические маршруты** на workers (`192.168.10.0/24 via 10.0.0.10`). Это проще, стабильнее и не трогает control plane.

### 3.4. Почему MASQUERADE только на wg0/eth1
Изначально в шаблоне использовалось:
```ini
PostUp = iptables -t nat -A POSTROUTING -j MASQUERADE
```

**Проблема:** без указания исходящего интерфейса (`-o`) `MASQUERADE` применялся ко **всему** исходящему трафику ноды, включая Cilium VXLAN, kubelet→apiserver, etcd→etcd. Это меняло source IP пакетов и ломало TLS, health checks и BPF-программы.

**Решение:** привязать `MASQUERADE` к конкретному интерфейсу:
- На controller-0: `-o wg0` (только трафик в туннель)
- На bastion: `-o eth1` (только трафик в сеть PostgreSQL)

### 3.5. Почему AllowedIPs на bastion не содержат 192.168.10.0/24
Bastion сам находится в сети `192.168.10.0/24` через интерфейс `eth1`. Добавление этой сети в `AllowedIPs` peer'а приводит к ошибке `RTNETLINK answers: File exists`, потому что маршрут `192.168.10.0/24` уже существует через `eth1`.

**Решение:** на bastion `AllowedIPs` содержат только адреса **за туннелем** (`10.200.0.2/32` — WG IP controller-0, `10.0.0.10/32` — физический IP controller-0 для Cilium SNAT). На controller-0 `AllowedIPs` содержат `10.200.0.1/32` (WG IP bastion) и `192.168.10.0/24` (сеть за bastion).

---

## 4. Конфигурация WireGuard

### 4.1. Bastion (Timeweb)

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <private_key_bastion>
PostUp = iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
# controller-0
PublicKey = <public_key_controller>
AllowedIPs = 10.200.0.2/32, 10.0.0.10/32
```

### 4.2. controller-0 (локальный кластер)

```ini
[Interface]
Address = 10.200.0.2/24
PrivateKey = <private_key_controller>
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
# bastion
PublicKey = <public_key_bastion>
Endpoint = 185.68.22.14:51820
AllowedIPs = 10.200.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25
```

---

## 5. Конфигурация Cilium

```yaml
cilium_values:
  kubeProxyReplacement: "true"
  k8sServiceHost: "10.0.0.10"
  k8sServicePort: "6443"
  devices: "ens3"
  routingMode: "tunnel"
  tunnelProtocol: "vxlan"
  loadBalancer:
    algorithm: "maglev"
  ipam:
    mode: "cluster-pool"
    operator:
      clusterPoolIPv4PodCIDRList: ["10.244.0.0/16"]
  bpf:
    masquerade: true
  cgroup:
    autoMount:
      enabled: false
    hostRoot: /sys/fs/cgroup
  operator:
    replicas: 1
  egressGateway:
    enabled: false  # <-- ОТКЛЮЧЕН, ломает control plane
```

---

## 6. Маршрутизация на workers

Для доступа подов на worker-нодах к PostgreSQL используются **статические маршруты** через controller-0.

### 6.1. Временная настройка (до перезагрузки)

```bash
# На worker-0 и worker-1
sudo ip route add 192.168.10.0/24 via 10.0.0.10
```

### 6.2. Постоянная настройка (systemd-networkd)

```ini
# /etc/systemd/network/10-pg-route.network
[Match]
Name=ens3

[Route]
Destination=192.168.10.0/24
Gateway=10.0.0.10
```

```bash
sudo systemctl restart systemd-networkd
```

### 6.3. IP Forwarding на controller-0

```bash
# Постоянно
sudo sysctl -w net.ipv4.ip_forward=1
# Добавить в /etc/sysctl.conf: net.ipv4.ip_forward=1

# Правила iptables
sudo iptables -I FORWARD -i ens3 -o wg0 -j ACCEPT
sudo iptables -I FORWARD -i wg0 -o ens3 -j ACCEPT

# Сохранение правил
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

## 7. Путь пакета от Pod к PostgreSQL

```
1. Pod (10.244.x.x) отправляет пакет на 192.168.10.4:5432
   ↓
2. Cilium VXLAN (overlay 10.244.0.0/16) доставляет пакет на worker
   ↓
3. Worker видит маршрут: 192.168.10.0/24 via 10.0.0.10
   Отправляет пакет на controller-0 через ens3
   ↓
4. Controller-0 получает пакет на ens3
   IP Forwarding активен, маршрут 192.168.10.0/24 dev wg0
   Пакет уходит в WireGuard туннель
   ↓
5. Bastion (10.200.0.1) получает пакет из туннеля
   MASQUERADE на eth1 меняет source IP на 192.168.10.7
   Пакет уходит в сеть PostgreSQL
   ↓
6. PostgreSQL (192.168.10.4) получает пакет
   Source IP: 192.168.10.7 (bastion)
   ↓
7. Обратный путь:
   PostgreSQL → шлюз 192.168.10.1 → bastion (192.168.10.7)
   Bastion видит destination 10.244.x.x в AllowedIPs (через 10.0.0.10)
   Заворачивает ответ в wg0 → controller-0 → Cilium reverse NAT → Pod
```

---

## 8. Проблемы, с которыми столкнулись

| Проблема | Причина | Решение |
|----------|---------|---------|
| `RTNETLINK answers: File exists` | `192.168.10.0/24` в `AllowedIPs` на bastion, где эта сеть уже локальна | Убрать `192.168.10.0/24` из `AllowedIPs` на bastion |
| Пинг bastion → controller-0 не проходит | Конфликт подсетей: `ens3` и `wg0` оба в `10.0.0.0/24` | Перевести WG в `10.200.0.0/24` |
| Пинг controller-0 → PostgreSQL не проходит | `MASQUERADE` привязан к `eth0`, а трафик к БД идёт через `eth1` | Убрать привязку к интерфейсу (`-o eth0`) на bastion |
| API server падает после применения Cilium политики | Egress Gateway в tunnel mode ломает hostNetwork static pods | Отключить Egress Gateway, использовать статические маршруты |
| API server падает после поднятия WG | Глобальный `MASQUERADE` без `-o` меняет source IP Cilium VXLAN и hostNetwork трафика | Привязать `MASQUERADE` к `wg0` на controller-0 |

---

## 9. Итоговый инвентарь Ansible

### `inventories/cloud.ini`

```ini
[bastion]
bastion-host ansible_host=185.68.22.14

[bastion:vars]
ansible_user=root
wg_tunnel_ip=10.200.0.1

[postgres_nodes]
pg-node-1 ansible_host=192.168.10.4
pg-node-2 ansible_host=192.168.10.5
pg-node-3 ansible_host=192.168.10.6

[postgres_nodes:vars]
ansible_user=root
ansible_ssh_common_args='-o ProxyJump=root@185.68.22.14'
```

### `inventories/local.ini`

```ini
[all:vars]
ansible_user=vladimir
ansible_ssh_private_key_file=~/.ssh/id_ed25519

[controllers]
controller-0 ansible_host=10.0.0.10

[controllers:vars]
wg_tunnel_ip=10.200.0.2

[workers]
worker-0 ansible_host=10.0.0.20
worker-1 ansible_host=10.0.0.21

[k8s:children]
controllers
workers
```

---

## 10. Проверка работоспособности

```bash
# 1. WG туннель
sudo wg show wg0
ping -c 3 10.200.0.1   # с controller-0
ping -c 3 10.200.0.2   # с bastion

# 2. Доступ к БД с controller-0
ping -c 3 192.168.10.4
nc -zv 192.168.10.4 5432

# 3. Доступ к БД из пода
kubectl run pg-test --rm -it --image=busybox --restart=Never -- /bin/sh
/ # ping -c 3 192.168.10.4
/ # nc -zv 192.168.10.4 5432

# 4. Стабильность control plane (подождать 2-3 минуты)
kubectl get pods -n kube-system
# RESTARTS у etcd, apiserver, scheduler должны быть 0 и не расти
```

---

*Документация составлена по итогам настройки site-to-site VPN между локальным Kubernetes-кластером (Cilium) и PostgreSQL-кластером в Timeweb Cloud.*

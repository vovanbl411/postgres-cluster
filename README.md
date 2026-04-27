# PostgreSQL HA Cluster + Hybrid Infrastructure Monitoring

> **Гибридная инфраструктура:** Локальный Kubernetes-кластер (Cilium) + облачный PostgreSQL HA (Patroni + Consul + Keepalived) + единый стек мониторинга (VictoriaMetrics) через зашифрованный WireGuard-туннель.

---

## 📋 Оглавление

- [PostgreSQL HA Cluster + Hybrid Infrastructure Monitoring](#postgresql-ha-cluster--hybrid-infrastructure-monitoring)
  - [📋 Оглавление](#-оглавление)
  - [1. Архитектура проекта](#1-архитектура-проекта)
    - [Ключевые решения](#ключевые-решения)
  - [2. Сетевая топология](#2-сетевая-топология)
    - [Таблица адресации](#таблица-адресации)
    - [Маршрутизация](#маршрутизация)
  - [3. Структура репозитория](#3-структура-репозитория)
  - [4. Компоненты инфраструктуры](#4-компоненты-инфраструктуры)
    - [4.1. Terraform — провижининг](#41-terraform--провижининг)
    - [4.2. Ansible — конфигурация](#42-ansible--конфигурация)
    - [4.3. Kubernetes + Cilium](#43-kubernetes--cilium)
    - [4.4. PostgreSQL HA (Patroni + Consul + Keepalived)](#44-postgresql-ha-patroni--consul--keepalived)
    - [4.5. WireGuard Site-to-Site VPN](#45-wireguard-site-to-site-vpn)
    - [4.6. Мониторинг (VictoriaMetrics + vmagent + exporters)](#46-мониторинг-victoriametrics--vmagent--exporters)
  - [5. Пошаговое развёртывание](#5-пошаговое-развёртывание)
    - [5.1. Этап 0: Подготовка](#51-этап-0-подготовка)
    - [5.2. Этап 1: Инфраструктура (Terraform)](#52-этап-1-инфраструктура-terraform)
    - [5.3. Этап 2: VPN (WireGuard)](#53-этап-2-vpn-wireguard)
    - [5.4. Этап 3: Kubernetes-кластер](#54-этап-3-kubernetes-кластер)
    - [5.5. Этап 4: PostgreSQL HA](#55-этап-4-postgresql-ha)
    - [5.6. Этап 5: Мониторинг](#56-этап-5-мониторинг)
  - [6. Операционная документация](#6-операционная-документация)
    - [6.1. Управление PostgreSQL-кластером](#61-управление-postgresql-кластером)
    - [6.2. Управление Kubernetes](#62-управление-kubernetes)
    - [6.3. Управление мониторингом](#63-управление-мониторингом)
    - [6.4. Диагностика VPN](#64-диагностика-vpn)
  - [7. Troubleshooting](#7-troubleshooting)
    - [7.1. Terraform](#71-terraform)
    - [7.2. WireGuard](#72-wireguard)
    - [7.3. PostgreSQL / Patroni](#73-postgresql--patroni)
    - [7.4. Мониторинг](#74-мониторинг)
  - [8. Безопасность](#8-безопасность)
  - [9. Полезные команды](#9-полезные-команды)

---

## 1. Архитектура проекта

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              ЛОКАЛЬНЫЙ ДАТАЦЕНТР                                    │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                         Kubernetes Cluster (Cilium)                         │    │
│  │                                                                             │    │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │    │
│  │  │ controller-0 │    │   worker-0   │    │   worker-1   │                   │    │
│  │  │ 10.0.0.10    │    │  10.0.0.20   │    │  10.0.0.21   │                   │    │
│  │  │ kube-apiserver│    │ kubelet      │    │ kubelet      │                  │    │
│  │  │ etcd         │    │ Cilium VXLAN │    │ Cilium VXLAN │                   │    │
│  │  │ wg0:10.200.0.2│   │              │    │              │                   │    │
│  │  │ node_exporter│    │ node_exporter│    │ node_exporter│                   │    │
│  │  │ vmagent      │    │ vmagent      │    │ vmagent      │                   │    │
│  │  │ wireguard_exp│    │              │    │              │                   │    │
│  │  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘                   │    │
│  │         │                   │                   │                           │    │
│  │         └───────────────────┼───────────────────┘                           │    │
│  │                             │                                               │    │
│  │                    ┌────────┴────────┐                                      │    │
│  │                    │  monitoring-0   │                                      │    │
│  │                    │   10.0.0.30     │                                      │    │
│  │                    │ VictoriaMetrics │◄─────────────────────────────────────┘    │
│  │                    │    (VMUI)       │              remote_write (push)          │
│  │                    │ 8428/vmui       │                                      │    │
│  │                    └────────┬────────┘                                      │    │
│  │                             │ wg0 (WireGuard)                               │    │
│  └─────────────────────────────┼───────────────────────────────────────────────┘    │
│                                │ 10.200.0.2                                         │
└────────────────────────────────┼────────────────────────────────────────────────────┘
                                 │
                    ╔════════════╧════════════╗
                    ║   WireGuard UDP/51820   ║
                    ╚════════════╤════════════╝
                                 │ 10.200.0.1
┌────────────────────────────────┼────────────────────────────────────────────────────┐
│                           ОБЛАКО (Timeweb Cloud)                                    │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │  Bastion Host (Cloudflare Tunnel)                                           │    │
│  │  ├─ eth0: публичный IP (туннель через Cloudflare Zero Trust)                │    │
│  │  ├─ eth1: 192.168.10.7 (VPC PostgreSQL)                                     │    │
│  │  ├─ wg0: 10.200.0.1/24 (WireGuard)                                          │    │
│  │  │ node_exporter, vmagent, wireguard_exporter                               │    │
│  │  └─ NAT: MASQUERADE eth1 для WG-трафика                                     │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                              │                                                      │
│         ┌────────────────────┼────────────────────┐                                 │
│         ▼                    ▼                    ▼                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌─────────────┐                            │
│  │ pg-node-1    │    │ pg-node-2    │    │ pg-node-3   │                            │
│  │ 192.168.10.4 │    │ 192.168.10.5 │    │ 192.168.10.6│                            │
│  │ PostgreSQL   │    │ PostgreSQL   │    │ PostgreSQL  │                            │
│  │ Patroni      │    │ Patroni      │    │ Patroni     │                            │
│  │ Consul       │    │ Consul       │    │ Consul      │                            │
│  │ HAProxy      │    │ HAProxy      │    │ HAProxy     │                            │
│  │ Keepalived   │    │ Keepalived   │    │ Keepalived  │                            │
│  │ node_exporter│    │ node_exporter│    │node_exporter│                            │
│  │ vmagent      │    │ vmagent      │    │ vmagent     │                            │
│  │ postgres_exp │    │ postgres_exp │    │ postgres_exp│                            │
│  │ VIP: 192.168.10.100 (floating)               │                                   │
│  └─────────────┘     └──────────────┘    └─────────────┘                            │
│                                                                                     │
│  Сеть: 192.168.10.0/24 (VPC) — изолированная, только IPv6-интернет                  │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Ключевые решения

| Решение | Обоснование |
|---------|------------|
| **WireGuard вместо IPSec/OpenVPN** | Простота, производительность на уровне ядра, быстрое восстановление при разрыве |
| **Cilium без Egress Gateway** | Egress Gateway ломал hostNetwork static pods (etcd, kube-apiserver) при перезагрузке BPF |
| **Статические маршруты на workers** | Надёжнее Cilium Egress Gateway, не трогает control plane |
| **VictoriaMetrics вместо Prometheus** | Push-модель (vmagent → VM) устойчивее к разрывам туннеля |
| **VMUI вместо Grafana** | Встроенный интерфейс, нет зависимости от apt-репозиториев (Cloudflare 403) |
| **Peer auth для postgres_exporter** | Не требует пароля, работает через unix-socket |
| **cargo-сборка wireguard_exporter** | GitHub releases только исходники, cargo — надёжнее |
| **Бинарники через controller** | Облачные ноды имеют только IPv6-интернет, нет IPv4 |

---

## 2. Сетевая топология

### Таблица адресации

| Сеть | Назначение | Хосты / Диапазон |
|------|-----------|------------------|
| `10.0.0.0/24` | Локальная сеть кластера | controller-0 (10.0.0.10), worker-0 (10.0.0.20), worker-1 (10.0.0.21), monitoring-0 (10.0.0.30) |
| `10.244.0.0/16` | Pod CIDR (Cilium VXLAN) | Все поды Kubernetes |
| `10.200.0.0/24` | WireGuard туннель | bastion (10.200.0.1), controller-0 (10.200.0.2) |
| `192.168.10.0/24` | Cloud VPC (Timeweb) | pg-node-1 (10.4), pg-node-2 (10.5), pg-node-3 (10.6), bastion eth1 (10.7), VIP (10.100) |

### Маршрутизация

**Локальный кластер → Облако:**
```
Pod (10.244.x.x) → Cilium VXLAN → worker (10.0.0.x) → controller-0 (10.0.0.10) → wg0 → bastion → PostgreSQL (192.168.10.x)
```

**Облако → Локальный кластер (мониторинг):**
```
pg-node (192.168.10.x) → bastion (192.168.10.7) → wg0 → controller-0 (10.200.0.2) → monitoring-0 (10.0.0.30)
```

**Статические маршруты:**

| Хост | Маршрут | Gateway | Назначение |
|------|---------|---------|------------|
| worker-0/1 | `192.168.10.0/24` | `10.0.0.10` | Доступ к PostgreSQL |
| controller-0 | `192.168.10.0/24` | `dev wg0` | Через туннель |
| bastion | `10.0.0.0/24` | `10.200.0.2` | Обратно в кластер |
| monitoring-0 | `192.168.10.0/24` | `10.0.0.10` | Метрики из облака |
| pg-node-1/2/3 | `10.0.0.0/24` | `192.168.10.7` | remote_write в VM |

---

## 3. Структура репозитория

```
.
├── ansible/
│   ├── ansible.cfg
│   ├── inventories/
│   │   ├── cloud.ini          # Облачные хосты (bastion, pg-node-*)
│   │   ├── local.ini          # Локальный кластер (controller, workers, monitoring)
│   │   └── monitoring.ini     # Только monitoring-0
│   ├── playbooks/
│   │   ├── deploy-agents-cloud.yml      # Агенты на bastion
│   │   ├── deploy-agents-k8s.yml        # Агенты на K8s-кластер
│   │   ├── deploy-db.yml                # PostgreSQL HA (Patroni + Consul + HAProxy + Keepalived)
│   │   ├── deploy-k8s.yml               # Kubernetes + Cilium
│   │   ├── deploy-monitoring.yml        # VictoriaMetrics сервер
│   │   ├── deploy-postgres-monitoring.yml # Агенты + postgres_exporter на ноды Patroni
│   │   └── deploy-vpn.yml               # WireGuard туннель
│   └── roles/
│       ├── common/              # Базовая настройка (репозитории, sysctl, NTP)
│       ├── consul/              # Consul DCS (3 сервера, bootstrap_expect=3)
│       ├── container_runtime/   # containerd
│       ├── haproxy/             # Балансировщик (5432 RW, 5433 RO)
│       ├── keepalived/          # VIP с VRRP (Unicast для облака)
│       ├── k8s_cni/             # Cilium
│       ├── k8s_control_plane/   # kubeadm init
│       ├── k8s_install/         # kubelet, kubeadm, kubectl
│       ├── k8s_prep/            # Подготовка (swap off, модули ядра)
│       ├── k8s_workers/         # Присоединение workers
│       ├── monitoring_agents/   # node_exporter + vmagent + wireguard_exporter
│       ├── monitoring_server/   # VictoriaMetrics + сборка wireguard_exporter через cargo
│       ├── postgres_exporter/   # Метрики PostgreSQL (peer auth через unix-socket)
│       ├── postgres_patroni/    # PostgreSQL 17 + Patroni
│       ├── vpn_routes_worker/   # Статические маршруты на workers
│       └── wireguard/           # wg0.conf, ключи, iptables
├── docs.md                      # Общая документация проекта
├── monitoring.md                # Архитектура мониторинга (изначальная)
├── monitoring-deployment-documentation.md  # Детальный гайд по деплою мониторинга
├── site-to-site-vpn-documentation.md       # Документация VPN
├── terraform/
│   ├── cloud/
│   │   ├── backend.tf           # S3-backend (Cloudflare R2)
│   │   ├── main.tf              # Ресурсы Timeweb + Cloudflare Tunnel
│   │   ├── providers.tf         # twc + cloudflare
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── modules/
│   │       └── twc_node/        # Модуль для создания нод
│   ├── local_k8s/
│   │   ├── main.tf              # Libvirt VMs для локального K8s
│   │   ├── network.tf
│   │   └── modules/
│   │       └── libvirt_node/
│   ├── local_monitoring/
│   │   └── main.tf              # VM для monitoring-0
│   └── templates/
│       ├── cloud_init_local.cfg
│       ├── inventory_cloud.tmpl
│       ├── inventory_local.tmpl
│       └── setup_cloud.sh.tpl   # Cloud-init для bastion
├── terraform_clouflare.md       # Документация Cloudflare Tunnel
├── TERRAFORM.md                 # Разбор Terraform-конфигурации
└── README.md                    # Этот файл
```

---

## 4. Компоненты инфраструктуры

### 4.1. Terraform — провижининг

**Провайдеры:** Timeweb Cloud (twc) + Cloudflare (cloudflare)

**Что создаётся:**
- 3x Cloud VPS для PostgreSQL (приватная сеть `192.168.10.0/24`, без публичных IP)
- Bastion-хост с Cloudflare Tunnel (Zero Trust, нет белого IP)
- VPC-сеть, SSH-ключи, проект
- S3-backend для state в Cloudflare R2

**Ключевые файлы:**
- `terraform/cloud/main.tf` — ноды кластера + bastion
- `terraform/cloud/modules/twc_node/` — переиспользуемый модуль
- `terraform/local_k8s/` — Libvirt VMs для локального K8s
- `terraform/local_monitoring/` — VM для monitoring-0

**Запуск:**
```bash
cd terraform/cloud
terraform init
terraform plan
terraform apply
```

**Проблемы и решения:**

| Проблема | Решение |
|----------|---------|
| Cloudflare API токен не подходит | Нужен токен уровня Account (Cloudflare Tunnel Edit), не только Zone.DNS |
| Модуль не видит провайдер | `required_providers` должен быть в каждом модуле |
| Публичные IP у нод кластера | Намеренно отсутствуют — доступ только через bastion |

---

### 4.2. Ansible — конфигурация

**Структура:** Роли + Playbooks. Каждая роль независима, с `defaults/main.yml` для параметризации.

**Принципы:**
- Идемпотентность — повторный запуск не ломает
- Бинарники скачиваются на Ansible controller (Gentoo), затем `copy` на target
- Облачные хосты не имеют IPv4-интернета — все загрузки через `delegate_to: localhost`

**Инвентарь:**
```ini
# inventories/local.ini
[controllers]
controller-0 ansible_host=10.0.0.10

[workers]
worker-0 ansible_host=10.0.0.20
worker-1 ansible_host=10.0.0.21

[monitoring]
monitoring-0 ansible_host=10.0.0.30

# inventories/cloud.ini
[bastion]
bastion-host ansible_host=<cloudflare-tunnel-domain>

[patroni]
pg-node-1 ansible_host=192.168.10.4
pg-node-2 ansible_host=192.168.10.5
pg-node-3 ansible_host=192.168.10.6
```

---

### 4.3. Kubernetes + Cilium

**Версия:** Kubernetes (kubeadm), Cilium (CNI)

**Ключевые решения:**
- `kubeProxyReplacement: true` — Cilium заменяет kube-proxy
- `egressGateway.enabled: false` — отключён, ломает control plane (etcd/apiserver падают при перезагрузке BPF)
- Статические маршруты на workers вместо Egress Gateway

**Cilium values:**
```yaml
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
  enabled: false  # <-- ОТКЛЮЧЁН
```

**Путь пакета от Pod к PostgreSQL:**
```
Pod (10.244.x.x) → Cilium VXLAN → worker (10.0.0.x) → controller-0 (10.0.0.10) → wg0 → bastion → PostgreSQL (192.168.10.x)
```

---

### 4.4. PostgreSQL HA (Patroni + Consul + Keepalived)

**Стек:**
- **PostgreSQL 17** — СУБД
- **Patroni** — оркестратор, автоматический failover
- **Consul** — DCS (Distributed Configuration Store), 3 сервера, bootstrap_expect=3
- **HAProxy** — балансировщик, порты 5432 (RW) и 5433 (RO)
- **Keepalived** — VIP 192.168.10.100, VRRP через Unicast (multicast блокируется в облаке)

**Логика HA:**
1. Consul — источник правды о лидере
2. Patroni управляет жизненным циклом PG, при падении — promote другой ноды
3. HAProxy опрашивает Patroni REST API (`/master` → 200 OK), живым считается только лидер
4. Keepalived гарантирует, что VIP всегда на живой ноде

**Проверка состояния:**
```bash
# На любой ноде Patroni
patronictl -c /etc/patroni/patroni.yml list
consul members
ip addr show eth1 | grep 192.168.10.100
```

---

### 4.5. WireGuard Site-to-Site VPN

**Топология:** Point-to-point (bastion ↔ controller-0)

**Подсеть туннеля:** `10.200.0.0/24` (выделена отдельно, чтобы не конфликтовать с `10.0.0.0/24`)

**Bastion (10.200.0.1):**
```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <key>
PostUp = iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE

[Peer]
PublicKey = <controller-pubkey>
AllowedIPs = 10.200.0.2/32, 10.0.0.0/24
```

**Controller-0 (10.200.0.2):**
```ini
[Interface]
Address = 10.200.0.2/24
PrivateKey = <key>
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
PublicKey = <bastion-pubkey>
Endpoint = <bastion-public-ip>:51820
AllowedIPs = 10.200.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25
```

**Ключевые проблемы:**

| Проблема | Причина | Решение |
|----------|---------|---------|
| Конфликт подсетей | `ens3` и `wg0` оба в `10.0.0.0/24` | Перевести WG в `10.200.0.0/24` |
| `RTNETLINK answers: File exists` | `192.168.10.0/24` в `AllowedIPs` на bastion | Убрать, эта сеть уже локальна через eth1 |
| Глобальный MASQUERADE | Без `-o` ломает hostNetwork/Cilium | Привязать к `wg0` (controller) и `eth1` (bastion) |
| API server падает | Egress Gateway ломает static pods | Отключить Egress Gateway, использовать статические маршруты |

---

### 4.6. Мониторинг (VictoriaMetrics + vmagent + exporters)

**Стек:**
- **VictoriaMetrics** (single-node) — хранилище метрик, порт 8428
- **vmagent** — сбор метрик, push в VM через `remote_write`
- **node_exporter** — метрики ОС (CPU, RAM, диски, сеть)
- **wireguard_exporter** — метрики WG (handshake, peers)
- **postgres_exporter** — метрики PostgreSQL (connections, replication, transactions)
- **VMUI** — встроенный веб-интерфейс для PromQL

**Архитектура сбора:**
```
[node_exporter:9100] ─┐
[wireguard_exp:9586] ─┼→ [vmagent:8429] ──remote_write──→ [VictoriaMetrics:8428]
[postgres_exp:9187] ──┘
```

**Почему push (vmagent) вместо pull (Prometheus):**
- Устойчивость к разрывам туннеля — метрики буферизируются локально
- Не требует открытия портов извне
- Проще NAT и маршрутизация

**Доступ к VMUI:**
```
http://10.0.0.30:8428/vmui
```

---

## 5. Пошаговое развёртывание

### 5.1. Этап 0: Подготовка

**Требования:**
- Ansible 2.14+
- Terraform 1.5+
- kubectl
- SSH-доступ ко всем хостам
- API-токены: Timeweb Cloud, Cloudflare

**Секреты (GitHub Actions / локально):**
```bash
export TF_VAR_timeweb_token="..."
export TF_VAR_cloudflare_api_token="..."
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
```

---

### 5.2. Этап 1: Инфраструктура (Terraform)

**Облако (Timeweb):**
```bash
cd terraform/cloud
terraform init
terraform plan
terraform apply
```

**Локальный кластер (Libvirt):**
```bash
cd terraform/local_k8s
terraform init
terraform apply
```

**Monitoring VM:**
```bash
cd terraform/local_monitoring
terraform init
terraform apply
```

**Проверка outputs:**
```bash
terraform output node_private_ips
terraform output bastion_tunnel_domain
```

---

### 5.3. Этап 2: VPN (WireGuard)

```bash
ansible-playbook -i inventories/local.ini playbooks/deploy-vpn.yml
```

**Проверка:**
```bash
# С controller-0
ping -c 3 10.200.0.1
ping -c 3 192.168.10.4

# С bastion
ping -c 3 10.200.0.2
ping -c 3 10.0.0.10
```

---

### 5.4. Этап 3: Kubernetes-кластер

```bash
ansible-playbook -i inventories/local.ini playbooks/deploy-k8s.yml
```

**Проверка:**
```bash
kubectl get nodes
kubectl get pods -n kube-system
```

---

### 5.5. Этап 4: PostgreSQL HA

```bash
ansible-playbook -i inventories/cloud.ini playbooks/deploy-db.yml
```

**Проверка:**
```bash
# На любой ноде Patroni
patronictl -c /etc/patroni/patroni.yml list
consul members
psql -h 192.168.10.100 -U postgres -c "SELECT pg_is_in_recovery();"
```

---

### 5.6. Этап 5: Мониторинг

**Шаг 5.1: VictoriaMetrics + сборка артефактов**
```bash
ansible-playbook -i inventories/local.ini playbooks/deploy-monitoring.yml --limit monitoring-0
```

**Проверка:**
```bash
curl -s http://10.0.0.30:8428/health
# OK
```

**Шаг 5.2: Агенты на K8s-кластер**
```bash
ansible-playbook -i inventories/local.ini playbooks/deploy-agents-k8s.yml
```

**Шаг 5.3: Агенты на облако (bastion)**
```bash
ansible-playbook -i inventories/cloud.ini playbooks/deploy-agents-cloud.yml
```

**Шаг 5.4: PostgreSQL мониторинг**
```bash
ansible-playbook -i inventories/cloud.ini playbooks/deploy-postgres-monitoring.yml
```

**Финальная проверка:**
```bash
curl -s "http://10.0.0.30:8428/api/v1/query?query=up" | jq -r '.data.result[] | "\(.metric.instance) \(.metric.job) \(.value[1])"'
```

**Ожидаемый результат:**
```
bastion-host node 1
controller-0 node 1
worker-0 node 1
worker-1 node 1
pg-node-1 node 1
pg-node-2 node 1
pg-node-3 node 1
pg-node-1 postgres 1
pg-node-2 postgres 1
pg-node-3 postgres 1
bastion-host wireguard 1
controller-0 wireguard 1
```

---

## 6. Операционная документация

### 6.1. Управление PostgreSQL-кластером

**Состояние кластера:**
```bash
patronictl -c /etc/patroni/patroni.yml list
```

**Ручное переключение лидера (switchover):**
```bash
patronictl -c /etc/patroni/patroni.yml switchover
```

**Перезагрузка ноды:**
```bash
patronictl -c /etc/patroni/patroni.yml restart postgres-cluster <member_name>
```

**Проверка VIP:**
```bash
ip addr show eth1 | grep 192.168.10.100
```

**Подключение к БД:**
```bash
# Через VIP (чтение/запись)
psql -h 192.168.10.100 -p 5432 -U postgres

# Через HAProxy RO (только чтение, балансировка реплик)
psql -h 192.168.10.100 -p 5433 -U postgres
```

---

### 6.2. Управление Kubernetes

**Проверка нод:**
```bash
kubectl get nodes -o wide
```

**Проверка подов:**
```bash
kubectl get pods -A
```

**Доступ к PostgreSQL из пода:**
```bash
kubectl run pg-test --rm -it --image=busybox --restart=Never -- /bin/sh
/ # nc -zv 192.168.10.100 5432
```

---

### 6.3. Управление мониторингом

**VMUI:**
```
http://10.0.0.30:8428/vmui
```

**Полезные PromQL-запросы:**
```promql
# Доступность всех targets
up

# CPU usage
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory available
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100

# PostgreSQL connections
pg_stat_activity_count

# PostgreSQL replication lag
pg_stat_replication_pg_stat_replication_lag

# WireGuard last handshake
wireguard_latest_handshake_seconds

# Disk usage
100 - ((node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100)
```

**Перезапуск сервисов:**
```bash
# На любом хосте
sudo systemctl restart victoria-metrics
sudo systemctl restart vmagent
sudo systemctl restart node_exporter
sudo systemctl restart wireguard_exporter
sudo systemctl restart postgres_exporter
```

---

### 6.4. Диагностика VPN

**Статус туннеля:**
```bash
sudo wg show wg0
```

**Проверка handshake:**
```bash
sudo wg show wg0 latest-handshakes
```

**Проверка маршрутов:**
```bash
ip route | grep wg0
ip route | grep 192.168.10
ip route | grep 10.0.0
```

**Проверка NAT:**
```bash
sudo iptables -t nat -L POSTROUTING -n -v
```

---

## 7. Troubleshooting

### 7.1. Terraform

| Проблема | Решение |
|----------|---------|
| `Authentication error (10000)` | Cloudflare токен должен иметь права Account → Cloudflare Tunnel Edit |
| Модуль не находит провайдер | Добавить `required_providers` в каждый модуль |
| State конфликт | Убедиться, что backend S3 настроен корректно, нет параллельных запусков |

### 7.2. WireGuard

| Проблема | Решение |
|----------|---------|
| `RTNETLINK answers: File exists` | Не добавлять локальную сеть в `AllowedIPs` |
| Пинг не проходит | Проверить `AllowedIPs`, маршруты, `PersistentKeepalive` |
| `Required key not available` | IP назначения не входит в `AllowedIPs` ни одного пира |
| API server падает | Глобальный `MASQUERADE` без `-o` ломает hostNetwork — привязать к конкретному интерфейсу |

### 7.3. PostgreSQL / Patroni

| Проблема | Решение |
|----------|---------|
| Patroni не стартует | Проверить `consul members`, убедиться что Consul доступен |
| Failover не происходит | Проверить TTL в Consul, `patronictl list` |
| VIP не переключается | Проверить Keepalived (`systemctl status keepalived`), VRRP скрипт |
| Репликация лагает | `patronictl list` → столбец Lag, проверить сеть |

### 7.4. Мониторинг

| Проблема | Решение |
|----------|---------|
| `403 Access Denied` (Grafana apt) | Использовать VMUI или скачивать `.deb` с GitHub |
| `Network is unreachable` (скачивание) | Бинарники через `delegate_to: localhost` на controller |
| `Peer authentication failed` (postgres) | Запускать exporter от `postgres`, использовать unix-socket |
| Метрики не доходят в VM | Проверить маршруты (`ip r`), `vmagent` логи, `ufw`/`iptables` |
| `cargo not found` | Установить Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| `dirmngr not found` | `apt install dirmngr` |
| wireguard job на workers | `monitoring_agent_install_wireguard_exporter: false` в playbook |

---

## 8. Безопасность

- **Нет публичных IP у нод PostgreSQL** — доступ только через bastion
- **Cloudflare Tunnel** — SSH без белого IP, аутентификация через Zero Trust
- **WireGuard** — шифрование трафика между локалкой и облаком
- **Приватная сеть VPC** — изолированный трафик репликации и управления
- **Peer authentication** — postgres_exporter без пароля через unix-socket
- **iptables MASQUERADE** строго по интерфейсам — не ломает hostNetwork

---

## 9. Полезные команды

```bash
# === Terraform ===
cd terraform/cloud && terraform init && terraform plan && terraform apply
terraform output node_private_ips
terraform destroy

# === Ansible ===
ansible-playbook -i inventories/local.ini playbooks/deploy-monitoring.yml --limit monitoring-0
ansible-playbook -i inventories/local.ini playbooks/deploy-agents-k8s.yml
ansible-playbook -i inventories/cloud.ini playbooks/deploy-agents-cloud.yml
ansible-playbook -i inventories/cloud.ini playbooks/deploy-postgres-monitoring.yml

# === Kubernetes ===
kubectl get nodes -o wide
kubectl get pods -A
kubectl run pg-test --rm -it --image=busybox --restart=Never -- /bin/sh

# === PostgreSQL ===
patronictl -c /etc/patroni/patroni.yml list
patronictl -c /etc/patroni/patroni.yml switchover
consul members
psql -h 192.168.10.100 -U postgres -c "SELECT pg_is_in_recovery();"

# === WireGuard ===
sudo wg show wg0
sudo wg show wg0 latest-handshakes
ip route | grep wg0

# === Мониторинг ===
curl -s http://10.0.0.30:8428/health
curl -s "http://10.0.0.30:8428/api/v1/query?query=up" | jq .
curl -s "http://10.0.0.30:8428/api/v1/query?query=pg_up" | jq .
curl -s http://localhost:9100/metrics | grep node_cpu
curl -s http://localhost:9187/metrics | grep pg_up
curl -s http://localhost:9586/metrics | grep wireguard

# === VMUI ===
# Открыть в браузере: http://10.0.0.30:8428/vmui
```

---

*Проект разработан в процессе построения гибридной инфраструктуры с полным циклом: Terraform → Ansible → Kubernetes → PostgreSQL HA → Мониторинг.*

*Документация актуальна на апрель 2026.*

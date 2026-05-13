# Hybrid Infrastructure Documentation

> **Гибридная инфраструктура:** Локальный Kubernetes-кластер (Cilium) + Docker Swarm + облачный PostgreSQL HA (Patroni + Consul + Keepalived) + GitLab CI/CD + единый стек мониторинга (VictoriaMetrics) через зашифрованный WireGuard mesh-туннель.
>

---
## 📋 Оглавление

- [Hybrid Infrastructure Documentation](#hybrid-infrastructure-documentation)
  - [📋 Оглавление](#-оглавление)
  - [1. Архитектура проекта](#1-архитектура-проекта)
    - [1.1. Ключевые решения](#11-ключевые-решения)
    - [1.2. Сетевая топология](#12-сетевая-топология)
      - [Таблица адресации](#таблица-адресации)
      - [WG Peers (из group\_vars/all/vars.yml)](#wg-peers-из-group_varsallvarsyml)
      - [Маршрутизация](#маршрутизация)
  - [2. Структура репозитория](#2-структура-репозитория)
    - [2.1. roles\_path в ansible.cfg](#21-roles_path-в-ansiblecfg)
  - [3. Terraform — провижининг](#3-terraform--провижининг)
    - [3.1. Облако (Timeweb Cloud)](#31-облако-timeweb-cloud)
    - [3.2. Локальный кластер (Libvirt/KVM)](#32-локальный-кластер-libvirtkvm)
    - [3.3. Cloudflare Tunnel (Bastion)](#33-cloudflare-tunnel-bastion)
    - [3.4. Terraform State Backend (R2)](#34-terraform-state-backend-r2)
  - [4. Ansible — конфигурация](#4-ansible--конфигурация)
    - [4.1. Архитектурные принципы](#41-архитектурные-принципы)
    - [4.2. Структура ролей](#42-структура-ролей)
    - [4.3. Ansible Vault](#43-ansible-vault)
    - [4.4. Плейбуки](#44-плейбуки)
      - [deploy-db.yml](#deploy-dbyml)
      - [deploy-k8s.yml](#deploy-k8syml)
      - [deploy-gitlab.yml](#deploy-gitlabyml)
      - [deploy-vpn.yml](#deploy-vpnyml)
      - [deploy-monitoring.yml](#deploy-monitoringyml)
      - [deploy-swarm.yml](#deploy-swarmyml)
  - [5. Компоненты инфраструктуры](#5-компоненты-инфраструктуры)
    - [5.1. Kubernetes + Cilium](#51-kubernetes--cilium)
    - [5.2. Docker Swarm](#52-docker-swarm)
    - [5.3. PostgreSQL HA (Patroni + Consul + Keepalived)](#53-postgresql-ha-patroni--consul--keepalived)
    - [5.4. GitLab CE + Runner](#54-gitlab-ce--runner)
    - [5.5. WireGuard Mesh VPN](#55-wireguard-mesh-vpn)
    - [5.6. Мониторинг (VictoriaMetrics)](#56-мониторинг-victoriametrics)
  - [6. Пошаговое развёртывание](#6-пошаговое-развёртывание)
    - [6.1. Этап 0: Подготовка](#61-этап-0-подготовка)
    - [6.2. Этап 1: Инфраструктура (Terraform)](#62-этап-1-инфраструктура-terraform)
    - [6.3. Этап 2: VPN (WireGuard)](#63-этап-2-vpn-wireguard)
    - [6.4. Этап 3: Kubernetes](#64-этап-3-kubernetes)
    - [6.5. Этап 4: Docker Swarm](#65-этап-4-docker-swarm)
    - [6.6. Этап 5: PostgreSQL HA](#66-этап-5-postgresql-ha)
    - [6.7. Этап 6: GitLab](#67-этап-6-gitlab)
    - [6.8. Этап 7: Мониторинг](#68-этап-7-мониторинг)
  - [7. Операционная документация](#7-операционная-документация)
    - [7.1. Управление PostgreSQL](#71-управление-postgresql)
    - [7.2. Управление Kubernetes](#72-управление-kubernetes)
    - [7.3. Управление Docker Swarm](#73-управление-docker-swarm)
    - [7.4. Управление GitLab](#74-управление-gitlab)
    - [7.5. Управление мониторингом](#75-управление-мониторингом)
    - [7.6. Диагностика VPN](#76-диагностика-vpn)
  - [8. Troubleshooting](#8-troubleshooting)
    - [8.1. Terraform](#81-terraform)
    - [8.2. WireGuard](#82-wireguard)
    - [8.3. PostgreSQL / Patroni](#83-postgresql--patroni)
    - [8.4. Kubernetes](#84-kubernetes)
    - [8.5. Docker Swarm](#85-docker-swarm)
    - [8.6. GitLab](#86-gitlab)
    - [8.7. Мониторинг](#87-мониторинг)
    - [8.8. Ansible Vault](#88-ansible-vault)
  - [9. Безопасность](#9-безопасность)
  - [10. Полезные команды](#10-полезные-команды)
  - [11. Роадмап](#11-роадмап)
    - [✅ Выполнено](#-выполнено)
    - [🔄 Ближайшее](#-ближайшее)
    - [📋 Долгосрочное](#-долгосрочное)

---

## 1. Архитектура проекта

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              ЛОКАЛЬНЫЙ ДАТАЦЕНТР                                    │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                         Kubernetes Cluster (Cilium)                         │    │
│  │                                                                             │    │
│  │  ┌────────────────┐    ┌───────────────┐    ┌────────────────┐              │    │
│  │  │ controller-0   │    │   worker-0    │    │   worker-1     │              │    │
│  │  │ 10.0.0.10      │    │  10.0.0.20    │    │  10.0.0.21     │              │    │
│  │  │ kube-apiserver │    │ kubelet       │    │ kubelet        │              │    │
│  │  │ etcd           │    │ Cilium VXLAN  │    │ Cilium VXLAN   │              │    │
│  │  │ wg0:10.200.0.10│    │wg0:10.200.0.11│    │ wg0:10.200.0.12│              │    │
│  │  │ node_exporter  │    │ node_exporter │    │ node_exporter  │              │    │
│  │  │ vmagent        │    │ vmagent       │    │ vmagent        │              │    │
│  │  └──────┬─────────┘    └────┬──────────┘    └──────┬─────────┘              │    │
│  │         │                   │                      │                        │    │
│  │         └───────────────────┼──────────────────────┘                        │    │
│  │                             │                                               │    │
│  │                    ┌────────┴────────┐                                      │    │
│  │                    │  monitoring-0   │                                      │    │
│  │                    │   10.0.0.30     │                                      │    │
│  │                    │   wg0:10.200.0.3│                                      │    │
│  │                    │ VictoriaMetrics │◄─────────────────────────────────────┘    │
│  │                    │    (VMUI)       │              remote_write (push)          │
│  │                    │ 8428/vmui       │                                      │    │
│  │                    └────────┬────────┘                                      │    │
│  │                             │ wg0 (WireGuard)                               │    │
│  └─────────────────────────────┼───────────────────────────────────────────────┘    │
│                                │                                                    │
│  ┌─────────────────────────────┼───────────────────────────────────────────────┐    │
│  │        GitLab (local)       │                                               │    │
│  │  ┌──────────────┐    ┌──────┴─────────┐                                     │    │
│  │  │ GitLab Master│    │GitLab Runner   │                                     │    │
│  │  │ 10.0.0.80    │    │  10.0.0.81     │                                     │    │
│  │  │ (без WG)     │    │ wg0:10.200.0.20│                                     │    │
│  │  │ CE Omnibus   │    │ Shell Exec     │                                     │    │
│  │  └──────────────┘    └────────────────┘                                     │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────┼────────────────────────────────────────────────────┘
                                 │
                    ╔════════════╧════════════╗
                    ║   WireGuard UDP/51820   ║
                    ║      MESH VPN           ║
                    ╚════════════╤════════════╝
                                 │ 10.200.0.1
┌────────────────────────────────┼────────────────────────────────────────────────────┐
│                           ОБЛАКО (Timeweb Cloud)                                    │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │  Bastion Host (Cloudflare Tunnel) — HUB                                     │    │
│  │  ├─ eth0: публичный IP (туннель через Cloudflare Zero Trust)                │    │
│  │  ├─ eth1: 192.168.10.7 (VPC PostgreSQL)                                     │    │
│  │  ├─ wg0: 10.200.0.1/24 (WireGuard HUB)                                      │    │
│  │  │ node_exporter, vmagent, wireguard_exporter                               │    │
│  │  └─ NAT: MASQUERADE eth1 для WG-трафика                                     │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                              │                                                      │
│         ┌────────────────────┼────────────────────┐                                 │
│         ▼                    ▼                    ▼                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌─────────────┐                            │
│  │ pg-node-1    │    │ pg-node-2    │    │ pg-node-3   │                            │
│  │ 192.168.10.4 │    │ 192.168.10.5 │    │ 192.168.10.6│                            │
│  │ wg0:10.200.0.4│   │ wg0:10.200.0.5│   │ wg0:10.200.0.6│                          │
│  │ PostgreSQL   │    │ PostgreSQL   │    │ PostgreSQL  │                            │
│  │ Patroni      │    │ Patroni      │    │ Patroni     │                            │
│  │ Consul       │    │ Consul       │    │ Consul      │                            │
│  │ HAProxy      │    │ HAProxy      │    │ HAProxy     │                            │
│  │ Keepalived   │    │ Keepalived   │    │ Keepalived  │                            │
│  │ node_exporter│    │ node_exporter│    │node_exporter│                            │
│  │ vmagent      │    │ vmagent      │    │ vmagent     │                            │
│  │ postgres_exp │    │ postgres_exp │    │ postgres_exp│                            │
│  │          VIP: 192.168.10.100 (floating)             │                            │
│  └─────────────┘     └──────────────┘    └─────────────┘                            │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │              Docker Swarm VPC (192.168.10.0/24)                             │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                       │    │
│  │  │ swarm-node-1 │  │ swarm-node-2 │  │ swarm-node-3 │  (без WG, через NAT)  │    │
│  │  │ Manager      │  │ Worker       │  │ Worker       │                       │    │
│  │  │ 192.168.10.X │  │ 192.168.10.X │  │ 192.168.10.X │                       │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘                       │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                     │
│  Сеть: 192.168.10.0/24 (VPC) — изолированная, только IPv6-интернет                  │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1. Ключевые решения

| Решение | Обоснование |
|---------|------------|
| **WireGuard Mesh (Hub-Spoke)** | Bastion — единственная точка с публичным IP, все остальные — spoke'ы в туннеле |
| **Cilium без Egress Gateway** | Egress Gateway ломал hostNetwork static pods (etcd, kube-apiserver) при перезагрузке BPF |
| **Статические маршруты на workers** | Надёжнее Cilium Egress Gateway, не трогает control plane |
| **VictoriaMetrics вместо Prometheus** | Push-модель (vmagent → VM) устойчивее к разрывам туннеля |
| **VMUI вместо Grafana** | Встроенный интерфейс, нет зависимости от apt-репозиториев (Cloudflare 403) |
| **Peer auth для postgres_exporter** | Не требует пароля, работает через unix-socket |
| **cargo-сборка wireguard_exporter** | GitHub releases только исходники, cargo — надёжнее |
| **Бинарники через controller** | Облачные ноды имеют только IPv6-интернет, нет IPv4 |
| **Ansible Vault для PostgreSQL** | Пароли Patroni шифруются, CI/CD безопасен |
| **GitLab токен через диск контроллера** | Нет хрупкого `hostvars` между ролями, работает при `--limit` |
| **FQCN везде** | `ansible.builtin.`, `ansible.posix.`, `kubernetes.core.` |

### 1.2. Сетевая топология

#### Таблица адресации

| Сеть | Назначение | Хосты / Диапазон |
|------|-----------|------------------|
| `10.0.0.0/24` | Локальная сеть кластера | controller-0 (10.0.0.10), worker-0 (10.0.0.20), worker-1 (10.0.0.21), monitoring-0 (10.0.0.30), gitlab-master (10.0.0.80), gitlab-runner (10.0.0.81) |
| `10.244.0.0/16` | Pod CIDR (Cilium VXLAN) | Все поды Kubernetes |
| `10.200.0.0/24` | **WireGuard Mesh туннель** | bastion (10.200.0.1), monitoring-0 (10.200.0.3), pg-node-1 (10.200.0.4), pg-node-2 (10.200.0.5), pg-node-3 (10.200.0.6), controller-0 (10.200.0.10), worker-0 (10.200.0.11), worker-1 (10.200.0.12), gitlab-runner-1 (10.200.0.20) |
| `192.168.10.0/24` | Cloud VPC (Timeweb) | pg-node-1 (192.168.10.4), pg-node-2 (192.168.10.5), pg-node-3 (192.168.10.6), bastion eth1 (192.168.10.7), VIP (192.168.10.100), swarm-ноды |

#### WG Peers (из group_vars/all/vars.yml)

```yaml
wg_peers:
  bastion-host:
    tunnel_ip: "10.200.0.1"
    is_hub: true
  monitoring-0:
    tunnel_ip: "10.200.0.3"
    is_hub: false
  pg-node-1:
    tunnel_ip: "10.200.0.4"
    is_hub: false
  pg-node-2:
    tunnel_ip: "10.200.0.5"
    is_hub: false
  pg-node-3:
    tunnel_ip: "10.200.0.6"
    is_hub: false
  controller-0:
    tunnel_ip: "10.200.0.10"
    is_hub: false
  worker-0:
    tunnel_ip: "10.200.0.11"
    is_hub: false
  worker-1:
    tunnel_ip: "10.200.0.12"
    is_hub: false
  gitlab-runner-1:
    tunnel_ip: "10.200.0.20"
    is_hub: false
```

#### Маршрутизация

**Локальный кластер → Облако:**
```
Pod (10.244.x.x) → Cilium VXLAN → worker (10.0.0.x) → controller-0 (10.0.0.10) → wg0 → bastion → PostgreSQL (192.168.10.x)
```

**WG Mesh трафик:**
```
spoke (любой) → wg0 → bastion (hub) → wg0 → другой spoke
```

**Облако → Локальный кластер (мониторинг):**
```
pg-node (192.168.10.x) → bastion (192.168.10.7) → wg0 → monitoring-0 (10.200.0.3) → 10.0.0.30
```

**Статические маршруты:**

| Хост | Маршрут | Gateway | Интерфейс | Назначение |
|------|---------|---------|-----------|------------|
| worker-0/1 | `192.168.10.0/24` | `10.0.0.10` | ens3 | Доступ к PostgreSQL |
| controller-0 | `192.168.10.0/24` | `dev wg0` | wg0 | Через туннель |
| monitoring-0 | `192.168.10.0/24` | `10.0.0.10` | ens3 | Через controller-0 |
| bastion | `10.0.0.0/24` | `10.200.0.10` | wg0 | Обратно в кластер |
| pg-node-1/2/3 | `10.0.0.0/24` | `192.168.10.7` | eth1 | remote_write в VM |

---

## 2. Структура репозитория

```txt
.
├── ansible/
│   ├── ansible.cfg
│   ├── .gitlab-tokens/
│   │   └── gitlab_runner_token
│   ├── .wg-keys/
│   │   ├── bastion-host.pub
│   │   ├── controller-0.pub
│   │   ├── worker-0.pub
│   │   ├── worker-1.pub
│   │   ├── monitoring-0.pub
│   │   ├── pg-node-1.pub
│   │   ├── pg-node-2.pub
│   │   ├── pg-node-3.pub
│   │   └── gitlab-runner-1.pub
│   ├── inventories/
│   │   ├── cloud.ini              # Terraform-generated (bastion, pg, monitoring)
│   │   ├── local.ini              # Terraform-generated (k8s, gitlab)
│   │   ├── gitlab.ini             # Terraform-generated (gitlab)
│   │   └── group_vars/
│   │       ├── all/
│   │       │   ├── vars.yml       # wg_peers, monitoring_network_cidr, порты
│   │       │   └── vault.yml      # (зарезервировано)
│   │       ├── bastion/
│   │       │   └── vars.yml
│   │       ├── gitlab_runner/
│   │       │   └── vars.yml
│   │       ├── monitoring/
│   │       │   └── vars.yml
│   │       └── postgres_nodes/
│   │           ├── vars.yml       # маппинг vault_* → обычные переменные
│   │           └── vault.yml      # Зашифрованные пароли Patroni
│   ├── playbooks/
│   │   ├── deploy-db.yml
│   │   ├── deploy-gitlab.yml
│   │   ├── deploy-k8s.yml
│   │   ├── deploy-monitoring.yml
│   │   ├── deploy-swarm.yml
│   │   └── deploy-vpn.yml
│   └── roles/
│       ├── common/                # Базовая настройка ОС
│       ├── docker_swarm/
│       │   └── swarm/             # Docker, Swarm init/join, overlay networks
│       ├── gitlab/
│       │   ├── master/            # GitLab CE, токен на диск контроллера
│       │   └── runner/            # GitLab Runner, регистрация через кэшированный токен
│       ├── kubernetes/
│       │   ├── prep/              # Swap off, kernel modules, sysctl, BPF
│       │   ├── container_runtime/ # containerd, SystemdCgroup = true
│       │   ├── install/           # kubeadm, kubelet, kubectl, crictl, CNI plugins
│       │   ├── control_plane/     # kubeadm init, kubeconfig, join command
│       │   ├── cni/               # Helm + Cilium (kube-proxy replacement)
│       │   └── workers/           # kubeadm join
│       ├── monitoring/
│       │   ├── server/            # VictoriaMetrics + VMUI
│       │   ├── node_exporter/
│       │   ├── vmagent/
│       │   ├── wireguard_exporter/
│       │   └── postgres_exporter/
│       ├── postgres_cluster/
│       │   ├── consul/
│       │   ├── patroni/
│       │   ├── haproxy/
│       │   └── keepalived/
│       └── vpn/
│           ├── bastion_nat/       # NAT + FORWARD + MASQUERADE для всего VPC
│           ├── routes/            # default route + DNS для vpc_node
│           └── wireguard/         # WG mesh (hub-spoke)
├── terraform/
│   ├── cloud/
│   │   ├── backend.tf             # S3-backend (Cloudflare R2)
│   │   ├── main.tf                # Ресурсы Timeweb + Cloudflare Tunnel
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── modules/
│   │       └── twc_node/          # Модуль для создания нод
│   ├── local_k8s/
│   │   ├── main.tf                # Libvirt VMs для локального K8s
│   │   ├── network.tf
│   │   └── modules/
│   │       └── libvirt_node/
│   ├── local_monitoring/
│   │   └── main.tf                # VM для monitoring-0
│   ├── local_gitlab/
│   │   └── main.tf                # VMs для GitLab master + runner
│   └── templates/
│       ├── cloud_init_local.cfg
│       ├── inventory_cloud.tmpl
│       ├── inventory_local.tmpl
│       └── setup_cloud.sh.tpl     # Cloud-init для bastion
└── README.md                      # Этот файл
```

### 2.1. roles_path в ansible.cfg

```ini
[defaults]
roles_path = ./roles:./roles/monitoring:./roles/vpn:./roles/postgres_cluster:./roles/kubernetes:./roles/docker_swarm:./roles/gitlab
```

---

## 3. Terraform — провижининг

### 3.1. Облако (Timeweb Cloud)

**Провайдеры:** Timeweb Cloud (`twc`) + Cloudflare (`cloudflare`)

**Что создаётся:**
- 3x Cloud VPS для PostgreSQL (приватная сеть `192.168.10.0/24`, без публичных IP)
- Bastion-хост с Cloudflare Tunnel (Zero Trust, нет белого IP)
- VPC-сеть, SSH-ключи, проект
- S3-backend для state в Cloudflare R2

**Запуск:**

```bash
cd terraform/cloud
terraform init
terraform plan
terraform apply
```

### 3.2. Локальный кластер (Libvirt/KVM)

**Что создаётся:**

- Kubernetes ноды (controller + workers) — Libvirt VMs
- Monitoring VM (monitoring-0)
- GitLab VMs (master + runner)

```bash
cd terraform/local_k8s && terraform init && terraform apply
cd terraform/local_monitoring && terraform init && terraform apply
cd terraform/local_gitlab && terraform init && terraform apply
```

### 3.3. Cloudflare Tunnel (Bastion)

**Архитектура:**

- Bastion НЕ имеет публичного IP
- `cloudflared` устанавливает исходящее соединение с Cloudflare
- SSH доступ через домен (например, `bastion.your-domain.com`)
- Zero Trust аутентификация

**Требования к токену Cloudflare:**

- Account → Cloudflare Tunnel → Edit
- Zone → DNS → Edit

**SSH config (`~/.ssh/config`):**

```conf
Host bastion.*
    ProxyCommand /usr/bin/cloudflared access ssh --hostname %h
    User root
    IdentityFile ~/.ssh/ansible_key
```

### 3.4. Terraform State Backend (R2)

```hcl
terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "postgres-cluster/terraform.tfstate"
    region = "auto"

    endpoints = {
      s3 = "https://<account_id>.r2.cloudflarestorage.com"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
```

**Аутентификация:**

```bash
export AWS_ACCESS_KEY_ID="r2_access_key"
export AWS_SECRET_ACCESS_KEY="r2_secret_key"
terraform init
```

---

## 4. Ansible — конфигурация

### 4.1. Архитектурные принципы

1. **Роли по домену**, не по техническому слою. Нет god roles.
2. **Одна роль = один компонент.** Каждая роль самодостаточна: пользователь, бинарник, systemd, firewall.
3. **Контроллер как кэш.** Бинарники скачиваются на Gentoo-контроллер (`delegate_to: localhost`), оттуда деплоятся.
4. **INI inventory + group_vars.** Terraform генерирует INI, переменные живут в `group_vars`.
5. **Vault для секретов.** Все чувствительные переменные в `vault.yml`.
6. **WG mesh самодостоятельный.** Ключи на контроллере в `.wg-keys/`, не зависят от `hostvars`.
7. **Два прогона для WG.** Сначала `keys`, потом `config`.
8. **DNS на VPC-нодах.** `systemd-resolved` отключается, статический `8.8.8.8`.
9. **FQCN везде.** `ansible.builtin.`, `ansible.posix.`, `kubernetes.core.`
10. **Firewall атомарно.** Каждая роль открывает только свой порт.
11. **Токены через диск контроллера.** GitLab runner token сохраняется мастером в `.gitlab-tokens/`, раннер читает оттуда.

### 4.2. Структура ролей

```txt
roles/
├── common/                # Базовая настройка ОС
├── docker_swarm/
│   └── swarm/             # Docker, Swarm init/join, overlay networks
├── gitlab/
│   ├── master/            # GitLab CE, токен на диск контроллера
│   └── runner/            # GitLab Runner, регистрация через кэшированный токен
├── kubernetes/
│   ├── prep/              # Swap off, kernel modules, sysctl, BPF
│   ├── container_runtime/ # containerd, SystemdCgroup = true
│   ├── install/           # kubeadm, kubelet, kubectl, crictl, CNI plugins
│   ├── control_plane/     # kubeadm init, kubeconfig, join command
│   ├── cni/               # Helm + Cilium (kube-proxy replacement)
│   └── workers/           # kubeadm join
├── monitoring/
│   ├── server/            # VictoriaMetrics + VMUI
│   ├── node_exporter/
│   ├── vmagent/
│   ├── wireguard_exporter/
│   └── postgres_exporter/
├── postgres_cluster/
│   ├── consul/
│   ├── patroni/
│   ├── haproxy/
│   └── keepalived/
└── vpn/
    ├── bastion_nat/       # NAT + FORWARD + MASQUERADE для всего VPC
    ├── routes/            # default route + DNS для vpc_node
    └── wireguard/         # WG mesh (hub-spoke)
```

### 4.3. Ansible Vault

**Что шифруется:**

| Секрет | Где хранить | Статус |
|--------|-------------|--------|
| Patroni replication password | `group_vars/postgres_nodes/vault.yml` | ✅ Внедрено |
| Patroni superuser password | `group_vars/postgres_nodes/vault.yml` | ✅ Внедрено |
| Patroni rewind password | `group_vars/postgres_nodes/vault.yml` | ✅ Внедрено |
| GitLab root password | `group_vars/all/vault.yml` | 🔄 Запланировано |
| GitLab runner token | `.gitlab-tokens/` (диск) | ✅ Работает |
| WireGuard приватные ключи | `.wg-keys/` (диск) | ✅ Рекомендуется оставить |

**Быстрый старт с Vault:**

```bash
# Создать vault-файл
cd ansible/
ansible-vault create inventories/group_vars/postgres_nodes/vault.yml

# Содержимое:
---
vault_patroni_replication_password: "supersecret-repl"
vault_patroni_superuser_password: "supersecret-super"
vault_patroni_rewind_password: "supersecret-rewind"

# Маппинг в vars.yml:
patroni_replication_password: "{{ vault_patroni_replication_password }}"
patroni_superuser_password: "{{ vault_patroni_superuser_password }}"
patroni_rewind_password: "{{ vault_patroni_rewind_password }}"
```

**Запуск с Vault:**

```bash
# Интерактивный ввод
ansible-playbook -i inventories/ playbooks/deploy-db.yml --ask-vault-pass

# Файл с паролем (для локальной работы)
echo "your_vault_password" > ~/.ansible_vault_pass
chmod 600 ~/.ansible_vault_pass
ansible-playbook -i inventories/ playbooks/deploy-db.yml --vault-password-file ~/.ansible_vault_pass
```

**CI/CD (GitLab):**

```yaml
deploy-db:
  stage: deploy
  script:
    - echo "$ANSIBLE_VAULT_PASSWORD" > /tmp/.vault_pass
    - chmod 600 /tmp/.vault_pass
    - ansible-playbook -i inventories/ playbooks/deploy-db.yml --vault-password-file /tmp/.vault_pass --diff
    - rm -f /tmp/.vault_pass
```

### 4.4. Плейбуки

#### deploy-db.yml

```yaml
---
- name: Deploy PostgreSQL HA cluster
  hosts: postgres_nodes
  become: true
  gather_facts: true

  pre_tasks:
    - name: Ensure base OS configuration
      ansible.builtin.import_role:
        name: common

  roles:
    - role: postgres_cluster/consul
      tags: [postgres, consul]
    - role: postgres_cluster/patroni
      tags: [postgres, patroni]
    - role: postgres_cluster/haproxy
      tags: [postgres, haproxy]
    - role: postgres_cluster/keepalived
      tags: [postgres, keepalived]
```

#### deploy-k8s.yml

```yaml
---
- name: Prepare all Kubernetes nodes
  hosts: k8s
  become: true
  gather_facts: true

  pre_tasks:
    - name: Ensure base OS configuration
      ansible.builtin.import_role:
        name: common

  roles:
    - role: kubernetes/prep
      tags: [k8s, prep]
    - role: kubernetes/container_runtime
      tags: [k8s, container_runtime]
    - role: kubernetes/install
      tags: [k8s, install]

- name: Initialize Kubernetes Control Plane
  hosts: controllers
  become: true
  gather_facts: true

  roles:
    - role: kubernetes/control_plane
      tags: [k8s, control_plane]
    - role: kubernetes/cni
      tags: [k8s, cni]

- name: Join Worker Nodes
  hosts: workers
  become: true
  gather_facts: true

  roles:
    - role: kubernetes/workers
      tags: [k8s, workers]
```

#### deploy-gitlab.yml

```yaml
---
- name: Deploy GitLab Master
  hosts: gitlab_master
  become: true
  gather_facts: true

  pre_tasks:
    - name: Ensure base OS configuration
      ansible.builtin.import_role:
        name: common

  roles:
    - role: gitlab/master
      tags: [gitlab, master]

- name: Deploy GitLab Runner
  hosts: gitlab_runner
  become: true
  gather_facts: true

  pre_tasks:
    - name: Ensure base OS configuration
      ansible.builtin.import_role:
        name: common

  vars:
    gitlab_master_url: "http://{{ hostvars[groups['gitlab_master'][0]]['ansible_default_ipv4']['address'] }}"

  roles:
    - role: gitlab/runner
      tags: [gitlab, runner]
```

#### deploy-vpn.yml

```yaml
---
- name: Setup bastion NAT
  hosts: bastion
  become: true
  roles:
    - role: vpn/bastion_nat
      tags: [vpn, nat]

- name: Setup routes for all VPC nodes
  hosts: all
  become: true
  roles:
    - role: vpn/routes
      tags: [vpn, routes]
      when: vpc_node | default(false) | bool

- name: Setup WireGuard
  hosts: all
  become: true
  roles:
    - role: vpn/wireguard
      tags: [vpn, wireguard]
      when: inventory_hostname in wg_peers
```

#### deploy-monitoring.yml

```yaml
---
- name: Deploy VictoriaMetrics server
  hosts: monitoring
  become: true
  gather_facts: true

  pre_tasks:
    - name: Ensure base OS configuration
      ansible.builtin.import_role:
        name: common

  roles:
    - role: monitoring/server
      tags: [monitoring, server]

- name: Deploy monitoring agents
  hosts: all
  become: true
  gather_facts: true

  roles:
    - role: monitoring/node_exporter
      tags: [monitoring, node_exporter]
    - role: monitoring/vmagent
      tags: [monitoring, vmagent]
    - role: monitoring/wireguard_exporter
      tags: [monitoring, wireguard_exporter]
      when: wireguard_exporter_enabled | default(false) | bool
    - role: monitoring/postgres_exporter
      tags: [monitoring, postgres_exporter]
      when: postgres_exporter_enabled | default(false) | bool
```

#### deploy-swarm.yml

```yaml
---
- name: Deploy Docker Swarm
  hosts: swarm_nodes
  become: true
  gather_facts: true

  pre_tasks:
    - name: Ensure base OS configuration
      ansible.builtin.import_role:
        name: common

  roles:
    - role: docker_swarm/swarm
      tags: [swarm, docker]
```

---

## 5. Компоненты инфраструктуры

### 5.1. Kubernetes + Cilium

**Версия:** Kubernetes 1.35.3 (kubeadm), Cilium (CNI)

**Ключевые решения:**

- `kubeProxyReplacement: true` — Cilium заменяет kube-proxy
- `egressGateway.enabled: false` — отключён, ломает control plane
- Статические маршруты на workers вместо Egress Gateway
- Бинарники скачиваются на контроллер (`delegate_to: localhost`)

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
  enabled: false
```

**Путь пакета от Pod к PostgreSQL:**

```
Pod (10.244.x.x) → Cilium VXLAN → worker (10.0.0.x) → controller-0 (10.0.0.10) → wg0 → bastion → PostgreSQL (192.168.10.x)
```

### 5.2. Docker Swarm

**Стек:** Docker CE + Swarm mode + overlay networks

**Архитектура:**

- 1 Manager + 2 Workers (минимум для HA)
- Overlay network `swarm-public` (attachable)
- Нет публичных IP у нод — доступ через bastion NAT
- Ноды НЕ в WireGuard mesh (только через bastion)

**Порты:**

| Порт | Протокол | Назначение |
|------|----------|------------|
| 2377 | TCP | Управление кластером |
| 7946 | TCP/UDP | Gossip-протокол |
| 4789 | UDP | VXLAN overlay |

**Инициализация:**

```bash
# На manager
docker swarm init --advertise-addr 192.168.10.7

# На workers
docker swarm join --token <token> 192.168.10.7:2377
```

**Критичные фиксы:**

- `live-restore: true` **несовместим со Swarm mode** — убран из `daemon.json`
- Маршруты через `vpn/routes` + флаг `vpc_node`, не отдельная роль
- NAT на bastion для доступа в интернет

### 5.3. PostgreSQL HA (Patroni + Consul + Keepalived)

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

**Критичные фиксы:**

- `ip_nonlocal_bind=1` для HAProxy (биндится на VIP, который есть только на MASTER)
- Keepalived priority — явный словарь, не `regex_replace` от hostname
- Порядок ролей: consul → patroni → haproxy → keepalived

**Проверка состояния:**

```bash
patronictl -c /etc/patroni/patroni.yml list
consul members
ip addr show eth1 | grep 192.168.10.100
```

### 5.4. GitLab CE + Runner

**Архитектура:**

- **GitLab Master** (Omnibus CE) — 10.0.0.80, 4 vCPU, 8 GB RAM
  - **НЕ** в WireGuard mesh (доступ только из локальной сети)
- **GitLab Runner** (Shell executor) — 10.0.0.81, 2 vCPU, 4 GB RAM
  - **В** WireGuard mesh (10.200.0.20) — для деплоя в облако

**Ключевые решения:**

- `gitlab.rb` параметризован через переменные
- Runner token кэшируется на диске контроллера (`.gitlab-tokens/`)
- Раннер читает токен через `slurp` + `delegate_to: localhost`
- Docker убран из раннера — ставится отдельной ролью `docker_swarm/swarm`

**Кэширование токена (мастер):**

```yaml
- name: Save runner token to controller cache
  ansible.builtin.copy:
    content: "{{ gitlab_runner_token_raw.stdout | trim }}"
    dest: "{{ gitlab_token_cache_dir }}/gitlab_runner_token"
    mode: '0600'
  delegate_to: localhost
  become: false
  no_log: true
```

**Чтение токена (раннер):**

```yaml
- name: Read runner token from controller cache
  ansible.builtin.slurp:
    src: "{{ gitlab_token_cache_dir }}/gitlab_runner_token"
  delegate_to: localhost
  become: false
  register: runner_token_cached
  no_log: true
  ignore_errors: true
```

### 5.5. WireGuard Mesh VPN

**Топология:** Hub-Spoke Mesh

- **Hub:** bastion (10.200.0.1) — единственная точка с публичным IP
- **Spokes:** все остальные ноды (monitoring, pg, k8s, gitlab-runner)

**WG Peers:**

```yaml
wg_peers:
  bastion-host:
    tunnel_ip: "10.200.0.1"
    is_hub: true
  monitoring-0:
    tunnel_ip: "10.200.0.3"
    is_hub: false
  pg-node-1:
    tunnel_ip: "10.200.0.4"
    is_hub: false
  pg-node-2:
    tunnel_ip: "10.200.0.5"
    is_hub: false
  pg-node-3:
    tunnel_ip: "10.200.0.6"
    is_hub: false
  controller-0:
    tunnel_ip: "10.200.0.10"
    is_hub: false
  worker-0:
    tunnel_ip: "10.200.0.11"
    is_hub: false
  worker-1:
    tunnel_ip: "10.200.0.12"
    is_hub: false
  gitlab-runner-1:
    tunnel_ip: "10.200.0.20"
    is_hub: false
```

**Конфигурация (пример для spoke):**

```ini
[Interface]
Address = 10.200.0.10/24
PrivateKey = <key>

[Peer]
PublicKey = <bastion-pubkey>
Endpoint = <bastion-public-ip>:51820
AllowedIPs = 10.200.0.0/24
PersistentKeepalive = 25
```

**Конфигурация bastion (hub):**

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <key>

[Peer]
# controller-0
PublicKey = <pubkey>
AllowedIPs = 10.200.0.10/32

[Peer]
# monitoring-0
PublicKey = <pubkey>
AllowedIPs = 10.200.0.3/32

# ... и так для каждого spoke
```

**Динамический endpoint (fallback цепочка):**

```jinja2
{% set peer_endpoint = peer.endpoint_host | default(hostvars[peer_name]['wg_endpoint_host'] | default(hostvars[peer_name]['ansible_host'] | default(wg_bastion_endpoint | default('')))) %}
```

Приоритет:

1. `peer.endpoint_host` из `wg_peers`
2. `hostvars[peer_name]['wg_endpoint_host']` (из Terraform-шаблона)
3. `hostvars[peer_name]['ansible_host']`
4. `wg_bastion_endpoint` (из `group_vars/all`)

**Ключевые проблемы и решения:**

| Проблема | Причина | Решение |
|----------|---------|---------|
| Конфликт подсетей | `ens3` и `wg0` оба в `10.0.0.0/24` | Перевести WG в `10.200.0.0/24` |
| `RTNETLINK answers: File exists` | `192.168.10.0/24` в `AllowedIPs` на bastion | Убрать, эта сеть уже локальна через eth1 |
| Глобальный MASQUERADE | Без `-o` ломает hostNetwork/Cilium | Привязать к `wg0` (controller) и `eth1` (bastion) |
| API server падает | Egress Gateway ломает static pods | Отключить Egress Gateway, использовать статические маршруты |

### 5.6. Мониторинг (VictoriaMetrics)

**Стек:**

- **VictoriaMetrics** (single-node) — хранилище метрик, порт 8428
- **vmagent** — сбор метрик, push в VM через `remote_write`
- **node_exporter** — метрики ОС (CPU, RAM, диски, сеть)
- **wireguard_exporter** — метрики WG (handshake, peers)
- **postgres_exporter** — метрики PostgreSQL (connections, replication, transactions)
- **VMUI** — встроенный веб-интерфейс для PromQL

**Архитектура сбора:**

```txt
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

**Критичные фиксы:**

- `unarchive` с `remote_src: true` падает — использовать `delegate_to: localhost`
- `chown` на `/usr/local/bin` — разделить на две задачи (data_dir с owner, bin_dir без)
- `vmagent` падает с `status=217/USER` — явное создание user/group в начале роли
- `hostvars` между разными inventory-файлами — ключи на диске контроллера (`.wg-keys/`)
- `lookup('file')` возвращает `None` — `| default('', true)` + проверка `| length > 0`

---

## 6. Пошаговое развёртывание

### 6.1. Этап 0: Подготовка

**Требования:**

- Ansible 2.14+
- Terraform 1.5+
- kubectl
- SSH-доступ ко всем хостам
- API-токены: Timeweb Cloud, Cloudflare
- Vault password (для PostgreSQL)

**Секреты:**

```bash
export TF_VAR_timeweb_token="..."
export TF_VAR_cloudflare_api_token="..."
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
# Vault password — в ~/.ansible_vault_pass (chmod 600)
```

### 6.2. Этап 1: Инфраструктура (Terraform)

**Облако (Timeweb):**

```bash
cd terraform/cloud
terraform init
terraform plan
terraform apply
```

**Локальный кластер (Libvirt):**

```bash
cd terraform/local_k8s && terraform init && terraform apply
cd terraform/local_monitoring && terraform init && terraform apply
cd terraform/local_gitlab && terraform init && terraform apply
```

### 6.3. Этап 2: VPN (WireGuard)

```bash
# Прогон 1: генерация ключей
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml --tags keys

# Прогон 2: конфигурация
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml --tags config
```

**Проверка:**
```bash
ansible bastion-host -i inventories/ -b -m shell -a "wg show"
ansible pg-node-1 -i inventories/ -m shell -a "ping -c 3 10.200.0.3"
ansible controller-0 -i inventories/ -m shell -a "ping -c 3 10.200.0.1"
```

### 6.4. Этап 3: Kubernetes

```bash
ansible-playbook -i inventories/ playbooks/deploy-k8s.yml
```

**Проверка:**
```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

### 6.5. Этап 4: Docker Swarm

```bash
ansible-playbook -i inventories/ playbooks/deploy-swarm.yml
```

**Проверка:**
```bash
ansible swarm-node-1 -i inventories/ -m shell -a "docker node ls"
ansible swarm-node-1 -i inventories/ -m shell -a "docker network ls | grep overlay"
```

### 6.6. Этап 5: PostgreSQL HA

```bash
ansible-playbook -i inventories/ playbooks/deploy-db.yml --ask-vault-pass
```

**Проверка:**

```bash
patronictl -c /etc/patroni/patroni.yml list
consul members
psql -h 192.168.10.100 -U postgres -c "SELECT pg_is_in_recovery();"
```

### 6.7. Этап 6: GitLab

```bash
ansible-playbook -i inventories/ playbooks/deploy-gitlab.yml
```

**Проверка:**

```bash
ansible gitlab-master-0 -i inventories/ -m shell -a "gitlab-ctl status"
ansible gitlab-runner-0 -i inventories/ -b -m shell -a "gitlab-runner list"
```

### 6.8. Этап 7: Мониторинг

```bash
ansible-playbook -i inventories/ playbooks/deploy-monitoring.yml
```

**Проверка:**

```bash
curl -s http://10.0.0.30:8428/health
curl -s "http://10.0.0.30:8428/api/v1/query?query=up" | jq .
```

---

## 7. Операционная документация

### 7.1. Управление PostgreSQL

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

# Через HAProxy RO (только чтение)
psql -h 192.168.10.100 -p 5433 -U postgres
```

### 7.2. Управление Kubernetes

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

### 7.3. Управление Docker Swarm

**Состояние кластера:**

```bash
docker node ls
docker service ls
docker service ps <service>
```

**Обновление сервиса:**

```bash
docker service update --image nginx:1.31 myapp
```

### 7.4. Управление GitLab

**Статус:**

```bash
gitlab-ctl status
gitlab-ctl reconfigure  # 5-15 минут!
```

**Бэкап:**

```bash
sudo gitlab-backup create
```

**Runner:**

```bash
gitlab-runner list
gitlab-runner verify
```

### 7.5. Управление мониторингом

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
sudo systemctl restart victoria-metrics
sudo systemctl restart vmagent
sudo systemctl restart node_exporter
sudo systemctl restart wireguard_exporter
sudo systemctl restart postgres_exporter
```

### 7.6. Диагностика VPN

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

## 8. Troubleshooting

### 8.1. Terraform

| Проблема | Решение |
|----------|---------|
| `Authentication error (10000)` | Cloudflare токен должен иметь права Account → Cloudflare Tunnel Edit |
| Модуль не находит провайдер | Добавить `required_providers` в каждый модуль |
| State конфликт | Убедиться, что backend S3 настроен корректно |

### 8.2. WireGuard

| Проблема | Решение |
|----------|---------|
| `RTNETLINK answers: File exists` | Не добавлять локальную сеть в `AllowedIPs` |
| Пинг не проходит | Проверить `AllowedIPs`, маршруты, `PersistentKeepalive` |
| `Required key not available` | IP назначения не входит в `AllowedIPs` |
| API server падает | Глобальный `MASQUERADE` без `-o` ломает hostNetwork |
| Нет связи между spoke'ами | В hub-spoke трафик идёт через bastion, проверить forwarding |

### 8.3. PostgreSQL / Patroni

| Проблема | Решение |
|----------|---------|
| Patroni не стартует | Проверить `consul members` |
| Failover не происходит | Проверить TTL в Consul, `patronictl list` |
| VIP не переключается | Проверить Keepalived, VRRP скрипт |
| Репликация лагает | `patronictl list` → Lag, проверить сеть |

### 8.4. Kubernetes

| Проблема | Решение |
|----------|---------|
| etcd/apiserver падает | Проверить Egress Gateway — должен быть отключён |
| Cilium не стартует | Проверить `devices`, `kubeProxyReplacement` |
| Pod не достаёт до БД | Проверить маршрут на worker: `192.168.10.0/24 via 10.0.0.10` |

### 8.5. Docker Swarm

| Проблема | Решение |
|----------|---------|
| `live-restore incompatible` | Убрать `live-restore` из `daemon.json` |
| Узлы не видят друг друга | Проверить порты 2377, 7946, 4789 |
| Нет интернета на нодах | Проверить NAT на bastion, маршрут по умолчанию |

### 8.6. GitLab

| Проблема | Решение |
|----------|---------|
| `gitlab-ctl reconfigure` падает | Минимум 8 GB RAM (или 4 GB + 4 GB swap) |
| Runner не регистрируется | Проверить `.gitlab-tokens/gitlab_runner_token` на контроллере |
| 401 на API | Использовать `gitlab-ctl status` вместо API |

### 8.7. Мониторинг

| Проблема | Решение |
|----------|---------|
| `403 Access Denied` (Grafana apt) | Использовать VMUI или скачивать `.deb` с GitHub |
| `Network is unreachable` | Бинарники через `delegate_to: localhost` |
| `Peer authentication failed` | Запускать exporter от `postgres`, unix-socket |
| Метрики не доходят в VM | Проверить маршруты, `vmagent` логи |
| `cargo not found` | Установить Rust |

### 8.8. Ansible Vault

| Проблема | Решение |
|----------|---------|
| `Attempting to decrypt but no vault secrets` | Забыли `--ask-vault-pass` или `--vault-password-file` |
| `vault_xxx` не определена | Проверить путь `vault.yml` и группу хоста |
| Переменная не подхватывается | Проверить маппинг в `vars.yml` |

---

## 9. Безопасность

- **Нет публичных IP у нод PostgreSQL** — доступ только через bastion
- **Cloudflare Tunnel** — SSH без белого IP, аутентификация через Zero Trust
- **WireGuard Mesh** — шифрование трафика между всеми нодами
- **Приватная сеть VPC** — изолированный трафик репликации и управления
- **Peer authentication** — postgres_exporter без пароля через unix-socket
- **iptables MASQUERADE** строго по интерфейсам
- **Ansible Vault** — пароли Patroni зашифрованы
- **Токены на диске** — GitLab runner token не в `hostvars`

---

## 10. Полезные команды

```bash
# === Terraform ===
cd terraform/cloud && terraform init && terraform plan && terraform apply
terraform output node_private_ips

# === Ansible ===
ansible-playbook -i inventories/ playbooks/deploy-db.yml --ask-vault-pass
ansible-playbook -i inventories/ playbooks/deploy-k8s.yml
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml --tags wireguard
ansible-playbook -i inventories/ playbooks/deploy-monitoring.yml
ansible-playbook -i inventories/ playbooks/deploy-swarm.yml
ansible-playbook -i inventories/ playbooks/deploy-gitlab.yml

# === Vault ===
ansible-vault create inventories/group_vars/postgres_nodes/vault.yml
ansible-vault edit inventories/group_vars/postgres_nodes/vault.yml
ansible-vault view inventories/group_vars/postgres_nodes/vault.yml

# === Kubernetes ===
kubectl get nodes -o wide
kubectl get pods -A
kubectl run pg-test --rm -it --image=busybox --restart=Never -- /bin/sh

# === Docker Swarm ===
docker node ls
docker service ls
docker service ps <service>

# === PostgreSQL ===
patronictl -c /etc/patroni/patroni.yml list
patronictl -c /etc/patroni/patroni.yml switchover
consul members
psql -h 192.168.10.100 -U postgres -c "SELECT pg_is_in_recovery();"

# === GitLab ===
gitlab-ctl status
gitlab-runner list
gitlab-runner verify

# === WireGuard ===
sudo wg show wg0
sudo wg show wg0 latest-handshakes
ip route | grep wg0

# === Мониторинг ===
curl -s http://10.0.0.30:8428/health
curl -s "http://10.0.0.30:8428/api/v1/query?query=up" | jq .
curl -s http://localhost:9100/metrics | grep node_cpu
curl -s http://localhost:9187/metrics | grep pg_up
curl -s http://localhost:9586/metrics | grep wireguard

# === VMUI ===
# http://10.0.0.30:8428/vmui
```

---

## 11. Роадмап

### ✅ Выполнено

- [x] Рефакторинг `gitlab/` — `gitlab/master`, `gitlab/runner`, токен через диск контроллера
- [x] Рефакторинг `kubernetes/` — бинарники через контроллер, FQCN
- [x] Рефакторинг `group_vars/` — убраны дубли, пустые файлы
- [x] WireGuard mesh — hub-spoke топология, fallback endpoint
- [x] Удаление legacy-ролей
- [x] Ansible Vault для PostgreSQL

### 🔄 Ближайшее

- [ ] Ansible Vault для GitLab (root password)
- [ ] Удалить старые плейбуки (`deploy-postgres-monitoring.yml`, `deploy-agents-cloud.yml`, `deploy-agents-k8s.yml`)
- [ ] Grafana (альтернатива VMUI)
- [ ] WAL-G бэкапы в R2
- [ ] PgBouncer (пул соединений)

### 📋 Долгосрочное

- [ ] Redis Cluster
- [ ] Kafka Cluster + CDC
- [ ] Taskfile.yml / Makefile
- [ ] Pre-commit hooks (`terraform fmt`, `ansible-lint`, `yamlfmt`)
- [ ] GitLab CI — `terraform validate`, `ansible-lint`, `--check` прогон
- [ ] Dynamic inventory (`community.general.terraform_state`)
- [ ] Alertmanager / vmalert
- [ ] Loki (логирование)


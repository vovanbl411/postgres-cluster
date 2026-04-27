# Документация: Развёртывание стека мониторинга (VictoriaMetrics + vmagent + exporters)

## 1. Общая архитектура

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ЛОКАЛЬНЫЙ КЛАСТЕР                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │ controller-0 │    │   worker-0   │    │   worker-1   │                   │
│  │ 10.0.0.10    │    │  10.0.0.20   │    │  10.0.0.21   │                   │
│  │ node_exporter│    │ node_exporter│    │ node_exporter│                   │
│  │ vmagent      │    │ vmagent      │    │ vmagent      │                   │
│  │ wireguard_exp│    │              │    │              │                   │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘                   │
│         │                   │                   │                           │
│         └───────────────────┼───────────────────┘                           │
│                             │                                               │
│                    ┌────────┴────────┐                                      │
│                    │  monitoring-0   │                                      │
│                    │   10.0.0.30     │                                      │
│                    │ VictoriaMetrics │◄─────────────────────────────────────┘
│                    │    (VMUI)       │         remote_write (push)
│                    └────────┬────────┘
│                             │ wg0 (WireGuard)
│                             │ 10.200.0.2
└─────────────────────────────┼───────────────────────────────────────────────┘
                              │
                    ╔═════════╧═════════╗
                    ║   WireGuard VPN   ║
                    ╚═════════╤═════════╝
                              │ 10.200.0.1
┌─────────────────────────────┼───────────────────────────────────────────────┐
│                           ОБЛАКО (Timeweb)                                  │
│  ┌──────────────┐    ┌─────┴──────┐    ┌──────────────┐     ┌──────────────┐│
│  │ bastion-host │    │  pg-node-1 │    │  pg-node-2   │     │  pg-node-3   ││
│  │ 217.18.62.74 │    │ 192.168.10.6│   │ 192.168.10.5 │     │ 192.168.10.4 ││
│  │ node_exporter│    │ node_exporter│   │ node_exporter│    │ node_exporter││
│  │ vmagent      │    │ vmagent      │   │ vmagent      │    │ vmagent      ││
│  │ wireguard_exp│    │ postgres_exp │   │ postgres_exp │    │ postgres_exp ││
│  │              │    │ Patroni/PG   │   │ Patroni/PG   │    │ Patroni/PG   ││
│  └──────────────┘    └─────────────┘    └──────────────┘    └──────────────┘│
│                                                                             │
│  Сеть: 192.168.10.0/24 (VPC) — только IPv6-интернет, IPv4 недоступен        │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 2. Компоненты стека

| Компонент | Назначение | Где установлен |
|-----------|-----------|----------------|
| **VictoriaMetrics** | Хранилище временных рядов | monitoring-0 |
| **vmagent** | Сбор и push метрик в VM | Все хосты |
| **node_exporter** | Метрики ОС (CPU, RAM, диски) | Все хосты |
| **wireguard_exporter** | Метрики WG (handshake, peers) | controller-0, bastion |
| **postgres_exporter** | Метрики PostgreSQL | pg-node-1,2,3 |
| **VMUI** | Веб-интерфейс для PromQL | Встроен в VictoriaMetrics |

---

## 3. Структура ролей

```
ansible/roles/
├── monitoring_server/          # VictoriaMetrics + сборка wireguard_exporter
│   ├── defaults/main.yml
│   ├── handlers/main.yml
│   └── tasks/main.yml
├── monitoring_agents/          # node_exporter + vmagent + wireguard_exporter (опционально)
│   ├── defaults/main.yml
│   ├── handlers/main.yml
│   ├── tasks/
│   │   ├── main.yml
│   │   ├── node_exporter.yml
│   │   ├── vmagent.yml
│   │   └── wireguard_exporter.yml
│   └── templates/
│       ├── node_exporter.service.j2
│       ├── vmagent.service.j2
│       └── vmagent-scrape.yml.j2
└── postgres_exporter/          # Метрики PostgreSQL
    ├── defaults/main.yml
    ├── handlers/main.yml
    ├── tasks/main.yml
    └── templates/
        ├── postgres_exporter.service.j2
        └── postgres_exporter.env.j2
```

---

## 4. Проблемы и решения

### 4.1. Grafana — 403 Access Denied (apt.grafana.com)

**Проблема:** Cloudflare/Varnish блокирует IP сервера, `apt.grafana.com` недоступен.

**Решение:** Отказались от Grafana в пользу встроенного VMUI VictoriaMetrics.

**Проверка:**
```bash
curl -I https://apt.grafana.com/gpg.key
# HTTP/2 403
```

**Альтернатива:** Если Grafana нужна — скачивать `.deb` напрямую с GitHub releases или использовать Docker.

---

### 4.2. wireguard_exporter — сборка через cargo

**Проблема:** GitHub releases блокируются, бинарники недоступны.

**Решение:** Собираем `prometheus_wireguard_exporter` через `cargo` на `monitoring-0`, раздаём на остальные хосты через Ansible controller.

**Шаги:**
```bash
# На monitoring-0 (через роль monitoring_server)
cargo install prometheus_wireguard_exporter --version 3.6.6 --root /opt/wireguard_exporter

# Забираем на controller
ansible-playbook -i inventories/local.ini playbooks/deploy-monitoring.yml --limit monitoring-0

# Файл появляется на controller
ls -la /tmp/wireguard_exporter_3.6.6
```

**Важно:** Версия в `monitoring_agents/defaults/main.yml` должна совпадать:
```yaml
wireguard_exporter_version: "3.6.6"
```

---

### 4.3. delegate_to: monitoring-0 — SSH недоступен из облака

**Проблема:** `delegate_to: monitoring-0` из облачного инвентаря падает с:
```
Could not resolve hostname monitoring-0: Name or service not known
```

**Решение:** Использовать `fetch` на controller + `copy` с `delegate_to: localhost`.

**Ключевой паттерн:**
```yaml
- name: Check if prebuilt binary exists on Ansible controller
  ansible.builtin.stat:
    path: "/tmp/wireguard_exporter_{{ wireguard_exporter_version }}"
  delegate_to: localhost
  become: false

- name: Install from controller
  ansible.builtin.copy:
    src: "/tmp/wireguard_exporter_{{ wireguard_exporter_version }}"
    dest: /usr/local/bin/wireguard_exporter
```

---

### 4.4. ufw не установлен на bastion

**Проблема:**
```
Failed to find required executable "ufw" in paths
```

**Решение:** Fallback на `iptables`:
```yaml
- name: Check if ufw is installed
  ansible.builtin.command: which ufw
  register: ufw_check
  changed_when: false
  ignore_errors: true

- name: Allow ports via iptables (fallback)
  ansible.builtin.iptables:
    chain: INPUT
    protocol: tcp
    destination_port: "{{ item }}"
    source: "10.0.0.0/24"
    jump: ACCEPT
  loop:
    - "{{ node_exporter_port }}"
    - "{{ vmagent_port }}"
    - "{{ wireguard_exporter_port }}"
  when: ufw_check.rc != 0
```

---

### 4.5. Network is unreachable на pg-node (IPv4 отсутствует)

**Проблема:** Ноды Patroni в облачной VPC (`192.168.10.0/24`) имеют только IPv6-интернет. `get_url` падает:
```
Request failed: <urlopen error [Errno 101] Network is unreachable>
```

**Решение:** Все бинарники скачиваются на **Ansible controller** (Gentoo с полным интернетом), затем раздаются через `copy`.

**Паттерн для всех ролей:**
```yaml
# Скачивание — только на controller (delegate_to: localhost)
- name: Download on controller
  ansible.builtin.get_url:
    url: "https://github.com/..."
    dest: "/tmp/..."
  delegate_to: localhost
  become: false

# Установка — copy на target
- name: Install binary from controller
  ansible.builtin.copy:
    src: "/tmp/..."
    dest: "/usr/local/bin/..."
```

---

### 4.6. postgres_exporter — peer authentication failed

**Проблема:** PostgreSQL слушает только unix-socket и `192.168.10.X`, `localhost:5432` недоступен. `pg_hba.conf` требует `peer` для local.

```
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed:
FATAL: Peer authentication failed for user "postgres_exporter"
```

**Решение:** Запускаем `postgres_exporter` от системного пользователя `postgres` с peer-аутентификацией через unix-socket.

**DSN:**
```
DATA_SOURCE_NAME=host=/var/run/postgresql user=postgres sslmode=disable
```

**Systemd service:**
```ini
[Service]
User=postgres
Group=postgres
```

**Важно:** Не создаём отдельного пользователя в PostgreSQL — используем существующего `postgres`.

---

### 4.7. Маршрутизация: monitoring-0 ↔ облако

**Проблема:** Пакеты из облака (`192.168.10.0/24`) доходят до `monitoring-0`, но ответы теряются — `monitoring-0` не знает маршрута обратно.

**Диагностика:**
```bash
# С pg-node-1
curl -v http://10.0.0.30:8428/health
# Immediate connect fail for 10.0.0.30: Network is unreachable

# На monitoring-0
tcpdump -i any port 8428 -n
# SYN приходит, SYN-ACK уходит в default gateway, а не в туннель
```

**Решение:** Добавить статические маршруты в обе стороны.

#### На monitoring-0 (systemd-networkd):
```bash
sudo ip route add 192.168.10.0/24 via 10.0.0.10
```

Закрепить через `/etc/systemd/network/20-cloud-vpc.route`:
```ini
[Route]
Destination=192.168.10.0/24
Gateway=10.0.0.10
```

#### На pg-node (netplan):
```bash
sudo ip route add 10.0.0.0/24 via 192.168.10.7
```

Закрепить через `/etc/netplan/99-monitoring-routes.yaml`:
```yaml
network:
  version: 2
  ethernets:
    eth1:
      routes:
        - to: 10.0.0.0/24
          via: 192.168.10.7
```

Применить:
```bash
sudo netplan apply
```

**Важно:** На monitoring-0 используем `systemd-networkd` (`.route` файлы), на pg-node — `netplan` (`.yaml` файлы).

---

### 4.8. WireGuard AllowedIPs — bastion не видит локальную сеть

**Проблема:** Bastion знает только о `10.0.0.10/32` (controller-0), но не о всей сети `10.0.0.0/24`.

```bash
# На bastion
cat /etc/wireguard/wg0.conf | grep AllowedIPs
# AllowedIPs = 10.200.0.2/32, 10.0.0.10/32
```

**Решение:** Расширить `AllowedIPs` в шаблоне `wg0.conf.j2`:
```ini
[Peer]
# bastion side
AllowedIPs = 10.200.0.2/32, 10.0.0.0/24
```

После изменения:
```bash
wg-quick down wg0 && wg-quick up wg0
```

---

### 4.9. WireGuard handshake — Required key not available

**Проблема:** После добавления маршрута `10.0.0.0/24 via 10.200.0.2` ping падает:
```
From 10.200.0.1 icmp_seq=1 Destination Host Unreachable
ping: sendmsg: Required key not available
```

**Причина:** WG не пропускает пакет, потому что IP назначения (`10.0.0.30`) не входит в `AllowedIPs` ни одного пира.

**Решение:** См. 4.8 — расширить `AllowedIPs` до `10.0.0.0/24`.

---

## 5. Пошаговый деплой

### Этап 1: VictoriaMetrics + сборка артефактов

```bash
ansible-playbook -i inventories/local.ini playbooks/deploy-monitoring.yml --limit monitoring-0
```

**Что происходит:**
- Устанавливается VictoriaMetrics
- Собирается `wireguard_exporter` через cargo
- Бинарник забирается на Ansible controller (`/tmp/wireguard_exporter_3.6.6`)
- Добавляется маршрут `192.168.10.0/24 via 10.0.0.10`

**Проверка:**
```bash
curl -s http://10.0.0.30:8428/health
# OK
```

---

### Этап 2: K8s кластер (controllers + workers)

```bash
ansible-playbook -i inventories/local.ini playbooks/deploy-agents-k8s.yml
```

**Что происходит:**
- `node_exporter` + `vmagent` на всех нодах
- `wireguard_exporter` только на `controller-0`

**Проверка:**
```bash
curl -s "http://10.0.0.30:8428/api/v1/query?query=up" | jq -r '.data.result[] | "\(.metric.instance) \(.metric.job) \(.value[1])"'
# controller-0 node 1
# worker-0 node 1
# worker-1 node 1
# controller-0 wireguard 1
```

---

### Этап 3: Облако (bastion)

```bash
ansible-playbook -i inventories/cloud.ini playbooks/deploy-agents-cloud.yml
```

**Что происходит:**
- `node_exporter` + `vmagent` + `wireguard_exporter`
- `iptables` вместо `ufw`

**Проверка:**
```bash
curl -s "http://10.0.0.30:8428/api/v1/query?query=up" | grep bastion
# bastion-host node 1
# bastion-host wireguard 1
```

---

### Этап 4: PostgreSQL (pg-node-1,2,3)

```bash
ansible-playbook -i inventories/cloud.ini playbooks/deploy-postgres-monitoring.yml
```

**Что происходит:**
- `node_exporter` + `vmagent` + `postgres_exporter`
- Маршрут `10.0.0.0/24 via 192.168.10.7` через netplan
- Peer-аутентификация через unix-socket

**Проверка:**
```bash
# На pg-node
curl -s http://localhost:9187/metrics | grep pg_up
# pg_up 1

# В VictoriaMetrics
curl -s "http://10.0.0.30:8428/api/v1/query?query=pg_up" | jq -r '.data.result[] | "\(.metric.instance) \(.value[1])"'
# pg-node-1 1
# pg-node-2 1
# pg-node-3 1
```

---

## 6. Идемпотентность

Второй запуск playbook'ов должен показать `changed=0` (или минимум изменений).

```bash
# Проверка
ansible-playbook -i inventories/local.ini playbooks/deploy-monitoring.yml --limit monitoring-0
ansible-playbook -i inventories/local.ini playbooks/deploy-agents-k8s.yml
ansible-playbook -i inventories/cloud.ini playbooks/deploy-agents-cloud.yml
ansible-playbook -i inventories/cloud.ini playbooks/deploy-postgres-monitoring.yml
```

---

## 7. Полезные PromQL запросы (VMUI)

Открыть: `http://10.0.0.30:8428/vmui`

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

---

## 8. Чек-лист troubleshooting

| Симптом | Причина | Решение |
|---------|---------|---------|
| `403 Access Denied` при скачивании | Cloudflare блокирует IP | Скачивать на controller, раздавать через `copy` |
| `Network is unreachable` | Нет IPv4 на хосте | `delegate_to: localhost` для `get_url` |
| `Peer authentication failed` | pg_hba требует peer | Запускать exporter от `postgres` через unix-socket |
| `Could not resolve hostname` | `delegate_to` на несуществующий хост | Использовать IP или `fetch` + `copy` |
| `Required key not available` | WG `AllowedIPs` не включает сеть | Расширить `AllowedIPs` в `wg0.conf` |
| `Connection refused` | PostgreSQL не слушает TCP | Использовать unix-socket |
| Метрики не доходят в VM | Нет маршрута | Добавить static route на обеих сторонах |
| `ufw not found` | Нет ufw на минимальном образе | Fallback на `iptables` |


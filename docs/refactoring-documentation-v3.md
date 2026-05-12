# Документация по рефакторингу Ansible-инфраструктуры

## 1. Архитектурные принципы (принятые в проекте)

1. **Роли по домену**, не по техническому слою. Нет god roles.
2. **Одна роль = один компонент.** Каждая роль самодостаточна: пользователь, бинарник, systemd, firewall.
3. **Контроллер как кэш.** Бинарники скачиваются на Gentoo-контроллер (`delegate_to: localhost`), оттуда деплоятся.
4. **INI inventory + group_vars.** Terraform генерирует INI, переменные живут в `group_vars`.
5. **Vault для секретов.** Пока не используется, но все чувствительные переменные должны жить в `vault.yml`.
6. **WG mesh самодостоятельный.** Ключи на контроллере в `.wg-keys/`, не зависят от `hostvars`.
7. **Два прогона для WG.** Сначала `keys`, потом `config`.
8. **DNS на VPC-нодах.** `systemd-resolved` отключается, статический `8.8.8.8`.
9. **FQCN везде.** `ansible.builtin.`, `ansible.posix.` — никаких коротких имён.
10. **Firewall атомарно.** Каждая роль открывает только свой порт.

---

## 2. Целевая структура ролей

```txt
ansible/roles/
├── _base/
│   └── common/                 # Базовая настройка ОС
├── postgres_cluster/           # deploy-db.yml
│   ├── consul/
│   ├── patroni/
│   ├── haproxy/
│   ├── keepalived/
│   └── exporter/               # thin wrapper → monitoring/postgres_exporter
├── docker_swarm/               # deploy-swarm.yml
│   ├── swarm/                  # Docker, Swarm init/join, overlay networks
│   └── gateway/                # УДАЛЕНО → функция перенесена в vpn/routes
├── gitlab/                     # deploy-gitlab.yml
│   ├── master/
│   └── runner/
├── monitoring/                 # deploy-monitoring.yml
│   ├── server/                 # VictoriaMetrics
│   ├── node_exporter/
│   ├── vmagent/
│   ├── wireguard_exporter/
│   └── postgres_exporter/
├── vpn/                        # deploy-vpn.yml
│   ├── bastion_nat/            # NAT + FORWARD для всего VPC
│   ├── routes/                 # default route + DNS для всех vpc_node
│   └── wireguard/              # WG mesh (hub-spoke)
└── network/
    └── bastion_nat/            # legacy, удалить
```

### 2.1. roles_path в ansible.cfg

```ini
[defaults]
roles_path = ./roles:./roles/monitoring:./roles/vpn:./roles/postgres_cluster:./roles/kubernetes:./roles/docker_swarm:./roles/gitlab
```

---

## 3. Рефакторинг postgres_cluster

### 3.1. Что было
- `roles/consul`, `roles/postgres_patroni`, `roles/haproxy`, `roles/keepalived` — плоско в корне.
- Нет `defaults/main.yml` — всё захардкожено.
- Нет firewall-правил.
- `keepalived` priority через `regex_replace` от hostname — хрупко.
- `haproxy` биндится на VIP, но `ip_nonlocal_bind` не включён — падает на BACKUP-нодах.

### 3.2. Что стало
- Всё в `roles/postgres_cluster/`.
- Каждая роль имеет `defaults/main.yml` с переменными.
- Firewall (`iptables`) в каждой роли.
- `keepalived` priority — явный словарь `keepalived_priority`.
- `sysctl net.ipv4.ip_nonlocal_bind=1` в `keepalived` (перед haproxy).

### 3.3. Критичные фиксы

#### `ip_nonlocal_bind` для HAProxy + Keepalived
HAProxy биндится на VIP (`192.168.10.100`), но VIP поднят только на MASTER-ноде keepalived. На BACKUP-нодах IP нет — haproxy падает.

**Решение:**

```yaml
- name: Enable binding to non-local IP for HAProxy
  ansible.builtin.sysctl:
    name: net.ipv4.ip_nonlocal_bind
    value: "1"
    state: present
    reload: true
```

#### Keepalived priority — явный словарь

Было:

```jinja2
priority {{ 100 - (inventory_hostname | regex_replace('[^\d]', '') | int) }}
```

Стало:

```yaml
keepalived_priority:
  pg-node-1: 101
  pg-node-2: 100
  pg-node-3: 99
```

#### Порядок ролей в deploy-db.yml

Keepalived должен быть **после** haproxy и patroni, т.к. `track_script` проверяет их.

```yaml

roles:
  - postgres_cluster/consul
  - postgres_cluster/patroni
  - postgres_cluster/haproxy
  - postgres_cluster/keepalived   # ← в конце
```

---

## 4. Рефакторинг docker_swarm

### 4.1. Что было
- `roles/docker_swarm` — одна роль со всем: install, init, join, network.
- `roles/node_gateway` — маршруты через bastion (дублирование vpn/routes).
- `roles/bastion_nat` в `deploy-swarm.yml` — NAT не в VPN.
- `daemon.json` был в templates, но **никогда не деплоился**.
- `live-restore: true` в `daemon.json` — **несовместим со Swarm mode**.

### 4.2. Что стало
- `docker_swarm/swarm/` — Docker install, Swarm init/join, overlay networks.
- `docker_swarm/gateway/` — **УДАЛЕНО**, функция в `vpn/routes`.
- `daemon.json` деплоится через `template` + таска `copy`.
- `live-restore` убран.

### 4.3. Критичные фиксы

#### `live-restore` несовместим со Swarm mode

```
failed to start cluster component: --live-restore daemon configuration is incompatible with swarm mode
```

**Решение:** убрать `live-restore` из `daemon.json`.

#### Systemd unit для маршрутов (gateway)

Первая попытка через `systemd-networkd` drop-in (`/etc/systemd/network/10-eth1.network.d/`) **не работает**, потому что netplan генерирует `.network` в `/run/systemd/network/`, и drop-in в `/etc/` не применяется.

**Решение:** `oneshot` systemd unit (`ansible-vpc-route.service`) с `ExecStart=/sbin/ip route replace`.

#### `ip route replace` вместо `add`

`ip route add` падает с `File exists` при повторном прогоне. `replace` — идемпотентно.

---

## 5. Рефакторинг VPN (универсальная архитектура)

### 5.1. Проблема

- `deploy-vpn.yml` хардкодил `hosts: postgres_nodes` для routes.
- `vpn/routes` имел `when: inventory_hostname in groups['postgres_nodes']` — ломалось при добавлении swarm.
- `vpn/bastion_nat` сохранял правила только через handler, который мог не сработать.
- `wg_peers` имел `endpoint_host` — захардкоженный публичный IP bastion.
- `vpn/wireguard` дублировал DNS-логику (`systemd-resolved`, static DNS), которая уже есть в `vpn/routes`.

### 5.2. Решение: флаг `vpc_node`

Terraform-шаблоны добавляют `vpc_node=true` в `[*:vars]`:

```ini
[swarm_nodes:vars]
vpc_node=true

[postgres_nodes:vars]
vpc_node=true
```

Ansible:

```yaml
- name: Setup routes for all VPC nodes
  hosts: all
  roles:
    - role: vpn/routes
      when: vpc_node | default(false) | bool
```

> **Важно:** `| bool` обязательно, иначе Ansible парсит строку `"true"` как строку, не boolean.

### 5.3. bastion_nat — flush_handlers + save

Все `iptables` таски имеют `notify: Save iptables`, и в конце роли:

```yaml
- name: Flush handlers to persist iptables immediately
  ansible.builtin.meta: flush_handlers
```

### 5.4. routes — systemd unit (не drop-in)

`systemd-networkd` drop-in не работает с netplan. Используем `oneshot` unit:

```ini
[Unit]
Description=Default route via VPC gateway (Ansible managed)
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace default via {{ vpc_gateway_ip }} dev {{ vpc_interface }}
```

### 5.5. WireGuard — динамический endpoint

Убран `endpoint_host` из `wg_peers`. Endpoint берётся из inventory:

```jinja2
Endpoint = {{ hostvars[groups['bastion'][0]]['ansible_host'] }}:{{ wg_port }}
```

При смене публичного IP bastion достаточно `terraform apply` + `ansible-playbook deploy-vpn.yml --tags wireguard`.

### 5.6. Terraform-шаблоны

Все cloud-шаблоны имеют:

```ini
[bastion:vars]
bastion_private_ip=${bastion_private_ip}

[swarm_nodes:vars]
vpc_node=true
```

---

## 6. Плейбуки (финальная версия)

### deploy-db.yml

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

### deploy-swarm.yml

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

### deploy-vpn.yml

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

---

## 7. Известные проблемы и решения

### 7.1. Docker + nftables на Gentoo (контроллер)

Docker создаёт `iptables` правила с `FORWARD DROP`, которые перекрывают `nftables`.

Решение — `libvirt_fix.nft` с `priority -10` (см. v2 документацию).

### 7.2. `unarchive` с `remote_src: true` падает

`ansible.builtin.unarchive` проверяет файл на контроллере перед распаковкой.

Решение — `delegate_to: localhost` для скачивания и распаковки.

### 7.3. `chown` на `/usr/local/bin`

Пользователь `monitoring` создавался в той же роли, но порядок в `loop` не гарантировал создание до `chown`.

Решение — разделить на две задачи: `file` для data_dir с owner, `file` для bin_dir без owner.

### 7.4. `vmagent` падает с `status=217/USER`

Пользователь `vmagent` не создавался в новой атомарной роли.

Решение — явное создание user/group в начале `monitoring/vmagent/tasks/main.yml`.

### 7.5. `hostvars` между разными inventory-файлами

`monitoring-0` (из `monitoring.ini`) не видел `bastion-host` (из `cloud.ini`) в `hostvars`.

Решение — отказ от `hostvars` для ключей. Ключи хранятся на диске контроллера в `.wg-keys/`.

### 7.6. `lookup('file')` возвращает `None`

`lookup('file', ..., errors='ignore')` возвращает `None`, а не пустую строку.

Решение:

```jinja2
{% set peer_pubkey = lookup('file', ...) | default('', true) %}
{% if peer_pubkey | length > 0 %}
```

### 7.7. RTNETLINK answers: File exists (маршруты WG)

`AllowedIPs` содержал `192.168.10.0/24` и `10.0.0.0/24` — маршруты уже существовали через `eth1`.

Решение — на spoke оставить только `AllowedIPs = 10.200.0.0/24`.

### 7.8. DNS не работает на pg-нодах после маршрута

`systemd-resolved` (127.0.0.53) не подхватывает новый default route.

Решение — отключить `systemd-resolved`, прописать статический DNS `8.8.8.8`.

### 7.9. Интернет на pg-нодах через bastion

Нет default route + NAT не настроен.

Решение:
1. Default route через `vpc_gateway_ip`
2. NAT на bastion для `192.168.10.0/24`
3. `net.ipv4.ip_forward=1`

---

## 8. Роадмап

### 8.1. Ближайшее (техдолг рефакторинга)

- [ ] **Ansible Vault**
  - `vault.yml` для `postgres_nodes` (пароли Patroni, репликации)
  - `vault.yml` для `gitlab` (root password, runner token)
  - `vault.yml` для `all` (WireGuard приватные ключи)
  - `--vault-password-file` в CI/CD

- [ ] **Удалить старые роли**
  - `monitoring_agents` (god role)
  - `monitoring_server` (перенесена в `monitoring/server`)
  - `postgres_exporter` (перенесена в `monitoring/postgres_exporter`)
  - `deploy-postgres-monitoring.yml`, `deploy-agents-cloud.yml`, `deploy-agents-k8s.yml`
  - `roles/docker_swarm/gateway` (функция в `vpn/routes`)
  - `roles/node_gateway`
  - `roles/bastion_nat` (если есть в корне)

- [ ] **Рефакторинг `kubernetes/`**
  - Перенести `k8s_prep`, `container_runtime`, `k8s_install`, `k8s_control_plane`, `k8s_workers`, `k8s_cni` в `roles/kubernetes/`
  - Вынести `vpn_routes_worker` из `deploy-k8s.yml` в `vpn/routes/` (уже работает через `vpc_node`)
  - Добавить `controller-0` в `wg_peers` при поднятии K8s

- [ ] **Рефакторинг `gitlab/`**
  - Перенести `gitlab_master`, `gitlab_runner` в `roles/gitlab/`
  - Добавить `gitlab-runner-1` в `wg_peers`

### 8.2. Долгосрочное

- [ ] **Taskfile.yml / Makefile** — единая точка входа
- [ ] **Pre-commit hooks** — `terraform fmt`, `ansible-lint`, `yamlfmt`
- [ ] **GitLab CI** — `terraform validate`, `ansible-lint`, `--check` прогон
- [ ] **Dynamic inventory** — `community.general.terraform_state`
- [ ] **Terraform структура** — `modules/` vs `environments/`

---

## 9. Команды для тестирования

### Inventory

```bash
ansible-inventory -i inventories/ --graph
ansible-inventory -i inventories/ --host monitoring-0
ansible-playbook -i inventories/ playbooks/site.yml --syntax-check
```

### Check mode

```bash
ansible-playbook -i inventories/ playbooks/deploy-db.yml --limit pg-node-1 --tags patroni --check --diff
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml --tags wireguard --check --diff
ansible-playbook -i inventories/ playbooks/deploy-swarm.yml --check --diff
```

### Проверка сервисов

```bash
ansible monitoring-0 -i inventories/ -m shell -a "systemctl status victoria-metrics"
ansible bastion-host -i inventories/ -m shell -a "systemctl status node_exporter vmagent wireguard_exporter"
ansible pg-node-1 -i inventories/ -m shell -a "systemctl status postgres_exporter vmagent wg-quick@wg0"
ansible swarm-node-1 -i inventories/ -m shell -a "systemctl status docker"
```

### Проверка WG

```bash
ansible bastion-host -i inventories/ -b -m shell -a "wg show"
ansible pg-node-1 -i inventories/ -b -m shell -a "wg show"
ansible pg-node-1 -i inventories/ -m shell -a "ping -c 3 10.200.0.3"
```

### Проверка remote_write

```bash
ansible monitoring-0 -i inventories/ -m shell -a   "curl -s 'http://localhost:8428/api/v1/query?query=up'"
```

### Проверка Swarm

```bash
ansible swarm-node-1 -i inventories/ -m shell -a "docker node ls"
ansible swarm-node-1 -i inventories/ -m shell -a "docker network ls | grep overlay"
```

### Проверка интернета на VPC-нодах

```bash
ansible swarm_nodes -i inventories/ -m shell -a "ping -c 3 8.8.8.8"
ansible postgres_nodes -i inventories/ -m shell -a "ping -c 3 8.8.8.8"
```

# Документация по рефакторингу Ansible-инфраструктуры

## 1. Исходное состояние (что было)

- **18 ролей** в плоской структуре `ansible/roles/` без доменного разделения.
- **God role** `monitoring_agents` — одна роль управляла `node_exporter`, `vmagent`, `wireguard_exporter` через булевы флаги `monitoring_agent_install_*`.
- **Переменные размазаны** по `vars` внутри плейбуков (`remote_write_url`, флаги экспортёров).
- **9 отдельных плейбуков** (`deploy-*.yml`) без единой точки входа.
- **Inventory** генерируется Terraform в формате INI (`inventory_local.ini`, `inventory_cloud.ini`).
- **Ansible Vault** не использовался — все секреты в открытом виде.
- **WireGuard** завязан на K8s `controller-0`, которого в текущем окружении нет.
- Docker на хосте (Gentoo) создаёт `iptables` правила, блокирующие форвардинг пакетов между сетями (решается через `nftables`).

---

## 2. Целевая архитектура

### 2.1. Принцип группировки ролей

Роли группируются **по домену/приложению**, а не по техническому слою:

```txt
ansible/roles/
├── _base/
│   └── common/                 # Базовая настройка ОС
├── postgres_cluster/           # deploy-db.yml
│   ├── consul/
│   ├── patroni/
│   ├── haproxy/
│   ├── keepalived/
│   └── exporter/               # postgres_exporter
├── kubernetes/                 # deploy-k8s.yml
│   ├── prep/
│   ├── container_runtime/
│   ├── install/
│   ├── control_plane/
│   ├── cni/
│   ├── workers/
│   └── routes/
├── docker_swarm/               # deploy-swarm.yml
│   ├── swarm/
│   └── gateway/
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
│   ├── bastion_nat/
│   ├── routes/
│   └── wireguard/
└── network/
    └── bastion_nat/
```

> **Важно:** Ansible по умолчанию не ищет роли рекурсивно. Для подролей в `monitoring/`, `vpn/` и т.д. необходимо прописать пути в `ansible.cfg`:
> ```ini
> roles_path = ./roles:./roles/monitoring:./roles/vpn:./roles/postgres_cluster:...
> ```

### 2.2. Переменные в `group_vars`

Вся окружение-специфичная логика переехала из `vars` плейбуков в `group_vars`:

```txt
ansible/inventories/group_vars/
├── all/vars.yml                # Глобальные: monitoring_network_cidr, scrape_interval, wg_peers
├── all/vault.yml               # Зарезервировано
├── bastion/vars.yml            # vmagent_remote_write_url, wireguard_exporter_enabled
├── controllers/vars.yml        # wireguard_exporter_enabled: false
├── monitoring/vars.yml         # victoria_metrics_version, retention
├── postgres_nodes/
│   ├── vars.yml                # postgres_exporter_enabled, vmagent_remote_write_url
│   └── vault.yml               # Зарезервировано
└── workers/vars.yml
```

> **Нюанс:** Inventory генерируется Terraform в формате INI. `group_vars` подхватываются Ansible автоматически, если лежат рядом с inventory-файлами (или в `inventories/group_vars/` при `inventory = ./inventories`).

---

## 3. Рефакторинг monitoring

### 3.1. Разбиение god role

**Было:** `monitoring_agents` с `when: monitoring_agent_install_*` внутри `main.yml`.

**Стало:** атомарные роли:

- `monitoring/node_exporter`
- `monitoring/vmagent`
- `monitoring/wireguard_exporter`
- `monitoring/postgres_exporter`
- `monitoring/server`

Каждая роль самодостаточна: создаёт своего пользователя, ставит бинарник, настраивает systemd, открывает **свой** порт в firewall.

### 3.2. Проблемы и решения

#### Проблема: `unarchive` с `remote_src: true` падает при скачивании на таргет

**Симптом:**

```
Source '/tmp/victoria-metrics-1.102.1.tar.gz' does not exist
```

**Причина:** `ansible.builtin.unarchive` с `remote_src: true` проверяет файл **на контроллере** перед распаковкой, чтобы определить тип архива. Если файла нет на Gentoo-контроллере — модуль падает.

**Решение:** Единообразный паттерн — скачивание и распаковка выполняются на **контроллере** (`delegate_to: localhost`), а на таргет копируется готовый бинарник через `copy`.

```yaml
- name: Download on controller
  ansible.builtin.get_url:
    url: "..."
    dest: "/tmp/victoria-metrics-{{ version }}.tar.gz"
  delegate_to: localhost
  become: false

- name: Extract on controller
  ansible.builtin.unarchive:
    src: "/tmp/victoria-metrics-{{ version }}.tar.gz"
    dest: "/tmp/"
    remote_src: true
  delegate_to: localhost
  become: false

- name: Install binary on target
  ansible.builtin.copy:
    src: "/tmp/victoria-metrics-prod"
    dest: "/usr/local/bin/victoria-metrics-prod"
```

> **Исключение:** `wireguard_exporter` билдится **на monitoring-сервере** через `cargo`, затем `fetch` на контроллер. Это сделано осознанно, так как на Gentoo-контроллере билд Rust-зависимостей проблематичен.

#### Проблема: `chown` на `/usr/local/bin`

**Симптом:**

```txt
chown failed: failed to look up user monitoring
```

**Причина:** В старой роли `loop` создавал директории `data_dir` и `bin_dir` с `owner: monitoring`, но `/usr/local/bin` принадлежит `root`, а пользователь `monitoring` создавался в той же роли, но порядок выполнения при loop не гарантировал создание до `chown`.

**Решение:** Разделить на две задачи:

```yaml
- name: Create VictoriaMetrics data directory
  ansible.builtin.file:
    path: "{{ victoria_metrics_data_dir }}"
    state: directory
    owner: "{{ monitoring_user }}"
    group: "{{ monitoring_group }}"
    mode: '0750'

- name: Ensure VictoriaMetrics bin directory exists
  ansible.builtin.file:
    path: "{{ victoria_metrics_bin_dir }}"
    state: directory
    mode: '0755'
  # Не меняем owner — /usr/local/bin принадлежит root
```

#### Проблема: `vmagent` падает с `status=217/USER`

**Симптом:**

```txt
Main PID: ... (code=exited, status=217/USER)
```

**Причина:** В новой роли `monitoring/vmagent` не создавался пользователь `vmagent` перед запуском сервиса. В старой god role пользователь создавался в `monitoring_agents/main.yml` до `include_tasks: vmagent.yml`.

**Решение:** Добавить в начало `monitoring/vmagent/tasks/main.yml`:
```yaml
- name: Ensure vmagent group exists
  ansible.builtin.group:
    name: "{{ vmagent_group }}"
    system: true
    state: present

- name: Ensure vmagent user exists
  ansible.builtin.user:
    name: "{{ vmagent_user }}"
    group: "{{ vmagent_group }}"
    system: true
    shell: /usr/sbin/nologin
    state: present
```

---

## 4. Рефакторинг VPN (полный разбор)

### 4.1. Архитектурная проблема

WireGuard был завязан на K8s `controller-0` (10.0.0.10) как шлюз. Но в текущем окружении K8s не поднят, и `controller-0` отсутствует в inventory. Это приводило к:

```txt
hostvars['controller-0'] is undefined
```

### 4.2. Решение: mesh-топология без привязки к K8s

**Цель:** сделать VPN самодостаточным. Бастион (10.200.0.1) — hub, `monitoring-0` (10.200.0.3) — spoke, pg-ноды (10.200.0.4-6) — spokes.

**Подход:**
1. Словарь пиров в `group_vars/all/vars.yml`:

```yaml
wg_peers:
  bastion-host:
    tunnel_ip: "10.200.0.1"
    is_hub: true
    endpoint_host: "188.225.47.146"
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
```

2. Генерация ключей через отдельную таску `generate_keys.yml` + `fetch` на контроллер в `ansible/.wg-keys/`.

3. Шаблон `wg0.conf.j2` использует `lookup('file', ...)` для чтения публичных ключей с контроллера, вместо `hostvars`.

### 4.3. Полный список проблем и решений

#### Проблема 1: `hostvars` между разными inventory-файлами

**Симптом:** `monitoring-0` (из `monitoring.ini`) не видит `bastion-host` (из `cloud.ini`) в `hostvars`.

**Причина:** Ansible загружает inventory файлы последовательно, но `hostvars` не мержатся между ними корректно при использовании `hostvars['имя_хоста']` в шаблонах.

**Решение:** Отказ от `hostvars` для ключей. Ключи хранятся на диске контроллера в `.wg-keys/` и подключаются через `lookup('file', ...)`. Это также позволяет переживать пересоздание хостов без потери ключей.

#### Проблема 2: `lookup('file')` возвращает `None`

**Симптом:**

```txt
The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()
```

**Причина:** `lookup('file', ..., errors='ignore')` возвращает `None`, а не пустую строку, когда файл не найден. `| default('', true)` не всегда ловит `None`.

**Решение:**

```jinja2
{% set peer_pubkey = lookup('file', wg_keys_dir ~ '/' ~ peer_name ~ '.pub', errors='ignore') | default('', true) %}
{% if peer_pubkey | length > 0 %}
```

#### Проблема 3: `RTNETLINK answers: File exists` — конфликт маршрутов

**Симптом:**

```txt
[#] ip -4 route add 192.168.10.0/24 dev wg0
RTNETLINK answers: File exists
```

**Причина:** `AllowedIPs` в `wg0.conf` содержал `192.168.10.0/24`. `wg-quick` автоматически создаёт маршрут для каждого `AllowedIPs` через `wg0`. Но `192.168.10.0/24` — это локальная сеть pg-ноды (eth1), и маршрут уже существует.

**Решение:** Убрать `192.168.10.0/24` из `AllowedIPs` на spoke. Spoke достаточно знать только `10.200.0.0/24` (WG-сеть).

#### Проблема 4: `RTNETLINK answers: File exists` — `10.0.0.0/24`

**Симптом:**

```txt
[#] ip -4 route add 10.0.0.0/24 dev wg0
RTNETLINK answers: File exists
```

**Причина:** `AllowedIPs` содержал `10.0.0.0/24`. На pg-нодах этот маршрут уже существует через `eth1` (`via 192.168.10.7`).

**Решение:** Убрать `10.0.0.0/24` из `AllowedIPs` на spoke. Итоговый `AllowedIPs` для spoke:

```txt
AllowedIPs = 10.200.0.0/24
```

> **Важно:** Hub (bastion) продолжает иметь `AllowedIPs = {{ peer.tunnel_ip }}/32` для каждого spoke — это корректно.

#### Проблема 5: DNS не работает на pg-нодах после добавления маршрута

**Симптом:**

```txt
Temporary failure resolving 'deb.debian.org'
```

**Причина:** `systemd-resolved` (127.0.0.53) не подхватывает новый default route. Он пытается достучаться до IPv6 DNS Timeweb, который не маршрутизируется.

**Решение:** Отключить `systemd-resolved` и прописать статический DNS:

```yaml
- name: Disable systemd-resolved stub
  ansible.builtin.systemd:
    name: systemd-resolved
    state: stopped
    enabled: false

- name: Configure static DNS
  ansible.builtin.copy:
    content: |
      nameserver 8.8.8.8
      nameserver 8.8.4.4
    dest: /etc/resolv.conf
    mode: '0644'
    force: true
```

#### Проблема 7: Интернет на pg-нодах через bastion

**Симптом:**
```
ping: connect: Network is unreachable
```

**Причина:** На pg-нодах нет default route. Есть только маршрут `10.0.0.0/24 via 192.168.10.7` (добавлен ранее для других целей), но нет `default via 192.168.10.7`.

**Решение:**
1. Добавить default route на pg-нодах через `vpc_gateway_ip: 192.168.10.7`
2. Добавить NAT на bastion для `192.168.10.0/24`:

```yaml
- name: NAT for VPC nodes
  ansible.builtin.iptables:
    table: nat
    chain: POSTROUTING
    source: 192.168.10.0/24
    jump: MASQUERADE
    comment: "NAT VPC nodes to internet"
```

#### Проблема 8: `apt` падает на pg-нодах при установке WireGuard

**Симптом:**

```txt
Failed to update apt cache after 5 retries
```

**Причина:** После добавления default route DNS всё ещё не работал (systemd-resolved кешировал старое состояние).

**Решение:** Комбинация двух фиксов:

1. Отключение `systemd-resolved` + статический DNS
2. Default route через bastion
3. NAT на bastion для 192.168.10.0/24

#### Проблема 9: `systemctl restart wg-quick@wg0` без sudo

**Симптом:**

```
Failed to restart wg-quick@wg0.service: Interactive authentication required.
```

**Причина:** На `monitoring-0` Ansible подключается под `vladimir`, а не `root`. Ad-hoc команда без `-b` (become).

**Решение:** Использовать `-b` (become) для restart:
```bash
ansible monitoring-0 -i inventories/ -b -m shell -a "systemctl restart wg-quick@wg0"
```

#### Проблема 10: Два прогона для генерации ключей

**Симптом:** На первом прогоне `configure.yml` не видит `.pub` файлы других хостов.

**Причина:** `generate_keys.yml` выполняется на всех хостах, но `fetch` на контроллер происходит во время выполнения. На момент `configure.yml` на первом хосте ключи второго ещё не fetch'нуты.

**Решение:** Два отдельных прогона:

```bash
# Прогон 1: только генерация и fetch ключей
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml --tags keys

# Прогон 2: конфигурация (теперь все .pub на месте)
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml --tags config
```

#### Проблема 11: `endpoint_host` захардкожен и меняется при пересоздании инфраструктуры

**Симптом:** После `terraform apply` с новым bastion IP WG не подключается.

**Причина:** `endpoint_host: "77.232.135.78"` в `group_vars/all/vars.yml` устарел.

**Решение:** Обновить `wg_peers.bastion-host.endpoint_host` в `group_vars/all/vars.yml` после каждого пересоздания. В перспективе — вынести в Terraform-шаблон:

```ini
[all:vars]
wg_bastion_endpoint=${bastion_ip}
```

---

## 5. Итоговая структура проекта (после рефакторинга)

```
ansible/
├── ansible.cfg
├── inventories/
│   ├── group_vars/
│   │   ├── all/
│   │   │   ├── vars.yml          # wg_peers, monitoring_network_cidr, порты
│   │   │   └── vault.yml         # (зарезервировано)
│   │   ├── bastion/
│   │   │   └── vars.yml
│   │   ├── controllers/
│   │   │   └── vars.yml
│   │   ├── monitoring/
│   │   │   └── vars.yml
│   │   ├── postgres_nodes/
│   │   │   ├── vars.yml
│   │   │   └── vault.yml
│   │   └── workers/
│   │       └── vars.yml
│   ├── monitoring.ini            # Terraform-generated
│   └── cloud.ini                 # Terraform-generated
├── playbooks/
│   ├── deploy-db.yml
│   ├── deploy-gitlab.yml
│   ├── deploy-k8s.yml
│   ├── deploy-monitoring.yml
│   ├── deploy-swarm.yml
│   ├── deploy-vpn.yml
│   └── new_deploy-monitoring.yml
└── roles/
    ├── monitoring/
    │   ├── node_exporter/
    │   ├── postgres_exporter/
    │   ├── server/
    │   ├── vmagent/
    │   └── wireguard_exporter/
    ├── vpn/
    │   ├── bastion_nat/
    │   ├── routes/
    │   └── wireguard/
    ├── common/
    ├── consul/
    ├── docker_swarm/
    ├── gitlab_master/
    ├── gitlab_runner/
    ├── haproxy/
    ├── k8s_cni/
    ├── k8s_control_plane/
    ├── k8s_install/
    ├── k8s_prep/
    ├── k8s_workers/
    ├── keepalived/
    ├── postgres_patroni/
    └── ...
```

---

## 6. Что предстоит сделать (роадмап)

### 6.1. Ближайшее (техдолг рефакторинга)

- [ ] **Ansible Vault**
  - Создать `vault.yml` для `postgres_nodes` (пароли Patroni, репликации)
  - Создать `vault.yml` для `gitlab` (root password, runner token)
  - Создать `vault.yml` для `all` (WireGuard приватные ключи — если не хранить в `.wg-keys/`)
  - Добавить `--vault-password-file` в CI/CD

- [ ] **Удалить старые роли**
  - `monitoring_agents` (god role)
  - `monitoring_server` (перенесена в `monitoring/server`)
  - `postgres_exporter` (перенесена в `monitoring/postgres_exporter`)
  - `deploy-postgres-monitoring.yml`, `deploy-agents-cloud.yml`, `deploy-agents-k8s.yml`

- [ ] **Рефакторинг `postgres_cluster/`**
  - Перенести `common`, `consul`, `patroni`, `haproxy`, `keepalived` в `roles/postgres_cluster/`

- [ ] **Рефакторинг `kubernetes/`**
  - Перенести `k8s_prep`, `container_runtime`, `k8s_install`, `k8s_control_plane`, `k8s_workers`, `k8s_cni` в `roles/kubernetes/`
  - Вынести `vpn_routes_worker` из `deploy-k8s.yml` в `vpn/routes/`
  - Добавить `controller-0` в `wg_peers` при поднятии K8s

- [ ] **Рефакторинг `docker_swarm/`**
  - Перенести `docker_swarm`, `node_gateway` в `roles/docker_swarm/`
  - Убрать `bastion_nat` из `deploy-swarm.yml` (он теперь в VPN)

- [ ] **Рефакторинг `gitlab/`**
  - Перенести `gitlab_master`, `gitlab_runner` в `roles/gitlab/`

### 6.2. Долгосрочное (автоматизация и качество)

- [ ] **Taskfile.yml / Makefile** — единая точка входа
- [ ] **Pre-commit hooks** — `terraform fmt`, `ansible-lint`, `yamlfmt`
- [ ] **GitLab CI** — `terraform validate`, `ansible-lint`, `--check` прогон
- [ ] **Dynamic inventory** — `community.general.terraform_state`
- [ ] **Terraform структура** — `modules/` vs `environments/`

---

## 7. Известные проблемы инфраструктуры (не Ansible)

### 7.1. Docker + nftables на Gentoo

Docker создаёт `iptables` правила с `FORWARD DROP`, которые перекрывают `nftables`. Решение — `libvirt_fix.nft` с `priority -10`:

```nft
chain bypass_docker {
    type filter hook forward priority -10; policy accept;
    ip saddr 10.0.0.0/24 accept
    ip daddr 10.0.0.0/24 accept
    ip saddr 10.244.0.0/16 accept
    ip daddr 10.244.0.0/16 accept
}
```

> **TODO:** Вынести это в роль `network/firewall` или `_base/common`.

### 7.2. Интернет на виртуалках

Виртуалки в локальной сети (10.0.0.0/24) не всегда имеют интернет из-за NAT/Docker. Поэтому бинарники скачиваются на **контроллере** (`delegate_to: localhost`), а не на таргете.

---

## 8. Соглашения и best practices (принятые в проекте)

1. **Роли атомарны** — одна роль = один компонент. Нет god roles.
2. **Пользователи изолированы** — `node_exporter`, `vmagent`, `victoria-metrics` — каждый со своим пользователем.
3. **Firewall порты** — каждая роль открывает только свой порт, не все сразу.
4. **Контроллер как кэш** — бинарники скачиваются на Gentoo-контроллер, оттуда деплоятся на таргеты.
5. **INI inventory + group_vars** — Terraform генерирует INI, переменные живут в `group_vars`.
6. **Теги иерархичны** — `monitoring`, `server`, `vmagent`, `node_exporter`.
7. **Vault для секретов** — пока не используется, но все чувствительные переменные должны жить в `vault.yml`.
8. **WG mesh самодостаточен** — ключи хранятся на контроллере в `.wg-keys/`, не зависят от `hostvars`.
9. **Два прогона для WG** — сначала `keys`, потом `config`.
10. **DNS на VPC-нодах** — `systemd-resolved` отключается, статический `8.8.8.8`.

---

## 9. Команды для тестирования и дебага

### 9.1. Проверка inventory

```bash
ansible-inventory -i inventories/ --graph
ansible-inventory -i inventories/ --host monitoring-0
ansible-playbook -i inventories/ playbooks/site.yml --syntax-check
```

### 9.2. Check mode

```bash
ansible-playbook -i inventories/ playbooks/new_deploy-monitoring.yml \
  --limit monitoring --tags server --check --diff

ansible-playbook -i inventories/ playbooks/deploy-vpn.yml \
  --tags wireguard --check --diff
```

### 9.3. Проверка сервисов

```bash
ansible monitoring-0 -i inventories/ -m shell -a "systemctl status victoria-metrics"
ansible bastion-host -i inventories/ -m shell -a "systemctl status node_exporter vmagent wireguard_exporter"
ansible pg-node-1 -i inventories/ -m shell -a "systemctl status postgres_exporter vmagent wg-quick@wg0"
```

### 9.4. Проверка WG

```bash
ansible bastion-host -i inventories/ -b -m shell -a "wg show"
ansible pg-node-1 -i inventories/ -b -m shell -a "wg show"
ansible pg-node-1 -i inventories/ -m shell -a "ping -c 3 10.200.0.3"
ansible pg-node-1 -i inventories/ -m shell -a "ping -c 3 10.200.0.1"
```

### 9.5. Проверка remote_write

```bash
ansible monitoring-0 -i inventories/ -m shell -a \
  "curl -s 'http://localhost:8428/api/v1/query?query=up'"

ansible bastion-host -i inventories/ -m shell -a "journalctl -u vmagent -n 20 --no-pager"
ansible pg-node-1 -i inventories/ -m shell -a "journalctl -u vmagent -n 20 --no-pager"
```


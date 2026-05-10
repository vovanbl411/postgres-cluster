# Документация по рефакторингу Ansible-инфраструктуры

> **Контекст:** Проект `postgres-cluster` перерос простую схему и требует структуризации. Проводился рефакторинг ролей Ansible с целью повышения управляемости, читаемости и масштабируемости.

---

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

```
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
│   ├── wireguard/
│   └── bastion_nat/
└── network/
    └── bastion_nat/
```

> **Важно:** Ansible по умолчанию не ищет роли рекурсивно. Для подролей в `monitoring/`, `vpn/` и т.д. необходимо прописать пути в `ansible.cfg`:
> ```ini
> roles_path = ./roles:./roles/monitoring:./roles/vpn:./roles/postgres_cluster:...
> ```

### 2.2. Переменные в `group_vars`

Вся окружение-специфичная логика переехала из `vars` плейбуков в `group_vars`:

```
ansible/inventories/group_vars/
├── all/vars.yml                # Глобальные: monitoring_network_cidr, scrape_interval
├── bastion/vars.yml            # vmagent_remote_write_url, wireguard_exporter_enabled
├── controllers/vars.yml        # wireguard_exporter_enabled: false
├── monitoring/vars.yml         # victoria_metrics_version, retention
├── postgres_nodes/
│   ├── vars.yml                # postgres_exporter_enabled: true
│   └── vault.yml               # (зарезервировано)
└── workers/vars.yml
```

> **Нюанс:** Inventory генерируется Terraform в формате INI. `group_vars` подхватываются Ansible автоматически, если лежат рядом с inventory-файлами (или в `inventories/group_vars/` при `inventory = ./inventories`).

---

## 3. Рефакторинг monitoring (пошагово)

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
```
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
```
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

## 4. Рефакторинг VPN

### 4.1. Архитектурная проблема

WireGuard был завязан на K8s `controller-0` (10.0.0.10) как шлюз. Но в текущем окружении K8s не поднят, и `controller-0` отсутствует в inventory. Это приводило к:
```
hostvars['controller-0'] is undefined
```

### 4.2. Решение: mesh-топология без привязки к K8s

**Цель:** сделать VPN самодостаточным. Бастион (10.200.0.1) — hub, `monitoring-0` (10.200.0.3) — spoke. `controller-0` добавится позже как ещё один spoke.

**Подход:**
1. Словарь пиров в `group_vars/all/vars.yml`:
```yaml
wg_peers:
  bastion-host:
    tunnel_ip: "10.200.0.1"
    is_hub: true
    endpoint_host: "77.232.135.78"
  monitoring-0:
    tunnel_ip: "10.200.0.3"
    is_hub: false
```

2. Генерация ключей через отдельную таску `generate_keys.yml` + `fetch` на контроллер в `ansible/.wg-keys/`.

3. Шаблон `wg0.conf.j2` использует `lookup('file', ...)` для чтения публичных ключей с контроллера, вместо `hostvars`.

### 4.3. Проблема: `hostvars` между разными inventory-файлами

**Симптом:** `monitoring-0` (из `monitoring.ini`) не видит `bastion-host` (из `cloud.ini`) в `hostvars`.

**Причина:** Ansible загружает inventory файлы последовательно, но `hostvars` не мержатся между ними корректно при использовании `hostvars['имя_хоста']` в шаблонах.

**Решение:** Отказ от `hostvars` для ключей. Ключи хранятся на диске контроллера в `.wg-keys/` и подключаются через `lookup('file', ...)`. Это также позволяет переживать пересоздание хостов без потери ключей.

---

## 5. Команды для тестирования и дебага

### 5.1. Проверка inventory

```bash
# Граф групп
ansible-inventory -i inventories/ --graph

# Переменные конкретного хоста
ansible-inventory -i inventories/ --host monitoring-0

# Синтаксис group_vars
ansible-playbook -i inventories/ playbooks/site.yml --syntax-check
```

### 5.2. Check mode (безопасный прогон)

```bash
# Monitoring server
ansible-playbook -i inventories/ playbooks/new_deploy-monitoring.yml \
  --limit monitoring --tags server --check --diff

# Bastion (все агенты)
ansible-playbook -i inventories/ playbooks/new_deploy-monitoring.yml \
  --limit bastion --check --diff

# Postgres exporter
ansible-playbook -i inventories/ playbooks/deploy-db.yml \
  --tags postgres_exporter --check --diff

# VPN
ansible-playbook -i inventories/ playbooks/deploy-vpn.yml \
  --tags wireguard --check --diff
```

### 5.3. Проверка сервисов после деплоя

```bash
# Monitoring server
ansible monitoring-0 -i inventories/ -m shell -a "systemctl status victoria-metrics"
ansible monitoring-0 -i inventories/ -m shell -a "curl -s localhost:8428/health"

# Bastion
ansible bastion-host -i inventories/ -m shell -a "systemctl status node_exporter vmagent wireguard_exporter"
ansible bastion-host -i inventories/ -m shell -a "curl -s localhost:9100/metrics | head -3"
ansible bastion-host -i inventories/ -m shell -a "curl -s localhost:9586/metrics | head -3"

# Postgres
ansible pg-node-1 -i inventories/ -m shell -a "systemctl status postgres_exporter"
ansible pg-node-1 -i inventories/ -m shell -a "curl -s localhost:9187/metrics | head -3"

# VPN
ansible bastion-host -i inventories/ -m shell -a "wg show"
ansible monitoring-0 -i inventories/ -m shell -a "wg show"
ansible bastion-host -i inventories/ -m shell -a "ping -c 3 10.200.0.3"
```

### 5.4. Проверка remote_write

```bash
# На VictoriaMetrics должны появиться метрики
ansible monitoring-0 -i inventories/ -m shell -a \
  "curl -s 'localhost:8428/api/v1/query?query=up'"

# Лог vmagent на bastion (timeout'ы должны пропасть)
ansible bastion-host -i inventories/ -m shell -a "journalctl -u vmagent -n 20"
```

---

## 6. Что предстоит сделать (роадмап)

### 6.1. Ближайшее (техдолг рефакторинга)

- [ ] **Завершить VPN рефакторинг**
  - Вынести маршруты `systemd-networkd` (10.200.0.0/24, 192.168.10.0/24) из `monitoring/server` в `vpn/network_routes`
  - Добавить `controller-0` в `wg_peers` при поднятии K8s
  - Проверить `eth1` на бастионе — если интерфейс другой, вынести в переменную

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

- [ ] **Доделать `deploy-db.yml`**
  - Убедиться, что `postgres_exporter` встал на всех 3 нодах
  - Перенести `common`, `consul`, `patroni`, `haproxy`, `keepalived` в `roles/postgres_cluster/`

### 6.2. Среднесрочное (другие домены)

- [ ] **Рефакторинг `kubernetes/`**
  - Перенести `k8s_prep`, `container_runtime`, `k8s_install`, `k8s_control_plane`, `k8s_workers`, `k8s_cni` в `roles/kubernetes/`
  - Вынести `vpn_routes_worker` из `deploy-k8s.yml` в `vpn/routes/`

- [ ] **Рефакторинг `docker_swarm/`**
  - Перенести `docker_swarm`, `node_gateway` в `roles/docker_swarm/`
  - Убрать `bastion_nat` из `deploy-swarm.yml` (он теперь в VPN)

- [ ] **Рефакторинг `gitlab/`**
  - Перенести `gitlab_master`, `gitlab_runner` в `roles/gitlab/`

- [ ] **Рефакторинг `vpn/`**
  - Перенести `vpn_routes_worker` в `vpn/routes/`
  - Перенести `wireguard` и `bastion_nat` (уже сделано)
  - Добавить роль `vpn/gateway` (бывший `node_gateway`)

### 6.3. Долгосрочное (автоматизация и качество)

- [ ] **Taskfile.yml / Makefile** — единая точка входа
  ```yaml
  tasks:
    tf:init:
      dir: terraform/environments/{{.ENV}}
      cmds: ["terraform init"]
    ansible:site:
      dir: ansible
      cmds: ["ansible-playbook -i inventories/ playbooks/site.yml"]
  ```

- [ ] **Pre-commit hooks**
  - `terraform fmt`, `terraform validate`
  - `ansible-lint`
  - `yamlfmt`

- [ ] **GitLab CI**
  - `terraform validate` / `plan`
  - `ansible-lint`
  - `--check` прогон на staging

- [ ] **Dynamic inventory**
  - Terraform пишет `outputs` с IP и тегами
  - Ansible использует `community.general.terraform_state` вместо статических INI

- [ ] **Terraform структура**
  - Вынести `modules/` (twc_node, libvirt_node) из `environments/`
  - `environments/` — только тонкие wrappers + `terraform.tfvars`

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

> **TODO:** Вынести это в роль `network/firewall` или `_base/common`, чтобы не поднимать руками.

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


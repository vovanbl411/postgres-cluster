# Документация инфраструктуры: Docker Swarm + GitLab CI/CD

## Оглавление

1. [Обзор архитектуры](#обзор-архитектуры)
2. [Облачная инфраструктура (Timeweb)](#облачная-инфраструктура)
3. [Локальная инфраструктура (Libvirt/KVM)](#локальная-инфраструктура)
4. [Автоматизация Ansible](#автоматизация-ansible)
5. [Кластер Docker Swarm](#кластер-docker-swarm)
6. [Настройка GitLab и Runner](#настройка-gitlab-и-runner)
7. [Конвейер CI/CD](#конвейер-cicd)
8. [Сеть и устранение неполадок](#сеть-и-устранение-неполадок)
9. [Операционные руководства](#операционные-руководства)

---

## Обзор архитектуры

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ЛОКАЛЬНЫЙ САЙТ (KVM/Libvirt)                   │
│  ┌──────────────────────┐          ┌──────────────────────┐                 │
│  │   GitLab Master      │          │   GitLab Runner      │                 │
│  │   (Omnibus CE)       │◄────────►│   (Shell Executor)   │                 │
│  │   10.0.0.80          │   SSH    │   10.0.0.81          │                 │
│  └──────────┬───────────┘          └──────────┬───────────┘                 │
│             │                                 │                             │
│             └─────────────────────────────────┘                             │
│                          GitLab CI/CD                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       │ Деплой через SSH (ProxyJump)
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ОБЛАКО (Timeweb Cloud)                            │
│                                                                             │
│   ┌─────────────────┐                                                       │
│   │  Cloudflare     │                                                       │
│   │  Connector      │◄── Публичный IP                                       │
│   │  (Bastion/Jump) │                                                       │
│   │  192.168.10.2   │                                                       │
│   └────────┬────────┘                                                       │
│            │ NAT / ProxyJump                                                │
│            ▼                                                                │
│   ┌──────────────────────────────────────────────────────┐                  │
│   │              Docker Swarm VPC (192.168.10.0/24)      │                  │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐│                  │
│   │  │ swarm-node-1 │  │ swarm-node-2 │  │ swarm-node-3 ││                  │
│   │  │ Manager      │  │ Worker       │  │ Worker       ││                  │
│   │  │ 192.168.10.7 │  │ 192.168.10.4 │  │ 192.168.10.5 ││                  │
│   │  └──────────────┘  └──────────────┘  └──────────────┘│                  │
│   └──────────────────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Ключевые архитектурные решения

- **Terraform** управляет инфраструктурой (облако + локальные ВМ).
- **Ansible** настраивает системы (не используются cloud-init скрипты в Terraform).
- **S3 Backend** хранит состояние Terraform (Cloudflare R2 / MinIO).
- **Bastion Host** обеспечивает NAT и SSH точку входа для приватных узлов swarm.
- **GitLab Runner** использует **Shell executor** для прямого SSH деплоя на удалённый Swarm.

---

## Облачная инфраструктура

### Timeweb Cloud: Кластер Docker Swarm

#### Ресурсы

| Ресурс | Кол-во | Характеристики | Назначение |
|--------|--------|----------------|------------|
| `twc_server.node` | 3 | 2 vCPU / 2 ГБ ОЗУ / 20 ГБ | Узлы Docker Swarm |
| `twc_server.connector` | 1 | 1 vCPU / 1 ГБ ОЗУ / 15 ГБ | Bastion + Cloudflare туннель |
| `twc_vpc` | 1 | 192.168.10.0/24 | Приватная сеть |

#### Terraform State Backend (Cloudflare R2)

```hcl
terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "docker-swarm-cluster/terraform.tfstate"
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

#### Модуль: `twc_node`

Модуль для повторного использования для узлов swarm. Применённые исправления:

- **Сопоставление архитектуры:** `ansible_architecture` возвращает `x86_64`, но Docker репозиторий ожидает `amd64`.
- **Debian 13 (Trixie):** Официально поддерживается Docker CE.
- **Выводы:** `private_ips` извлекается из типа сети `local`.

#### Известные проблемы и исправления

1. **Несоответствие архитектуры Docker CE репозитория:**

   ```hcl
   # В Ansible: маппинг x86_64 -> amd64
   docker_arch: "{{ 'amd64' if ansible_architecture == 'x86_64' else ansible_architecture }}"
   ```

2. **Отсутствие публичного IP:** Узлы swarm имеют только приватные IP. Доступ в интернет через NAT на Bastion.

---

## Локальная инфраструктура

### Libvirt/KVM: Лаборатория GitLab

#### Ресурсы

| ВМ | IP | vCPU | ОЗУ | Назначение |
|----|-----|------|-----|------------|
| `gitlab-master-0` | 10.0.0.80 | 4 | 8 ГБ | GitLab CE Omnibus |
| `gitlab-runner-0` | 10.0.0.81 | 2 | 4 ГБ | GitLab Runner (Shell) |

#### Базовый образ

Облачный образ Ubuntu 24.04 (Noble):

```
/var/lib/libvirt/images/noble-server-cloudimg-amd64.img
```

#### Сеть

Сеть Libvirt NAT `local-net` (10.0.0.0/24) с DHCP и DNS.

#### Конфликт Docker + Libvirt nftables

**Проблема:** Docker создаёт таблицу `ip filter` с политикой `drop`. Libvirt создаёт правила с политикой `accept`. В nftables, DROP имеет приоритет на том же hook.

**Решение:** Сервис systemd внедряет правила ACCEPT в Docker-цепочку `DOCKER-USER`:

```ini
[Unit]
Description=Allow libvirt traffic through Docker FORWARD rules
After=docker.service libvirtd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables -I DOCKER-USER -i virbr+ -j ACCEPT
ExecStart=/sbin/iptables -I DOCKER-USER -o virbr+ -j ACCEPT
ExecStop=/sbin/iptables -D DOCKER-USER -i virbr+ -j ACCEPT
ExecStop=/sbin/iptables -D DOCKER-USER -o virbr+ -j ACCEPT

[Install]
WantedBy=multi-user.target
```

---

## Автоматизация Ansible

### Роль: `docker_swarm`

Устанавливает Docker CE и инициализирует кластер Swarm.

**Ключевые детали реализации:**

- Используется официальный метод установки Docker (устаревший `apt_key` не используется).
- GPG ключ скачивается в `/etc/apt/keyrings/docker.asc`.
- Кодовое имя Debian извлекается из `/etc/os-release`.
- Swarm инициализируется на первом узле (manager).
- Рабочие узлы (workers) присоединяются через токен.
- Overlay-сети создаются автоматически.

**Порядок выполнения задач:**

```
install_docker.yml → init_swarm.yml → join.yml → network.yml
```

**Идемпотентность:**

- При инициализации Swarm проверяется вывод `docker info` перед запуском.
- При присоединении worker проверяется `docker info` перед подключением.

### Роль: `bastion_nat`

Настраивает NAT на облачном bastion для узлов swarm.

```yaml
- iptables -t nat -A POSTROUTING -s 192.168.10.0/24 -j MASQUERADE
- iptables -A FORWARD -s 192.168.10.0/24 -j ACCEPT
- iptables -A FORWARD -d 192.168.10.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
```

### Роль: `node_gateway`

Добавляет маршрут по умолчанию через bastion на узлах swarm.

```yaml
ip route add default via <bastion_private_ip> dev eth1
```

Реализовано через сервис systemd oneshot для обеспечения постоянства.

### Роль: `gitlab_master`

Устанавливает GitLab CE Omnibus.

**Применённые критические исправления:**

1. **ОЗУ:** Минимум 8 ГБ (или 4 ГБ + 4 ГБ swap).
2. **Тайм-аут перенастройки:** `gitlab-ctl reconfigure` занимает 5–15 минут.
3. **Получение токена:** Используется `gitlab-rails runner` для извлечения токена регистрации из БД:

   ```ruby
   Gitlab::CurrentSettings.current_application_settings.runners_registration_token
   ```
4. **Репозиторий:** Жёстко задан `noble` (Ubuntu 24.04) вместо `ansible_distribution_release`.

**Шаблон `gitlab.rb.j2`:**

```ruby
external_url 'http://{{ ansible_default_ipv4.address }}'
postgresql['shared_buffers'] = "256MB"
sidekiq['max_concurrency'] = 10
prometheus_monitoring['enable'] = false
gitlab_rails['registry_enabled'] = false
```

### Роль: `gitlab_runner`

Устанавливает GitLab Runner с Shell executor.

**Регистрация:**

```bash
gitlab-runner register   --non-interactive   --url http://<gitlab_master_ip>   --registration-token <token>   --executor shell   --tag-list docker,swarm   --run-untagged true
```

**Передача токена:** Получается из `hostvars[gitlab_master]['gitlab_runner_token_raw']`.

---

## Кластер Docker Swarm

### Инициализация

```bash
# На manager-узле
docker swarm init --advertise-addr 192.168.10.7

# На рабочих узлах (workers)
docker swarm join --token <token> 192.168.10.7:2377
```

### Overlay-сеть

```bash
docker network create --driver overlay --attachable swarm-public
```

### Проверка

```bash
docker node ls
docker service ls
docker service ps <service>
```

### Требуемые порты
| Порт | Протокол | Назначение |
|------|----------|------------|
| 2377 | TCP | Управление кластером |
| 7946 | TCP/UDP | Gossip-протокол |
| 4789 | UDP | VXLAN overlay |

---

## Конвейер CI/CD

### Пример `.gitlab-ci.yml`

```yaml
stages:
  - build
  - deploy

variables:
  DOCKER_REGISTRY: "docker.io"
  IMAGE_NAME: "$DOCKER_REGISTRY/myapp"
  SSH_OPTS: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

build:
  stage: build
  script:
    - docker login -u $DOCKER_USER -p $DOCKER_PASS
    - docker build -t $IMAGE_NAME:$CI_COMMIT_SHA .
    - docker push $IMAGE_NAME:$CI_COMMIT_SHA
  tags:
    - docker

deploy:
  stage: deploy
  script:
    - |
      ssh $SSH_OPTS -J root@<bastion_ip> root@<swarm_manager_ip>         "docker service update --image $IMAGE_NAME:$CI_COMMIT_SHA myapp"
  tags:
    - swarm
  only:
    - main
```

### Требования к Runner

- CLI `docker` (для сборки образов)
- `openssh-client` (для ProxyJump)
- SSH-ключ с доступом к bastion → swarm manager

---

## Сеть и устранение неполадок

### Проблема: Узлы Swarm не могут достичь Docker Hub

**Симптом:** `docker service create` завершается с ошибкой `No such image`.

**Причина:** У узлов есть только приватные IP; маршрута по умолчанию нет.

**Решение:** Настроить NAT на bastion и маршрут по умолчанию на узлах.

### Проблема: `apt-key` не найден в Debian 13

**Симптом:** Ansible завершается с ошибкой `Failed to find required executable "apt-key"`.

**Решение:** Используйте `get_url` для скачивания `.asc` ключа в `/etc/apt/keyrings/`.

### Проблема: `Conflicting values set for option Signed-By`

**Симптом:** Конфликт `docker.gpg` и `docker.asc`.

**Решение:** Удалите старые файлы `.gpg` перед добавлением новых ключей `.asc`.

### Проблема: GitLab API возвращает 401

**Симптом:** Модуль `uri` завершается с ошибкой на `/api/v4/version`.

**Решение:** В новых версиях GitLab требуется аутентификация. Используйте `gitlab-ctl status` + `gitlab-rails runner` вместо этого.

### Проблема: nftables DROP против ACCEPT

**Симптом:** ВМ не имеют доступа в интернет при запущенном Docker на хосте.

**Решение:** Сервис systemd добавляет правила в цепочку `DOCKER-USER`.

---

## Операционные руководства

### Полный деплой (с нуля)

```bash
# 1. Облачная инфраструктура
cd terraform/cloud-docker-swarm
terraform init
terraform apply

# 2. Генерация Ansible inventory
cd ../../ansible
# inventory генерируется автоматически через Terraform local_file

# 3. Деплой Swarm + NAT + Gateway
ansible-playbook -i inventories/cloud.ini playbooks/deploy-swarm.yml

# 4. Локальная инфраструктура GitLab
cd ../terraform/local_gitlab
terraform init
terraform apply

# 5. Деплой GitLab + Runner
ansible-playbook -i inventories/gitlab.ini playbooks/deploy-gitlab.yml
```

### Добавление нового узла Swarm

1. Обновите `var.node_count` в Terraform.
2. `terraform apply`.
3. Запустите Ansible playbook (новый узел присоединится автоматически).

### Бэкап GitLab

```bash
# На gitlab-master-0
sudo gitlab-backup create
```

### Обновление сервиса Docker Swarm

```bash
# Через CI/CD (рекомендуется)
git push origin main

# Вручную
ssh -J root@bastion root@manager   "docker service update --image nginx:1.31 myapp"
```

---

## Ссылка на структуру файлов

```
.
├── ansible/
│   ├── inventories/
│   │   ├── cloud.ini          # Узлы Swarm (генерируется автоматически)
│   │   └── gitlab.ini         # ВМ GitLab (генерируется автоматически)
│   ├── playbooks/
│   │   ├── deploy-swarm.yml
│   │   └── deploy-gitlab.yml
│   └── roles/
│       ├── bastion_nat/
│       ├── docker_swarm/
│       ├── gitlab_master/
│       ├── gitlab_runner/
│       ├── node_gateway/
│       └── stack_deploy/
├── terraform/
│   ├── cloud-docker-swarm/    # Timeweb Cloud
│   ├── local_gitlab/          # ВМ Libvirt
│   └── templates/
│       ├── inventory_cloud.tmpl
│       ├── inventory_local.tmpl
│       └── gitlab.tmpl
└── docs/
    └── infrastructure.md      # Этот файл
```

---

## Стек технологий

| Уровень | Технология |
|---------|------------|
| Провайдер облака | Timeweb Cloud |
| Локальный гипервизор | KVM / Libvirt |
| IaC | Terraform |
| CM (управление конфигурациями) | Ansible |
| Оркестрация контейнеров | Docker Swarm |
| CI/CD | GitLab CE + GitLab Runner |
| Бэкенд состояния (State Backend) | Cloudflare R2 / MinIO |
| ОС (Облако) | Debian 13 (Trixie) |
| ОС (Локальная) | Ubuntu 24.04 (Noble) |
| Сеть | Cloudflare Tunnel, NAT, VXLAN |

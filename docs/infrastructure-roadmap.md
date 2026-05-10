# Дорожная карта расширения инфраструктуры: PostgreSQL, Redis, Kafka, Backups

> **Документ проектирует будущее состояние инфраструктуры.** Все новые сервисы размещаются в изолированных сетях с чётким разделением ответственности. Существующая гибридная архитектура (локальный K8s + облачная БД) сохраняется и расширяется.

---

## 📋 Оглавление

- [Дорожная карта расширения инфраструктуры: PostgreSQL, Redis, Kafka, Backups](#дорожная-карта-расширения-инфраструктуры-postgresql-redis-kafka-backups)
  - [📋 Оглавление](#-оглавление)
  - [1. Общая концепция](#1-общая-концепция)
    - [Принципы проектирования](#принципы-проектирования)
    - [Эволюция инфраструктуры](#эволюция-инфраструктуры)
  - [2. Сетевая архитектура (целевая)](#2-сетевая-архитектура-целевая)
    - [2.1. Сводная таблица всех сетей](#21-сводная-таблица-всех-сетей)
    - [2.2. Маршрутизация между зонами](#22-маршрутизация-между-зонами)
    - [Каждая зона — изолированная VPC](#каждая-зона--изолированная-vpc)
    - [Маршруты (целевая таблица)](#маршруты-целевая-таблица)
  - [3. Зона A: PostgreSQL HA + Backups](#3-зона-a-postgresql-ha--backups)
    - [3.1. Текущее состояние](#31-текущее-состояние)
    - [3.2. WAL-G бэкапы](#32-wal-g-бэкапы)
    - [3.3. Логическая репликация](#33-логическая-репликация)
    - [3.4. PgBouncer (пул соединений)](#34-pgbouncer-пул-соединений)
    - [3.5. Read Replicas + HAProxy](#35-read-replicas--haproxy)
    - [3.6. Мониторинг PostgreSQL](#36-мониторинг-postgresql)
  - [4. Зона B: Redis Cluster](#4-зона-b-redis-cluster)
    - [4.1. Архитектура Redis Cluster](#41-архитектура-redis-cluster)
    - [4.2. Сетевая изоляция Redis](#42-сетевая-изоляция-redis)
    - [4.3. Redis Sentinel (альтернатива)](#43-redis-sentinel-альтернатива)
    - [4.4. Персистентность и бэкапы](#44-персистентность-и-бэкапы)
    - [4.5. Мониторинг Redis](#45-мониторинг-redis)
  - [5. Зона C: Kafka Cluster](#5-зона-c-kafka-cluster)
    - [5.1. Архитектура Kafka](#51-архитектура-kafka)
    - [5.2. KRaft vs ZooKeeper](#52-kraft-vs-zookeeper)
    - [5.3. Топики и партиции](#53-топики-и-партиции)
    - [5.4. Schema Registry](#54-schema-registry)
    - [5.5. Kafka Connect (CDC)](#55-kafka-connect-cdc)
    - [5.6. Мониторинг Kafka](#56-мониторинг-kafka)
  - [6. Зона D: Object Storage (Backups)](#6-зона-d-object-storage-backups)
    - [6.1. Cloudflare R2](#61-cloudflare-r2)
    - [6.2. Политики хранения](#62-политики-хранения)
    - [6.3. Шифрование](#63-шифрование)
  - [7. Зона E: Monitoring (расширенная)](#7-зона-e-monitoring-расширенная)
    - [7.1. Alertmanager / vmalert](#71-alertmanager--vmalert)
    - [7.2. Дашборды](#72-дашборды)
    - [7.3. Логирование (Loki)](#73-логирование-loki)
  - [8. Интеграция сервисов](#8-интеграция-сервисов)
    - [8.1. Application → PgBouncer → PostgreSQL](#81-application--pgbouncer--postgresql)
    - [8.2. Application → Redis Cluster](#82-application--redis-cluster)
    - [8.3. PostgreSQL → Kafka Connect → Kafka](#83-postgresql--kafka-connect--kafka)
    - [8.4. Kafka → Consumers](#84-kafka--consumers)
  - [9. Отказоустойчивость и DR](#9-отказоустойчивость-и-dr)
    - [9.1. RPO и RTO по сервисам](#91-rpo-и-rto-по-сервисам)
    - [9.2. План аварийного восстановления](#92-план-аварийного-восстановления)
  - [10. Ресурсы и бюджет](#10-ресурсы-и-бюджет)
    - [Текущие ресурсы (Timeweb Cloud)](#текущие-ресурсы-timeweb-cloud)
    - [Планируемые ресурсы](#планируемые-ресурсы)
  - [11. Этапы внедрения](#11-этапы-внедрения)
    - [Этап 1: WAL-G бэкапы (2-3 дня)](#этап-1-wal-g-бэкапы-2-3-дня)
    - [Этап 2: PgBouncer (1-2 дня)](#этап-2-pgbouncer-1-2-дня)
    - [Этап 3: Redis Cluster (3-5 дней)](#этап-3-redis-cluster-3-5-дней)
    - [Этап 4: Kafka Cluster (5-7 дней)](#этап-4-kafka-cluster-5-7-дней)
    - [Этап 5: Observability (3-4 дня)](#этап-5-observability-3-4-дня)
    - [Этап 6: Интеграция и тестирование (3-5 дней)](#этап-6-интеграция-и-тестирование-3-5-дней)

---

## 1. Общая концепция

### Принципы проектирования

| Принцип | Реализация |
|---------|-----------|
| **Изоляция по сетям** | Каждый сервис — своя подсеть / VPC, доступ через bastion или VPN |
| **Push-модель мониторинга** | vmagent на каждой ноде → VictoriaMetrics (уже работает) |
| **Бэкапы в S3** | WAL-G, redis-cli, kafka-backup → Cloudflare R2 |
| **IaC всё** | Terraform + Ansible, repeatable, versioned |
| **Нет публичных IP у БД** | Только через bastion / VPN / internal LB |
| **Peer-аутентификация где возможно** | postgres_exporter, redis_exporter — unix-socket |

### Эволюция инфраструктуры

```
Phase 1 (Сейчас):     K8s (local) ──WG──► PostgreSQL HA (cloud)
                              │
                              └──► VictoriaMetrics (local)

Phase 2 (Бэкапы):    + WAL-G ──► R2 (S3)
                      + PgBouncer
                      + Read Replicas

Phase 3 (Redis):     + Redis Cluster (cloud, new VPC)
                      + redis_exporter → VM

Phase 4 (Kafka):     + Kafka Cluster (cloud, new VPC)
                      + Kafka Connect (CDC from PostgreSQL)
                      + Schema Registry

Phase 5 (Observability): + vmalert / Alertmanager
                         + Loki (логи)
                         + Дашборды
```

---

## 2. Сетевая архитектура (целевая)

### 2.1. Сводная таблица всех сетей

| Зона | Сеть | Назначение | Хосты | Шлюз в другие сети |
|------|------|-----------|-------|-------------------|
| **Local K8s** | `10.0.0.0/24` | Локальный кластер | controller-0, worker-0,1, monitoring-0 | controller-0 (WG) |
| **WG Tunnel** | `10.200.0.0/24` | WireGuard VPN | bastion (10.200.0.1), controller-0 (10.200.0.2) | — |
| **Pod CIDR** | `10.244.0.0/16` | Kubernetes pods | Все pods | Cilium VXLAN |
| **Zone A: PostgreSQL** | `192.168.10.0/24` | PostgreSQL HA + Patroni + Consul | pg-node-1,2,3, bastion eth1 | bastion (WG) |
| **Zone B: Redis** | `192.168.20.0/24` | Redis Cluster | redis-node-1..6 | redis-bastion (WG) |
| **Zone C: Kafka** | `192.168.30.0/24` | Kafka + ZooKeeper/KRaft | kafka-broker-1,2,3, kafka-connect | kafka-bastion (WG) |
| **Zone D: Backups** | — | Cloudflare R2 (S3) | — | HTTPS (публичный) |
| **Zone E: Monitoring** | `10.0.0.30/32` | VictoriaMetrics + VMUI | monitoring-0 | controller-0 |

### 2.2. Маршрутизация между зонами

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              ЛОКАЛЬНЫЙ ДАТАЦЕНТР                                    │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │  Kubernetes Cluster (10.0.0.0/24) + Pods (10.244.0.0/16)                    │    │
│  │  controller-0 (10.0.0.10) ──wg0──► 10.200.0.2                               │    │
│  │  monitoring-0 (10.0.0.30) ←── метрики ── все зоны                           │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                              │                                                      │
│                    ╔═════════╧═════════╗                                            │
│                    ║  WireGuard VPN  ║  10.200.0.0/24                               │
│                    ╚═════════╤═════════╝                                            │
│                              │                                                      │
└──────────────────────────────┼──────────────────────────────────────────────────────┘
                               │
┌──────────────────────────────┼────────────────────────────────────────────────────────┐
│                           ОБЛАКО (Timeweb Cloud)                                      │
│                                                                                       │
│  ┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐│
│  │  Zone A: PostgreSQL     │  │  Zone B: Redis          │  │  Zone C: Kafka          ││
│  │  192.168.10.0/24        │  │  192.168.20.0/24        │  │  192.168.30.0/24        ││
│  │                         │  │                         │  │                         ││
│  │  pg-node-1 (10.4)       │  │  redis-node-1 (20.4)    │  │  kafka-broker-1 (30.4)  ││
│  │  pg-node-2 (10.5)       │  │  redis-node-2 (20.5)    │  │  kafka-broker-2 (30.5)  ││
│  │  pg-node-3 (10.6)       │  │  redis-node-3 (20.6)    │  │  kafka-broker-3 (30.6)  ││
│  │  bastion (10.7)         │  │  redis-node-4 (20.7)    │  │  kafka-connect (30.7)   ││
│  │                         │  │  redis-node-5 (20.8)    │  │  schema-registry (30.8) ││
│  │  VIP: 192.168.10.100    │  │  redis-node-6 (20.9)    │  │                         ││
│  │                         │  │  redis-bastion (20.10)  │  │  kafka-bastion (30.10)  ││
│  │  WG: 10.200.0.1         │  │  WG: 10.200.0.3         │  │  WG: 10.200.0.4         ││
│  └─────────────────────────┘  └─────────────────────────┘  └─────────────────────────┘│
│           │                            │                            │                 │
│           └────────────────────────────┼────────────────────────────┘                 │
│                                        │                                              │
│                              ┌─────────┴─────────┐                                    │
│                              │  Zone D: Backups  │                                    │
│                              │  Cloudflare R2    │                                    │
│                              │  (S3-compatible)  │                                    │
│                              └───────────────────┘                                    │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

### Каждая зона — изолированная VPC

- **Разные подсети** — нет пересечений адресов
- **Свой bastion** — каждая зона имеет точку входа через WG
- **Свой WG endpoint** — уникальный IP в туннеле (10.200.0.x)
- **Межзоновый трафик** — через локальный K8s (controller-0) как hub

### Маршруты (целевая таблица)

| Откуда | Куда | Gateway | Интерфейс | Примечание |
|--------|------|---------|-----------|------------|
| K8s Pod (10.244.x.x) | PostgreSQL (192.168.10.x) | 10.0.0.10 | ens3 → wg0 | Через controller-0 |
| K8s Pod | Redis (192.168.20.x) | 10.0.0.10 | ens3 → wg0 | Через controller-0 |
| K8s Pod | Kafka (192.168.30.x) | 10.0.0.10 | ens3 → wg0 | Через controller-0 |
| PostgreSQL (192.168.10.x) | Monitoring (10.0.0.30) | 192.168.10.7 | eth1 → wg0 | Через pg-bastion |
| Redis (192.168.20.x) | Monitoring (10.0.0.30) | 192.168.20.10 | eth1 → wg0 | Через redis-bastion |
| Kafka (192.168.30.x) | Monitoring (10.0.0.30) | 192.168.30.10 | eth1 → wg0 | Через kafka-bastion |
| monitoring-0 | PostgreSQL | 10.0.0.10 | ens3 | Через controller-0 |
| monitoring-0 | Redis | 10.0.0.10 | ens3 | Через controller-0 |
| monitoring-0 | Kafka | 10.0.0.10 | ens3 | Через controller-0 |

---

## 3. Зона A: PostgreSQL HA + Backups

### 3.1. Текущее состояние

Уже развёрнуто:
- PostgreSQL 17 + Patroni + Consul (3 ноды)
- HAProxy (5432 RW, 5433 RO) + Keepalived (VIP 192.168.10.100)
- node_exporter + vmagent + postgres_exporter
- Метрики доходят в VictoriaMetrics

### 3.2. WAL-G бэкапы

**Архитектура:**
```
PostgreSQL Leader
    │
    ├─── archive_command = 'wal-g wal-push %p'
    │
    ├─── wal-g backup-push (cron, ежедневно 02:00)
    │
    └─── Cloudflare R2 (S3-compatible)
         └── bucket: postgres-backups
             ├── basebackups/
             │   ├── 20260427T020000Z/
             │   ├── 20260428T020000Z/
             │   └── ...
             └── wal/
                 ├── 000000010000000000000001
                 └── ...
```

**Retention policy:**
- Полные бэкапы: 7 штук (7 дней)
- WAL: 30 дней
- Итого: PITR на 30 дней назад

**WAL-G конфигурация:**
```bash
# /etc/wal-g/wal-g.yaml
AWS_ACCESS_KEY_ID: <r2-access-key>
AWS_SECRET_ACCESS_KEY: <r2-secret-key>
AWS_ENDPOINT: https://<account-id>.r2.cloudflarestorage.com
AWS_S3_FORCE_PATH_STYLE: true
WALG_S3_PREFIX: s3://postgres-backups
WALG_COMPRESSION_METHOD: lz4
WALG_DELTA_MAX_STEPS: 7
WALG_UPLOAD_CONCURRENCY: 4
PGHOST: /var/run/postgresql
PGUSER: postgres
```

**Роль Ansible:** `wal_g`
- Установка бинарника (скачивание на controller, copy на target)
- Создание systemd таймера для backup-push
- Настройка postgresql.conf: `archive_mode = on`, `archive_command`
- Мониторинг: wal-g-exporter или custom script

**Восстановление (PITR):**
```bash
# 1. Остановить Patroni на ноде
systemctl stop patroni

# 2. Очистить данные
rm -rf /var/lib/postgresql/17/main/*

# 3. Восстановить из бэкапа
wal-g backup-fetch /var/lib/postgresql/17/main LATEST

# 4. Создать recovery.signal
touch /var/lib/postgresql/17/main/recovery.signal

# 5. Настроить recovery.conf (PostgreSQL 17: postgresql.conf)
echo "restore_command = 'wal-g wal-fetch %f %p'" >> postgresql.conf

# 6. Запустить PostgreSQL в recovery
systemctl start postgresql

# 7. После recovery — перезапустить Patroni
systemctl start patroni
```

### 3.3. Логическая репликация

**Зачем:** Репликация отдельных таблиц/БД на другие кластеры (аналитика, тестирование, миграция).

**Архитектура:**
```
┌──────────────────────┐         ┌─────────────────────┐
│  PostgreSQL HA       │         │  PostgreSQL Analytic│
│  (Production)        │         │  (Read-only replica)│
│  192.168.10.0/24     │         │  192.168.40.0/24    │
│                      │         │                     │
│  CREATE PUBLICATION  │────────►│  CREATE SUBSCRIPTION│
│  pub_analytics FOR   │  logical│  sub_analytics      │
│  TABLE events, orders│  repl   │  CONNECTION 'host=..│
└──────────────────────┘         └─────────────────────┘
```

**Настройка:**
```sql
-- На лидере (production)
CREATE PUBLICATION pub_analytics FOR TABLE events, orders, users;

-- На аналитическом кластере
CREATE SUBSCRIPTION sub_analytics
CONNECTION 'host=192.168.10.100 port=5432 user=replicator password=... dbname=app'
PUBLICATION pub_analytics;
```

**Ограничения:**
- Только таблицы (не мат. представления, не DDL)
- Нет авто-failover подписки (нужен внешний мониторинг)
- Большие транзакции → лаг репликации

### 3.4. PgBouncer (пул соединений)

**Зачем:** PostgreSQL неэффективен при большом количестве коротких соединений. PgBouncer держит пул готовых соединений.

**Архитектура:**
```
Application (1000 conn) ──► PgBouncer (50 conn) ──► PostgreSQL (max_connections=200)
```

**Режимы:**
- **Session** — соединение 1:1 с бэкендом (совместимость)
- **Transaction** — соединение отдаётся после COMMIT (рекомендуется)
- **Statement** — соединение отдаётся после каждого запроса (рискованно)

**Конфигурация:**
```ini
; /etc/pgbouncer/pgbouncer.ini
[databases]
app = host=192.168.10.100 port=5432 dbname=app

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = hba
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 10000
default_pool_size = 50
reserve_pool_size = 10
server_idle_timeout = 600
```

**Размещение:** На каждой ноде приложения (sidecar) или на dedicated VM в зоне K8s.

### 3.5. Read Replicas + HAProxy

**Текущее:** HAProxy на порту 5433 балансирует между репликами.

**Улучшение:** Отдельный HAProxy tier для read-only трафика.

```
Application (read) ──► haproxy-read (192.168.10.101:5433)
                           │
                           ├──► pg-node-1 (replica) ── weight 100
                           ├──► pg-node-2 (replica) ── weight 100
                           └──► pg-node-3 (leader) ─── weight 0 (backup)
```

**Проверка здоровья:**
```
option httpchk GET /replica
http-check expect status 200
```

Patroni REST API `/replica` возвращает 200 только для реплик.

### 3.6. Мониторинг PostgreSQL

**Уже работает:** postgres_exporter (peer auth, unix-socket)

**Дополнительно:**
- **wal-g-exporter** — метрики бэкапов (время последнего, размер, ошибки)
- **pgbouncer_exporter** — метрики пула (активные соединения, ожидание, ошибки)
- **patroni_exporter** — метрики кластера (роль, lag, timeline)

**PromQL:**
```promql
# Лаг репликации
pg_stat_replication_pg_stat_replication_lag

# Количество активных соединений
pg_stat_activity_count{datname="app"}

# Время с последнего бэкапа
time() - wal_g_last_backup_timestamp

# Ожидание в PgBouncer
pgbouncer_pools_client_waiting
```

---

## 4. Зона B: Redis Cluster

### 4.1. Архитектура Redis Cluster

**Redis Cluster** — нативное шардирование с авто-failover.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    Redis Cluster (6 нод)                                 │
│                   192.168.20.0/24                                        │
│                                                                          │
│   ┌────────────────┐    ┌───────────────────┐      ┌────────────────────┐│
│   │ redis-node-1   │    │ redis-node-2      │      │ redis-node-3       ││
│   │ 192.168.20.4   │    │ 192.168.20.5      │      │ 192.168.20.6       ││
│   │ Master: 0-5460 │    │ Master: 5461-10922│      │ Master: 10923-16383││
│   │ Replica: node-4│    │Replica: node-5    │      │ Replica: node-6    ││
│   └──────┬─────────┘    └──────┬────────────┘      └──────┬─────────────┘│
│          │                     │                          │              │
│   ┌──────┴────────┐       ┌────┴──────────┐         ┌─────┴────────┐     │
│   │ redis-node-4  │       │ redis-node-5  │         │ redis-node-6 │     │
│   │ 192.168.20.7  │       │ 192.168.20.8  │         │ 192.168.20.9 │     │
│   │ Replica node-1│       │ Replica node-2│         │Replica node-3│     │
│   └───────────────┘       └───────────────┘         └──────────────┘     │
│                                                                          │
│   Hash slots: 0-16383 (равномерно распределены)                          │
│   Replication: async (каждый master имеет 1 replica)                     │
│   Failover: автоматический (если master падает, replica                  │
│             promote'ится через gossip)                                   │
└──────────────────────────────────────────────────────────────────────────┘
```

**Почему 6 нод (3 master + 3 replica):**
- Минимум для production: 3 master (кворум)
- Replica нужны для failover и чтения
- Можно масштабировать до 100+ нод

**Порты:**
- `6379` — клиентские соединения
- `16379` — bus (gossip, cluster communication)

### 4.2. Сетевая изоляция Redis

**VPC:** `192.168.20.0/24` (отдельная от PostgreSQL)

**Bastion:** `redis-bastion` (192.168.20.10, WG: 10.200.0.3)

**Доступ:**
- Из K8s: через controller-0 → WG → redis-bastion → Redis
- Из PostgreSQL: напрямую (если нужно кэширование)
- Извне: только через bastion / VPN

**Firewall (iptables на каждой ноде):**
```bash
# Разрешить cluster bus (gossip)
iptables -A INPUT -p tcp --dport 6379 -s 192.168.20.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 16379 -s 192.168.20.0/24 -j ACCEPT

# Запретить всё остальное
iptables -A INPUT -p tcp --dport 6379 -j DROP
iptables -A INPUT -p tcp --dport 16379 -j DROP
```

### 4.3. Redis Sentinel (альтернатива)

**Когда использовать Sentinel вместо Cluster:**
- Нужна только HA (master + replica), не шардирование
- Данные помещаются в RAM одной ноды
- Простота конфигурации важнее масштабирования

**Sentinel архитектура:**
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Sentinel 1 │◄───►│  Sentinel 2 │◄───►│  Sentinel 3 │
│  (monitor)  │     │  (monitor)  │     │  (monitor)  │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       └───────────────────┼───────────────────┘
                           │
                    ┌──────┴──────┐
                    │   Master    │◄───── Application (write)
                    │  192.168... │
                    └──────┬──────┘
                           │ replication
                    ┌──────┴──────┐
                    │   Replica   │◄───── Application (read)
                    │  192.168... │
                    └─────────────┘
```

**Рекомендация:** Для нашей инфраструктуры — **Redis Cluster**, так как планируется рост и шардирование.

### 4.4. Персистентность и бэкапы

**RDB (snapshot):**
```bash
# redis.conf
save 900 1      # сохранять если 1 изменение за 15 мин
save 300 10     # сохранять если 10 изменений за 5 мин
save 60 10000   # сохранять если 10000 изменений за 1 мин
dbfilename dump.rdb
dir /var/lib/redis
```

**AOF (Append Only File):**
```bash
appendonly yes
appendfsync everysec  # баланс производительности/надёжности
```

**Бэкапы в R2:**
```bash
# Скрипт бэкапа (cron, ежечасно)
redis-cli BGSAVE
sleep 5
cp /var/lib/redis/dump.rdb /tmp/redis-backup-$(date +%Y%m%d-%H%M).rdb
rclone copy /tmp/redis-backup-*.rdb r2:redis-backups/
```

**Роль Ansible:** `redis_cluster`
- Установка Redis 7.x
- Настройка cluster (redis-cli --cluster create)
- Настройка persistence (RDB + AOF)
- Бэкап-скрипт + systemd timer
- redis_exporter для мониторинга

### 4.5. Мониторинг Redis

**redis_exporter** (на каждой ноде):
```bash
redis_exporter --redis.addr=redis://localhost:6379
```

**PromQL:**
```promql
# Доступность ноды
redis_up

# Использование памяти
redis_memory_used_bytes / redis_memory_max_bytes * 100

# Количество ключей
redis_db_keys{db="0"}

# Операций в секунду
rate(redis_commands_processed_total[1m])

# Сетевой трафик
rate(redis_net_input_bytes_total[1m])
rate(redis_net_output_bytes_total[1m])

# Cluster state
redis_cluster_state  # 1 = ok, 0 = fail
redis_cluster_slots_assigned
redis_cluster_slots_ok
```

---

## 5. Зона C: Kafka Cluster

### 5.1. Архитектура Kafka

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Kafka Cluster (3 брокера)                        │
│                       192.168.30.0/24                               │
│                                                                     │
│   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
│   │ kafka-broker-1  │  │ kafka-broker-2  │  │ kafka-broker-3  │     │
│   │ 192.168.30.4    │  │ 192.168.30.5    │  │ 192.168.30.6    │     │
│   │                 │  │                 │  │                 │     │
│   │  broker.id=1    │  │  broker.id=2    │  │  broker.id=3    │     │
│   │  listeners=...  │  │  listeners=...  │  │  listeners=...  │     │
│   │  log.dirs=/data │  │  log.dirs=/data │  │  log.dirs=/data │     │
│   └─────────────────┘  └─────────────────┘  └─────────────────┘     │
│                                                                     │
│   Replication factor: 3 (каждая партиция на всех брокерах)          │
│   Min ISR: 2 (минимум 2 синхронных реплики для commit)              │
│   Retention: 7 дней (логи), компрессия: snappy                      │
│                                                                     │
│   ┌─────────────────┐  ┌─────────────────┐                          │
│   │ kafka-connect   │  │ schema-registry │                          │
│   │ 192.168.30.7    │  │ 192.168.30.8    │                          │
│   │                 │  │                 │                          │
│   │  CDC from PG    │  │  Avro schemas   │                          │
│   │  Sink to S3     │  │  compatibility  │                          │
│   └─────────────────┘  └─────────────────┘                          │
│                                                                     │
│   Bastion: kafka-bastion (192.168.30.10, WG: 10.200.0.4)            │
└─────────────────────────────────────────────────────────────────────┘
```

**Порты:**
- `9092` — PLAINTEXT (внутри VPC)
- `9093` — SSL (если нужен)
- `2181` — ZooKeeper (если используется)
- `8081` — Schema Registry REST API
- `8083` — Kafka Connect REST API

### 5.2. KRaft vs ZooKeeper

| | KRaft (Kafka 3.x+) | ZooKeeper |
|---|---------------------|-----------|
| **Архитектура** | Встроенный консенсус (Raft) | Внешний координатор |
| **Зависимости** | Нет | ZooKeeper ensemble (3 ноды) |
| **Сложность** | Меньше | Больше |
| **Производительность** | Лучше (меньше hops) | Хуже |
| **Зрелость** | Production-ready с Kafka 3.3+ | Проверено годами |

**Рекомендация:** KRaft для новых инсталляций (проще, быстрее).

**KRaft конфигурация:**
```properties
# server.properties (KRaft)
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@kafka-broker-1:9093,2@kafka-broker-2:9093,3@kafka-broker-3:9093
listeners=PLAINTEXT://:9092,CONTROLLER://:9093
log.dirs=/var/lib/kafka/data
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
```

### 5.3. Топики и партиции

**Топик `events` (основной поток событий):**
```bash
kafka-topics.sh --create   --topic events   --partitions 12   --replication-factor 3   --config retention.ms=604800000   --config compression.type=snappy
```

**Топик `cdc-users` (CDC из PostgreSQL):**
```bash
kafka-topics.sh --create   --topic cdc-users   --partitions 6   --replication-factor 3   --config cleanup.policy=compact  # log compaction для CDC
```

**Почему 12 партиций:**
- Масштабирование: до 12 параллельных consumers
- Баланс: не слишком много (накладные расходы), не мало (бутылочное горлышко)

### 5.4. Schema Registry

**Зачем:** Версионирование схем Avro/Protobuf/JSON Schema. Consumer знает, как десериализовать сообщение.

**Работа:**
```bash
# Регистрация схемы
curl -X POST http://192.168.30.8:8081/subjects/events-value/versions   -H "Content-Type: application/vnd.schemaregistry.v1+json"   -d '{"schema": "{"type":"record",...}"}'

# Проверка совместимости
curl http://192.168.30.8:8081/compatibility/subjects/events-value/versions/latest
```

**Compatibility modes:**
- `BACKWARD` (default) — новая схема читает старые данные
- `FORWARD` — старая схема читает новые данные
- `FULL` — оба направления

### 5.5. Kafka Connect (CDC)

**Debezium connector** — CDC из PostgreSQL в Kafka.

```json
{
  "name": "postgres-cdc-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "192.168.10.100",
    "database.port": "5432",
    "database.user": "debezium",
    "database.password": "...",
    "database.dbname": "app",
    "database.server.name": "pg-app",
    "plugin.name": "pgoutput",
    "table.include.list": "public.users,public.orders",
    "topic.prefix": "cdc"
  }
}
```

**Что происходит:**
1. Debezium читает WAL PostgreSQL (логическая репликация)
2. Каждая DML-операция → событие в Kafka
3. Событие содержит: `before` (старые данные), `after` (новые данные), `op` (c/u/d)

**Потребители:**
- ElasticSearch (поиск)
- S3 (архив)
- Analytics DB (ClickHouse)
- Cache invalidation (Redis)

### 5.6. Мониторинг Kafka

**kafka_exporter** (JMX + Prometheus):
```bash
kafka_exporter --kafka.server=kafka-broker-1:9092
```

**PromQL:**
```promql
# Доступность брокеров
kafka_brokers

# Lag по consumer group
kafka_consumer_group_lag{group="app-consumers"}

# Размер партиции
kafka_topic_partition_current_offset{topic="events"}

# Under-replicated partitions (критично!)
kafka_topic_partition_under_replicated_partition

# Request rate
rate(kafka_server_brokertopicmetrics_messagesin_total[1m])

# Disk usage
kafka_log_log_size{topic="events"}
```

---

## 6. Зона D: Object Storage (Backups)

### 6.1. Cloudflare R2

**Почему R2:**
- S3-compatible API
- Нет egress-тарифов (в отличие от AWS S3)
- Интеграция с Terraform state
- Уже используется для Terraform backend

**Бакеты:**
| Бакет | Назначение | Политика |
|-------|-----------|----------|
| `postgres-backups` | WAL-G бэкапы + WAL | 30 дней |
| `redis-backups` | RDB snapshots | 7 дней |
| `kafka-backups` | Логи топиков (MirrorMaker 2) | 30 дней |
| `terraform-state` | Terraform стейт | версионирование |
| `app-logs` | Логи приложений (Loki) | 90 дней |

### 6.2. Политики хранения

**R2 Lifecycle Rules:**
```xml
<LifecycleConfiguration>
  <Rule>
    <ID>postgres-wal-expiration</ID>
    <Status>Enabled</Status>
    <Filter>
      <Prefix>wal/</Prefix>
    </Filter>
    <Expiration>
      <Days>30</Days>
    </Expiration>
  </Rule>
  <Rule>
    <ID>postgres-basebackups-transition</ID>
    <Status>Enabled</Status>
    <Filter>
      <Prefix>basebackups/</Prefix>
    </Filter>
    <Transition>
      <Days>7</Days>
      <StorageClass>InfrequentAccess</StorageClass>
    </Transition>
  </Rule>
</LifecycleConfiguration>
```

### 6.3. Шифрование

**Server-side encryption (SSE):**
- R2 шифрует данные at rest по умолчанию
- Дополнительно: client-side encryption для sensitive данных

**WAL-G encryption:**
```bash
export WALG_PGP_KEY_PATH=/etc/wal-g/pgp-key.asc
```

---

## 7. Зона E: Monitoring (расширенная)

### 7.1. Alertmanager / vmalert

**vmalert** (встроен в VictoriaMetrics ecosystem):
```yaml
# /etc/vmalert/alerts.yml
groups:
  - name: postgresql
    rules:
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL is down on {{ $labels.instance }}"

      - alert: PostgreSQLReplicationLag
        expr: pg_stat_replication_pg_stat_replication_lag > 10000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Replication lag > 10s on {{ $labels.instance }}"

      - alert: PostgreSQLBackupOld
        expr: time() - wal_g_last_backup_timestamp > 86400
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "No backup for 24h"

  - name: redis
    rules:
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical

      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels:
          severity: warning

  - name: kafka
    rules:
      - alert: KafkaUnderReplicatedPartitions
        expr: kafka_topic_partition_under_replicated_partition > 0
        for: 1m
        labels:
          severity: critical

      - alert: KafkaConsumerLagHigh
        expr: kafka_consumer_group_lag > 100000
        for: 15m
        labels:
          severity: warning
```

**Alertmanager integration:**
```yaml
# alertmanager.yml
route:
  receiver: telegram
  routes:
    - match:
        severity: critical
      receiver: telegram
      continue: true
    - match:
        severity: warning
      receiver: email

receivers:
  - name: telegram
    telegram_configs:
      - bot_token: <token>
        chat_id: <chat_id>
  - name: email
    email_configs:
      - to: ops@example.com
        from: alerts@example.com
        smarthost: smtp.example.com:587
```

### 7.2. Дашборды

**VMUI** — базовый интерфейс VictoriaMetrics.

**Grafana** (опционально, если решим проблему с apt):
- Импорт дашбордов:
  - Node Exporter Full (ID: 1860)
  - PostgreSQL Overview (ID: 9628)
  - Redis Dashboard (ID: 763)
  - Kafka Overview (ID: 7589)

### 7.3. Логирование (Loki)

**Архитектура:**
```
Application logs ──► Promtail (на каждой ноде) ──► Loki ──► Grafana
```

**Promtail config:**
```yaml
server:
  http_listen_port: 9080

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: postgresql
    static_configs:
      - targets:
          - localhost
        labels:
          job: postgresql
          __path__: /var/log/postgresql/*.log

  - job_name: patroni
    static_configs:
      - targets:
          - localhost
        labels:
          job: patroni
          __path__: /var/log/patroni/*.log
```

**Loki хранение:** R2 (S3) через `loki-storage-config`.

---

## 8. Интеграция сервисов

### 8.1. Application → PgBouncer → PostgreSQL

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  App Pod │───►│ PgBouncer│───►│ HAProxy  │───►│PostgreSQL│
│(K8s)     │    │(sidecar) │    │(VIP)     │    │(Leader)  │
└──────────┘    │:6432     │    │:5432     │    └──────────┘
                └──────────┘    └──────────┘
```

**Connection string:**
```
postgresql://user:pass@pgbouncer:6432/app?sslmode=disable
```

### 8.2. Application → Redis Cluster

```
┌──────────┐    ┌──────────┐
│  App Pod │───►│ Redis    │
│(K8s)     │    │ Cluster  │
└──────────┘    │(192.168..)│
                └──────────┘
```

**Client config (Python redis-py):**
```python
from redis.cluster import RedisCluster

rc = RedisCluster(
    startup_nodes=[
        {"host": "192.168.20.4", "port": "6379"},
        {"host": "192.168.20.5", "port": "6379"},
        {"host": "192.168.20.6", "port": "6379"},
    ],
    decode_responses=True,
    skip_full_coverage_check=True,
)
```

### 8.3. PostgreSQL → Kafka Connect → Kafka

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│PostgreSQL│───►│ Debezium │───►│ Kafka    │
│(WAL)     │    │ Connect  │    │(cdc-*)   │
└──────────┘    └──────────┘    └──────────┘
```

**Use cases:**
- Cache invalidation (CDC → Redis)
- Search index update (CDC → ElasticSearch)
- Analytics (CDC → ClickHouse)
- Audit log (CDC → S3)

### 8.4. Kafka → Consumers

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│ Kafka    │───►│ Consumer │───►│ Action   │
│(events)  │    │(app)     │    │          │
└──────────┘    └──────────┘    └──────────┘
```

**Consumer groups:**
| Group | Назначение | Топики |
|-------|-----------|--------|
| `cache-invalidator` | Инвалидация Redis | `cdc-users`, `cdc-orders` |
| `search-indexer` | Обновление ElasticSearch | `events`, `cdc-*` |
| `analytics` | Загрузка в ClickHouse | `events` |
| `notifications` | Отправка email/push | `events` |

---

## 9. Отказоустойчивость и DR

### 9.1. RPO и RTO по сервисам

| Сервис | RPO | RTO | Стратегия |
|--------|-----|-----|-----------|
| PostgreSQL | ~0 (WAL) | 15-30 сек | Patroni failover + WAL-G PITR |
| Redis | 1 час (RDB) | 2-5 мин | Cluster failover + RDB restore |
| Kafka | 0 (replication) | 30 сек | Replica promotion + ISR |
| VictoriaMetrics | 0 (HA) | 5 мин | Single-node, бэкап в R2 |

### 9.2. План аварийного восстановления

**Сценарий 1: Падение PostgreSQL master**
1. Patroni автоматически promote'ит replica (10-15 сек)
2. HAProxy переключает трафик (health check)
3. Keepalived перемещает VIP
4. Мониторинг: alert `PostgreSQLDown` → проверка вручную

**Сценарий 2: Потеря всего PostgreSQL кластера**
1. Развернуть новые ноды через Terraform
2. Восстановить из WAL-G бэкапа (PITR)
3. Перенастроить Patroni + Consul
4. Время восстановления: 15-30 мин

**Сценарий 3: Падение Redis master**
1. Redis Cluster автоматически failover'ит на replica
2. Application reconnect через клиентскую библиотеку
3. Время: 1-2 сек

**Сценарий 4: Потеря всего датацентра**
1. Восстановить Terraform в другом регионе
2. Восстановить PostgreSQL из WAL-G (R2)
3. Восстановить Redis из RDB (R2)
4. Восстановить Kafka из MirrorMaker 2 (репликация в другой регион)
5. RTO: 1-2 часа

---

## 10. Ресурсы и бюджет

### Текущие ресурсы (Timeweb Cloud)

| Сервис | Ноды | CPU | RAM | Диск | Стоимость/мес |
|--------|------|-----|-----|------|---------------|
| PostgreSQL | 3 | 2 | 4GB | 50GB | ~3000₽ |
| Bastion | 1 | 1 | 1GB | 15GB | ~500₽ |
| **Итого** | | | | | **~3500₽** |

### Планируемые ресурсы

| Сервис | Ноды | CPU | RAM | Диск | Стоимость/мес |
|--------|------|-----|-----|------|---------------|
| PostgreSQL | 3 | 2 | 4GB | 100GB | ~3000₽ |
| Redis Cluster | 6 | 1 | 2GB | 20GB | ~3000₽ |
| Kafka | 3 | 2 | 4GB | 200GB | ~3000₽ |
| Bastions (3) | 3 | 1 | 1GB | 15GB | ~1500₽ |
| R2 Storage | — | — | — | 500GB | ~500₽ |
| **Итого** | | | | | **~11000₽** |

---

## 11. Этапы внедрения

### Этап 1: WAL-G бэкапы (2-3 дня)
- [ ] Роль Ansible `wal_g`
- [ ] Бакет R2 `postgres-backups`
- [ ] Настройка `archive_command`
- [ ] Тестовое восстановление
- [ ] Алерты на бэкапы

### Этап 2: PgBouncer (1-2 дня)
- [ ] Роль Ansible `pgbouncer`
- [ ] Настройка пула (transaction mode)
- [ ] Мониторинг pgbouncer_exporter
- [ ] Нагрузочное тестирование

### Этап 3: Redis Cluster (3-5 дней)
- [ ] Terraform: VPC `192.168.20.0/24`, 6 нод, bastion
- [ ] Роль Ansible `redis_cluster`
- [ ] Настройка cluster (redis-cli --cluster create)
- [ ] Persistence (RDB + AOF)
- [ ] Бэкапы в R2
- [ ] redis_exporter → VictoriaMetrics
- [ ] Алерты

### Этап 4: Kafka Cluster (5-7 дней)
- [ ] Terraform: VPC `192.168.30.0/24`, 3 брокера, bastion
- [ ] Роль Ansible `kafka_cluster`
- [ ] KRaft mode (без ZooKeeper)
- [ ] Schema Registry
- [ ] Kafka Connect + Debezium (CDC)
- [ ] kafka_exporter → VictoriaMetrics
- [ ] Алерты

### Этап 5: Observability (3-4 дня)
- [ ] vmalert + Alertmanager
- [ ] Telegram/email нотификации
- [ ] Loki (логи)
- [ ] Дашборды (Grafana или VMUI)

### Этап 6: Интеграция и тестирование (3-5 дней)
- [ ] App → PgBouncer → PostgreSQL
- [ ] App → Redis Cluster
- [ ] PostgreSQL → Kafka Connect → Kafka
- [ ] Kafka → Consumers
- [ ] Нагрузочное тестирование
- [ ] DR-тестирование (восстановление из бэкапов)

---

*Документ составлен в апреле 2026. Все сети, IP и архитектурные решения — проектные*

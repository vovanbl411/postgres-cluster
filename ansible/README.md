# PostgreSQL HA Cluster (Patroni + Consul + HAProxy + Keepalived)

Ansible-плейбук для автоматизированного развертывания отказоустойчивого кластера PostgreSQL. Архитектура построена по принципу "Shared Nothing" с автоматическим Failover и единой точкой входа через Virtual IP (VIP).

## 🏛 Архитектура

Кластер состоит из 3-х узлов (нод), на каждом из которых развернут полный стек компонентов:

* **PostgreSQL 17**: Основная СУБД.
* **Patroni**: Обученный оркестратор. Управляет кластером PostgreSQL, выполняет автоматический Failover и следит за состоянием репликации.
* **Consul**: Distributed Configuration Store (DCS). Хранит метаданные кластера и обеспечивает Service Discovery. Запущен в режиме Server (bootstrap_expect=3).
* **HAProxy**: Балансировщик нагрузки. Обеспечивает маршрутизацию трафика:
  * **Port 5432** — Запись/Чтение (RW), маршрутизируется строго на текущего Лидера Patroni.
  * **Port 5433** — Только чтение (RO), балансируется между репликами.
* **Keepalived**: Управляет плавающим IP-адресом (VIP 192.168.10.100).

### ☁️ Особенности для Cloud-инфраструктуры

В публичных облаках (например, Timeweb Cloud) мультикаст-трафик часто блокируется на уровне сети. Поэтому Keepalived настроен на работу через Unicast.
Дополнительно реализована проверка состояния Patroni (vrrp_script опрашивает REST API Patroni). Это гарантирует, что VIP всегда "приземляется" на ту ноду, которая в данный момент является Лидером базы данных, исключая лишние сетевые прыжки (extra hops).

## 🛠 Структура проекта

* `ansible.cfg` — Базовые настройки Ansible (включен pipelining, отключена проверка ключей).
* `inventory.ini` — Описание хостов и настройка Bastion-узла для безопасного доступа.
* `site.yml` — Главный плейбук.
* **Roles**:
  * `common` — Установка базовых утилит, настройка Chrony и параметров sysctl (включая ip_nonlocal_bind=1).
  * `consul` — Установка и настройка Consul-агентов.
  * `postgres_patroni` — Установка PostgreSQL 17, Patroni, Python-зависимостей и инициализация кластера.
  * `haproxy` — Настройка балансировщика.
  * `keepalived` — Настройка VIP, Unicast-пиров и health-чеков для HAProxy и Patroni.

## 🚀 Быстрый старт

### 1. Подготовка

Убедитесь, что у вас установлен Ansible и есть SSH-доступ к целевым серверам. В текущей конфигурации используется прыжок через Bastion-хост.
Отредактируйте `inventory.ini` под вашу инфраструктуру:

```ini
[bastion]
bastion-host ansible_host=185.247.185.128
ansible_user=root

[postgres_nodes]
pg-node-1 ansible_host=192.168.10.6
pg-node-2 ansible_host=192.168.10.5
pg-node-3 ansible_host=192.168.10.4

[postgres_nodes:vars]
ansible_user=root
ansible_ssh_common_args='-o ProxyJump=root@185.247.185.128'
```

### 2. Настройка переменных

В роли `postgres_patroni` (файл `roles/postgres_patroni/defaults/main.yml`) задайте безопасные пароли для репликации и суперпользователя:
```yaml
replication_password: "your_secure_replication_password"
superuser_password: "your_secure_superuser_password"
postgres_version: "17"
```

*(Для production-окружений рекомендуется использовать Ansible Vault).*

В роли `keepalived` (шаблон `roles/keepalived/templates/keepalived.conf.j2`) убедитесь, что указан правильный интерфейс приватной сети (например, eth1) и свободный VIP-адрес:

```conf
virtual_ipaddress {
    192.168.10.100/32
}
```

### 3. Запуск деплоя

Запустите основной плейбук:

```bash
ansible-playbook -i inventory.ini site.yml
```

## 🔧 Администрирование кластера

Все команды управления кластером выполняются через утилиту `patronictl` на любой из нод.

### Просмотр состояния кластера:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

### Ручное переключение Лидера (Switchover):

```bash
patronictl -c /etc/patroni/patroni.yml switchover
```

### Перезагрузка ноды (без даунтайма кластера):

```bash
patronictl -c /etc/patroni/patroni.yml restart postgres-cluster <member_name>
```

### Проверка текущего владельца VIP:

```bash
ip addr show eth1 | grep 192.168.10.100
```

### Проверка состояния Consul:

```bash
consul members
```

## 📝 Обслуживание и мониторинг

### Логика работы Failover

1. **Детекция**: Если процесс PostgreSQL на Лидере падает, Patroni пытается его поднять. Если падает сама нода, её "ключ Лидера" в Consul истекает по TTL (30 сек).
2. **Выборы**: Остальные ноды Patroni видят, что Лидера нет, и пытаются захватить ключ в Consul. Нода с самым актуальным WAL (наименьшим лагом) становится новым Лидером.
3. **Переключение**:
   * Patroni на новом Лидере переводит PG в режим RW.
   * HAProxy на всех нодах видит статус 200 OK от нового Лидера и перенаправляет трафик.
   * Keepalived (если упала именно нода с VIP) переносит адрес 192.168.10.100 на следующую по приоритету ноду.

### Безопасность (Hardening)

В текущей конфигурации применены следующие меры:

* **Изоляция**: Весь трафик репликации и управления идет через приватную сеть 192.168.10.0/24.
* **Привилегии**: Сервисы Consul и Patroni работают от выделенных системных пользователей с ограниченными правами.

## 🔍 Директории и файлы конфигурации

* Конфигурация Patroni: `/etc/patroni/patroni.yml`
* Сервис Patroni: `/etc/systemd/system/patroni.service`
* Конфигурация HAProxy: `/etc/haproxy/haproxy.cfg`
* Конфигурация Keepalived: `/etc/keepalived/keepalived.conf`
* Конфигурация Consul: `/etc/consul.d/consul.hcl`

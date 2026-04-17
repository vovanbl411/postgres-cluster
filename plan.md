# Техническое задание: Отказоустойчивый PostgreSQL кластер (Patroni + Consul + Keepalived)

## 1. Цель проекта

Развернуть полностью автоматизированный, отказоустойчивый кластер PostgreSQL с использованием инфраструктурного подхода (IaC) и CI/CD пайплайна.

## 2. Стек технологий

 * Провайдер: Timeweb Cloud (3x Cloud VPS).
 * Infrastructure as Code: Terraform (провайдер twc).
 * State Backend: Cloudflare R2 (S3-compatible).
 * CI/CD: GitHub Actions (бесплатные раннеры).
 * Configuration Management: Ansible (написание собственных ролей).
 * База данных: PostgreSQL.
 * HA-менеджер: Patroni.
 * DCS (Distributed Configuration Store): Consul (режим сервера на всех нодах).
 * Балансировка и вход: HAProxy + Keepalived (один плавающий VIP).

## 3. Этапы реализации

### Этап 1: Инфраструктурный слой (Terraform)

1. Настройка Backend: Конфигурация terraform { backend "s3" { ... } } для Cloudflare R2.
 2. Ресурсы Timeweb:
    * 3 виртуальных сервера (рекомендуемый конфиг: от 2 ГБ RAM для стабильной работы Consul + PG).
    * Локальная сеть (VPC) для внутреннего трафика (репликация, Consul, опросы Patroni).
    * Настройка SSH-ключей для доступа Ansible.
 3. Outputs: Вывод IP-адресов серверов для динамического формирования инвентаря Ansible.

 ### Этап 2: Автоматизация (GitHub Actions)

1. Secrets: Добавление TWC_TOKEN, R2_ACCESS_KEY, R2_SECRET_KEY, SSH_PRIVATE_KEY в секреты репозитория.
2. Pipeline:
    * terraform plan при Pull Request.
    * terraform apply при пуше в main.
    * Запуск ansible-playbook после успешного развертывания инфраструктуры.

### Этап 3: Конфигурация системы (Ansible)

Разработка ролей:

 * common: Настройка репозиториев, установка базовых пакетов, настройка сети, системные лимиты (sysctl), NTP.
 * consul: Установка Consul, настройка кластера (3 сервера), TLS (опционально для практики), gossip-encryption.
 * postgres: Установка только бинарников PG и необходимых расширений.
 * patroni: Настройка patroni.yml, интеграция с Consul, создание systemd-юнита.
 * haproxy: Конфигурация бекендов с проверкой через Patroni REST API (порт 8008).
 * keepalived: Настройка VRRP-инстанса. Одна нода — MASTER (владелец VIP), остальные — BACKUP.

### Этап 4: Логика работы HA

 1. Consul выступает как «источник правды» о том, кто сейчас лидер.
 2. Patroni управляет жизненным циклом PG: если лидер падает, Patroni в Consul переписывает ключ лидера, и другая нода делает promote.
 3. HAProxy на каждой ноде опрашивает всех Patroni. Живым считается только тот бекенд, который отвечает 200 OK на запрос /master.
 4. Keepalived гарантирует, что даже если одна VM выключится целиком, VIP-адрес «переедет» на живую ноду, и приложение продолжит слать запросы на тот же IP.

## 4. План тестирования (Acceptance Criteria)

Чтобы считать проект успешным, нужно провести следующие тесты:

 * Deployment Test: Все роли отработали без ошибок, patronictl list показывает кластер из 3 нод (1 Leader, 2 Replicas).
 * Consul Check: consul members показывает 3 живых ноды.
 * VIP Check: Пинг VIP-адреса проходит. Подключение psql -h <VIP> ведет на текущего лидера.
 * Failover Test:
    * kill -9 процесса Postgres на мастере -> автоматический выбор нового лидера за 10-15 секунд.
    * Выключение всей VM мастера через панель Timeweb -> VIP переезжает, HAProxy переключает трафик.
 * Switchover Test: Плановая передача роли лидера через patronictl switchover без потери данных.

## 5. Дополнительные идеи (на будущее)

 * Добавление мониторинга (Prometheus + Grafana + Postgres Exporter).
 * Настройка бэкапов (например, с помощью WAL-G в тот же Cloudflare R2).

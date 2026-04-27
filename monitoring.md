# Архитектура гибридной инфраструктуры: Локальный K8s + Cloud DB

## 1. Обзор проекта
Цель — обеспечить безопасную и стабильную связность между локальным кластером Kubernetes и облачной базой данных PostgreSQL в Timeweb через зашифрованный туннель WireGuard, минимизируя вмешательство в стабильность Control Plane.

## 2. Сетевая топология

### Сводная таблица адресации

| Сеть | Назначение | Примечание |
|------|------------|------------|
| 10.0.0.0/24 | Локальная сеть кластера | Физический L2/L3 сегмент |
| 10.244.0.0/16 | Pod CIDR (Cilium) | Внутрикластерная сеть подов |
| 10.200.0.0/24 | WireGuard Tunnel | Транзитная сеть (Bastion <-> Controller) |
| 192.168.10.0/24 | Cloud VPC (Timeweb) | Сеть размещения PostgreSQL |

### Логика маршрутизации (Вариант "A")
Для обеспечения стабильности etcd и kube-apiserver на controller-0 принято решение отказаться от Cilium Egress Gateway в пользу классической маршрутизации:

1. Worker Nodes: Используют controller-0 (10.0.0.10) как шлюз для доступа к сети 192.168.10.0/24.
2. Controller-0: Выполняет форвардинг пакетов в интерфейс wg0 и делает маскарадинг.
3. Bastion: Принимает пакеты из туннеля и доставляет их до PostgreSQL через локальный интерфейс VPC.

## 3. Настройка сетевых правил (NAT)

### Controller-0 (Gateway)
Чтобы не нарушить связность hostNetwork компонентов Kubernetes, маскарадинг строго ограничен исходящим интерфейсом туннеля:

```bash
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
```

### Bastion (Cloud Side)
Маскарадинг для трафика из кластера при выходе в сеть базы данных:

```bash
iptables -t nat -A POSTROUTING -s 10.200.0.0/24 -o eth1 -j MASQUERADE
```

## 4. Автоматизация (IaC)

### Terraform
* Provisioning: Создание виртуалки для мониторинга, настройка дисков и сетевых интерфейсов.

### Ansible
Стек разделен на независимые роли для гибкого управления:

1. wireguard: Установка и настройка туннеля на controller-0 и bastion.
2. vpn_routes_worker: Создание systemd-юнита на воркерах для управления статическим маршрутом до облачной сети.
3. monitoring_server: Развертывание VictoriaMetrics (Single Node) и Grafana на выделенной VM.
4. exporters_setup: Установка node_exporter, vmagent и wireguard_exporter на все узлы инфраструктуры.

## 5. Мониторинг и Observability

### Стек
* VictoriaMetrics: Хранение временных рядов.
* vmagent: Сбор метрик по модели Push (устойчивость к разрывам туннеля).
* Grafana: Визуализация.

### Ключевые метрики для алертинга
* WireGuard Connectivity: last_handshake_seconds (алерт, если > 180с).
* Database Availability: TCP-чек порта 5432 через туннель (Blackbox Exporter).
* Cilium Health: Дропы пакетов в eBPF-плане и состояние эндпоинтов.
* Etcd Stability: Задержки fsync на контроллере.

> **Note**: При любых изменениях в конфигурации WireGuard на контроллере, всегда проверять доступность API-сервера локально (`curl -k https://localhost:6443/healthz`).

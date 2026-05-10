# Анализ конфигурации Terraform для Postgres HA кластера в Timeweb Cloud

Полный разбор всех файлов в директории `terraform/` построчно, с объяснением что, как и почему сделано.

---

## 🔍 Общая структура проекта

```
terraform/
├── backend.tf          # Конфигурация бэкенда для хранения стейта
├── providers.tf        # Декларация провайдеров и их версии
├── variables.tf        # Входные переменные проекта
├── main.tf             # Основная логика развертывания
├── outputs.tf          # Выходные значения после применения
├── setup.sh.tpl        # Шаблон cloud-init для коннектора
├── cloud-init.yaml.tpl.back  # Резервная копия старого шаблона
└── modules/
    └── twc_node/       # Модуль для создания нод кластера
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── providers.tf
```

---

## 📄 Файл: `backend.tf`

Конфигурирует хранилище состояния Terraform в S3 совместимом хранилище:

```hcl
terraform {
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "postgres-cluster/terraform.tfstate"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
```

✅ **Что происходит и почему:**
1.  `bucket = "terraform-state"` - Имя бакета где будет храниться стейт
2.  `key = "postgres-cluster/terraform.tfstate"` - Полный путь к файлу стейта внутри бакета
3.  Все `skip_*` параметры отключают проверки которые есть у AWS S3, но отсутствуют у большинства совместимых S3 хранилищ (в том числе у Timeweb Cloud Objects)
4.  `use_path_style = true` - Использование старого стиля URL (`s3.host/bucket`) вместо виртуального хостинга (`bucket.s3.host`) - обязательный параметр для большинства S3 провайдеров кроме AWS
5.  В конфигурации закомменчен `endpoint` и `region` - они подставляются динамически через переменные окружения в CI/CD пайплайне, чтобы не хардкодить креденшелы

---

## 📄 Файл: `providers.tf`

Определяет какие провайдеры будут использоваться и их версии:

```hcl
terraform {
  required_providers {
    twc = {
      source = "tf.timeweb.cloud/timeweb-cloud/timeweb-cloud"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40.0"
    }
  }
  required_version = ">= 1.5"
}
```

✅ **Что происходит:**
1.  `twc` - официальный провайдер Timeweb Cloud для управления ресурсами через их API
2.  `cloudflare` - провайдер для управления сервисами Cloudflare (в данном случае Zero Trust туннели)
3.  Заблокирована мажорная версия Cloudflare на 4.x, чтобы избежать ломающих изменений
4.  Требуется Terraform версии минимум 1.5 - это первая версия с поддержкой большинства современных фич используемых в конфигурации

```hcl
provider "twc" {
  token = var.timeweb_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

✅ **Почему так:**
- Оба провайдера получают токены через входные переменные, что позволяет безопасно передавать их из переменных окружения или секретов CI/CD без хардкода

---

## 📄 Файл: `variables.tf`

Все входные переменные которые нужно передать для работы конфигурации:

| Переменная               | Тип    | Описание                                                                 |
|--------------------------|--------|--------------------------------------------------------------------------|
| `timeweb_token`          | string | API токен от Timeweb Cloud, чувствительный, скрывается в выводе         |
| `cloudflare_api_token`   | string | API токен от Cloudflare, чувствительный                                 |
| `location`               | string | Регион развертывания, по умолчанию ru-1 (Москва)                        |
| `instance_count`         | number | Количество нод в кластере, по умолчанию 3 (минимальное кол-во для HA)   |
| `ssh_public_key`         | string | Публичный SSH ключ который будет добавлен на все серверы                 |
| `cloudflare_account_id`  | string | ID аккаунта Cloudflare                                                   |
| `cloudflare_zone_id`     | string | ID доменной зоны в Cloudflare                                            |
| `tunnel_domain`          | string | Домен на котором будет доступен SSH бастион через туннель                |

✅ **Важно:** 3 ноды это стандартное минимальное количество для отказоустойчивых кластеров с рафт консенсусом (как у Patroni, Consul, Etcd)

---

## 📄 Файл: `main.tf`

Основная логика развертывания инфраструктуры. Разбит на логические блоки.

### 1. Data Sources (Получение существующих данных)

```hcl
data "twc_os" "debian" {
  name    = "debian"
  version = "13"
}
```
✅ Получает ID образа Debian 13 из каталога образов Timeweb. Преимущество перед хардкодом ID - всегда будет актуальный образ.

```hcl
data "twc_configurator" "base_conf" {
  location = var.location
}
```
✅ Получает конфигуратор аппаратных ресурсов для указанного региона. Обязательный параметр при создании серверов в Timeweb.

```hcl
data "twc_image" "connector" {
  name = "debian-13-cloudflared"
} 
```
✅ Получает ID уже готового образа с предустановленным cloudflared для коннектора.

### 2. Общие ресурсы

```hcl
resource "twc_project" "postgres_cluster" {
  name        = "Postgres-HA-Project"
  description = "Cluster with Patroni, Consul и Keepalived"
}
```
✅ Создает отдельный проект в Timeweb Cloud для всей инфраструктуры кластера. Позволяет группировать все ресурсы вместе.

```hcl
resource "twc_vpc" "cluster_net" {
  name      = "pg-cluster-vnet"
  location  = var.location
  subnet_v4 = "192.168.10.0/24"
}
```
✅ Создает приватную изолированную сеть для кластера. Все ноды и коннектор будут находиться в этой сети, общаться между собой по локальным адресам. Выбрана подсеть /24 - достаточно адресов для будущего масштабирования.

```hcl
resource "twc_ssh_key" "ansible_key" {
  name = "ansible-key"
  body = var.ssh_public_key
}
```
✅ Добавляет SSH ключ в аккаунт Timeweb, который потом будет автоматически прописан на всех создаваемых серверах.

### 3. Вызов модуля для нод кластера

```hcl
module "postgres_nodes" {
  source = "./modules/twc_node"

  node_count      = var.instance_count
  name_prefix     = "pg-node"

  os_id           = data.twc_os.debian.id
  configurator_id = data.twc_configurator.base_conf.id
  project_id      = twc_project.postgres_cluster.id
  ssh_key_id      = twc_ssh_key.ansible_key.id
  vpc_id          = twc_vpc.cluster_net.id
}
```
✅ Вызывает локальный модуль который создает указанное количество идентичных серверов для нод Postgres кластера.
✅ Все параметры передаются из верхнего уровня, модуль не имеет собственных хардкодов.

### 4. Cloudflare Zero Trust туннель (Бастион)

```hcl
resource "random_password" "tunnel_secret" {
  length = 64
}
```
✅ Генерирует криптостойкий случайный секрет длиной 64 символа для аутентификации туннеля.

```hcl
resource "cloudflare_zero_trust_tunnel_cloudflared" "ssh_tunnel" {
  account_id = var.cloudflare_account_id
  name       = "timeweb_bastion_tunnel"
  secret     = base64encode(random_password.tunnel_secret.result)
}
```
✅ Создает туннель Cloudflare Tunnel. Это современный заменит классическому VPN и SSH бастиону с белым IP. Сервер сам устанавливает исходящее соединение с Cloudflare, без необходимости открывать входящие порты и публичного IP.

```hcl
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "ssh_config" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.ssh_tunnel.id

  config {
    ingress_rule {
      hostname = var.tunnel_domain
      service  = "ssh://localhost:22"
    }

    ingress_rule {
      service  = "http_status:404"
    }
  }
}
```
✅ Конфигурирует правила маршрутизации для туннеля:
- Когда кто-то обращается на указанный домен - трафик перенаправляется на локальный порт 22 (SSH) сервера
- Все остальные запросы возвращают 404

```hcl
resource "cloudflare_record" "tunnel_dns" {
  zone_id   = var.cloudflare_zone_id
  name    = split(".", var.tunnel_domain)[0]
  content   = "${cloudflare_zero_trust_tunnel_cloudflared.ssh_tunnel.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
```
✅ Создает DNS запись которая указывает на туннель Cloudflare.

### 5. Сервер коннектора (Бастион)

```hcl
resource "twc_server" "connector" {
  name = "cloudflare-connector"
  image_id = data.twc_image.connector.id
  project_id = twc_project.postgres_cluster.id
  ssh_keys_ids = [twc_ssh_key.ansible_key.id]

  configuration {
    configurator_id = data.twc_configurator.base_conf.id
    cpu = 1
    ram = 1024
    disk = 15360
  }

  local_network {
    id = twc_vpc.cluster_net.id
  }

  cloud_init = templatefile("${path.module}/setup.sh.tpl", {
    tunnel_token = cloudflare_zero_trust_tunnel_cloudflared.ssh_tunnel.tunnel_token
  })
}
```
✅ Создает минимальный сервер (1 ядро, 1ГБ RAM, 15ГБ диск) который выступает в роли бастиона:
- Находится в той же приватной сети что и ноды кластера
- НЕ имеет публичного IP адреса
- Подключается к Cloudflare через туннель
- Через cloud-init автоматически устанавливает и запускает агент туннеля с токеном

```hcl
resource "twc_server_ip" "connector_ip" {
  source_server_id = twc_server.connector.id
  type             = "ipv4"
}
```
✅ Опционально создает публичный IP для коннектора (в данный момент не используется, т.к. доступ идет через туннель)

---

## 📄 Файл: `setup.sh.tpl`

Шаблон скрипта который выполняется при первом запуске сервера коннектора:

```bash
exec > /var/log/bastion-setup.log 2>&1
set -x
```
✅ Весь вывод скрипта пишется в лог файл для отладки, включается режим трассировки команд.

```bash
fallocate -l 512M /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```
✅ Создает и подключает файл подкачки 512МБ. На маленьких серверах с 1ГБ RAM это практически обязательно, чтобы избежать OOM киллеров при малейшей нагрузке.

```bash
/usr/local/bin/cloudflared service install ${tunnel_token}
```
✅ Устанавливает cloudflared как системный сервис и автоматически подключает его к созданному туннелю.

---

## 📄 Модуль: `modules/twc_node/`

Переиспользуемый модуль для создания идентичных серверов нод кластера.

### `modules/twc_node/main.tf`

```hcl
resource "twc_server" "node" {
  count = var.node_count
```
✅ Параметр `count` создает столько серверов сколько указано в переменной `node_count` (по умолчанию 3)

```hcl
  name         = "${var.name_prefix}-${count.index + 1}"
```
✅ Имена серверов получаются вида: `pg-node-1`, `pg-node-2`, `pg-node-3`

✅ Остальные параметры (ОС, сеть, SSH ключ) передаются из верхнего уровня, модуль полностью независимый и конфигурируемый.

### `modules/twc_node/outputs.tf`

```hcl
output "private_ips" {
  value = [for s in twc_server.node : try([for n in s.networks : n.ips[0].ip if n.type == "local"][0],"IP не найден")]
}
```
✅ Возвращает список приватных IP адресов всех созданных нод. Именно эти адреса потом будут использоваться Ansible для конфигурации самого кластера Postgres.

⚠️ **Замечание:** Выходной параметр `public_ips` сейчас возвращает пустой массив. Это сделано намеренно, так как ноды кластера НЕ должны иметь публичных IP адресов для повышения безопасности. Доступ к ним только через бастион коннектор.

---

## 📄 Файл: `outputs.tf`

Значения которые будут выведены после успешного применения конфигурации:

```hcl
output "node_public_ips" {
  value       = module.postgres_nodes.public_ips
  description = "Public IPs from the twc_node module"
}
```
✅ Пустой массив, как и ожидалось.

```hcl
output "node_private_ips" {
  value       = module.postgres_nodes.private_ips
  description = "Private IPs from the twc_node module"
}
```
✅ Самый важный вывод - список приватных IP нод кластера. Именно их потом нужно будет передать в Ansible для установки и конфигурации Patroni, Consul и Postgres.

```hcl
output "bastion_tunnel_token" {
  value = cloudflare_zero_trust_tunnel_cloudflared.ssh_tunnel.tunnel_token
  description = "Токен для подключения cloudflared"
  sensitive = true
}
```
✅ Токен туннеля помечен как чувствительный, поэтому Terraform не будет его показывать в открытом виде в выводе.

---

## 🧠 Архитектурные решения и безопасность

✅ **Плюсы реализации:**
1.  ❌ Нет публичных IP у нод кластера - значительно повышает безопасность
2.  🔐 Доступ только через Cloudflare Tunnel который аутентифицирует пользователей
3.  🧩 Все ресурсы сгруппированы в отдельный проект
4.  🔄 Все параметризировано, нет хардкодов
5.  📦 Используется модуль для нод, легко изменить количество серверов
6.  📝 Все секреты помечены как чувствительные
7.  🔀 Приватная сеть изолирована от внешнего мира

⚠️ **Что можно улучшить:**
1.  В модуле twc_node output public_ips сейчас всегда пустой - нужно либо исправить либо удалить
2.  Сейчас коннектор имеет лишний созданный публичный IP который не используется
3.  Нет правил фаервола - по умолчанию в Timeweb все порты открыты
4.  Нет группы безопасности для ограничения трафика внутри VPC

---

## 🚀 Что дальше происходит

Эта Terraform конфигурация **только создает пустые серверы и инфраструктуру**. Сам кластер Postgres с Patroni, Consul, Keepalived и всем остальным потом конфигурируется отдельно с помощью Ansible на этих уже созданных серверах.

# Ресурс SSH-ключа
resource "twc_ssh_key" "main" {
  name = "vladimir-key"
  body = var.ssh_public_key
}

# Проект
resource "twc_project" "postgres_cluster" {
  name        = "Postgres-HA-Project"
  description = "Cluster with Patroni, Consul and Keepalived"
}

# Приватная сеть
resource "twc_vpc" "cluster_net" {
  name        = "pg-cluster-vnet"
  description = "Internal network for database traffic"
  location    = var.location
  subnet_v4   = "192.168.10.0/24"
}

# Образ ОС
data "twc_os" "debian" {
  name    = "debian"
  version = "13"
}

# Конфигуратор
data "twc_configurator" "base_conf" {
  location = var.location
}

# Ресурсы серверов
resource "twc_server" "pg_nodes" {
  count = var.instance_count

  name       = "pg-node-${count.index + 1}"
  os_id      = data.twc_os.debian.id
  project_id = twc_project.postgres_cluster.id

  # Используем ID созданного выше ресурса
  ssh_keys_ids = [twc_ssh_key.main.id]

  configuration {
    configurator_id = data.twc_configurator.base_conf.id
    cpu             = 2
    ram             = 2048
    disk            = 20480
  }

  local_network {
    id = twc_vpc.cluster_net.id
  }
}

# Создаем проект
resource "twc_project" "postgres_cluster" {
  name        = "Postgres-HA-Project"
  description = "Cluster with Patroni, Consul and Keepalived"
}

# Приватная сеть
resource "twc_vpc" "cluster_net" {
  name        = "pg-cluster-vnet"
  description = "Internal network for database traffic"
  location    = var.region
}

# Образ ОС и конфигурация нод
data "twc_os" "debian" {
  name    = "debian"
  version = "13" # Традиционный выбор для стабильной БД
}

data "twc_configurator" "base_conf" {
  location = var.region
  # Выбираем подходящий тариф (минимум 2GB RAM для Consul + PG)
  cpu      = 2
  ram      = 2048
  disk     = 20480
}

resource "twc_server" "pg_nodes" {
  count = var.instance_count

  name         = "pg-node-${count.index + 1}"
  os_id        = data.twc_os.debian.id
  configurator_id = data.twc_configurator.base_conf.id
  project_id   = twc_project.postgres_cluster.id

  ssh_keys = [var.ssh_public_key]

  # Подключаем к VPC
  local_network {
    id = twc_vpc.cluster_net.id
  }
}

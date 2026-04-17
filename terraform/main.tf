# Общие Data Sources
data "twc_os" "debian" {
  name    = "debian"
  version = "13"
}

data "twc_configurator" "base_conf" {
  location = var.location
}

# Общие ресурсы (Сеть, Проект, SSH Ключ)
resource "twc_project" "postgres_cluster" {
  name        = "Postgres-HA-Project"
  description = "Cluster with Patroni, Consul and Keepalived"
}

resource "twc_vpc" "cluster_net" {
  name      = "pg-cluster-vnet"
  location  = var.location
  subnet_v4 = "192.168.10.0/24"
}

resource "twc_ssh_key" "ansible_key" {
  name = "ansible-key"
  body = var.ssh_public_key
}

# ВЫЗОВ МОДУЛЯ
module "postgres_nodes" {
  source = "./modules/twc_node"

  # Передаем переменные внутрь модуля
  node_count      = var.instance_count
  name_prefix     = "pg-node"

  os_id           = data.twc_os.debian.id
  configurator_id = data.twc_configurator.base_conf.id
  project_id      = twc_project.postgres_cluster.id
  ssh_key_id      = twc_ssh_key.ansible_key.id
  vpc_id          = twc_vpc.cluster_net.id
}

resource "twc_server" "bastion" {
  name         = "bastion-gateway"
  os_id        = data.twc_os.debian.id
  project_id   = twc_project.postgres_cluster.id
  ssh_keys_ids = [twc_ssh_key.ansible_key.id]

  configuration {
    configurator_id = data.twc_configurator.base_conf.id
    cpu             = 1
    ram             = 1024
    disk            = 15360
  }

  local_network {
    id = twc_vpc.cluster_net.id
    ip = "192.168.10.10"
  }
}

  resource "twc_server_ip" "bastion_ip" {
    source_server_id = twc_server.bastion.id
    type             = "ipv4"
  }
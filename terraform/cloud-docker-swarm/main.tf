# Общие Data Sources
data "twc_os" "debian" {
  name    = "debian"
  version = "13"
}

data "twc_configurator" "base_conf" {
  location = var.location
}

data "twc_image" "connector" {
  name = "debian-13-cloudflared"
} 

# Общие ресурсы (Сеть, Проект, SSH Ключ)
resource "twc_project" "docker-swarm" {
  name        = "Docker-Swarm-Project"
  description = "Docker Swarm cluster"
}

resource "twc_vpc" "cluster_net" {
  name      = "docker-swarm-cluster-vnet"
  location  = var.location
  subnet_v4 = "192.168.10.0/24"
}

resource "twc_ssh_key" "ansible_key" {
  name = "ansible-key"
  body = var.ssh_public_key
}

# ВЫЗОВ МОДУЛЯ
module "swarm_nodes" {
  source = "./../cloud/modules/twc_node"

  # Передаем переменные внутрь модуля
  node_count      = var.instance_count
  name_prefix     = "swarm-node"

  os_id           = data.twc_os.debian.id
  configurator_id = data.twc_configurator.base_conf.id
  project_id      = twc_project.docker-swarm.id
  ssh_key_id      = twc_ssh_key.ansible_key.id
  vpc_id          = twc_vpc.cluster_net.id
}

  resource "twc_server" "connector" {
    name = "cloudflare-connector"
    image_id = data.twc_image.connector.id
    project_id = twc_project.docker-swarm.id
    ssh_keys_ids = [twc_ssh_key.ansible_key.id]

    configuration {
      configurator_id = data.twc_configurator.base_conf.id
      cpu = 1
      ram = 1024
      disk = 15360
    }

    local_network {
      id = twc_vpc.cluster_net.id
      ip = "192.168.10.7"
    }
  }

  resource "twc_server_ip" "connector_ip" {
    source_server_id = twc_server.connector.id
    type             = "ipv4"
  }

  resource "local_file" "ansible_inventory" {
    content              = templatefile("${path.module}/../templates/inventory_swarm.tmpl", {
      swarm_ips          = module.swarm_nodes.private_ips
      bastion_ip         = twc_server_ip.connector_ip.ip
      bastion_private_ip = "192.168.10.7"
    })

    filename        = "${path.module}/../../ansible/inventories/swarm.ini"
    file_permission = "0644"
  }
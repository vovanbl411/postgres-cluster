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

  resource "random_password" "tunnel_secret" {
    length = 64
  }

  resource "cloudflare_zero_trust_tunnel_cloudflared" "ssh_tunnel" {
    account_id = var.cloudflare_account_id
    name       = "timeweb_bastion_tunnel"
    secret     = base64encode(random_password.tunnel_secret.result)
  }

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

  resource "cloudflare_record" "tunnel_dns" {
    zone_id   = var.cloudflare_zone_id
    name    = split(".", var.tunnel_domain)[0]
    content   = "${cloudflare_zero_trust_tunnel_cloudflared.ssh_tunnel.id}.cfargotunnel.com"
    type    = "CNAME"
    proxied = true
  }

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

  resource "twc_server_ip" "connector_ip" {
    source_server_id = twc_server.connector.id
    type             = "ipv4"
  }
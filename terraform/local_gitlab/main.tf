resource "libvirt_network" "local_net" {
  name      = var.network_name
  mode      = "nat"
  domain    = "local"
  addresses = ["10.0.0.0/24"]

  dhcp {
    enabled = true
  }

  dns {
    enabled    = true
    local_only = false
  }

  autostart = true
}

# Свой базовый образ (чтобы не зависеть от тома в папке local)
resource "libvirt_volume" "gitlab_base" {
  name   = "gitlab-base-image"
  pool   = "default"
  source = var.base_image_path
  format = "qcow2"
}

# Поднимаем ноду через готовый модуль(Gitlab Master)
module "gitlab_master" {
  source = "../local_k8s/modules/libvirt_node"

  name           = "gitlab-master-0"
  vcpu           = 4
  memory         = 8192
  ip             = "10.0.0.80"
  mac            = "52:54:00:00:00:80"
  base_volume_id = libvirt_volume.gitlab_base.id
  network_name   = var.network_name
  
  cloudinit_template_path = "${path.module}/../templates/cloud_init_local.cfg"
  ssh_public_key          = file(var.ssh_public_key_path)
}


# Gitlab runner
module "gitlab_runner" {
  source = "../local_k8s/modules/libvirt_node"

  name           = "gitlab-runner-0"
  vcpu           = 2
  memory         = 4096
  ip             = "10.0.0.81"
  mac            = "52:54:00:00:00:81"
  base_volume_id = libvirt_volume.gitlab_base.id
  network_name   = var.network_name

  cloudinit_template_path = "${path.module}/../templates/cloud_init_local.cfg"
  ssh_public_key          = file(var.ssh_public_key_path)
}

# Генерируем отдельный инвентарь для gitlab
resource "local_file" "ansible_inventory_gitlab" {
  content = templatefile("${path.module}/../templates/gitlab.tmpl", {
    nodes = {
      "gitlab-master-0" = {
        ip   = module.gitlab_master.node_ip
        role = "gitlab_master"
      }
      "gitlab-runner-0" = {
        ip   = module.gitlab_runner.node_ip
        role = "gitlab_runner"
      }
    }
  })
  filename = "${path.module}/../../ansible/inventories/gitlab.ini"
  file_permission = "0644"
}
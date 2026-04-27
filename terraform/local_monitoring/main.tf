
# Свой базовый образ (чтобы не зависеть от тома в папке local)
resource "libvirt_volume" "monitoring_base" {
  name   = "monitoring-base-image"
  pool   = "default"
  source = var.base_image_path
  format = "qcow2"
}

# Поднимаем ноду через готовый модуль
module "monitoring_node" {
  source = "../local_k8s/modules/libvirt_node"

  name           = "monitoring-0"
  vcpu           = 2
  memory         = 4096
  ip             = "10.0.0.30"
  mac            = "52:54:00:00:00:30"
  base_volume_id = libvirt_volume.monitoring_base.id
  network_name   = var.network_name
  
  cloudinit_template_path = "${path.module}/../templates/cloud_init_local.cfg"
  ssh_public_key          = file(var.ssh_public_key_path)
}

# Генерируем отдельный инвентарь для мониторинга
resource "local_file" "ansible_inventory_monitoring" {
  content = templatefile("${path.module}/../templates/inventory_local.tmpl", {
    nodes = {
      "monitoring-0" = {
        ip   = module.monitoring_node.node_ip
        role = "monitoring"
      }
    }
  })
  filename = "${path.module}/../../ansible/inventories/monitoring.ini"
}
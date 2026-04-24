# Общий базовый образ
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-24-04-base"
  pool  = "default"
  source = var.base_image_path
  format = "qcow2"
}

# Используем модуль через for_each
module "k8s_nodes" {
  source   = "./modules/libvirt_node"
  for_each = var.k8s_nodes

  name           = each.key
  vcpu           = each.value.vcpu
  memory         = each.value.memory
  ip             = each.value.ip
  mac            = each.value.mac
  base_volume_id = libvirt_volume.ubuntu_base.id
  network_name   = libvirt_network.k8s_network.name
  
  # Путь к общему шаблону
  cloudinit_template_path = "${path.module}/../templates/cloud_init.cfg"
  ssh_public_key          = file(var.ssh_public_key_path)
}

# Генерация инвентаря теперь обращается к выходам модуля
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/../templates/inventory.tmpl", {
    nodes = {
      for name, config in var.k8s_nodes : name => {
        ip = module.k8s_nodes[name].node_ip
        role = config.role
      }
    }
  })
  filename = "${path.module}/../../ansible/inventories/local.ini"
}
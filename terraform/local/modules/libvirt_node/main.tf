resource "libvirt_volume" "disk" {
  name           = "${var.name}-disk.qcow2"
  pool           = var.pool
  base_volume_id = var.base_volume_id
  size           = var.disk_size
}

resource "libvirt_cloudinit_disk" "commoninit" {
  name       = "${var.name}-init.iso"
  pool       = var.pool
  user_data  = templatefile(var.cloudinit_template_path, {
    ssh_key  = var.ssh_public_key
    hostname = var.name
  })

    meta_data = jsonencode({
    instance-id    = var.name
    local-hostname = var.name
  })
}

resource "libvirt_domain" "node" {
  name   = var.name
  memory = var.memory
  vcpu   = var.vcpu
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  network_interface {
    network_name = var.network_name
    addresses    = [var.ip]
    mac          = var.mac
  }

  # Оптимизация: проброс CPU для лучшей производительности
  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.disk.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
  }
}
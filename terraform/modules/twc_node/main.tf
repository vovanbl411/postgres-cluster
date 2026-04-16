resource "twc_server" "node" {
  count = var.node_count

  name         = "${var.name_prefix}-${count.index + 1}"
  os_id        = var.os_id
  project_id   = var.project_id
  ssh_keys_ids = [var.ssh_key_id]

  configuration {
    configurator_id = var.configurator_id
    cpu             = 1
    ram             = 1024
    disk            = 15360
  }

  local_network {
    id = var.vpc_id
  }
}

resource "twc_server_ip" "ip" {
  count            = var.node_count
  source_server_id = twc_server.node[count.index].id
  type             = "ipv4"
}

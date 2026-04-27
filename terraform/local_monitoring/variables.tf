variable "base_image_path" {
  type    = string
  default = "/var/lib/libvirt/images/noble-server-cloudimg-amd64.img"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "network_name" {
  type    = string
  default = "k8s-net"
}
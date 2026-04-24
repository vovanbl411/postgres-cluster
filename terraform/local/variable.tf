variable "base_image_path" {
  description = "Path to the Ubuntu Cloud Image"
  type        = string
  default     = "/var/lib/libvirt/images/noble-server-cloudimg-amd64.img"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "k8s_nodes" {
  description = "Map of Kubernetes nodes to create"
  type = map(object({
    ip     = string
    mac    = string
    vcpu   = number
    memory = number
    role   = string
  }))
}

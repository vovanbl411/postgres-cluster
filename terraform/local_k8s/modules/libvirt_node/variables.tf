variable "name" { 
  type = string 
}

variable "vcpu" { 
  type = number 
}

variable "memory" { 
  type = number 
}

variable "ip" { 
  type = string 
}

variable "mac" { 
  type = string 
}


variable "base_volume_id" { 
  type = string 
}

variable "network_name" { 
  type = string 
}

variable "cloudinit_template_path" { 
  type = string 
}

variable "ssh_public_key" { 
  type = string 
}

variable "pool" {
  type    = string
  default = "default"
}

variable "disk_size" {
  type    = number
  default = 21474836480 # 20GB в байтах, если провайдер требует байты
}
terraform {
  
  required_version = ">= 0.13"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "=0.7.6"
    }
    
    local = {
      source  = "hashicorp/local"
      version = ">=2.8.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

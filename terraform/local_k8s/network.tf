resource "libvirt_network" "k8s_network" {
  name = "k8s-net"
  mode = "nat"

  domain = "k8s.local"


  addresses = ["10.0.0.0/24"]
  autostart = true
  
  dns {
    enabled = true
    local_only = true
  }
}

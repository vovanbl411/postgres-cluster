output "id" {
  description = "The ID of the created libvirt domain"
  value       = libvirt_domain.node.id
}

output "name" {
  description = "The name of the node"
  value       = libvirt_domain.node.name
}

output "node_ip" {
  description = "The IP address assigned to the node"
  # Берем первый адрес из первого интерфейса
  value       = libvirt_domain.node.network_interface[0].addresses[0]
}
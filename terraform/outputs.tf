output "node_public_ips" {
  value       = twc_server.pg_nodes[*].networks[0].ips[0].ip
  description = "Public IPs for Ansible SSH connection"
}

output "node_private_ips" {
  value       = twc_server.pg_nodes[*].local_network[0].ip
  description = "Private IPs for VPC internal communication"
}

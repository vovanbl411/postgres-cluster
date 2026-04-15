output "node_public_ips" {
  value       = twc_server_ip.pg_ips[*].ip
  description = "Public IPs for Ansible SSH connection"
}

output "node_private_ips" {
  value       = [for s in twc_server.pg_nodes : s.local_network[0].ip]
  description = "Private IPs for VPC internal communication"
}

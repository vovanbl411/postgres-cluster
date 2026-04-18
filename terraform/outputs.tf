output "node_public_ips" {
  value       = module.postgres_nodes.public_ips
  description = "Public IPs from the twc_node module"
}

output "node_private_ips" {
  value       = module.postgres_nodes.private_ips
  description = "Private IPs from the twc_node module"
}

output "bastion_tunnel_token" {
  value = cloudflare_zero_trust_tunnel_cloudflared.ssh_tunnel.tunnel_token
  description = "Токен для подключения cloudflared"
  sensitive = true
}
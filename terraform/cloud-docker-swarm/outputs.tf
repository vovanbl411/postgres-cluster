output "swarm_private_ips" {
  description = "Приватные IP нод Docker Swarm"
  value       = module.swarm_nodes.private_ips
}

output "connector_public_ip" {
  description = "Публичный IP Cloudflare Connector"
  value       = twc_server_ip.connector_ip.ip
}

output "vpc_id" {
  value = twc_vpc.cluster_net.id
}

output "project_id" {
  value = twc_project.docker-swarm.id
}
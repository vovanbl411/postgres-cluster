output "public_ips" {
  value = twc_server_ip.ip[*].ip
}

output "private_ips" {
  value = [for s in twc_server.node : s.local_network[0].ip]
}

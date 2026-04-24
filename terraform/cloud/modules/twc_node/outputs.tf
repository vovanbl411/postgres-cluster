output "public_ips" {
  value = []
}

output "private_ips" {
  value = [for s in twc_server.node : try([for n in s.networks : n.ips[0].ip if n.type == "local"][0],"IP не найден")]
}

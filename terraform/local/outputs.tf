output "k8s_nodes_summary" {
  description = "Summary of provisioned Kubernetes nodes"
  value = {
    for k, v in module.k8s_nodes : k => {
      id = v.id
      ip = v.node_ip
    }
  }
}
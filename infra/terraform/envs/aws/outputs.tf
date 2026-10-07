output "url" {
  value = "http://${var.host_ip}/"
}

output "containers" {
  value = module.stack.containers
}

output "grafana_tunnel" {
  value = "ssh -i ~/.ssh/adpulse_aws -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 ubuntu@${var.host_ip}"
}

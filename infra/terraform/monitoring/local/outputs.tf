output "prometheus_networks" {
  value = module.monitoring.prometheus_networks
}

output "urls" {
  value = {
    grafana      = "http://127.0.0.1:3000"
    prometheus   = "http://127.0.0.1:9090"
    alertmanager = "http://127.0.0.1:9093"
  }
}

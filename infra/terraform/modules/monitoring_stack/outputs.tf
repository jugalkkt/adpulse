output "network" {
  value = docker_network.monitoring.name
}

output "textfile_volume" {
  value = docker_volume.textfile.name
}

output "prometheus_networks" {
  value = sort(concat([docker_network.monitoring.name], var.env_networks))
}

output "network" {
  description = "Docker network of this env (Ansible attaches API replicas to it)."
  value       = docker_network.env.name
}

output "subnet" {
  value = var.subnet
}

output "nginx_url" {
  value = "http://${var.nginx_host_ip == "0.0.0.0" ? "<public-ip>" : var.nginx_host_ip}:${var.nginx_host_port}"
}

output "chaos_enabled" {
  value = var.chaos_enabled
}

output "containers" {
  value = sort([
    docker_container.postgres.name,
    docker_container.redis.name,
    docker_container.toxiproxy.name,
    docker_container.nginx.name,
    docker_container.backup_agent.name,
    docker_container.postgres_exporter.name,
    docker_container.redis_exporter.name,
    docker_container.loadgen.name,
  ])
}

output "env" {
  value = local.env
}

output "network" {
  value = module.stack.network
}

output "nginx_url" {
  value = module.stack.nginx_url
}

output "chaos_enabled" {
  value = module.stack.chaos_enabled
}

output "containers" {
  value = module.stack.containers
}

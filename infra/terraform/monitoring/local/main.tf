# Local monitoring stack, shared by staging and prod.
#   make monitoring   (passes env_networks = the env networks that exist now)

module "monitoring" {
  source = "../../modules/monitoring_stack"

  repo_root              = abspath("${path.root}/../../../..")
  env_networks           = var.env_networks
  images                 = var.images
  grafana_admin_password = var.grafana_admin_password
  enable_healer          = var.enable_healer
}
